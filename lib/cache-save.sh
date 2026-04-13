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
# Even under the action's mutex, the script does a post-acquire re-check: if
# a sibling runner finished saving the same key while we waited on the lock,
# the entry will already exist and we exit cleanly rather than rsync-ing on
# top of it. Without the re-check, the final `mv` would NOT fail — POSIX mv
# nests the staging dir inside the existing entry, leaving a corrupted layout
# (real files at the top level, a ghost .tmp-<key>-<pid>/ subdir alongside
# them). The mutex serializes the rsync+mv pair; the re-check makes the
# serialized second caller a clean no-op instead of a corrupting rename.
#
# Atomic publication: rsync to a temp dir under entries/, then mv into
# place. Concurrent readers either see the old (or no) entry or the
# fully-written new one — never a partial directory.
set -e

script_dir=$(
    CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=lib/cache-common.sh
. "${script_dir}/cache-common.sh"

path_to_cache="$1"
cache_key="$2"
cache_dir="$3"


if [ -z "$path_to_cache" ] || [ -z "$cache_key" ] || [ -z "$cache_dir" ]; then
    printf '::error::cache-save: path, key, and cache-dir must not be empty\n'
    exit 1
fi

entries_dir="${cache_dir}/entries"

start_time=$(date +%s)

encoded_key=$(encode_key "$cache_key")

if [ ! -d "$path_to_cache" ]; then
    printf '::notice::Cache save skipped — source path does not exist: %s\n' "$path_to_cache"
    exit 0
fi

# After acquiring the mutex, re-check whether another waiter already populated
# the entry. If so, exit cleanly — the cache is consistent and we have no work
# to do. This check is load-bearing: it is the reason waiting on local-mutex is
# safe. Without it, a second caller waking up after the first released the lock
# would rsync into its own ".tmp-<encoded_key>-$$" staging dir (the $$ disambiguates
# tmp paths so they never literally collide), then the final `mv` would silently
# NEST that staging dir inside the existing entry — POSIX `mv src dest` where
# dest is an existing directory moves src to dest/basename(src) rather than
# failing. The result is a corrupted entry whose real files live at
# entries/<encoded-key>/ shadowed by a ghost subdirectory
# entries/<encoded-key>/.tmp-<encoded-key>-<pid>/ that the EXIT-trap rm -rf can't
# reach because $tmp_entry no longer names a real path after the mv.
if [ -d "${entries_dir}/${encoded_key}" ]; then
    printf '::debug::Cache entry already exists, skipping save: %s\n' "$cache_key"
    exit 0
fi

mkdir -p "$entries_dir"
tmp_entry="${entries_dir}/.tmp-${encoded_key}-$$"

cleanup_tmp() {
    rm -rf "$tmp_entry" 2>/dev/null || true
}
trap cleanup_tmp EXIT INT TERM

printf '::debug::Saving to local cache: %s\n' "$cache_key"
# Exclude the restore marker so a prefix-hit restore followed by save on the
# same path (restore → install → save, the canonical README pattern) doesn't
# carry the previous entry's name into the new entry on disk.
rsync -a --exclude="${MARKER_NAME}" "${path_to_cache}/" "${tmp_entry}/"
printf '%s' "$cache_key" > "${tmp_entry}/${ENTRY_KEY_NAME}"
mv "$tmp_entry" "${entries_dir}/${encoded_key}"

elapsed=$(( $(date +%s) - start_time ))
size=$(du -sh "${entries_dir}/${encoded_key}" 2>/dev/null | cut -f1 || printf '?')
file_count=$(find "${entries_dir}/${encoded_key}" -type f | wc -l | tr -d ' ')
printf '::notice::Cache saved: %s (%s files, %s in %ds)\n' "$cache_key" "$file_count" "$size" "$elapsed"
printf '::debug::Entry path: %s\n' "${entries_dir}/${encoded_key}"
append_summary "- **local-cache** \`${cache_key}\` → 💾 Saved (${size}, ${elapsed}s)"
