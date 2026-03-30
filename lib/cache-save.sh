#!/bin/sh
# Save a directory to the local disk cache.
#
# Usage: cache-save.sh <path> <key> <cache-dir>
#
# Uses an atomic rename (rsync to temp dir, then mv) so concurrent readers
# never observe a partial cache entry. Uses mkdir-based advisory locking
# (POSIX-atomic on all filesystems) so concurrent writers are safe.
#
# Stale lock recovery: if the lock-holder PID is no longer alive (e.g. killed
# by OOM killer or machine reboot), the lock is cleared and acquisition is
# retried once rather than skipping the save permanently.
set -e

path_to_cache="$1"
cache_key="$2"
cache_dir="$3"

entries_dir="${cache_dir}/entries"
locks_dir="${cache_dir}/.locks"

sanitize_key() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_'
}

safe_key=$(sanitize_key "$cache_key")

if [ ! -d "$path_to_cache" ]; then
    printf 'Source path does not exist, skipping save: %s\n' "$path_to_cache"
    exit 0
fi

if [ -d "${entries_dir}/${safe_key}" ]; then
    printf 'Cache entry already exists, skipping save: %s\n' "$cache_key"
    exit 0
fi

mkdir -p "$locks_dir"
lock_dir="${locks_dir}/${safe_key}.lock"

# mkdir is atomic on POSIX filesystems so concurrent runners cannot both win.
if ! mkdir "$lock_dir" 2>/dev/null; then
    # Check if the lock-holder is still alive. A SIGKILL or reboot leaves a
    # stale lock that would otherwise block saves for this key forever.
    stale_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if [ -n "$stale_pid" ] && ! kill -0 "$stale_pid" 2>/dev/null; then
        rm -rf "$lock_dir"
        mkdir "$lock_dir" 2>/dev/null || { printf 'Lock contention, skipping: %s\n' "$cache_key"; exit 0; }
    else
        printf 'Another process is saving this key, skipping: %s\n' "$cache_key"
        exit 0
    fi
fi
printf '%s' "$$" > "$lock_dir/pid"

release_lock() {
    rmdir "$lock_dir" 2>/dev/null || true
}
trap release_lock EXIT INT TERM

# Re-check after acquiring lock (another writer may have finished while we waited).
if [ -d "${entries_dir}/${safe_key}" ]; then
    printf 'Cache entry appeared while acquiring lock, skipping save: %s\n' "$cache_key"
    exit 0
fi

# Sync to a temp entry, then rename atomically into place.
mkdir -p "$entries_dir"
tmp_entry="${entries_dir}/.tmp-${safe_key}-$$"

cleanup_tmp() {
    release_lock
    rm -rf "$tmp_entry" 2>/dev/null || true
}
trap cleanup_tmp EXIT INT TERM

rsync -a "${path_to_cache}/" "${tmp_entry}/"
mv "$tmp_entry" "${entries_dir}/${safe_key}"

trap release_lock EXIT INT TERM

size=$(du -sh "${entries_dir}/${safe_key}" 2>/dev/null | cut -f1 || printf '?')
printf 'Saved cache entry: %s (%s)\n' "$cache_key" "$size"
