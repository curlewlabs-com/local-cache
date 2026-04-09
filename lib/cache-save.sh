#!/bin/sh
# Called by the composite action's save step to persist a directory to local
# disk, avoiding network round-trips to GitHub's cache servers.
#
# Usage: cache-save.sh <path> <key> <cache-dir>
#
# Concurrency: this script is NOT safe to call directly under contention.
# The composite action wraps it in curlewlabs-com/local-mutex (per-key
# lock), and the action is the supported entry point for callers that may
# run in parallel. Direct invocation is fine for single-process callers
# (e.g. CI fixtures setting up state for downstream tests).
#
# Even under the action's mutex, the script does a post-acquire re-check:
# if a sibling runner finished saving the same key while we waited on the
# lock, the entry will already exist and we exit cleanly rather than
# rsync-ing on top of it. mv would refuse the rename otherwise.
#
# Atomic publication: rsync to a temp dir under entries/, then mv into
# place. Concurrent readers either see the old (or no) entry or the
# fully-written new one — never a partial directory.
set -e

# SYNC: must match lib/cache-restore.sh:MARKER_NAME exactly.
MARKER_NAME=".local-cache-restore"

path_to_cache="$1"
cache_key="$2"
cache_dir="$3"


if [ -z "$path_to_cache" ] || [ -z "$cache_key" ] || [ -z "$cache_dir" ]; then
    printf '::error::cache-save: path, key, and cache-dir must not be empty\n'
    exit 1
fi

entries_dir="${cache_dir}/entries"

start_time=$(date +%s)

# SYNC: must match lib/cache-restore.sh:sanitize_key exactly.
sanitize_key() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_'
}

# SYNC: must match lib/cache-restore.sh:append_summary exactly.
append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}

safe_key=$(sanitize_key "$cache_key")
# Reject keys that sanitize to "." or ".." — these would resolve to the entries
# directory itself or its parent rather than a named entry.
case "$safe_key" in
    .|..) printf '::error::cache-save: key must not be "." or ".."\n'; exit 1 ;;
esac

if [ ! -d "$path_to_cache" ]; then
    printf '::notice::Cache save skipped — source path does not exist: %s\n' "$path_to_cache"
    exit 0
fi

# After acquiring the mutex, re-check whether another waiter already populated
# the entry. If so, exit cleanly — the cache is consistent and we have no work
# to do. This check is load-bearing: it is the reason waiting on local-mutex is
# safe, because without it two callers waiting on the same lock would both try
# to rsync on top of each other once the lock released.
if [ -d "${entries_dir}/${safe_key}" ]; then
    printf '::debug::Cache entry already exists, skipping save: %s\n' "$cache_key"
    exit 0
fi

mkdir -p "$entries_dir"
tmp_entry="${entries_dir}/.tmp-${safe_key}-$$"

cleanup_tmp() {
    rm -rf "$tmp_entry" 2>/dev/null || true
}
trap cleanup_tmp EXIT INT TERM

printf '::debug::Saving to local cache: %s\n' "$cache_key"
# Exclude the restore marker so a prefix-hit restore followed by save on the
# same path (restore → install → save, the canonical README pattern) doesn't
# carry the previous entry's name into the new entry on disk.
rsync -a --exclude="${MARKER_NAME}" "${path_to_cache}/" "${tmp_entry}/"
mv "$tmp_entry" "${entries_dir}/${safe_key}"

elapsed=$(( $(date +%s) - start_time ))
size=$(du -sh "${entries_dir}/${safe_key}" 2>/dev/null | cut -f1 || printf '?')
file_count=$(find "${entries_dir}/${safe_key}" -type f | wc -l | tr -d ' ')
printf '::notice::Cache saved: %s (%s files, %s in %ds)\n' "$cache_key" "$file_count" "$size" "$elapsed"
printf '::debug::Entry path: %s\n' "${entries_dir}/${safe_key}"
append_summary "- **local-cache** \`${cache_key}\` → 💾 Saved (${size}, ${elapsed}s)"
