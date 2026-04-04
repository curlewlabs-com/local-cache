#!/bin/sh
# Called by the composite action's save step to persist a directory to local
# disk, avoiding network round-trips to GitHub's cache servers.
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


if [ -z "$path_to_cache" ] || [ -z "$cache_key" ] || [ -z "$cache_dir" ]; then
    printf '::error::cache-save: path, key, and cache-dir must not be empty\n'
    exit 1
fi

entries_dir="${cache_dir}/entries"
locks_dir="${cache_dir}/.locks"

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

if [ -d "${entries_dir}/${safe_key}" ]; then
    printf '::debug::Cache entry already exists, skipping save: %s\n' "$cache_key"
    exit 0
fi

mkdir -p "$locks_dir"
lock_dir="${locks_dir}/${safe_key}.lock"

# mkdir is atomic on POSIX filesystems so concurrent runners cannot both win.
if ! mkdir "$lock_dir" 2>/dev/null; then
    # Check if the lock-holder is still alive. A SIGKILL, OOM kill, or reboot
    # leaves a stale lock that would otherwise block saves for this key forever.
    # Missing PID file (process killed between mkdir and PID write) is treated
    # the same as a dead PID — the holder is gone either way.
    stale_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if [ -z "$stale_pid" ] || ! kill -0 "$stale_pid" 2>/dev/null; then
        # Jittered sleep prevents two runners from both detecting the stale lock
        # and racing through rm + mkdir at the same instant.
        jitter=$(( $$ % 5 + 1 ))
        printf '::debug::Stale lock detected (PID %s). Waiting %ds before recovery.\n' "${stale_pid:-missing}" "$jitter"
        sleep "$jitter"
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

# Filesystem capability detection — helps diagnose restore performance.
# Restores use copy-on-write (APFS clones or reflinks) when available,
# falling back to a regular copy on ext4 and similar filesystems.
case "$(uname -s)" in
    Darwin)
        printf '::debug::macOS detected — restores will use APFS clones (copy-on-write)\n' ;;
    Linux)
        # Test whether the filesystem supports reflinks by cloning a sample file.
        sample=$(find "${entries_dir}/${safe_key}" -type f 2>/dev/null | head -1 || true)
        if [ -n "$sample" ]; then
            reflink_test=$(mktemp "${entries_dir}/.reflink-test-XXXXXX" 2>/dev/null || true)
            if [ -n "$reflink_test" ] && cp --reflink=always "$sample" "$reflink_test" 2>/dev/null; then
                printf '::debug::Reflink support detected — restores will use copy-on-write\n'
            else
                printf '::debug::No reflink support (ext4 or similar) — restores will use full copy\n'
            fi
            rm -f "$reflink_test" 2>/dev/null || true
        fi ;;
    *)
        printf '::debug::Unknown OS — restores will use rsync fallback\n' ;;
esac

elapsed=$(( $(date +%s) - start_time ))
size=$(du -sh "${entries_dir}/${safe_key}" 2>/dev/null | cut -f1 || printf '?')
file_count=$(find "${entries_dir}/${safe_key}" -type f | wc -l | tr -d ' ')
printf '::notice::Cache saved: %s (%s files, %s in %ds)\n' "$cache_key" "$file_count" "$size" "$elapsed"
printf '::debug::Entry path: %s\n' "${entries_dir}/${safe_key}"
append_summary "- **local-cache** \`${cache_key}\` → 💾 Saved (${size}, ${elapsed}s)"
