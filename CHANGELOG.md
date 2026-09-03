# Changelog

## Unreleased

### Bug fixes

- Fix `docker: Error response from daemon: invalid mode: ro,ro` when recreating containers whose bind mounts are read-only (e.g. `-v /etc/localtime:/etc/localtime:ro`). `Mounts[].Mode` already carries `ro` for such mounts and the generator appended another `ro` based on `RW=false`, producing an invalid doubled mode. The `ro` flag is now appended only when not already present in the mount options.

- Stop failing bind restores whose host path is a symlink, most notably `/etc/localtime -> /usr/share/zoneinfo/…` when a container mounts `-v /etc/localtime:/etc/localtime`. The archive preserves the link, and the restore used to reject any symlink bind root over a (too conservative) ambiguity concern; absolute links keep their meaning when moved out of staging, so they now pass through, and relative links are lexically rewritten to an absolute target first. Symlink roots carry no file content, so the tree-escape check does not apply to them.

- Fix an intermittent race that silently skipped the shared-image-group rebuild: `tar --help | grep -q -- '--delete'` runs under `set -o pipefail`, and `grep -q` exits as soon as it matches, so `tar` (\~16 KB of help text) could receive SIGPIPE and fail with 141, making the whole pipeline report "no --delete support" about 20% of the time. The group logic was then skipped entirely, the base image was never rebuilt, and container run scripts fell back to `docker pull` of the private image, failing the restore. The check (and the same pattern for `docker run --help | grep -q -- '--health-start-interval'`) now captures the help text in a variable and matches with `[[ == *pattern* ]]`, which cannot be affected by SIGPIPE. Verifiable with: `for i in {1..10}; do tar --help 2>&1 | grep -q -- '--delete' && echo Y || echo N; done` under pipefail.

- Strip the donor container's labels from the rebuilt shared base image. `docker commit` bakes the donor container's labels (e.g. `traefik.*` routing labels) into the snapshot config; without stripping, every group member inherits them at creation, so reverse proxies such as Traefik register every member under the donor's router/service names. Symptoms include `Could not define the service name for the router: too many services`, one service load-balancing across unrelated containers, routers silently disabled, and Let's Encrypt certificates never being requested for the affected domains (browsers show the Traefik default self-signed certificate as "connection is not private"). Container labels are re-applied per container from the backup metadata when the restore script creates them, so nothing is lost.

- Bundle the volume-tool image `alpine:3.20` (\~3.5 MB) into `images.tar` during backup so the restore side gets it via `docker load` and never needs `docker pull`. Servers that intentionally keep an old environment can ship an `unpigz` built against zlib < 1.2.3, which makes every `docker pull` fail at layer extraction (`failed to register layer: unpigz: abort`) while `docker load` keeps working; the migration is now immune to this and fully offline-capable.

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

