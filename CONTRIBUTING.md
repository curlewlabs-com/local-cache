# Contributing

Thanks for your interest in improving `local-cache`. The bar for a change is
whether every restore still hands its runner an intact copy of its own, and
nothing a save, restore or gc sweep does alongside it can corrupt an entry or
that copy. Bug fixes, faster restores that build the same tree, clearer
messages when a step refuses or misses, and clearer docs are all welcome.

## Before a large change

Open an issue describing the problem first. Two things carry that guarantee
and are easy to break by accident. The locks: which ones a save, a restore and
a gc sweep take, and the order they nest in, so that nothing holds a target
lock while it waits on a key lock. The on-disk layout: the encoded entry
names, the restore marker, and the split between an entry's last-used and
last-written times, which runners on older releases share. README.md's "How
it works" and "Eviction" sections describe both, and AGENTS.md lists the
locks. A short discussion up front saves rework.

## Running the checks

CI runs these on every push to `main` and every pull request against it:

```sh
shellcheck -x --source-path=SCRIPTDIR lib/*.sh
actionlint
```

The integration tests are the steps of `.github/workflows/ci.yml`, and run on
GitHub's hosted runners: on `ubuntu-latest`, where restores copy with `rsync`;
on `macos-latest`, where they clone with `cp -c`; on an Ubuntu leg that mounts
XFS with reflinks over `/tmp`, where they clone with `cp --reflink`; and in a
stress job that races prefix restores against a gc sweep. A new test goes in
that file beside them.

Keep each pull request to one change, with its test, and describe the why in
its body. AGENTS.md holds the repository's rules and its release steps.

## License

By submitting a contribution for inclusion in this project, you agree that it
is licensed under the MIT and Apache-2.0 licenses, as the README's License
section describes, without any additional terms or conditions.
