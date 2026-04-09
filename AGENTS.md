# local-cache — Agent Instructions

## What this repo is

A GitHub composite action that provides local-disk caching for self-hosted runners, as a drop-in replacement for `actions/cache`. See README.md for full context.

## Rules

- Shell scripts in `lib/` must use `#!/bin/sh` and pass `shellcheck` with no warnings.
- No external dependencies beyond `rsync`, `sh`, and standard POSIX utilities. The one published-action dependency is [`curlewlabs-com/local-mutex`](https://github.com/curlewlabs-com/local-mutex), which `save/action.yml` uses to serialize per-key concurrent writers via the kernel's `lockf`/`flock` primitive. Pin local-mutex to a specific patch version (e.g. `@v1.0.4`, not `@v1`) so that updates land as reviewable PRs rather than silently following whatever the upstream major tag points at.
- The action interface (`action.yml`, `save/action.yml`) must remain compatible with `actions/cache` inputs/outputs (`path`, `key`, `restore-keys`, `cache-hit`, `cache-matched-key`).
- Every change ships with a test in `.github/workflows/ci.yml`.
- Tag releases as `v2`, `v3`, etc. (major only). Use floating major tags.
- Never add a `cache-dir` default — callers must always be explicit about where their cache lives.
