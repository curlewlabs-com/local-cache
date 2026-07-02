#!/bin/sh
# Evict least-recently-used cache entries and their restore targets, without
# racing concurrent saves and restores.
#
# Usage: cache-gc.sh [--apply] [--max-age-days N] <cache-dir>
#
#   --max-age-days N  Evict entries whose last use is older than N days. Last
#                     use is the mtime of the entry's metadata file
#                     (.local-cache-key), stamped on every served restore
#                     (including the constant-time marker-skip), so it tracks
#                     genuine recency of use across every runner sharing the
#                     store. Default: 30.
#   --apply           Actually delete. Default: dry run — report what would be
#                     reclaimed without touching anything.
#
# Locking. This script must run under local-mutex, which exports LOCAL_MUTEX_CLI
# (its own path) into the environment; gc/action.yml provides that by wrapping
# the whole sweep in the store-wide `cache-gc` lock. The sweep re-invokes itself
# through that CLI to take two finer locks — the SAME ones the save and restore
# paths hold — so it never races them:
#
#   * cache-save-<raw-key>   Held while an entry is re-checked and evicted: the
#                            per-key lock save and restore-phase-2 also take. A
#                            save or full restore of that key cannot interleave
#                            with its eviction.
#   * cache-target-<path>    Held while a recorded restore target is reclaimed:
#                            the per-target lock restore-phase-1 also takes. The
#                            marker check, owner-coldness re-check, and rm are
#                            atomic against a concurrent restore to that path.
#
# Whenever both are held they are acquired key ⊃ target, and no actor holds the
# target lock while waiting on a key lock (restore Phase 1 takes only the target
# lock), so a sweep and a restore can never deadlock. Whole entries and whole targets
# only, never individual files, because a partial delete would corrupt the
# rsync source of a concurrent restore.
#
# Safety is layered. The locks make eviction atomic against concurrent saves
# and restores. But a job USES a restored target for minutes after its restore
# step (and its lock) has finished — a window no lock spans — so the
# max-age-days threshold covers it: a cold entry proves no runner has restored
# it (the last-use mtime is a global signal, bumped by any runner) within the
# window, so with a window wider than the longest job every target copy is idle.
# As independent backstops a target is spared if its owning entry is no longer
# cold (a concurrent skip-hit bumped it under the target lock, which the reclaim
# observes) or if anything under it was modified within the window (an
# in-progress build writes into its restored tree). A consumer whose jobs
# approach the window must widen it — this is a time heuristic, not a lock.
set -eu

script_dir=$(
    CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)
self="${script_dir}/$(basename -- "$0")"
# shellcheck source=lib/cache-common.sh
. "${script_dir}/cache-common.sh"

stat_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
dir_size_h() { du -sh "$1" 2>/dev/null | cut -f1 || printf '?'; }

# True if the entry metadata's last-use mtime is at or before the sweep cutoff.
# Read fresh on every call, so a caller holding a lock observes a concurrent
# mark_used bump. Unreadable mtime reads as "now" (hot) — fail safe.
is_cold() {
    ic_use=$(stat_mtime "$1" 2>/dev/null || echo "$GC_NOW")
    [ "$ic_use" -le "$GC_CUTOFF" ]
}

# --- internal, lock-held subcommands (re-invoked via LOCAL_MUTEX_CLI) ---
# Arguments arrive by environment (GC_*), never on the command line, so target
# paths and raw keys containing shell metacharacters cannot be misparsed.

