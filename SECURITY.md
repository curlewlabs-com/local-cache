# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it
privately via [GitHub's security advisory feature](https://github.com/curlewlabs-com/local-cache/security/advisories/new).

Do not open a public issue for security vulnerabilities.

## Scope

This action reads and writes cache entries on the runner's local filesystem
using `rsync` and standard POSIX utilities. The primary security surface is:

- **Key-to-path mapping:** The `key` and `restore-keys` inputs are encoded into
  collision-free directory names before they are used on disk. This blocks path
  traversal via cache keys without conflating distinct raw keys such as `a/b`
  and `a:b`.
- **File operations:** The action creates, copies, and deletes directories
  under the caller-specified `cache-dir`. It does not access the network.
