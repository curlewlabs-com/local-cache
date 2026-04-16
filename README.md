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

**Two-phase restore:** The restore step runs in two phases. Phase 1 checks the marker in parallel with no locking — if the target is already current, the restore finishes immediately. If not, Phase 2 acquires a per-key lock (shared with the save step via [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex)) and performs the full rsync. This means steady-state restores (the common case) never contend on the lock, while cold-start restores serialize against each other and against concurrent saves of the same key.

On save, content is synced to a temp directory then renamed atomically into place. Concurrent writers of the same key are serialized through [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex) (`lockf`/`flock` under the hood, kernel-managed cleanup on process death). The second writer waits for the first to finish, then re-checks and exits cleanly because the entry now exists. Saves of *different* keys still run in parallel — the lock is per-key.

**Why clean-before-restore matters:** The `rm -rf` on every re-sync (i.e. whenever the marker is missing or points at a different key) is deliberate — it prevents stale content from accumulating across version bumps. Without it, tools that install new versions alongside old ones (e.g. `subosito/flutter-action` in `runner.tool_cache`) would cause the save step to capture every version ever installed, growing the cache entry without bound. The clean re-sync ensures the target only ever contains what the cache entry has plus what the current install step adds — nothing from previous versions survives.

**Why not hard links?** v1 used `rsync --link-dest` for zero-copy restores. This is unsafe when multiple runners restore the same entry concurrently: hard links share the same inode, so if one consumer modifies a file (e.g. `flutter` upgrading `engine.version` during setup), the modification corrupts the cache entry for every other consumer.

**Why not copy-on-write (APFS clones, reflinks)?** CoW semantics are not portable: `cp -c` is macOS-only (APFS), `cp --reflink` is Linux-only (Btrfs/XFS, not ext4), and edge-case behavior (failure modes, metadata preservation on fallback) varies across OS versions. We optimize for easy to understand over minimal: one tool (`rsync`), one behavior, no platform detection. The marker-based skip also makes CoW redundant for the common case — steady-state restores are constant-time work, and version bumps (the only case CoW would help) are rare and take seconds.

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

`restore-keys` are tried in order. The first prefix that has any match wins; within that prefix's matches, the most recently modified entry is used. A prefix match sets `cache-hit=false` so the save step still runs and writes a *new* entry under the caller's exact key — the prefix-matched entry is not updated in place, so repeated runs with a rolling exact key produce N separate entries over time (see the "No TTL or eviction" limitation below).

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

## Limitations

- **No TTL or eviction.** Cache entries accumulate until manually deleted. For artifacts that change infrequently (e.g. Flutter SDK, updated monthly) this is fine. Clean up with `rm -rf cache-dir/entries/*`.
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
