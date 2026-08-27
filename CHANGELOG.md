# Changelog

## Unreleased

### Bug fixes

- Bundle the volume-tool image `alpine:3.20` (~3.5 MB) into `images.tar` during backup so the restore side gets it via `docker load` and never needs `docker pull`. Servers that intentionally keep an old environment can ship an `unpigz` built against zlib < 1.2.3, which makes every `docker pull` fail at layer extraction (`failed to register layer: unpigz: abort`) while `docker load` keeps working; the migration is now immune to this and fully offline-capable.
- When the tool image is still missing (old bundles on such servers), print actionable guidance (remove or upgrade `pigz`, or re-create the bundle with the new script) before aborting before any data is touched.
- Stop failing volume and bind restores over absolute symlinks such as `mysql.sock -> /var/run/mysqld/mysqld.sock`, a common runtime artifact in MySQL data volumes. Absolute links resolve inside the service container that mounts the volume and cannot escape to the host; they are now preserved with an informational log entry instead of silently aborting the whole restore transaction.
- Print the offending link path and target when a relative symlink lexically escapes the mount root, instead of failing without any diagnostic.

## 2.0.0

### Reliability

- Fail the backup when an image, named volume, bind mount, Compose file, or network definition cannot be captured.
- Preserve command exit codes and return a non-zero status when any restore item fails.
- Restore the source server's original running-container state on normal exit, errors, and signals.
- Keep containers that were already stopped in their original stopped state.
- Remove invalid top-level `local` declarations from generated scripts.

### Restore fidelity

- Add `RESTORE_EXISTING=replace|skip|fail`; the default `replace` performs a complete configuration restore.
- Preserve custom network driver, IPAM, subnet, gateway, IPv6, options, labels, static IPs, and aliases.
- Merge all Compose `-f` files into a canonical restore configuration.
- Preserve relative and absolute `env_file` inputs as a fallback.
- Restore fractional CPU limits, health-check forms, and container namespace references.

### Compatibility

- Add `--backup` and `--restore=URL` non-interactive modes.
- Add fallbacks for systems without GNU `flock`, `timeout`, `sed -i`, or `grep -P`.
- Keep Bash 4.0 as the minimum supported version.

### Low-friction security

- Use owner-only permissions for generated artifacts.
- Generate and verify a SHA-256 manifest automatically.
- Validate archive paths before extraction.
- Preserve random URL paths in Python and BusyBox HTTP modes.
- Add no-store, attachment, and nosniff HTTP response headers.

### Testing

- Add unit tests for failure propagation, generated scripts, checksums, archives, and Compose parsing.
- Add Docker integration coverage for networks, static IPs, health checks, fractional CPU limits, Compose, and existing-container policies.
- Add GitHub Actions jobs for syntax, ShellCheck, shfmt, unit tests, and Docker integration.
