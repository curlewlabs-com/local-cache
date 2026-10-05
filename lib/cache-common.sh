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
# target path, mtime = last restore. Kept OUT of the entry dir on purpose -
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
# cache-matched-key - the entry's raw key. Bumped only on a backward-
# incompatible change to the marker or entry layout (v1 used hard links; v2
# uses independent copies - rsync, or reflink clones, which build the same
# tree, so either may read what the other wrote). Referenced by literal in
# .github/workflows/ci.yml marker tests - keep those literals in sync if you
# bump this.
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

# Return 0 (true) if GNU cp can clone (reflink) files from SRC_DIR into
# DEST_DIR, an existing directory this process may write to. That needs cp with
# --reflink (GNU coreutils), both directories on one filesystem, and a
# filesystem that shares extents between files. Support depends on mkfs
# options (XFS without reflink=1 cannot) and the kernel, not on the filesystem
# type alone, so this clones a real probe file rather than matching on type.
# The probe is written into DEST_DIR, never the source: a restore's source is
# a store entry, which may be read-only and whose directory mtime orders
# prefix matches.
gnu_can_reflink() {
    cr_src_dev=$(stat -c %d -- "$1" 2>/dev/null) || return 1
    cr_dest_dev=$(stat -c %d -- "$2" 2>/dev/null) || return 1
    [ -n "$cr_src_dev" ] && [ "$cr_src_dev" = "$cr_dest_dev" ] || return 1
    cr_probe="$2/.local-cache-reflink-probe.$$"
    printf 'local-cache reflink probe\n' > "${cr_probe}.src" 2>/dev/null || return 1
    cr_rc=0
    cp --reflink=always -- "${cr_probe}.src" "${cr_probe}.dst" 2>/dev/null || cr_rc=1
    rm -f -- "${cr_probe}.src" "${cr_probe}.dst"
    return "$cr_rc"
}

# Return 0 (true) if SRC_DIR and DEST_DIR are on one APFS volume, where macOS
# cp -c clones every file with clonefile(2). A probe cannot answer this one:
# unlike GNU --reflink=always, cp -c falls back to an ordinary copy when it
# cannot clone and still exits 0, so this reads the volume's type from mount
# instead. Same device, not just APFS, because a clone between two APFS
# volumes - even in one container - is a copy. (macOS reports its read-only
# system volume under the data volume's device, so a save FROM the system
# volume is labeled a clone but copied; nothing local-cache writes lands
# there, so the label is the only casualty.) The tools are named by absolute
# path because a runner with GNU coreutils first on PATH has a cp without -c
# and a stat whose -f means something else.
apfs_can_clone() {
    [ "$(uname -s)" = Darwin ] || return 1
    ac_src_dev=$(/usr/bin/stat -f %d "$1" 2>/dev/null) || return 1
    ac_dest=$(/usr/bin/stat -f '%d %Sd' "$2" 2>/dev/null) || return 1
    [ -n "$ac_src_dev" ] && [ "$ac_src_dev" = "${ac_dest%% *}" ] || return 1
    /sbin/mount | awk -v disk="/dev/${ac_dest#* }" \
        '$1 == disk && /\(apfs[,)]/ { found = 1 } END { exit !found }'
}

# Copy the contents of SRC_DIR into the existing directory DEST_DIR, leaving
# out every file or directory, at any depth, named by the remaining arguments
# (rsync's unanchored --exclude). Sets copy_method to the engine used, for the
# caller's log line.
#
# Where the filesystem can clone - GNU cp --reflink on Linux, cp -c on an APFS
# volume - the copy is a clone: DEST shares SRC's data blocks until either side
# writes, so it costs neither the time nor the disk of a full copy. Each clone
# is still its own inode, so a write into a restored file never reaches the
# entry or another runner's copy - the isolation that hard links (v1) broke.
# Everywhere else, rsync -a, unchanged.
#
# The clone paths build the tree rsync would: cp -p keeps mode, timestamps, and
# ownership where permitted; -P copies symlinks as symlinks; and no engine
# preserves hard links between files. They also keep what rsync -a drops: ACLs,
# and on macOS extended attributes and file flags, which clonefile(2) carries
# with the data. cp has no --exclude, so the excluded names are deleted after
# the copy, and a subdirectory one was deleted from gets a fresh mtime where
# rsync would carry the source's. --reflink=auto rather than =always: the probe
# proved the filesystem clones, but a single file can still refuse (Btrfs
# nodatacow), and that file should be copied rather than fail the whole
# restore; cp -c falls back the same way on its own.
copy_tree() {
    ct_src="$1"
    ct_dest="$2"
    shift 2
    if gnu_can_reflink "$ct_src" "$ct_dest"; then
        copy_method="reflink"
        cp -R -P -p --reflink=auto -- "${ct_src}/." "${ct_dest}/"
    elif apfs_can_clone "$ct_src" "$ct_dest"; then
        copy_method="reflink"
        /bin/cp -c -R -P -p -- "${ct_src}/." "${ct_dest}/"
    else
        copy_method="rsync"
        # Rewrite the name list in place as --exclude flags.
        for ct_name in "$@"; do
            set -- "$@" "--exclude=${ct_name}"
            shift
        done
        rsync -a "$@" "${ct_src}/" "${ct_dest}/"
        return
    fi
    for ct_name in "$@"; do
        find "$ct_dest" -mindepth 1 -name "$ct_name" -prune -exec rm -rf -- {} +
    done
}

# Canonicalize a target path LEXICALLY (no symlink or ".." resolution - that
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
