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

start_time=$(date +%s)

sanitize_key() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_'
}

append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}

safe_key=$(sanitize_key "$cache_key")

if [ ! -d "$path_to_cache" ]; then
    printf '::notice::Cache save skipped — source path does not exist: %s\n' "$path_to_cache"
    exit 0
fi

if [ -d "${entries_dir}/${safe_key}" ]; then
    printf '::debug::Cache entry already exists, skipping save: %s\n' "$cache_key"
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
        printf '::debug::Removing stale lock (PID %s no longer running)\n' "$stale_pid"
        rm -rf "$lock_dir"
        mkdir "$lock_dir" 2>/dev/null || { printf '::debug::Lock contention after stale recovery, skipping: %s\n' "$cache_key"; exit 0; }
    else
        printf '::debug::Another process is saving this key, skipping: %s\n' "$cache_key"
        exit 0
    fi
fi
printf '%s' "$$" > "$lock_dir/pid"

release_lock() {
    rm -rf "$lock_dir" 2>/dev/null || true
}
trap release_lock EXIT INT TERM

# Re-check after acquiring lock (another writer may have finished while we waited).
if [ -d "${entries_dir}/${safe_key}" ]; then
    printf '::debug::Cache entry appeared while acquiring lock, skipping save: %s\n' "$cache_key"
    exit 0
fi

mkdir -p "$entries_dir"
tmp_entry="${entries_dir}/.tmp-${safe_key}-$$"

cleanup_tmp() {
    release_lock
    rm -rf "$tmp_entry" 2>/dev/null || true
}
trap cleanup_tmp EXIT INT TERM

printf '::debug::Saving to local cache: %s\n' "$cache_key"
rsync -a "${path_to_cache}/" "${tmp_entry}/"
mv "$tmp_entry" "${entries_dir}/${safe_key}"

trap release_lock EXIT INT TERM

# Verify hard links are available by checking the link count on a sample file.
# nlink > 1 means future restores will be zero-copy; nlink = 1 means rsync
# will fall back to a full copy (cross-filesystem or no hardlink support).
sample=$(find "${entries_dir}/${safe_key}" -type f 2>/dev/null | head -1 || true)
if [ -n "$sample" ]; then
    nlink=$(stat -c '%h' "$sample" 2>/dev/null || stat -f '%l' "$sample" 2>/dev/null || true)
    # 2>/dev/null guards against non-numeric stat output (e.g. empty string) which
    # would make [ -gt ] a syntax error on some shells; || true already handles that,
    # but the redirect silences the shell-level error message cleanly.
    if [ "${nlink:-0}" -gt 1 ] 2>/dev/null; then
        printf '::debug::Hard links available (nlink=%s) — future restores will be zero-copy\n' "$nlink"
    else
        printf '::debug::Hard links not available — future restores will use full copy\n'
    fi
fi

elapsed=$(( $(date +%s) - start_time ))
size=$(du -sh "${entries_dir}/${safe_key}" 2>/dev/null | cut -f1 || printf '?')
file_count=$(find "${entries_dir}/${safe_key}" -type f | wc -l | tr -d ' ')
printf '::notice::Cache saved: %s (%s files, %s in %ds)\n' "$cache_key" "$file_count" "$size" "$elapsed"
printf '::debug::Entry path: %s\n' "${entries_dir}/${safe_key}"
append_summary "- **local-cache** \`${cache_key}\` → 💾 Saved (${size}, ${elapsed}s)"