# Runs under cache-target-<GC_TARGET_PATH>. Reclaims one recorded target iff it
# still belongs to the cold entry being evicted and is idle. Exit 0 means the
# entry may be evicted as far as this target is concerned (reclaimed, already
# gone, forged/dangerous record, or owned by a different key now); exit 3 means
# the target is a live copy of THIS entry, so the caller must keep the entry
# (and its record) rather than orphan the copy.
do_reclaim_target() {
    tpath="$GC_TARGET_PATH"
    # A corrupted or forged record must never widen the sweep to the machine
    # root or a live workspace.
    if path_is_dangerous "$tpath"; then
        printf '::notice::cache-gc: keep target (unsafe path: %s)\n' "${tpath:-<empty>}"
        return 0
    fi
    [ -e "$tpath" ] || return 0

    # Ownership, under the target lock: the marker names the entry the target
    # currently holds. The record only says this entry was once restored here;
    # the target may since have been re-restored from a different (possibly hot)
    # key, rewriting its marker. Reclaim only if the marker still names the cold
    # owner being evicted.
    cur_marker=$(cat "${tpath}/${MARKER_NAME}" 2>/dev/null || printf '')
    if [ "$cur_marker" != "${MARKER_VERSION}:${GC_OWNER_KEY}" ]; then
        printf '::notice::cache-gc: keep target %s (marker %s is not the evicted %s:%s)\n' \
            "$tpath" "${cur_marker:-<none>}" "$MARKER_VERSION" "$GC_OWNER_KEY"
        return 0
    fi

    # Owner still cold, re-read under this target lock. A skip-hit restore bumps
    # the owner's last-use (mark_used) while holding THIS lock, so this read
    # observes it: a hot owner means a job is using the target right now — and
    # the skip path leaves the tree untouched, so the mtime backstop below can't
    # see it. This check is the primary guard for that case.
    if ! is_cold "$GC_OWNER_META"; then
        printf '::notice::cache-gc: keep target %s (owner no longer cold)\n' "$tpath"
        return 3
    fi

    # Independent backstop: an in-progress build writes into its restored tree.
    if [ -n "$(find "$tpath" -mtime -"$GC_MAX_AGE_DAYS" 2>/dev/null | head -n 1)" ]; then
        printf '::notice::cache-gc: keep target %s (modified within the window)\n' "$tpath"
        return 3
    fi

    tsize=$(dir_size_h "$tpath")
    if [ "$GC_APPLY" = true ]; then
        rm -rf "$tpath"
    fi
    printf 'x\n' >> "$GC_TARGETS_TALLY"
    printf '::notice::cache-gc: %s target %s (%s)\n' "$GC_VERB" "$tpath" "$tsize"
    return 0
}

