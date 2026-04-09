#!/bin/sh
# Called by the composite action's restore step to avoid network round-trips
# to GitHub's cache servers.
#
# Usage: cache-restore.sh <path> <key> <cache-dir> [restore-keys]
#
# Writes to $GITHUB_OUTPUT:
#   cache-hit=true|false
#   cache-matched-key=<key>
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

MARKER_NAME=".local-cache-restore"
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

path_to_cache="$1"
cache_key="$2"
cache_dir="$3"
restore_keys="${4:-}"


if [ -z "$path_to_cache" ] || [ -z "$cache_key" ] || [ -z "$cache_dir" ]; then
    printf '::error::cache-restore: path, key, and cache-dir must not be empty\n'
    exit 1
fi

# GITHUB_OUTPUT must exist before any output is written. Outside Actions it is
# unset; a missing path with set -e would abort the script on the first write.
if [ -z "${GITHUB_OUTPUT:-}" ]; then
    GITHUB_OUTPUT=$(mktemp)
    printf '::debug::GITHUB_OUTPUT not set, writing outputs to temp file %s\n' "$GITHUB_OUTPUT"
fi

entries_dir="${cache_dir}/entries"

start_time=$(date +%s)

# SYNC: must match lib/cache-save.sh:sanitize_key exactly.
sanitize_key() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_'
}

# SYNC: must match lib/cache-save.sh:append_summary exactly.
append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
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
        return
    fi

    # Target is stale, from v1, or doesn't exist — start fresh.
    # NOTE: concurrent restores to the *same* target path are unsupported.
    # Each runner must have its own path value (e.g. runner.tool_cache).
    rm -rf "$path_to_cache"
    mkdir -p "$path_to_cache"
    rsync -a "$entry_path/" "$path_to_cache/"

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
}

safe_key=$(sanitize_key "$cache_key")
# Reject keys that sanitize to "." or ".." — these resolve to the entries directory
# itself or its parent, causing rsync to leak all cached entries.
case "$safe_key" in
    .|..) printf '::error::cache-restore: key must not be "." or ".."\n'; exit 1 ;;
esac

# Only count entries when debug logging is actually on — a production restore
# that hits the marker-skip happy path must be constant-time work, and the
# entries dir can hold enough directories that `find | wc -l` is a real cost.
if [ "${RUNNER_DEBUG:-}" = "1" ]; then
    entry_count=$(find "${entries_dir}/" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ' || printf '0')
    printf '::debug::Checking local cache — key: %s, entries: %s\n' "$cache_key" "$entry_count"
fi

if [ -d "${entries_dir}/${safe_key}" ]; then
    do_restore "${entries_dir}/${safe_key}" "$cache_key" "true"
    exit 0
fi

if [ -n "$restore_keys" ]; then
    found_match=""
    tmpfile=$(mktemp)
    printf '%s\n' "$restore_keys" > "$tmpfile"
    while IFS= read -r prefix; do
        [ -z "$prefix" ] && continue
        [ -n "$found_match" ] && break
        safe_prefix=$(sanitize_key "$prefix")
        # SC2012: keys are sanitized to [a-zA-Z0-9._-] so filenames are safe.
        # SC2015: || true applies only to cd failing; ls|head always succeeds.
        # -- prevents keys starting with "-" from being interpreted as ls flags.
        # shellcheck disable=SC2012,SC2015
        match=$(cd "${entries_dir}" 2>/dev/null && ls -dt -- "${safe_prefix}"* 2>/dev/null | head -1 || true)
        # Reject staging dirs (.tmp-*) and dot-traversal paths (., ..) —
        # a prefix starting with "." could match in-progress temp entries.
        case "$match" in
            .|..|.tmp-*) match="" ;;
        esac
        if [ -n "$match" ]; then
            found_match="$match"
        fi
    done < "$tmpfile"
    rm -f "$tmpfile"

    if [ -n "$found_match" ]; then
        # matched_key is the sanitized directory name, not the original key
        # with special characters — the original is not recoverable after
        # sanitization. Callers should treat this as an opaque identifier.
        do_restore "${entries_dir}/${found_match}" "$found_match" "false"
        exit 0
    fi
fi

elapsed=$(( $(date +%s) - start_time ))
printf '::notice::Cache miss: %s\n' "$cache_key"
printf '::debug::No match found for key or any restore-keys prefix\n'
append_summary "- **local-cache** \`${cache_key}\` → ❌ Miss (${elapsed}s)"
printf 'cache-hit=false\n' >> "$GITHUB_OUTPUT"
printf 'cache-matched-key=\n' >> "$GITHUB_OUTPUT"
