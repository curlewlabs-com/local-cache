#!/bin/sh

# shellcheck disable=SC2034
MARKER_NAME=".local-cache-restore"
ENTRY_KEY_NAME=".local-cache-key"

# Encode every byte as hex so distinct raw keys always map to distinct
# directory names while remaining safe as path components.
encode_key() {
    hex=$(printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n')
    printf 'k-%s' "$hex"
}

append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}
