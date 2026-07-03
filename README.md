# local-cache

Self-hosted GitHub Actions runners download the same large artifacts from GitHub's cache servers on every run — the Flutter SDK, Cargo registries, CocoaPods specs, npm packages. When you have multiple runners on the same machine, each one downloads independently, wasting minutes of CI time on network IO for content that's already sitting on the local disk.

`local-cache` is a drop-in replacement for [`actions/cache`](https://github.com/actions/cache) that reads and writes a shared directory on the runner's local filesystem. The first runner to hit a cache miss downloads and stores the content locally; every subsequent runner restores from disk in seconds. No network round-trip, no cloud storage, no per-runner duplication.

## Why

`actions/cache` stores entries on GitHub's servers. Every restore is a download over the network, and every save is an upload. For large artifacts — the Flutter SDK is ~1.8 GB, a Cargo registry can be hundreds of MB — this costs real time on every run, even when nothing has changed.

Self-hosted runners on the same physical machine make this worse: each runner operates independently, so if you have multiple runners and a warm cloud cache, every cold start pays the full download on every runner.

With `local-cache`, the artifact lives on the machine's local disk. On the first cold run, all concurrent runners download independently — there is no mechanism to make later runners wait for the first to finish. The save step serializes concurrent writers per-key via [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex), so two runners cannot corrupt the same entry; the second writer hits a post-acquire re-check, sees the entry already exists, and exits cleanly. After that initial population, no runner ever downloads again.

## How it works

Cache entries are stored as plain directories under `cache-dir/entries/k-<sha256>/`. The directory name is a SHA-256 hash of the caller's raw key (fixed-length, collision-free), and each entry also stores the original key in a small metadata file. On restore, `rsync -a` copies the entry contents to the target path. A marker file (`.local-cache-restore`) in the target records which key was last restored:

- **Marker matches the matched entry** → restore is skipped entirely (constant-time work). For prefix matches, "matched entry" is the resolved cache key for newly saved entries, and the legacy directory name when restoring an older pre-encoding entry.
- **Marker missing or different key** → target is cleaned and re-synced from cache
- **No marker (v1 upgrade)** → treated as stale, cleaned and re-synced

**Two-phase restore:** The restore step runs in two phases. Phase 1 checks the marker under a per-*target* lock — keyed by the restore path, not the cache key, so runners restoring to their own paths never contend and steady-state restores stay parallel across the fleet. If the target is already current, the restore finishes there. Otherwise Phase 1 resolves *which* entry to serve (the exact key, or the newest `restore-keys` prefix match) and hands it to Phase 2, which takes the per-*key* lock on **that entry's own key** — the requested key for an exact hit, the resolved entry's stored key for a prefix hit — shared with the save step via [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex). Nested inside it is that same per-target lock; it then rsyncs the resolved entry. Locking the entry's own key rather than merely the requested one matters because it is the exact lock the [`gc`](#the-gc-action) takes to evict that entry: on a prefix hit the two keys differ, and locking the requested key would leave the rsync *source* exposed to a concurrent eviction. Phase 2 restores exactly the entry Phase 1 resolved — never re-resolving to a different, unlocked one — and misses cleanly if the gc evicted it in the interval. The per-target lock is what lets the gc reclaim a restore target without racing a restore to it. No actor holds the target lock while waiting on the key lock (Phase 1 takes the target lock alone; Phase 2 and the gc nest key ⊃ target), so a restore and a sweep can never deadlock.

On save, content is synced to a temp directory then renamed atomically into place. Concurrent writers of the same key are serialized through [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex) (`lockf`/`flock` under the hood, kernel-managed cleanup on process death). The second writer waits for the first to finish, then re-checks and exits cleanly because the entry now exists. Saves of *different* keys still run in parallel — the lock is per-key.

**Why clean-before-restore matters:** The `rm -rf` on every re-sync (i.e. whenever the marker is missing or points at a different key) is deliberate — it prevents stale content from accumulating across version bumps. Without it, tools that install new versions alongside old ones (e.g. `subosito/flutter-action` in `runner.tool_cache`) would cause the save step to capture every version ever installed, growing the cache entry without bound. The clean re-sync ensures the target only ever contains what the cache entry has plus what the current install step adds — nothing from previous versions survives.

**Why not hard links?** v1 used `rsync --link-dest` for zero-copy restores. This is unsafe when multiple runners restore the same entry concurrently: hard links share the same inode, so if one consumer modifies a file (e.g. `flutter` upgrading `engine.version` during setup), the modification corrupts the cache entry for every other consumer.

**Why not copy-on-write (APFS clones, reflinks)?** CoW semantics are not portable: `cp -c` is macOS-only (APFS), `cp --reflink` is Linux-only (Btrfs/XFS, not ext4), and edge-case behavior (failure modes, metadata preservation on fallback) varies across OS versions. We optimize for easy to understand over minimal: one tool (`rsync`), one behavior, no platform detection. The marker-based skip also makes CoW redundant for the common case — steady-state restores are constant-time work, and version bumps (the only case CoW would help) are rare and take seconds.

**Last-use tracking (for eviction):** Every restore that serves an entry — including the constant-time marker-skip path — updates the modification time of that entry's metadata file (`.local-cache-key`). This gives each entry an accurate *last-used* timestamp, distinct from the entry directory's own mtime (which records the last *write* and is what prefix matching sorts on). Nothing here evicts anything on its own; it makes a least-recently-used sweep possible and safe — see [Eviction](#eviction).

## Usage

The restore/save split is intentional: composite actions have no automatic post-step hook, so the save must be called explicitly after your install step. This also gives you control over the condition — you only pay the save cost when the cache actually missed.

```yaml
- name: Read Flutter version
  id: flutter-version
  run: echo "version=$(cat .flutter-version)" >> "$GITHUB_OUTPUT"

- name: Restore Flutter SDK
  id: flutter-cache
  uses: curlewlabs-com/local-cache@v3
  with:
    path: ${{ runner.tool_cache }}/flutter
    key: flutter-${{ steps.flutter-version.outputs.version }}-stable-${{ runner.os }}-${{ runner.arch }}
    cache-dir: /path/to/shared/cache   # persistent path shared across runners on this machine

- name: Set up Flutter
  uses: subosito/flutter-action@v2
  with:
    flutter-version: ${{ steps.flutter-version.outputs.version }}
    channel: stable
    cache: false

- name: Save Flutter SDK
  if: steps.flutter-cache.outputs.cache-hit != 'true'
  uses: curlewlabs-com/local-cache/save@v3
  with:
    path: ${{ runner.tool_cache }}/flutter
    key: flutter-${{ steps.flutter-version.outputs.version }}-stable-${{ runner.os }}-${{ runner.arch }}
    cache-dir: /path/to/shared/cache
```

On first run: cache miss → install runs → save populates the shared cache.
On subsequent runs (same key): marker matches → restore skipped → instant.
On version bump: marker differs → clean + rsync → a few seconds.

### Eliminating the three-step pattern

If you use the same tool in multiple workflows, a [local composite action](https://docs.github.com/en/actions/sharing-automations/creating-actions/creating-a-composite-action) wrapping restore + install + save collapses it to a single `uses:` line in every caller. Because the install step is *inside* the composite action, the save can be its last step — no explicit save step needed in the calling workflow.

```yaml
# .github/actions/flutter-setup/action.yml
inputs:
  flutter-version: { required: true }
  cache-dir: { required: true }
runs:
  using: composite
  steps:
    - uses: curlewlabs-com/local-cache@v3
      id: cache
      with:
        path: ${{ runner.tool_cache }}/flutter
        key: flutter-${{ inputs.flutter-version }}-stable-${{ runner.os }}-${{ runner.arch }}
        cache-dir: ${{ inputs.cache-dir }}
    - uses: subosito/flutter-action@v2
      with:
        flutter-version: ${{ inputs.flutter-version }}
        channel: stable
        cache: false
    - if: steps.cache.outputs.cache-hit != 'true'
      uses: curlewlabs-com/local-cache/save@v3
      with:
        path: ${{ runner.tool_cache }}/flutter
        key: flutter-${{ inputs.flutter-version }}-stable-${{ runner.os }}-${{ runner.arch }}
        cache-dir: ${{ inputs.cache-dir }}
```

Callers then use `uses: ./.github/actions/flutter-setup` with just `flutter-version` and `cache-dir`.

### Fallback keys

```yaml
- uses: curlewlabs-com/local-cache@v3
  with:
    path: ${{ env.HOME }}/.cargo/registry
    key: cargo-${{ hashFiles('Cargo.lock') }}
    restore-keys: |
      cargo-
    cache-dir: /path/to/shared/cache
```

`restore-keys` are tried in order. The first prefix that has any match wins; within that prefix's matches, the entry with the newest directory mtime — the most recently *saved* — is used. (A restore updates an entry's *last-used* time on its metadata file, not the directory, so reads never reorder this selection — see [Eviction](#eviction).) A prefix match sets `cache-hit=false` so the save step still runs and writes a *new* entry under the caller's exact key — the prefix-matched entry is not updated in place, so repeated runs with a rolling exact key produce N separate entries over time (see [Eviction](#eviction)).

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| `path` | Yes | Path to restore the cached directory to |
| `key` | Yes | Exact cache key |
| `restore-keys` | No | Newline-separated key prefixes for fallback matching |
| `cache-dir` | Yes | Absolute path to local cache directory (must be persistent and shared across runners; tilde expansion not supported) |

## Outputs

| Output | Description |
|--------|-------------|
| `cache-hit` | `true` if an exact key match was found |
| `cache-matched-key` | Key that was actually restored (empty on miss). For exact hits this is always the original raw key; for prefix hits it is the original raw key for newly saved entries, and the legacy directory name when restoring an older pre-encoding entry. |

### Environment variables

The restore step also sets these variables via `$GITHUB_ENV` for use in subsequent steps:

| Variable | Description |
|----------|-------------|
| `LOCAL_CACHE_HIT` | Same as `cache-hit` — `true` on exact match, `false` otherwise |
| `LOCAL_CACHE_MATCHED_KEY` | Same as `cache-matched-key` |

These are a convenience for steps that cannot easily reference action outputs (e.g. scripts in a separate composite action).

## Save inputs

| Input | Required | Description |
|-------|----------|-------------|
| `path` | Yes | Directory to save |
| `key` | Yes | Cache key |
| `cache-dir` | Yes | Must match the restore step |

## Upgrading from v2

Change `@v2` to `@v3` in your workflow files.

v3 features a collision-safe encoded on-disk cache layout. Existing exact-key entries from v2 and v1 remain fully readable, while newly saved entries use the safe encoded format. Your action workflows need no code changes other than bumping the tag; the underlying cache storage migration is transparent.

## Upgrading from v1

Change `@v1` to `@v3` in your workflow files. No other changes needed.

On the first restore after upgrading, the target directory is cleaned and re-synced (since v1 left hard-linked files with no marker). After that, restores with the same key are skipped entirely.

**Purge bloated v1 entries after upgrading.** v1 did not clean the target before restoring, so tools that install new versions alongside old ones (e.g. Flutter) caused the save step to capture every version ever installed. After upgrading, delete the old entries so the next save creates a clean one:

```sh
rm -rf /path/to/cache-dir/entries/* /path/to/cache-dir/entries/.tmp-*
```

The second glob sweeps any orphan staging directories left behind by crashed saves (see the Limitations section below). The default shell glob `*` does not match dotfiles, so both patterns are needed. This forces a one-time cache miss and re-download. Future entries will be clean because v2's restore starts from an empty target.

## When not to use this

If the tool respects an environment variable that controls where it stores its cache or installation (e.g. `PUB_CACHE`, `CARGO_HOME`, `BUN_INSTALL_CACHE_DIR`, `GRADLE_USER_HOME`), point that variable at a shared persistent directory instead. Every runner on the machine will use the same live directory with zero copying overhead — no restore or save step needed.

Use `local-cache` when you cannot control where a tool installs itself. The Flutter SDK (`subosito/flutter-action` installs into `runner.tool_cache`, which is per-runner) and the Cargo registry (`$HOME/.cargo`, which is per-user home) are typical examples: they do not natively share state across runners on the same machine.

## Eviction

`local-cache` never evicts on its own — a save doesn't touch sibling entries — so a key that encodes a rolling value (a Flutter SDK version, a `Cargo.lock` hash) accumulates one entry per value. What the action *does* provide is an accurate **last-used** signal, so an external sweep can reclaim space by genuine recency of use rather than recency of creation.

Every restore that serves an entry, including the constant-time marker-skip path, bumps the modification time of that entry's metadata file (`.local-cache-key`). So that file's mtime answers *"when was this entry last used"*, independent of the entry directory's mtime, which answers *"when was this entry last written"* (and is what prefix/`restore-keys` resolution sorts on). The two never interfere: reads move the former, writes move the latter.

That makes a least-recently-used sweep safe to run on a schedule:

```sh
# Remove entries not used in the last 30 days.
# Whole-entry granularity is deliberate: deleting individual files from
# inside a live entry would mutate the rsync source of an in-flight restore
# and corrupt it. Only ever remove an entry directory as a unit.
for meta in /path/to/cache-dir/entries/*/.local-cache-key; do
    [ -e "$meta" ] || continue
    if [ -n "$(find "$meta" -mtime +30)" ]; then
        rm -rf "$(dirname "$meta")"
    fi
done
```

Tune the window to your disk budget and bump cadence. Entries written by an older version that predate the metadata file are skipped by the loop above; clear those with a one-time `rm -rf cache-dir/entries/*` after upgrading, which forces a clean re-download on next use. This manual loop reclaims *entries* only — not the per-runner restore-target copies or their records in the parallel `targets/` tree; the [`gc` action](#the-gc-action) below reclaims both, under the save/restore locks.

### The `gc` action

`curlewlabs-com/local-cache/gc@v3` runs that sweep for you, and additionally reclaims the **restore targets** — the per-runner copies an entry was rsynced *to* on each cache hit, which accumulate separately from the store. Every served restore records its target in a parallel `targets/<encoded-key>/` tree (a sibling of `entries/`, kept out of the entry so it can't disturb prefix-selection order), one small file per target; when the gc evicts a cold entry it reclaims those recorded copies first, then the entry itself — each under the same per-key and per-target locks the save and restore steps hold, so a sweep never races live traffic.

```yaml
- uses: curlewlabs-com/local-cache/gc@v3
  with:
    cache-dir: /path/to/cache-dir   # the same value your restore/save steps use
    max-age-days: 30                # evict entries not restored in this many days
    apply: true                     # omit or set false for a dry-run report
```

Because the last-used mtime is bumped by *any* runner that shares the store, a cold entry proves every runner's copy is idle — so one scheduled gc reclaims both the store and the per-runner tool caches across all runners on the machine.

**Safety is layered.** The gc holds the same per-key and per-target locks as save and restore, so evicting an entry can't race a save or restore of it and reclaiming a target can't race a restore to it. What no lock can cover is the window *after* a restore step — and its lock — has finished, while the job keeps using the restored copy for minutes: that is what `max-age-days` covers, so it must comfortably exceed your longest job. As further independent backstops the gc spares a target whose owning entry is no longer cold (a concurrent restore bumped it) or any target with a file modified inside the window (an in-progress build writes into its restored tree). The locks make eviction atomic; the time threshold is what makes it safe — keep it well above your longest job. Size that window for the job's *total* runtime, reads included: `rsync -a` preserves the cache's original mtimes and a skip rewrites nothing, so the mtime backstop only ever sees *writes into* a target, never a job merely reading one. And since the locks live in one shared directory (`/tmp` by default), every runner sharing the `cache-dir` must share that lock directory too — automatic on a single machine, but on a topology that gives each runner a private `/tmp` the locks don't cross runners and the gc could delete a target another runner is restoring.

## Limitations

- **No automatic eviction.** A save never deletes sibling entries, so a key that encodes a rolling value accumulates one entry per value over time. Entries do carry an accurate last-used timestamp, so a scheduled least-recently-used sweep — the bundled [`gc` action](#the-gc-action), which reclaims cold entries and their restore targets under the same locks the save and restore steps hold, or the entry-only shell recipe above — can reclaim space safely. See [Eviction](#eviction). For a full reset, `rm -rf cache-dir/entries/* cache-dir/targets/*`.
- **SIGKILL/OOM can orphan staging directories.** The save step rsyncs into a `.tmp-<key>-<pid>` staging directory under `entries/` and then renames it into place atomically. A normal exit, `INT`, or `TERM` cleans the staging directory up via trap, but `SIGKILL` / OOM kill / power loss between `mkdir` and `mv` leaves the `.tmp-*` directory behind. These are safe — the restore-side prefix match rejects any `.tmp-*` name so they never produce ghost cache hits — but they do consume disk space. If you notice `entries/` growing unexpectedly, sweep them with `rm -rf cache-dir/entries/.tmp-*` during a maintenance window.
- **Each restore is a full copy.** When the marker doesn't match (version bump, first v2 restore), the full artifact is copied from cache to target. For a 1.8 GB Flutter SDK this takes a few seconds on SSD — trivial compared to the network download it replaces.
- **macOS Spotlight indexing.** On macOS runners, restoring large cache entries (e.g. the Flutter SDK) can trigger `mds` / `mds_stores` to re-index the restored files, causing CPU spikes. Exclude the runner's root directory (or at minimum the `cache-dir`) from Spotlight indexing via System Settings > Spotlight > Privacy, or programmatically with `mdutil -i off /path/to/runner`.
- **Windows Defender on WSL2.** If your runners run inside WSL2 and you notice CPU spikes from `MsMpEng.exe` after cache restores, Windows Defender may be scanning files written to the WSL2 filesystem. Add the WSL2 distribution's directory to the Defender exclusion list in Windows Security settings.
- **No GitHub cloud fallback.** Unlike `actions/cache`, there is no network fallback on a local miss. The first run on a new machine always downloads.
- **Explicit save required.** Composite actions have no automatic post-step hook, so you must call `curlewlabs-com/local-cache/save@v3` explicitly after your install step. A JavaScript action with a `post:` hook would enable a single-step interface, but adds a build step and Node.js dependency that this action avoids by being pure shell.

## Releasing

Every release ships **both** an immutable patch tag (`vMAJOR.MINOR.PATCH`, e.g. `v3.0.1`) and a floating major tag (`vMAJOR`, e.g. `v3`). Users who want exact reproducibility pin to `@v3.0.1`; users who want automatic minor/patch updates inside the v3 series pin to `@v3`. Both tag kinds exist for every release. See [AGENTS.md](AGENTS.md) for the full contract.

After merging to `main`:

```sh
# Immutable patch tag — never force-moved once pushed.
git tag v3.x.y HEAD
git push origin v3.x.y

# Floating major tag — force-updated to the latest v3.x.y commit on every release.
git tag -f v3 HEAD
git push --force origin v3

# GitHub release for the marketplace.
gh release create v3.x.y --title "v3.x.y" --notes "changelog here"
```

## License

MIT
