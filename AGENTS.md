# local-cache — Agent Instructions

## What this repo is

A GitHub composite action that provides local-disk caching for self-hosted runners, as a drop-in replacement for `actions/cache`. See README.md for full context.

## Rules

- Shell scripts in `lib/` must use `#!/bin/sh` and pass `shellcheck` with no warnings.
- No external dependencies beyond `rsync`, `sh`, and standard POSIX utilities.
- The action interface (`action.yml`, `save/action.yml`) must remain compatible with `actions/cache` inputs/outputs (`path`, `key`, `restore-keys`, `cache-hit`, `cache-matched-key`).
- Every change ships with a test in `.github/workflows/ci.yml`.
- Tag releases as `v1`, `v2`, etc. (major only). Use floating major tags.
- Never add a `cache-dir` default — callers must always be explicit about where their cache lives.
