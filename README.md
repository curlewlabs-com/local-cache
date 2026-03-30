# local-cache

Local-disk cache for self-hosted GitHub Actions runners.

A drop-in replacement for [`actions/cache`](https://github.com/actions/cache) that reads and writes a shared directory on the runner's local filesystem instead of GitHub's cloud cache servers. When you run N runners on the same physical machine, they all share one cache — the first runner to encounter a cache miss downloads and stores the content, and every subsequent runner gets an instant local hit.

## Why

`actions/cache` uploads to and downloads from GitHub's servers on every run. For large artifacts like the Flutter SDK (~1.8 GB), this adds meaningful time to every CI run even on a cache hit. If you have multiple self-hosted runners on the same machine, each runner downloads independently.

With `local-cache`, a cache hit is a local `rsync` with hard links — effectively instant regardless of artifact size.

## How it works

Cache entries are stored as plain directories under `cache-dir/entries/<key>/`. On restore, `rsync --link-dest` creates hard links from the cache entry to the target path (zero-copy on same filesystem, automatic fallback to copy cross-filesystem). On save, content is synced to a temp directory then renamed atomically into place. Concurrent writers are serialized with a `mkdir`-based advisory lock; the second writer skips rather than corrupting the entry.

## Usage

Because this is a composite action (no JavaScript post-step hook), save must be called explicitly after your install step. Use the restore/save split pattern:

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
On subsequent runs (any runner on the same machine): cache hit → rsync with hard links → near-instant.

### Fallback keys

```yaml
- uses: curlewlabs-com/local-cache@v1
  with:
    path: ~/.cargo/registry
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
| `cache-dir` | Yes | Local directory for cache storage (must be persistent and shared across runners) |

## Outputs

| Output | Description |
|--------|-------------|
| `cache-hit` | `true` if an exact key match was found |
| `cache-matched-key` | Key that was actually restored (empty on miss) |

## Save inputs

| Input | Required | Description |
|-------|----------|-------------|
| `path` | Yes | Directory to save |
| `key` | Yes | Cache key |
| `cache-dir` | Yes | Must match the restore step |

## Limitations

- **No TTL or eviction.** Cache entries accumulate until manually deleted. For artifacts that change infrequently (e.g. Flutter SDK, updated monthly) this is fine. Clean up with `rm -rf cache-dir/entries/`.
- **Hard links require same filesystem.** If `cache-dir` is on a different filesystem than `path`, `rsync` falls back to a regular copy automatically. The cache still works, just without the zero-copy benefit.
- **No GitHub cloud fallback.** Unlike `actions/cache`, there is no network fallback on a local miss. The first run on a new machine always downloads.
- **Composite action only.** No implicit post-step save hook. You must call `curlewlabs-com/local-cache/save@v1` explicitly.

## License

MIT
