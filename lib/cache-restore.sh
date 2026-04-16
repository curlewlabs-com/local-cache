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
set -e

script_dir=$(
    CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=lib/cache-common.sh
. "${script_dir}/cache-common.sh"

# Marker format version. Bumped when the on-disk layout of either the marker
# file or the cache entries changes in a backward-incompatible way (e.g. v1
# used hard links; v2 uses full rsync copies). The marker content is
# "${MARKER_VERSION}:<matched-key>", where <matched-key> is the same value
# the action emits as cache-matched-key — the caller's raw (unsanitized) key
# on an exact hit, or the resolved on-disk entry name on a prefix hit. A
# mismatch triggers a clean re-sync. Referenced by literal in
# .github/workflows/ci.yml marker tests — keep those literals in sync if you
# bump this.
MARKER_VERSION="v2"

check_only="false"
if [ "$1" = "--check" ]; then
    check_only="true"
    shift
fi

path_to_cache="$1"
cache_key="$2"
cache_dir="$3"
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
}

encoded_key=$(encode_key "$cache_key")
legacy_safe_key=$(printf '%s' "$cache_key" | tr -c 'a-zA-Z0-9._-' '_')

if [ "${RUNNER_DEBUG:-}" = "1" ]; then
    printf '::debug::Checking local cache — key: %s, entries-dir: %s\n' "$cache_key" "$entries_dir"
fi

if [ -d "${entries_dir}/${encoded_key}" ]; then
    do_restore "${entries_dir}/${encoded_key}" "$cache_key" "true"
    # If do_restore returned success in check_only mode (meaning skip-lock=true), we exit.
    exit 0
fi

if [ -d "${entries_dir}/${legacy_safe_key}" ]; then
    do_restore "${entries_dir}/${legacy_safe_key}" "$cache_key" "true"
    exit 0
fi

if [ -n "$restore_keys" ]; then
    found_match=""
    tmpfile=$(mktemp)
    printf '%s\n' "$restore_keys" > "$tmpfile"
    while IFS= read -r prefix; do
        [ -z "$prefix" ] && continue
        [ -n "$found_match" ] && break
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
                    found_match="$entry_name"
                    break
                    ;;
            esac
        done
    done < "$tmpfile"
    rm -f "$tmpfile"

    if [ -n "$found_match" ]; then
        do_restore "${entries_dir}/${found_match}" "$(read_entry_key "${entries_dir}/${found_match}")" "false"
        exit 0
    fi
fi

# Miss path (only reached if check_only failed or no match found)
if [ "$check_only" = "true" ]; then
    exit 0
fi

elapsed=$(( $(date +%s) - start_time ))
printf '::notice::Cache miss: %s\n' "$cache_key"
printf '::debug::No match found for key or any restore-keys prefix\n'
append_summary "- **local-cache** \`${cache_key}\` → ❌ Miss (${elapsed}s)"
printf 'cache-hit=false\n' >> "$GITHUB_OUTPUT"
printf 'cache-matched-key=\n' >> "$GITHUB_OUTPUT"

if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'LOCAL_CACHE_HIT=false\nLOCAL_CACHE_MATCHED_KEY=\n' >> "$GITHUB_ENV"
fi
