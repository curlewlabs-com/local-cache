# local-cache

Local-disk cache for self-hosted GitHub Actions runners.

A drop-in replacement for [`actions/cache`](https://github.com/actions/cache) that reads and writes a shared directory on the runner's local filesystem instead of GitHub's cloud cache servers. When you run N runners on the same physical machine, they all share one cache — the first runner to encounter a cache miss downloads and stores the content, and every subsequent runner gets an instant local hit.

## Why

`actions/cache` stores entries on GitHub's servers. Every restore is a download over the network, and every save is an upload. For large artifacts — the Flutter SDK is ~1.8 GB, a Cargo registry can be hundreds of MB — this costs real time on every run, even when nothing has changed.

Self-hosted runners on the same physical machine make this worse: each runner operates independently, so if you have four runners and a warm cloud cache, you still download the artifact four times per run.

With `local-cache`, the artifact lives on the machine's local disk. On the first cold run, all concurrent runners download independently — there is no mechanism to make later runners wait for the first to finish. One runner saves the result; the others skip the save cleanly via a `mkdir`-based advisory lock that prevents concurrent writes from corrupting the entry. After that initial population, no runner ever downloads again: each restore is an `rsync --link-dest` that creates hard links into the cache directory rather than copying data. Restore time scales with file count rather than data size, so even a 1.8 GB Flutter SDK restores in seconds instead of minutes.

## How it works

Cache entries are stored as plain directories under `cache-dir/entries/<key>/`. On restore, `rsync -a` copies the entry to the target path — a plain local copy that takes seconds even for large artifacts. The value is avoiding the network download, not optimizing the local copy. On save, content is synced to a temp directory then renamed atomically into place. Concurrent writers are serialized with a `mkdir`-based advisory lock; the second writer skips rather than corrupting the entry.

**Why not hard links?** An earlier version used `rsync --link-dest` for zero-copy restores. This is unsafe when multiple runners restore the same entry concurrently: hard links share the same inode, so if one consumer modifies a file (e.g. `flutter` upgrading `engine.version` during setup), the modification is visible to every other consumer *and* corrupts the cache entry itself.

## Usage

The restore/save split is intentional: composite actions have no automatic post-step hook, so the save must be called explicitly after your install step. This also gives you control over the condition — you only pay the save cost when the cache actually missed.

```yaml
- name: Read Flutter version
  id: flutter-version
  run: echo "version=$(cat .flutter-version)" >> "$GITHUB_OUTPUT"

- name: Restore Flutter SDK
  id: flutter-cache
  uses: curlewlabs-com/local-cache@v1
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
  uses: curlewlabs-com/local-cache/save@v1
  with:
    path: ${{ runner.tool_cache }}/flutter
    key: flutter-${{ steps.flutter-version.outputs.version }}-stable-${{ runner.os }}-${{ runner.arch }}
    cache-dir: /path/to/shared/cache
```

On first run: cache miss → install runs → save populates the shared cache.
On subsequent runs (any runner on the same machine): cache hit → local rsync copy → seconds instead of minutes.

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
    - uses: curlewlabs-com/local-cache@v1
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
      uses: curlewlabs-com/local-cache/save@v1
      with:
        path: ${{ runner.tool_cache }}/flutter
        key: flutter-${{ inputs.flutter-version }}-stable-${{ runner.os }}-${{ runner.arch }}
        cache-dir: ${{ inputs.cache-dir }}
```

Callers then use `uses: ./.github/actions/flutter-setup` with just `flutter-version` and `cache-dir`.

### Fallback keys

```yaml
- uses: curlewlabs-com/local-cache@v1
  with:
    path: ${{ env.HOME }}/.cargo/registry
    key: cargo-${{ hashFiles('Cargo.lock') }}
    restore-keys: |
      cargo-
    cache-dir: /path/to/shared/cache
```

`restore-keys` are tried in order. The most recently modified matching entry wins. A prefix match sets `cache-hit=false` so the save step still runs and updates the entry with the exact key.

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
| `cache-matched-key` | Key that was actually restored (empty on miss). For prefix matches, this is the sanitized on-disk directory name, not the original key. |

## Save inputs

| Input | Required | Description |
|-------|----------|-------------|
| `path` | Yes | Directory to save |
| `key` | Yes | Cache key |
| `cache-dir` | Yes | Must match the restore step |

## When not to use this

If the tool respects an environment variable that controls where it stores its cache or installation (e.g. `PUB_CACHE`, `CARGO_HOME`, `BUN_INSTALL_CACHE_DIR`, `GRADLE_USER_HOME`), point that variable at a shared persistent directory instead. Every runner on the machine will use the same live directory with zero copying overhead — no restore or save step needed.

Use `local-cache` when you cannot control where a tool installs itself. The Flutter SDK (`subosito/flutter-action` installs into `runner.tool_cache`, which is per-runner) and the Cargo registry (`$HOME/.cargo`, which is per-user home) are typical examples: they do not natively share state across runners on the same machine.

## Limitations

- **No TTL or eviction.** Cache entries accumulate until manually deleted. For artifacts that change infrequently (e.g. Flutter SDK, updated monthly) this is fine. Clean up with `rm -rf cache-dir/entries/`.
- **Each restore is a full copy.** Disk usage scales with cache size × concurrent restores. For artifacts that don't change often (Flutter SDK), this is a few GB of local disk — trivial compared to the network time saved.
- **macOS Spotlight indexing.** On macOS runners, restoring large cache entries (e.g. the Flutter SDK) can trigger `mds` / `mds_stores` to re-index the restored files, causing CPU spikes. Exclude the runner's root directory (or at minimum the `cache-dir`) from Spotlight indexing via System Settings > Spotlight > Privacy, or programmatically with `mdutil -i off /path/to/runner`.
- **Windows Defender on WSL2.** If your runners run inside WSL2 and you notice CPU spikes from `MsMpEng.exe` after cache restores, Windows Defender may be scanning files written to the WSL2 filesystem. Add the WSL2 distribution's directory to the Defender exclusion list in Windows Security settings.
- **No GitHub cloud fallback.** Unlike `actions/cache`, there is no network fallback on a local miss. The first run on a new machine always downloads.
- **Explicit save required.** Composite actions have no automatic post-step hook, so you must call `curlewlabs-com/local-cache/save@v1` explicitly after your install step. A JavaScript action with a `post:` hook would enable a single-step interface, but adds a build step and Node.js dependency that this action avoids by being pure shell.

## Releasing

Users pin to `@v1` (floating major tag). After merging to `main`:

```sh
# Move the floating tag so @v1 users get the update.
git tag -f v1 HEAD
git push --force origin v1

# Create a versioned release for the marketplace.
git tag v1.x.y HEAD
git push origin v1.x.y
gh release create v1.x.y --title "v1.x.y" --notes "changelog here"
```

## License

MIT
