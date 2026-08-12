# local-cache — Agent Instructions

## What this repo is

A GitHub composite action that provides local-disk caching for self-hosted runners, as a drop-in replacement for `actions/cache`. See README.md for full context.

## Rules

- Shell scripts in `lib/` must use `#!/bin/sh` and pass `shellcheck` with no warnings.
- No external dependencies beyond `rsync`, `sh`, and standard POSIX utilities. The one published-action dependency is [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex), which `action.yml`, `save/action.yml`, and `gc/action.yml` use to serialize concurrent access via the kernel's `lockf`/`flock` primitive: a per-key (`cache-save-<key>`) lock for save and the restore's full rsync, a per-target (`cache-target-<path>`) lock for the restore's quick check (and, nested in the key lock, its full restore), and the gc sweep — itself under a store-wide (`cache-gc`) lock — re-invokes itself through local-mutex's exported `LOCAL_MUTEX_CLI` to take those same per-key and per-target locks, so eviction never races a live save or restore. That CLI surface requires local-mutex **v2.1.0+**. **Pin this dependency to a full-length commit SHA with the tag it resolved from in a trailing comment (e.g. `@88393519d9c8488eeea41bbbb810e33a1ac6609a # v2.1.0`)** — not a version tag of any kind. Rationale: `local-cache` is a *published* action whose `action.yml` ships to public consumers. A floating `@v2` would mean every local-mutex retag silently changes behavior for pinned `local-cache@v3` consumers, defeating the point of pinning; and a version tag is no better as a guarantee, because a tag stays movable after it is pushed — that we never move ours is a convention a consumer has no way to verify, and moved tags have been a supply-chain vector in the wild. A SHA is the only ref they can check for themselves. Five refs carry this pin: `action.yml` (×2), `save/action.yml`, `gc/action.yml`, and the two `actions/checkout` steps in `.github/workflows/ci.yml` that fetch local-mutex for the direct-script gc lock tests — those last two are `with:`/`ref:` inputs rather than `uses:` refs, so dependabot does not see them and they only move when a human moves them. The trailing comment is documentation, not a checked assertion: dependabot rewrites it when it bumps a `uses:` ref, but it will not repair one that is already wrong (dependabot-core#7912), so re-derive the tag→SHA mapping from the local-mutex repo rather than trusting the comment. Bump all five in one dedicated PR when you want to adopt a new local-mutex release.
- The action interface (`action.yml`, `save/action.yml`) must remain compatible with `actions/cache` inputs/outputs (`path`, `key`, `restore-keys`, `cache-hit`, `cache-matched-key`).
- Every change ships with a test in `.github/workflows/ci.yml`.
- Release tagging: every release gets a **fixed patch tag** of the
  form `vMAJOR.MINOR.PATCH` (e.g. `v3.0.0`, `v3.0.1`) that, once pushed,
  we never force-move — this is what downstream callers pin to if they
  want a stable reference. Treat that as a promise we keep, not a
  property the platform enforces: no tag ruleset protects this repo, so
  a caller who needs the guarantee rather than the promise pins the
  commit SHA instead, exactly as we pin local-mutex above. In addition,
  the **floating major tag** `vMAJOR` (e.g. `v3`) is force-updated on
  every release in that major series so it always points at the latest
  `v3.x.y` commit. Callers that track `@v3` get automatic minor/patch
  updates inside the same major
  series; callers pinned to `@v3.0.1` stay pinned forever. Both kinds of
  tags exist in this repo and both are part of the release contract. Use
  `git tag v3.0.1 HEAD` (fixed) and `git tag -f v3 HEAD` followed by
  `git push --force origin v3` (floating) when cutting a release, and
  create a matching GitHub release with `gh release create v3.0.1`.
- Never add a `cache-dir` default — callers must always be explicit about where their cache lives.
