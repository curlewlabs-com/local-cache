# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it
privately via [GitHub's security advisory feature](https://github.com/curlewlabs-com/local-cache/security/advisories/new).

Do not open a public issue for security vulnerabilities.

## Scope

This action reads and writes cache entries on the runner's local filesystem
using `rsync` and standard POSIX utilities. The primary security surface is:

- **Input sanitization:** The `key` and `restore-keys` inputs are sanitized to
  `[a-zA-Z0-9._-]` before being used as directory names. Path traversal via
  cache keys is blocked by this sanitization. Keys that sanitize to `.` or `..`
  are explicitly rejected.
- **File operations:** The action creates, copies, and deletes directories
  under the caller-specified `cache-dir`. It does not access the network.
