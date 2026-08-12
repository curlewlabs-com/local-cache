# local-cache — Agent Instructions

## What this repo is

A GitHub composite action that provides local-disk caching for
self-hosted runners, as a drop-in replacement for `actions/cache`. See
README.md for full context.

## Rules

- Shell scripts in `lib/` must use `#!/bin/sh` and pass `shellcheck`
  with no warnings.
- No external dependencies beyond `rsync`, `sh`, and standard POSIX
  utilities. The one published-action dependency is local-mutex, which
  has its own section below.
- The action interface (`action.yml`, `save/action.yml`) must remain
  compatible with `actions/cache` inputs and outputs: `path`, `key`,
  `restore-keys`, `cache-hit`, `cache-matched-key`.
- Every change ships with a test in `.github/workflows/ci.yml`.
- Never add a `cache-dir` default. Callers must always be explicit
  about where their cache lives.

## The local-mutex dependency

[`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex)
serializes concurrent access through the kernel's `lockf`/`flock`
primitive. `action.yml`, `save/action.yml`, and `gc/action.yml` all use
it.

### What each lock guards

| Lock | Held by |
| --- | --- |
| `cache-save-<key>` | Save, and the restore's full rsync. |
| `cache-target-<path>` | The restore's quick check — and, nested inside the key lock, its full restore. |
| `cache-gc` | The gc sweep, store-wide. |

The gc sweep re-invokes itself through local-mutex's exported
`LOCAL_MUTEX_CLI` to take those same per-key and per-target locks, so
eviction never races a live save or restore. That CLI surface requires
local-mutex **v2.1.0+**.

### Pin it to a commit SHA

Pin local-mutex to a full-length commit SHA, carrying the tag it
resolved from in a trailing comment. Never pin to a version tag.

```yaml
uses: curlewlabs-com/local-mutex@88393519d9c8488eeea41bbbb810e33a1ac6609a # v2.1.0
```

Why not a tag:

- **`local-cache` is a published action.** Its `action.yml` ships to
  public consumers, so a floating `@v2` would let every local-mutex
  retag silently change behavior for a consumer pinned to
  `local-cache@v3` — defeating the point of their pin.
- **A version tag is no better as a guarantee.** Tags stay movable
  after they are pushed. That we never move ours is a convention a
  consumer has no way to verify, and moved tags have been a
  supply-chain vector in the wild. A SHA is the only ref they can check
  for themselves.

### Bumping the pin

Move every site in one dedicated PR. `grep -rn local-mutex .`
enumerates the live set — sweep that rather than a remembered count,
because a single file can carry the pin more than once.

Two traps:

- **The CI checkouts are invisible to dependabot.** The
  `actions/checkout` steps in `.github/workflows/ci.yml` that fetch
  local-mutex for the direct-script gc lock tests pass it as a
  `with:`/`ref:` input, not a `uses:` ref. Dependabot never sees them;
  they move only when a human moves them.
- **The trailing comment is documentation, not a checked assertion.**
  Dependabot rewrites it when it bumps a `uses:` ref, but it will not
  repair one that is already wrong (dependabot-core#7912). Re-derive
  the tag→SHA mapping from the local-mutex repo instead of trusting
  what the comment says.

## Releases

Every release gets a **fixed patch tag** — `vMAJOR.MINOR.PATCH`, e.g.
`v3.0.1` — that we never force-move once pushed. This is what
downstream callers pin to when they want a stable reference.

Treat that as a promise we keep, not a property the platform enforces:
no tag ruleset protects this repo. A caller who needs the guarantee
rather than the promise pins the commit SHA instead, exactly as we pin
local-mutex above.

Every release also force-updates the **floating major tag** —
`vMAJOR`, e.g. `v3` — so it always points at the latest `v3.x.y`
commit. Callers tracking `@v3` get automatic minor and patch updates
inside that major series; callers pinned to `@v3.0.1` stay pinned
forever. Both kinds of tag exist here, and both are part of the release
contract.

To cut a release:

```sh
git tag v3.0.1 HEAD          # fixed patch tag
git push origin v3.0.1

git tag -f v3 HEAD           # floating major tag
git push --force origin v3

gh release create v3.0.1
```
