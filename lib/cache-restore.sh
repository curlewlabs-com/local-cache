#!/bin/sh
# Called by the composite action's restore step to avoid network round-trips
# to GitHub's cache servers.
#
# Usage: cache-restore.sh [flags] <path> <key> <cache-dir> [restore-keys]
#
# Flags:
#   --check: Only verify if the target already possesses the expected key.
#            If current, it emits metadata and signals 'skip-lock=true'.
#
# Writes to $GITHUB_OUTPUT:
#   cache-hit=true|false
#   cache-matched-key=<key>
#   skip-lock=true          (--check mode only, when target is current)
#
# Writes to $GITHUB_ENV (when set):
#   LOCAL_CACHE_HIT=true|false
#   LOCAL_CACHE_MATCHED_KEY=<key>
#
# On a cache hit, rsync copies the entry to the target path.  The value
# of the local cache is avoiding repeated network downloads — the copy
# itself is a plain local operation (a few seconds for ~1.8 GB).
#
# A marker file (.local-cache-restore) in the target directory records
# which cache key was last restored.  When the marker matches the
# current key, the restore is skipped entirely — constant-time work.  When it
# doesn't match (or is missing, e.g. from a v1 hard-link restore), the
# target is cleaned and re-synced from the local cache.
set -eu

script_dir=$(
    CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=lib/cache-common.sh
. "${script_dir}/cache-common.sh"

check_only="false"
# Phase 2 restores the exact entry Phase 1 already resolved (--restore <name>),
# so the per-key lock it holds names that entry's own key — the same lock gc
# takes to evict it. Empty in Phase 1 and for direct callers, which resolve
# inline.
restore_entry=""
# ${1:-}, not $1: under `set -u` a bare positional on a missing arg aborts with
# "unbound variable" before the empty-string checks below can emit the
# caller-facing error. The guards keep those checks the single failure path.
if [ "${1:-}" = "--check" ]; then
    check_only="true"
    shift
elif [ "${1:-}" = "--restore" ]; then
    shift
    restore_entry="${1:-}"
    if [ -z "$restore_entry" ]; then
        printf '::error::cache-restore: --restore requires an entry name\n' >&2
        exit 1
    fi
    shift
fi

path_to_cache="${1:-}"
cache_key="${2:-}"
cache_dir="${3:-}"
restore_keys="${4:-}"

if [ -z "$path_to_cache" ] || [ -z "$cache_key" ] || [ -z "$cache_dir" ]; then
    printf '::error::cache-restore: path, key, and cache-dir must not be empty\n'
    exit 1
fi

# cache-restore.sh does an unconditional `rm -rf "$path_to_cache"` on a
# stale-marker re-sync (see do_restore below). A misconfigured caller
# passing `path: /` or `path: $HOME` must not be able to wipe the
# machine, so reject targets that would destroy the system root or a
# known runner workspace before any filesystem side effects. The check
# runs up-front so it also fires in --check mode, which keeps the error
# shape consistent across Phase 1 and Phase 2 and catches bad paths
# before Phase 2 even acquires the mutex.
check_not_restore_ancestor() {
    target_norm="$1"
    danger_label="$2"
    danger_raw="$3"
    [ -z "$danger_raw" ] && return 0
    # Normalize trailing slashes on the danger path to match target_norm.
    danger_norm="$danger_raw"
    while [ "${danger_norm%/}" != "$danger_norm" ]; do
        danger_norm="${danger_norm%/}"
    done
    [ -z "$danger_norm" ] && danger_norm="/"
    case "$danger_norm" in
        "$target_norm"|"$target_norm"/*)
            printf '::error::cache-restore: refusing to restore to %s — rm -rf would delete %s (%s)\n' "$path_to_cache" "$danger_label" "$danger_raw" >&2
            exit 2
            ;;
    esac
}

# Whitespace-only paths never resolve to a sensible target; they usually
# indicate an expansion failure in the caller's workflow YAML.
case "$path_to_cache" in
    *[![:space:]]*) ;;
    *)
        printf '::error::cache-restore: path must not be whitespace-only\n' >&2
        exit 2
        ;;
esac

# Absolute paths only; relative paths resolve against this script's CWD,
# which varies between Phase 1 and Phase 2 (Phase 2 runs inside
# local-mutex's working directory), and is therefore unsafe to trust.
case "$path_to_cache" in
    /*) ;;
    *)
        printf '::error::cache-restore: path must be absolute: %s\n' "$path_to_cache" >&2
        exit 2
        ;;
esac

# Trivially unsafe paths — caught even when HOME/RUNNER_WORKSPACE/
# GITHUB_WORKSPACE are all unset (e.g. local smoke-testing).
case "$path_to_cache" in
    /|/.|/..)
        printf '::error::cache-restore: refusing to restore to %s — rm -rf would affect the system root\n' "$path_to_cache" >&2
        exit 2
        ;;
esac

# Normalize trailing slashes on the target so "/foo/" and "/foo" hit the
# ancestor check identically. Preserve root ("/" must stay "/").
path_to_cache_norm="$path_to_cache"
while [ "${path_to_cache_norm%/}" != "$path_to_cache_norm" ]; do
    path_to_cache_norm="${path_to_cache_norm%/}"
done
[ -z "$path_to_cache_norm" ] && path_to_cache_norm="/"

check_not_restore_ancestor "$path_to_cache_norm" HOME "${HOME:-}"
check_not_restore_ancestor "$path_to_cache_norm" RUNNER_WORKSPACE "${RUNNER_WORKSPACE:-}"
check_not_restore_ancestor "$path_to_cache_norm" GITHUB_WORKSPACE "${GITHUB_WORKSPACE:-}"

# GITHUB_OUTPUT must exist before any output is written. Outside Actions it is
# unset; a missing path with set -e would abort the script on the first write.
if [ -z "${GITHUB_OUTPUT:-}" ]; then
    GITHUB_OUTPUT=$(mktemp)
    printf '::debug::GITHUB_OUTPUT not set, writing outputs to temp file %s\n' "$GITHUB_OUTPUT"
fi

entries_dir="${cache_dir}/entries"
start_time=$(date +%s)

read_entry_key() {
    entry_path="$1"
    if [ -f "${entry_path}/${ENTRY_KEY_NAME}" ]; then
        cat "${entry_path}/${ENTRY_KEY_NAME}"
        return
    fi

    # Legacy v2 entries predate ENTRY_KEY_NAME, so the original raw key is not
    # recoverable for prefix matches. Fall back to the directory name.
    basename "$entry_path"
}

# Check whether the target already has the expected content from a
# previous v2 restore.  Returns 0 (true) if the marker matches.
is_current() {
    marker="${path_to_cache}/${MARKER_NAME}"
    [ -f "$marker" ] && [ "$(cat "$marker")" = "${MARKER_VERSION}:$1" ]
}

# Stamp the entry's last-use time so an external LRU sweep can evict by
# genuine recency of use. We bump the mtime of the entry's metadata file
# (.local-cache-key), NOT the entry directory: prefix/restore-keys
# resolution sorts candidates by directory mtime (`ls -dt`), so touching the
# directory would silently retarget selection from most-recently-saved to
# most-recently-used. Touching a file inside the directory leaves the
# directory's own mtime untouched (only adding/removing entries changes it),
# keeping the two signals separate — directory mtime = last write, metadata
# mtime = last use. Best-effort: a read-only store, or a legacy pre-encoding
# entry that predates the metadata file, must not fail an otherwise-good
# restore.
mark_used() {
    entry_meta="$1/${ENTRY_KEY_NAME}"
    [ -f "$entry_meta" ] || return 0
    touch -- "$entry_meta" 2>/dev/null \
        || printf '::debug::mark_used: could not touch %s (read-only store?)\n' "$entry_meta"
}

# Record this restore's target so cache-gc.sh can reclaim the per-runner copy
# once the entry goes cold. Records live in a parallel targets/<encoded-key>/
# tree (a sibling of entries/), NOT inside the entry — writing into the entry
# would bump its directory mtime, which prefix/restore-keys resolution sorts on.
# One file per target, named by the target-path hash: concurrent restores of
# the same key to different runner targets write different files, so no lock is
# needed even on the constant-time skip path. Content is the absolute target;
# the file's mtime is this restore's time. Best-effort — a read-only store must
# not fail an otherwise-good restore.
record_target() {
    # Record the LEXICALLY-NORMALIZED path (see normalize_path). gc locks
    # cache-target-<recorded-path> and rm's the recorded path; the restore steps
    # lock the same normalized string (action.yml normalizes inputs.path before
    # the lock), so two spellings of one physical target (a trailing slash, //,
    # /./) can't split the per-target lock and let gc race a live restore.
    rt_norm=$(normalize_path "$path_to_cache")
    rt_dir="${cache_dir}/${TARGETS_DIR_NAME}/$(basename "$1")"
    mkdir -p "$rt_dir" 2>/dev/null || return 0
    rt_file="${rt_dir}/$(sha256_hex "$rt_norm")"
    printf '%s' "$rt_norm" > "$rt_file" 2>/dev/null \
        || printf '::debug::record_target: could not write %s (read-only store?)\n' "$rt_file"
}

# Emit the miss outputs. Used both on a genuine miss and when the entry Phase 1
# resolved was evicted before Phase 2 could lock it — a clean miss beats copying
# a half-deleted source. Leaves the target untouched, matching a cold-start miss.
emit_miss() {
    em_elapsed=$(( $(date +%s) - start_time ))
    printf '::notice::Cache miss: %s\n' "$cache_key"
    printf '::debug::No match found for key or any restore-keys prefix\n'
    append_summary "- **local-cache** \`${cache_key}\` → ❌ Miss (${em_elapsed}s)"
    printf 'cache-hit=false\n' >> "$GITHUB_OUTPUT"
    printf 'cache-matched-key=\n' >> "$GITHUB_OUTPUT"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'LOCAL_CACHE_HIT=false\nLOCAL_CACHE_MATCHED_KEY=\n' >> "$GITHUB_ENV"
    fi
}

do_restore() {
    entry_path="$1"
    matched_key="$2"
    is_exact="$3"

    # If a previous v2 restore left a marker matching this key, the
    # target already has the right content — skip the copy entirely.
    if is_current "$matched_key"; then
        elapsed=$(( $(date +%s) - start_time ))
        printf '::debug::Target is current (marker matches) — skipping restore\n'
        if [ "$is_exact" = "true" ]; then
            printf 'cache-hit=true\n' >> "$GITHUB_OUTPUT"
            printf '::notice::Cache hit (exact, skipped): %s (%ds)\n' "$matched_key" "$elapsed"
            append_summary "- **local-cache** \`${matched_key}\` → ✅ Hit (skipped, ${elapsed}s)"
        else
            printf 'cache-hit=false\n' >> "$GITHUB_OUTPUT"
            printf '::notice::Cache hit (prefix, skipped): %s (%ds)\n' "$matched_key" "$elapsed"
            append_summary "- **local-cache** \`${matched_key}\` → ⚠️ Prefix hit (skipped, ${elapsed}s)"
        fi
        printf 'cache-matched-key=%s\n' "$matched_key" >> "$GITHUB_OUTPUT"

        if [ -n "${GITHUB_ENV:-}" ]; then
            printf 'LOCAL_CACHE_HIT=%s\nLOCAL_CACHE_MATCHED_KEY=%s\n' "$is_exact" "$matched_key" >> "$GITHUB_ENV"
        fi

        if [ "$check_only" = "true" ]; then
            printf 'skip-lock=true\n' >> "$GITHUB_OUTPUT"
        fi
        mark_used "$entry_path"
        record_target "$entry_path"
        return
    fi

    # In check-only mode, if we aren't current, we stop here and let the 
    # serialized step take over.
    if [ "$check_only" = "true" ]; then
        return
    fi

    # Target is stale, from v1, or doesn't exist — start fresh.
    # NOTE: concurrent restores to the *same* target path are unsupported.
    # Each runner must have its own path value (e.g. runner.tool_cache).
    rm -rf "$path_to_cache"
    mkdir -p "$path_to_cache"
    rsync -a \
        --exclude="${MARKER_NAME}" \
        --exclude="${ENTRY_KEY_NAME}" \
        "$entry_path/" \
        "$path_to_cache/"

    # Write the v2 marker so future restores with the same key skip.
    printf '%s:%s' "$MARKER_VERSION" "$matched_key" > "${path_to_cache}/${MARKER_NAME}"

    elapsed=$(( $(date +%s) - start_time ))
    size=$(du -sh "$path_to_cache" 2>/dev/null | cut -f1 || printf '?')
    file_count=$(find "$path_to_cache" -type f | wc -l | tr -d ' ')
    printf '::debug::Restored %s files (%s) from: %s\n' "$file_count" "$size" "$entry_path"
    printf '::debug::Cache dir: %s\n' "$cache_dir"
    if [ "$is_exact" = "true" ]; then
        printf 'cache-hit=true\n' >> "$GITHUB_OUTPUT"
        printf '::notice::Cache hit (exact): %s (%s in %ds)\n' "$matched_key" "$size" "$elapsed"
        append_summary "- **local-cache** \`${matched_key}\` → ✅ Hit (${size}, ${elapsed}s)"
    else
        printf 'cache-hit=false\n' >> "$GITHUB_OUTPUT"
        printf '::notice::Cache hit (prefix): %s (%s in %ds)\n' "$matched_key" "$size" "$elapsed"
        append_summary "- **local-cache** \`${matched_key}\` → ⚠️ Prefix hit (${size}, ${elapsed}s)"
    fi
    printf 'cache-matched-key=%s\n' "$matched_key" >> "$GITHUB_OUTPUT"

    if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'LOCAL_CACHE_HIT=%s\nLOCAL_CACHE_MATCHED_KEY=%s\n' "$is_exact" "$matched_key" >> "$GITHUB_ENV"
    fi

    mark_used "$entry_path"
    record_target "$entry_path"
}

encoded_key=$(encode_key "$cache_key")
legacy_safe_key=$(printf '%s' "$cache_key" | tr -c 'a-zA-Z0-9._-' '_')

if [ "${RUNNER_DEBUG:-}" = "1" ]; then
    printf '::debug::Checking local cache — key: %s, entries-dir: %s\n' "$cache_key" "$entries_dir"
fi

# Phase 2: restore the exact entry Phase 1 resolved and is locked on. Re-running
# the resolution here could land on a DIFFERENT entry (a prefix hit's newest
# match can change between the phases), which the held cache-save-<matched-key>
# lock would not cover — reopening the eviction race the lock exists to close. An
# exact/legacy name carries the requested key; any other name is a prefix hit
# carrying the entry's own stored key. If the entry was evicted in the Phase 1→2
# window it is simply gone, so miss cleanly.
if [ -n "$restore_entry" ]; then
    entry_path="${entries_dir}/${restore_entry}"
    if [ ! -d "$entry_path" ]; then
        emit_miss
        exit 0
    fi
    if [ "$restore_entry" = "$encoded_key" ] || [ "$restore_entry" = "$legacy_safe_key" ]; then
        do_restore "$entry_path" "$cache_key" "true"
    else
        do_restore "$entry_path" "$(read_entry_key "$entry_path")" "false"
    fi
    exit 0
fi

# Resolve the matching entry once: exact, then legacy-safe name, then the newest
# restore-keys prefix match. matched_key is the key the marker and gc lock on —
# the requested key for an exact/legacy hit, the entry's own stored key for a
# prefix hit (gc skips legacy entries, which have no stored key).
matched_name=""
matched_exact="false"
matched_key=""
if [ -d "${entries_dir}/${encoded_key}" ]; then
    matched_name="$encoded_key"
    matched_exact="true"
    matched_key="$cache_key"
elif [ -d "${entries_dir}/${legacy_safe_key}" ]; then
    matched_name="$legacy_safe_key"
    matched_exact="true"
    matched_key="$cache_key"
elif [ -n "$restore_keys" ]; then
    tmpfile=$(mktemp)
    printf '%s\n' "$restore_keys" > "$tmpfile"
    while IFS= read -r prefix; do
        [ -z "$prefix" ] && continue
        [ -n "$matched_name" ] && break
        # SHA-256 directory names are not prefix-preserving, so we scan
        # all entries and compare stored raw keys.  ls -dt sorts newest
        # first.  Entry names are k-<hex> or legacy [a-zA-Z0-9._-]+ —
        # no whitespace — so word-splitting in the for-loop is safe.
        # shellcheck disable=SC2012,SC2015
        for entry_name in $(cd "${entries_dir}" 2>/dev/null && ls -dt -- * 2>/dev/null || true); do
            case "$entry_name" in
                .|..|.tmp-*) continue ;;
            esac
            entry_key=$(read_entry_key "${entries_dir}/${entry_name}")
            case "$entry_key" in
                "${prefix}"*)
                    matched_name="$entry_name"
                    matched_key="$entry_key"
                    break
                    ;;
            esac
        done
    done < "$tmpfile"
    rm -f "$tmpfile"
fi

if [ -z "$matched_name" ]; then
    # Genuine miss. In --check mode this ends Phase 1: Phase 2 is skipped when
    # matched-key is empty, so the miss is surfaced here rather than there.
    emit_miss
    exit 0
fi

if [ "$check_only" = "true" ]; then
    # Hand the resolved entry to Phase 2 so its per-key lock names this entry's
    # own key — the same lock gc takes to evict it.
    printf 'matched-name=%s\n' "$matched_name" >> "$GITHUB_OUTPUT"
    printf 'matched-key=%s\n' "$matched_key" >> "$GITHUB_OUTPUT"
fi

# In --check mode do_restore emits skip-lock + hit outputs only if the target is
# already current; otherwise it returns and Phase 2 does the copy under the lock.
do_restore "${entries_dir}/${matched_name}" "$matched_key" "$matched_exact"
exit 0
