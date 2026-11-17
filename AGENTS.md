# local-cache - Agent Instructions

## What this repo is

A GitHub composite action that provides local-disk caching for
self-hosted runners, as a drop-in replacement for `actions/cache`. See
README.md for full context.

## Rules

- Shell scripts in `lib/` must use `#!/bin/sh` and pass `shellcheck`
  with no warnings.
- No external dependencies beyond `rsync`, `sh`, and standard POSIX
  utilities. The one published-action dependency is local-mutex, which
  has its own section below. GNU `cp --reflink` (Linux) and the
  built-in `cp -c` (macOS, APFS) are used only where `copy_tree` in
  `lib/cache-common.sh` finds the filesystem can clone, never required:
  it falls back to `rsync` everywhere else, so a change to any copy path
  must keep them all building the same tree. Clones are restore-only;
  saves always `rsync`, for the reasons at that line of `lib/cache-save.sh`.
- The action interface (`action.yml`, `save/action.yml`) must remain
  compatible with `actions/cache` inputs and outputs: `path`, `key`,
  `restore-keys`, `cache-hit`, `cache-matched-key`.
- Every change ships with a test in `.github/workflows/ci.yml`.
- Never add a `cache-dir` default. Callers must always be explicit
  about where their cache lives.
- Tracked text is ASCII. Use plain hyphens, `->`, and words instead of Unicode
  punctuation or decorative status symbols.

## The local-mutex dependency

[`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex)
serializes concurrent access through the kernel's `lockf`/`flock`
primitive. `action.yml`, `save/action.yml`, and `gc/action.yml` all use
it.

### What each lock guards

| Lock | Held by |
| --- | --- |
| `cache-save-<key>` | Save, and the restore's full copy. |
| `cache-target-<path>` | The restore's quick check - and, nested inside the key lock, its full restore. |
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
  `local-cache@v3` - defeating the point of their pin.
- **A version tag is no better as a guarantee.** Tags stay movable
  after they are pushed. That we never move ours is a convention a
  consumer has no way to verify, and moved tags have been a
  supply-chain vector in the wild. A SHA is the only ref they can check
  for themselves.

### Bumping the pin

Every site moves in one PR. Renovate opens it when local-mutex
releases: it reads the `uses:` refs itself and the `ref:` inputs
through the `# renovate:` comment above each, and moves each SHA with
its trailing comment, all on one branch. By hand,
`grep -rn local-mutex .` enumerates the live set - sweep that rather
than a remembered count, because a single file can carry the pin more
than once.

Two traps:

- **A site that is not a `uses:` ref needs the comment.** The
  `actions/checkout` steps in `.github/workflows/ci.yml` that fetch
  local-mutex for the direct-script gc lock tests pass it as a
  `with:`/`ref:` input. Renovate reads those only through the
  `# renovate: ... pin=digest` comment on the line above; a new one
  without it stays behind when the rest move.
- **The trailing comment is documentation, not a checked assertion.**
  Renovate rewrites it with the SHA, and nothing verifies one written
  by hand. When editing by hand, re-derive the tag->SHA mapping from
  the local-mutex repo instead of trusting what the comment says.

## Pinning everything else

Every other action in this repo - the `actions/checkout` steps in
`.github/workflows/ci.yml` - is pinned the same way: its release's
commit SHA, with the tag in a trailing comment. These steps run only in
our CI, but a tag can still be moved to other code between two of its
runs, and only a SHA names what runs. Renovate proposes each new
release and moves the SHA and the comment together.

This costs alerting. GitHub raises Dependabot *alerts* only for actions
pinned with semantic versioning, [not for actions pinned to a
SHA][secure-use], so a fix to one of these actions reaches this repo as
Renovate's next update rather than as an alert.

The checkout steps that fetch local-mutex carry two pins on adjacent
lines:

```yaml
- name: Check out local-mutex (pinned) for the direct-script gc lock tests
  uses: actions/checkout@<checkout commit SHA> # v7.0.1
  with:
    repository: curlewlabs-com/local-mutex
    # renovate: datasource=github-tags depName=curlewlabs-com/local-mutex pin=digest
    ref: <local-mutex commit SHA> # v2.3.0
    path: .local-mutex
```

The `uses:` SHA is the checkout pin. The `ref:` SHA is the local-mutex
pin, which this step carries because the tests must run against the
identical local-mutex tree the actions resolve, so it moves with the
local-mutex pins above, never with checkout's.

[secure-use]: https://docs.github.com/en/actions/reference/security/secure-use

## Releases

Every release gets a **fixed patch tag** - `vMAJOR.MINOR.PATCH`, e.g.
`v3.0.1` - that we never force-move once pushed. This is what
downstream callers pin to when they want a stable reference.

The repository enforces that contract twice: the fixed-version-tag ruleset
blocks updates and deletions of `vMAJOR.MINOR.PATCH`, and publishing its GitHub
Release makes the tag and release assets immutable. A caller may still pin the
commit SHA when its own policy requires a content-addressed reference, exactly
as we pin local-mutex above.

Every release also force-updates the **floating major tag** -
`vMAJOR`, e.g. `v3` - so it always points at the latest `v3.x.y`
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

gh release create v3.0.1  # locks the patch tag and release assets
```
