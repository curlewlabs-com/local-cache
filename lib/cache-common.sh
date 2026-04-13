#!/bin/sh

# shellcheck disable=SC2034
MARKER_NAME=".local-cache-restore"
ENTRY_KEY_NAME=".local-cache-key"

# Map a raw cache key to a fixed-length, filesystem-safe directory name.
# SHA-256 keeps the output at 66 characters (k- + 64 hex) regardless of
# input length, avoiding NAME_MAX issues with long keys.
encode_key() {
    # sha256sum: Linux (GNU coreutils); shasum: macOS / Perl
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)
    else
        hash=$(printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1)
    fi
    printf 'k-%s' "$hash"
}

append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}
