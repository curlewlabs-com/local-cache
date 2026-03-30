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

start_time=$(date +%s)

# Replace characters that are not safe in directory names with underscores.
sanitize_key() {
    printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_'
}

# stat syntax differs between Linux (-c) and macOS (-f).
hardlink_status() {
    target_dir="$1"
    sample=$(find "$target_dir" -type f | head -1 2>/dev/null || true)
    [ -z "$sample" ] && return
    nlink=$(stat -c '%h' "$sample" 2>/dev/null || stat -f '%l' "$sample" 2>/dev/null || true)
    if [ "${nlink:-0}" -gt 1 ] 2>/dev/null; then
        printf '::debug::Hard links confirmed (nlink=%s) — restore was zero-copy\n' "$nlink"
    else
        printf '::debug::Copying files (cross-filesystem fallback) — restore used full copy\n'
    fi
}

append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}

do_restore() {
    entry_path="$1"
    matched_key="$2"
    is_exact="$3"
    mkdir -p "$path_to_cache"
    rsync -a --link-dest="${entry_path}/" "${entry_path}/" "${path_to_cache}/"
    hardlink_status "$path_to_cache"
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
        # ls -dt with a glob sorts by mtime without grep. SC2012: keys are
        # sanitized to [a-zA-Z0-9._-] so filenames are safe. SC2015: the
        # || true applies only to cd failing; ls|head always succeeds.
        # shellcheck disable=SC2012,SC2015
        match=$(cd "${entries_dir}" 2>/dev/null && ls -dt "${safe_prefix}"* 2>/dev/null | head -1 || true)
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