# Runs under cache-save-<raw-key>. Re-checks the entry is still cold, reclaims
# its recorded targets (each under its own target lock, nested), then removes
# the entry.
do_evict_entry() {
    name="$GC_ENTRY_NAME"
    entry="${GC_CACHE_DIR}/entries/${name}"
    meta="${entry}/${ENTRY_KEY_NAME}"
    targets_dir="${GC_CACHE_DIR}/${TARGETS_DIR_NAME}/${name}"

    # The entry can vanish between the unlocked scan and this lock (a prior
    # sweep, a manual reset).
    [ -d "$entry" ] || return 0
    [ -f "$meta" ] || return 0

    # Re-check under the key lock: a save or full restore of this key (both hold
    # this lock) since the scan bumps last-use. Leave the whole entry and its
    # targets if it went hot — a job may be restoring from it right now.
    if ! is_cold "$meta"; then
        printf '::debug::cache-gc: %s no longer cold since scan — keeping\n' "$name"
        return 0
    fi

    raw_key=$(cat "$meta" 2>/dev/null || printf '%s' "$name")
    entry_size=$(dir_size_h "$entry")

    any_live=false
    if [ -d "$targets_dir" ]; then
        GC_OWNER_KEY="$raw_key"
        GC_OWNER_META="$meta"
        export GC_OWNER_KEY GC_OWNER_META GC_TARGET_PATH
        for rec in "$targets_dir"/*; do
            [ -f "$rec" ] || continue
            tpath=$(cat "$rec" 2>/dev/null || true)
            [ -n "$tpath" ] || continue
            GC_TARGET_PATH="$tpath"
            # Nested key ⊃ target. reclaim-target exits 0 when the entry may be
            # evicted as far as this target is concerned, 3 when the target is a
            # live copy of this entry. Any other code is a failure — keep the
            # entry to be safe and surface it; one target must never abort the
            # whole sweep.
            set +e
            # shellcheck disable=SC2016
            sh "$LOCAL_MUTEX_CLI" "cache-target-${tpath}" 'sh "$GC_SELF" --__reclaim-target'
            rc=$?
            set -e
            case "$rc" in
                0) ;;
                3) any_live=true ;;
                *)
                    any_live=true
                    printf '::warning::cache-gc: reclaim of %s failed (rc=%s) — entry kept\n' "$tpath" "$rc" >&2
                    ;;
            esac
        done
    fi

    # Keep the entry if any of its targets is a live copy: its record dir must
    # survive so a later sweep can reclaim that copy once it goes idle.
    if [ "$any_live" = true ]; then
        printf '::notice::cache-gc: keep entry %s (a live target still derives from it)\n' "$raw_key"
        return 0
    fi

    # Re-check once more before removing the entry: a skip-hit restore holds only
    # a target lock, not this key lock, so it can bump last-use — or record a new
    # target not in the snapshot above — during the target loop. Deleting a
    # now-hot entry would waste a re-save and strand a just-served target's
    # marker. Targets reclaimed above were idle when reclaimed and stay so.
    if ! is_cold "$meta"; then
        printf '::notice::cache-gc: keep entry %s (became hot during sweep)\n' "$raw_key"
        return 0
    fi

    last_use=$(stat_mtime "$meta" 2>/dev/null || echo "$GC_NOW")
    age_days=$(((GC_NOW - last_use) / 86400))
    if [ "$GC_APPLY" = true ]; then
        rm -rf "$entry" "$targets_dir"
    fi
    printf 'x\n' >> "$GC_ENTRIES_TALLY"
    printf '::notice::cache-gc: %s entry %s (%s, idle %sd)\n' "$GC_VERB" "$raw_key" "$entry_size" "$age_days"
    append_summary "- **local-cache gc** \`${raw_key}\` → 🗑️ ${GC_SUM_VERB} (${entry_size}, idle ${age_days}d)"
    return 0
}

case "${1:-}" in
    --__evict-entry) do_evict_entry; exit 0 ;;
    --__reclaim-target) do_reclaim_target; exit $? ;;
esac

# --- main sweep (the entry point the gc action invokes) ---

# gc must serialize against saves and restores, which it does by taking their
# locks through local-mutex's CLI. Without it there is no safe way to proceed,
# so refuse rather than sweep unlocked.
if [ -z "${LOCAL_MUTEX_CLI:-}" ] || [ ! -f "${LOCAL_MUTEX_CLI:-}" ]; then
    printf '::error::cache-gc: LOCAL_MUTEX_CLI is unset or not a readable file. Run gc via the gc action (which wraps it in local-mutex), or wrap the script in local-mutex yourself so eviction serializes against saves and restores.\n' >&2
    exit 1
fi

apply=false
max_age_days=30

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)
            apply=true
            shift
            ;;
        --max-age-days)
            max_age_days="${2:-}"
            if [ -z "$max_age_days" ]; then
                printf '::error::cache-gc: --max-age-days requires a value\n' >&2
                exit 1
            fi
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            printf '::error::cache-gc: unknown flag: %s\n' "$1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

cache_dir="${1:-}"
if [ -z "$cache_dir" ]; then
    printf '::error::cache-gc: cache-dir must not be empty\n' >&2
    exit 1
fi
# Reject 0 and leading zeros, not just non-digits. 0 makes cutoff=now, so a
# just-bumped (hot) entry reads cold and `find -mtime -0` matches nothing —
# both safety guards fail open and gc would delete an in-use target. Leading
# zeros are octal traps: `$(( ))` reads 08/09 as an error (aborting the sweep)
# and 010 as 8, while `find -mtime -010` reads 10 — one value, two windows.
case "$max_age_days" in
    '' | *[!0-9]* | 0*)
        printf '::error::cache-gc: --max-age-days must be a positive integer without leading zeros, got: %s\n' "$max_age_days" >&2
        exit 1
        ;;
esac

entries_dir="${cache_dir}/entries"
if [ ! -d "$entries_dir" ]; then
    printf '::notice::cache-gc: no entries dir at %s — nothing to do\n' "$entries_dir"
    exit 0
fi

now=$(date +%s)
cutoff=$((now - max_age_days * 86400))
if [ "$apply" = true ]; then
    verb=removed
    sum_verb=Evicted
    printf '::notice::cache-gc: apply mode — entries and targets idle >%sd will be removed\n' "$max_age_days"
else
    verb=would-remove
    sum_verb=Reclaimable
    printf '::notice::cache-gc: dry run — reporting entries idle >%sd (nothing removed)\n' "$max_age_days"
fi

# Sweep-wide state shared with the lock-held subcommands via the environment.
# A single now/cutoff fixes one coldness bar for the whole sweep. Reclaim tallies
# are files because the subcommands run in their own processes (under the locks)
# and cannot increment a parent variable; the sweep is serialized store-wide, so
# no two of them append concurrently.
GC_SELF="$self"
GC_CACHE_DIR="$cache_dir"
GC_MAX_AGE_DAYS="$max_age_days"
GC_APPLY="$apply"
GC_NOW="$now"
GC_CUTOFF="$cutoff"
GC_VERB="$verb"
GC_SUM_VERB="$sum_verb"
GC_ENTRIES_TALLY=$(mktemp)
GC_TARGETS_TALLY=$(mktemp)
# Clean the tallies on ANY exit — a set -e abort in the sweep below must not leak
# temp files on a long-lived runner. Only the main sweep reaches here; the
# lock-held subcommands exit at the dispatch above, before this trap is armed.
trap 'rm -f "$GC_ENTRIES_TALLY" "$GC_TARGETS_TALLY"' EXIT
export GC_SELF GC_CACHE_DIR GC_MAX_AGE_DAYS GC_APPLY GC_NOW GC_CUTOFF \
    GC_VERB GC_SUM_VERB GC_ENTRIES_TALLY GC_TARGETS_TALLY GC_ENTRY_NAME

for entry in "${entries_dir}"/*; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")
    # Staging dirs from an interrupted save (SIGKILL/OOM between rsync and mv)
    # are not real entries.
    case "$name" in
        .tmp-*) continue ;;
    esac

    meta="${entry}/${ENTRY_KEY_NAME}"
    # Legacy entries predate the metadata file: no last-use signal and no raw
    # key, so leave them (clear those with `rm -rf entries/*` after upgrading).
    if [ ! -f "$meta" ]; then
        printf '::debug::cache-gc: %s has no %s — skipping (legacy)\n' "$name" "$ENTRY_KEY_NAME"
        continue
    fi

    # Unlocked candidate check; evict-entry re-checks authoritatively under the
    # key lock. A candidate that goes hot in between is spared there.
    is_cold "$meta" || continue

    # The lock name is the RAW key (the same string save and restore lock on),
    # so gc's key lock is the very lock those paths take — not merely a
    # same-named sibling. local-mutex hashes it, so length and content are free.
    raw_key=$(cat "$meta" 2>/dev/null || printf '%s' "$name")

    GC_ENTRY_NAME="$name"
    # shellcheck disable=SC2016
    sh "$LOCAL_MUTEX_CLI" "cache-save-${raw_key}" 'sh "$GC_SELF" --__evict-entry' \
        || printf '::warning::cache-gc: eviction of %s failed — kept\n' "$raw_key" >&2
done

# Sweep record dirs whose entry is gone (e.g. after a manual `rm -rf entries/*`
# reset): the records are useless without the entry's last-use signal. Removes
# only the stale records, never the on-disk targets they name — once the entry
# is gone there is no coldness signal to justify deleting a live copy. Lock-free
# is safe: a restore only records under an entry that exists, so a dead entry's
# record dir has no writer.
targets_root="${cache_dir}/${TARGETS_DIR_NAME}"
if [ -d "$targets_root" ]; then
    for trec in "$targets_root"/*; do
        [ -d "$trec" ] || continue
        tname=$(basename "$trec")
        if [ ! -d "${entries_dir}/${tname}" ]; then
            if [ "$apply" = true ]; then
                rm -rf "$trec"
            fi
            printf '::debug::cache-gc: %s orphaned target records %s (no matching entry)\n' "$verb" "$tname"
        fi
    done
fi

reclaimed_entries=$(wc -l < "$GC_ENTRIES_TALLY" 2>/dev/null | tr -d '[:space:]')
reclaimed_targets=$(wc -l < "$GC_TARGETS_TALLY" 2>/dev/null | tr -d '[:space:]')
# tallies are removed by the EXIT trap

printf '::notice::cache-gc: %s %s entr(y/ies) and %s target(s) idle >%sd\n' \
    "$verb" "$reclaimed_entries" "$reclaimed_targets" "$max_age_days"
append_summary "- **local-cache gc** → ${sum_verb} ${reclaimed_entries} entr(y/ies) + ${reclaimed_targets} target(s) idle >${max_age_days}d"
