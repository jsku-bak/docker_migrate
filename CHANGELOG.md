# Changelog

## Unreleased

### New features

- Detect host port conflicts before a restore starts changing anything, instead of failing hours later in the container-start or management-plane stage. The restore side now collects every host port the migration will need — bridge port mappings and the management-panel port from the bundle manifest, plus the actual listening ports of `--network host` containers — and checks them against listeners on the target. When a conflict is found the occupying container or process is named explicitly (e.g. `端口 80/tcp 已被容器 traefik 占用`), and the fix no longer depends on the operator noticing it: an interactive menu offers to stop the conflicting containers (recorded and automatically restarted if the restore rolls back), to re-scan after manual cleanup, or to ignore; `RESTORE_PORT_CONFLICT=stop|fail|ignore` preselects the behavior for non-interactive runs. Backup now records the real listening ports of running host-network containers (`DmHostListenPorts`) and the panel port (`admin_port`) so the precheck is precise for new bundles, while older bundles fall back to a documented 80/443 heuristic for host-network containers. If the management plane still fails to come up in stage \[G], the log now prints the current listeners on the panel/80/443 ports so the conflicting process is visible immediately instead of only after the rollback has wiped the evidence.

### Bug fixes

- Fix re-running a hybrid (bt-cloudwaf) restore on a target that already has the management plane running (e.g. restoring a second migration over a previous successful one, or re-running a failed restore). The old panel process holds open file handles under `/www/cloud_waf` and occupies the 8379 admin port; `[B0]` used to overwrite those files underneath it, leaving the process in a confused state so the `[G]` stage's `/etc/init.d/btw start` failed and the port never listened — the whole restore then rolled back. Restore now quiesces the pre-existing management plane right after the rollback transaction is prepared: it stops the systemd unit first (so `Restart=` cannot bring it back), falls back to the init script and a pattern-based `pkill`, and refuses to continue (safe rollback) only if the old process cannot be stopped at all. Whether the old panel was running is recorded in the transaction directory, and on rollback — after files and containers are back to their old state — the old panel is restarted automatically, so a failed re-restore no longer leaves the previously working management plane down.

### New features

- Change the default HTTP transfer port from 8080 to 8099 and open it in the firewall automatically. Before the download server starts, the script detects an active firewall (ufw via `/etc/ufw/ufw.conf`, then firewalld, then iptables with DROP/REJECT rules present) and allows exactly the chosen port — the 8099 default, a `PORT=` override, an interactively entered custom port, or an auto-incremented port when the requested one is busy. Rules the script added itself are revoked when the transfer service stops (including the unexpected-exit path); pre-existing user rules are detected and left untouched. When nothing can be opened automatically (e.g. cloud security groups), a warning tells the user which port to open manually.

- Support hybrid "Docker data plane + host management plane" applications, beginning with BT Cloud WAF (bt-cloudwaf). Backup now detects `cloudwaf_*` containers among the selection and packs the host-side management components (`/www/cloud_waf` with container-mounted subdirectories excluded to avoid double packing, `/etc/init.d/btw`, the `/usr/bin/btw` symlink, and any `btw.service` systemd unit) into a new `hostside/` bundle section, recording them under `hostside` in `manifest.json`. The panel is quiesced with `btw admin_stop` before archiving its SQLite state and restarted after the data-plane containers come back, so the source server's running state is preserved.

- Restore the host-side components in a new `[B0]` stage before bind mounts are replayed, reusing the `restore_bind_exact` transaction (same-filesystem move, one-shot alpine extraction, WAL rollback). A new `[G]` stage then brings the management plane up on the target: installs missing runtime dependencies (`ipset`, without which the CloudWaf panel silently fails to bind its port), rewrites the source server IP in panel configs (`serverip.json`, `iplist.txt`) to the new server IP (explicit `RESTORE_HOSTSIDE_IP` wins over public-IP detection), registers the systemd unit, starts the service idempotently, and waits for the admin port to listen before printing the new admin URL. The panel only accepts TLS 1.3, so the health probe retries with `--tlsv1.3` and treats "port listening but local curl got no response" as a warning rather than a restore failure, since restore hosts with an older curl/OpenSSL cannot negotiate TLS 1.3 at all and would otherwise trigger a spurious full rollback. On rollback, the management processes are killed before file rollback so open file handles cannot keep writing into restored paths.

### Bug fixes

- Fix hybrid (bt-cloudwaf) restores being rejected with `迁移包 manifest 结构或路径不安全，拒绝恢复` right after a successful download, decrypt, and integrity check. Backup wrote `hostside.services` in `manifest.json` as a single JSON object, but the restore-side validator (`restore_manifest_is_safe`) and the `[G]` management-plane startup stage both iterate it as an array, so every hybrid bundle failed the manifest gate. The validator now accepts both the legacy single-object form and the array form, `[G]` normalizes the entry to an array before iterating, and backup writes the canonical array form. Existing 2.3.0 bundles do not need to be re-packed — re-running the restore with the fixed script against the preserved diagnostic bundle is enough.

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

