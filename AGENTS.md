# local-cache — Agent Instructions

## What this repo is

A GitHub composite action that provides local-disk caching for self-hosted runners, as a drop-in replacement for `actions/cache`. See README.md for full context.

## Rules

- Shell scripts in `lib/` must use `#!/bin/sh` and pass `shellcheck` with no warnings.
- No external dependencies beyond `rsync`, `sh`, and standard POSIX utilities. The one published-action dependency is [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex), which both `action.yml` and `save/action.yml` use to serialize per-key concurrent access via the kernel's `lockf`/`flock` primitive. **Pin this dependency to an immutable patch tag (e.g. `@v2.0.0`)**, not the floating major tag. Rationale: `local-cache` is a *published* action whose `action.yml` ships to public consumers. A floating `@v2` in our `action.yml` would mean every local-mutex retag silently changes behavior for pinned `local-cache@v3` consumers, defeating the point of pinning. Bump the pin in a dedicated PR when you want to adopt a new local-mutex release.
- The action interface (`action.yml`, `save/action.yml`) must remain compatible with `actions/cache` inputs/outputs (`path`, `key`, `restore-keys`, `cache-hit`, `cache-matched-key`).
- Every change ships with a test in `.github/workflows/ci.yml`.
- Tag releases as `v2`, `v3`, etc. (major only). Use floating major tags.
- Never add a `cache-dir` default — callers must always be explicit about where their cache lives.
