#!/bin/sh
# Restore a cached directory from local disk.
#
# Usage: cache-restore.sh <path> <key> <cache-dir> [restore-keys]
#
# Writes to $GITHUB_OUTPUT:
#   cache-hit=true|false
#   cache-matched-key=<key>
#
# On a cache hit, rsync restores the entry to <path> using hard links where
# possible (same filesystem) so the restore is near-instant regardless of
# cache size. Falls back to a regular copy automatically when hard links are
# not available (cross-filesystem).
set -e

path_to_cache="$1"
cache_key="$2"
cache_dir="$3"
restore_keys="${4:-}"

entries_dir="${cache_dir}/entries"

# Replace characters that are not safe in directory names with underscores.
sanitize_key() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_'
}

do_restore() {
    entry_path="$1"
    matched_key="$2"
    is_exact="$3"
    mkdir -p "$path_to_cache"
    rsync -a --link-dest="${entry_path}/" "${entry_path}/" "${path_to_cache}/"
    if [ "$is_exact" = "true" ]; then
        printf 'cache-hit=true\n' >> "$GITHUB_OUTPUT"
    else
        printf 'cache-hit=false\n' >> "$GITHUB_OUTPUT"
    fi
    printf 'cache-matched-key=%s\n' "$matched_key" >> "$GITHUB_OUTPUT"
    size=$(du -sh "$path_to_cache" 2>/dev/null | cut -f1 || printf '?')
    printf 'Restored %s from: %s\n' "$size" "$entry_path"
}

safe_key=$(sanitize_key "$cache_key")

# Try exact match first.
if [ -d "${entries_dir}/${safe_key}" ]; then
    printf 'Cache hit (exact): %s\n' "$cache_key"
    do_restore "${entries_dir}/${safe_key}" "$cache_key" "true"
    exit 0
fi

# Try restore-keys prefix matching. Most recently modified matching entry wins.
if [ -n "$restore_keys" ]; then
    found_match=""
    found_prefix=""
    tmpfile=$(mktemp)
    printf '%s\n' "$restore_keys" > "$tmpfile"
    while IFS= read -r prefix; do
        [ -z "$prefix" ] && continue
        [ -n "$found_match" ] && break
        safe_prefix=$(sanitize_key "$prefix")
        # ls -dt with a glob sorts by mtime without grep. SC2012: keys are
        # sanitized to [a-zA-Z0-9._-] so filenames are safe. SC2015: the
        # || true applies only to cd failing; ls|head always succeeds.
        # shellcheck disable=SC2012,SC2015
        match=$(cd "${entries_dir}" 2>/dev/null && ls -dt "${safe_prefix}"* 2>/dev/null | head -1 || true)
        if [ -n "$match" ]; then
            found_match="$match"
            found_prefix="$prefix"
        fi
    done < "$tmpfile"
    rm -f "$tmpfile"

    if [ -n "$found_match" ]; then
        printf "Cache hit (prefix '%s'): %s\n" "$found_prefix" "$found_match"
        do_restore "${entries_dir}/${found_match}" "$found_match" "false"
        exit 0
    fi
fi

printf 'Cache miss: %s\n' "$cache_key"
printf 'cache-hit=false\n' >> "$GITHUB_OUTPUT"
printf 'cache-matched-key=\n' >> "$GITHUB_OUTPUT"
