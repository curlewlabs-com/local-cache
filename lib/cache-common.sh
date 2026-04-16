#!/bin/sh

# shellcheck disable=SC2034
MARKER_NAME=".local-cache-restore"
ENTRY_KEY_NAME=".local-cache-key"

# Return the raw SHA-256 hex digest of a cache key. Shared by both the
# storage-directory name (encode_key below) and the per-key mutex name
# computed in action.yml / save/action.yml, so two distinct long keys
# that would collide under local-mutex's sanitize-and-truncate
# sanitization still hash to different digests here and therefore
# serialize on different locks.
hash_key() {
    # sha256sum: Linux (GNU coreutils); shasum: macOS / Perl
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    fi
}

# Map a raw cache key to a fixed-length, filesystem-safe directory name.
# SHA-256 keeps the output at 66 characters (k- + 64 hex) regardless of
# input length, avoiding NAME_MAX issues with long keys.
encode_key() {
    printf 'k-%s' "$(hash_key "$1")"
}

append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}
