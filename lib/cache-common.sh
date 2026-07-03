#!/bin/sh

# Metadata names, read by the entry scripts that source this file
# (cache-restore.sh / cache-save.sh / cache-gc.sh), so they look unused here.
# shellcheck disable=SC2034
MARKER_NAME=".local-cache-restore"
# shellcheck disable=SC2034
ENTRY_KEY_NAME=".local-cache-key"
# Restore targets are recorded under a top-level `targets/` dir in the cache (a
# sibling of `entries/`), one subdir per entry keyed by the same encoded key,
# one small file per target: name = target-path hash, content = the absolute
# target path, mtime = last restore. Kept OUT of the entry dir on purpose —
# adding a child to an entry would bump the entry's mtime, which prefix/
# restore-keys resolution sorts on (see touch-on-restore). cache-gc.sh reads it
# to reclaim the per-runner copies when the entry is evicted.
# shellcheck disable=SC2034
TARGETS_DIR_NAME="targets"

# Marker file format version. cache-restore.sh writes MARKER_NAME in a restored
# target as "${MARKER_VERSION}:<matched-key>"; it is read back both by
# cache-restore.sh (is the target already current?) and by cache-gc.sh (does
# this target still belong to the entry being evicted?) before either skips a
# restore or reclaims a copy. <matched-key> is the value the action emits as
# cache-matched-key — the entry's raw key. Bumped only on a backward-
# incompatible change to the marker or entry layout (v1 used hard links; v2
# uses full rsync copies). Referenced by literal in .github/workflows/ci.yml
# marker tests — keep those literals in sync if you bump this.
# shellcheck disable=SC2034
MARKER_VERSION="v2"

# Hex SHA-256 of the argument. sha256sum on Linux (GNU coreutils); shasum on
# macOS / Perl. Derives fixed-length, filesystem-safe names from arbitrary
# strings (cache keys, absolute target paths).
sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else
        printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
    fi
}

# Map a raw cache key to a fixed-length, filesystem-safe directory name. The
# k- prefix keeps entry dirs visually distinct; the SHA-256 keeps the output
# at 66 characters regardless of input length, avoiding NAME_MAX issues with
# long keys.
encode_key() {
    printf 'k-%s' "$(sha256_hex "$1")"
}

append_summary() {
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# Canonicalize a target path LEXICALLY (no symlink or ".." resolution — that
# needs a non-portable realpath). Collapses repeated slashes and drops "."
# components and any trailing slash, so /tmp/foo, /tmp/foo/, /tmp//foo and
# /tmp/./foo all yield /tmp/foo. This is what lets the per-target lock name and
# the target record identify one physical target by one string: two spellings of
# the same directory MUST map to the same cache-target-<path> lock, or a restore
# under one spelling races the gc reclaiming the record written under the other.
# Apply before deriving a cache-target-<path> lock name or a target record.
# Distinct symlink paths to one directory stay distinct (documented limitation).
normalize_path() {
    np_in=${1:-}
    # IFS/-f are scoped to the subshell so the field split on "/" and the
    # glob-off cannot leak to the caller; its stdout is the normalized path.
    # `if`, not `case`, inside the $(): bash 3.2 (macOS /bin/sh) misparses a
    # case-pattern ")" as the command-substitution close.
    np_out=$(
        IFS=/
        set -f
        np_acc=''
        # shellcheck disable=SC2086 # deliberate word-split on IFS=/
        for np_seg in $np_in; do
            if [ -z "$np_seg" ] || [ "$np_seg" = . ]; then
                continue
            fi
            np_acc="${np_acc}/${np_seg}"
        done
        if [ "${np_in#/}" != "$np_in" ]; then
            # absolute: keep the leading slash ("/" for an all-slash input)
            if [ -n "$np_acc" ]; then printf '%s' "$np_acc"; else printf '/'; fi
        else
            printf '%s' "${np_acc#/}"
        fi
    )
    printf '%s' "$np_out"
}

# Return 0 (true) if PATH is too dangerous to `rm -rf`: empty, relative, the
# filesystem root, or equal-to / an ancestor of $HOME, $RUNNER_WORKSPACE, or
# $GITHUB_WORKSPACE. cache-gc.sh calls this before deleting a recorded restore
# target so a corrupted or forged record can never widen the sweep to the
# machine root or a live workspace. Mirrors the up-front target guards in
# cache-restore.sh (which exit); this returns a status so the caller can skip
# the one record and surface it instead of aborting the whole sweep.
path_is_dangerous() {
    p="$1"
    [ -z "$p" ] && return 0
    case "$p" in
        /*) ;;
        *) return 0 ;; # relative
    esac
    # Strip trailing slashes so "/foo/" and "/foo" compare identically; "/"
    # collapses to empty and is caught below as the root.
    while [ "${p%/}" != "$p" ]; do
        p="${p%/}"
    done
    [ -z "$p" ] && return 0 # was "/" (or all slashes)
    case "$p" in
        */. | */..) return 0 ;; # trailing . or .. component
    esac
    for danger in "${HOME:-}" "${RUNNER_WORKSPACE:-}" "${GITHUB_WORKSPACE:-}"; do
        [ -z "$danger" ] && continue
        d="$danger"
        while [ "${d%/}" != "$d" ]; do
            d="${d%/}"
        done
        [ -z "$d" ] && d="/"
        # Dangerous if p IS d, or d lives under p (deleting p would take out d).
        case "$d" in
            "$p" | "$p"/*) return 0 ;;
        esac
    done
    return 1
}
