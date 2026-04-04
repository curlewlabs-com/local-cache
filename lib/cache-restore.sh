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
# On a cache hit, the entry is restored using copy-on-write where available:
#   1. macOS APFS:  cp -cR  (clonefile — instant, zero disk until modified)
#   2. Linux CoW:   cp -a --reflink=auto  (Btrfs/XFS — same benefit; ext4
#                   silently falls back to a regular copy)
#   3. Fallback:    rsync -a  (plain copy — works everywhere)
#
# Why not hard links?  Hard links share the same inode data, so a consumer
# that modifies a restored file (e.g. flutter upgrading engine.version)
# corrupts the cache entry for every other consumer.  CoW clones share data
# blocks until written, then diverge — safe for concurrent modification.
set -e

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

# Restore the cache entry to the target path using the best available
# copy strategy.  Tries CoW clones first (APFS on macOS, reflink on
# Linux Btrfs/XFS), then falls back to a plain copy.
#
# To upgrade WSL2 runners from plain-copy to CoW: format the cache
# partition as Btrfs (mkfs.btrfs) — cp --reflink=auto will pick it up
# automatically with no code change here.
cow_restore() {
    src="$1"
    dst="$2"

    # macOS APFS: cp -cR creates per-file clones via clonefile(2).
    # Instant, zero additional disk until a file is modified.
    if cp -cR "$src/" "$dst/" 2>/dev/null; then
        printf '::debug::Restored via APFS clone (copy-on-write)\n'
        return 0
    fi

    # Linux Btrfs/XFS: cp --reflink=auto uses ioctl(FICLONE) for CoW.
    # On ext4 (default WSL2), --reflink=auto silently falls back to a
    # regular copy — no error, just uses disk.
    if cp -a --reflink=auto "$src/" "$dst/" 2>/dev/null; then
        printf '::debug::Restored via cp (reflink=auto)\n'
        return 0
    fi

    # POSIX baseline: plain rsync copy.  No hard links — see header
    # comment for why hard links are unsafe here.
    rsync -a "$src/" "$dst/"
    printf '::debug::Restored via rsync (plain copy)\n'
}

# SYNC: must match lib/cache-save.sh:append_summary exactly.
append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}

do_restore() {
    entry_path="$1"
    matched_key="$2"
    is_exact="$3"

    # Clean the target before restoring.  This handles two cases:
    #   1. Migration from hard-link restores: old files share inodes with
    #      the cache entry — any modification corrupts the cache.  nlink>1
    #      is the telltale sign.
    #   2. Stale content from a previous SDK version that the cache entry
    #      no longer contains.  cp/rsync overlay without deleting, so
    #      leftover files would persist silently.
    # Starting fresh ensures the restored tree exactly matches the entry.
    if [ -d "$path_to_cache" ]; then
        sample=$(find "$path_to_cache" -type f 2>/dev/null | head -1 || true)
        nlink=0
        if [ -n "$sample" ]; then
            nlink=$(stat -c '%h' "$sample" 2>/dev/null || stat -f '%l' "$sample" 2>/dev/null || echo 0)
        fi
        # Guard against non-numeric stat output.
        if [ "${nlink:-0}" -gt 1 ] 2>/dev/null; then
            printf '::warning::Clearing hard-linked restore at %s (migrating to copy-on-write)\n' "$path_to_cache"
        fi
        rm -rf "$path_to_cache"
    fi

    mkdir -p "$path_to_cache"
    cow_restore "$entry_path" "$path_to_cache"
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

entry_count=$(find "${entries_dir}/" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ' || printf '0')
printf '::debug::Checking local cache — key: %s, entries: %s\n' "$cache_key" "$entry_count"

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
