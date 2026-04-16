# local-cache — Agent Instructions

## What this repo is

A GitHub composite action that provides local-disk caching for self-hosted runners, as a drop-in replacement for `actions/cache`. See README.md for full context.

## Rules

- Shell scripts in `lib/` must use `#!/bin/sh` and pass `shellcheck` with no warnings.
- No external dependencies beyond `rsync`, `sh`, and standard POSIX utilities. The one published-action dependency is [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex), which both `action.yml` and `save/action.yml` use to serialize per-key concurrent access via the kernel's `lockf`/`flock` primitive. **Pin this dependency to an immutable patch tag (e.g. `@v2.0.1`)**, not the floating major tag. Rationale: `local-cache` is a *published* action whose `action.yml` ships to public consumers. A floating `@v2` in our `action.yml` would mean every local-mutex retag silently changes behavior for pinned `local-cache@v3` consumers, defeating the point of pinning. Bump the pin in a dedicated PR when you want to adopt a new local-mutex release.
- The action interface (`action.yml`, `save/action.yml`) must remain compatible with `actions/cache` inputs/outputs (`path`, `key`, `restore-keys`, `cache-hit`, `cache-matched-key`).
- Every change ships with a test in `.github/workflows/ci.yml`.
- Release tagging: every release gets an **immutable patch tag** of the
  form `vMAJOR.MINOR.PATCH` (e.g. `v3.0.0`, `v3.0.1`) that, once pushed,
  is never force-moved — this is what downstream callers pin to if they
  need exact reproducibility. In addition, the **floating major tag**
  `vMAJOR` (e.g. `v3`) is force-updated on every release in that major
  series so it always points at the latest `v3.x.y` commit. Callers that
  track `@v3` get automatic minor/patch updates inside the same major
  series; callers pinned to `@v3.0.1` stay pinned forever. Both kinds of
  tags exist in this repo and both are part of the release contract. Use
  `git tag v3.0.1 HEAD` (immutable) and `git tag -f v3 HEAD` followed by
  `git push --force origin v3` (floating) when cutting a release, and
  create a matching GitHub release with `gh release create v3.0.1`.
- Never add a `cache-dir` default — callers must always be explicit about where their cache lives.
