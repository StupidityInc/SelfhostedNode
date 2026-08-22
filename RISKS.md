# Accepted Risks

These residual risks remain accepted for this personal tooling after
the WP1–WP5 changes (lobaro-primary backup, Tailscale IP SSOT, addon
pattern). They were either reduced from High by recent work but not
fully closed, or are accepted as the cost of a small, single-operator
stack. The system is "ready for careful throwaway-VPS testing", not
fully production-trustworthy.

## High (residual, not yet closed)

- **The full throwaway-VPS test plan in `TESTING.md` has not been
  executed by a human in this session**, and most sections are marked
  `[LIVE NODE — deferred per AGENT.md §5 rule 5]`. A human operator
  must run them before deploying on real hardware.

## Operational residual (WP5 + addons)

- **Addon failure does not roll back core state.** When an addon
  requested this run fails, `bootstrap.sh` aborts with an error but
  the lobaro container, UFW, and Tailscale state are not torn down.
  The operator sees the failure and re-runs with the same opt-in flag.
  This is intentional (addon failures should not be destructive), but
  it does mean a half-installed addon can sit on disk until the
  operator intervenes.
- **Beszel validation helpers are duplicated** between
  `addons/beszel-agent/install.sh` (current location) and the implicit
  "shared library" location. Any change to the hub-reachability rules
  must be mirrored. WP6 deliberately leaves the duplication in place;
  WP7+ may dedupe into a sourced helper.
- **Beszel credential prompts now happen near the end of bootstrap**
  (step 9, "Addon dispatch") rather than at the start. Operators who
  relied on the old UX will see credential prompts later in the run.
  The collected values and the resulting container are identical;
  only the timing changed.

## Backup path (lobaro-primary, post-WP2 + WP5)

- **Lobaro cron runs in UTC** (`CronTimeZone=UTC`). The
  `BACKUP_CRON` baked into `setup-restic.lobaro.yml.tmpl` is a UTC
  expression derived from `NODE_NAME`. Operators in non-UTC timezones
  must remember this when reading the schedule or computing "next
  backup window".
- **No systemd `Persistent=true` semantics for the lobaro cron.**
  Unlike `restic-backup.timer`, missed windows during container
  downtime do **not** replay at the next boot. `restart:
  unless-stopped` plus the in-container BusyBox cron typically catch
  up at the next window; an operator who observes a stale snapshot for
  more than `STALE_HOURS` (default 36) should run
  `docker exec restic-backup /bin/backup` manually. WP7 may add an
  outside-cron fallback.
- **`/etc/restic/env.docker` is a raw `KEY=VALUE` file**, written by
  `setup-restic.sh` with no shell quoting. The compose `env_file:`
  parser does not perform shell expansion, so this is correct, but
  operators who `cat env.docker` expecting shell-quoting rules will
  be confused by the bare values.
- **The container error log is a secondary signal only.** A grep for
  `ERROR|FATAL|Error:` in `docker logs restic-backup --tail 200`
  produces WARN, never FAIL, in `check-node.sh`. The lobaro image's
  cron auto-recovers from transient errors, so a hard FAIL on log
  noise would be wrong — but operators who want a stricter signal
  should inspect the container logs directly.
- **Host-native and lobaro are mutually exclusive at install time.**
  `addons/restic-host-native/install.sh` REFUSES while the lobaro
  container is running. The inverse is enforced by `setup-restic.sh`
  as a WARN (not refuse), so re-runs and migration windows are not
  blocked. `check-node.sh` also WARNs (without affecting the exit
  code) when both paths are active, supporting WP7's migration
  helper.

## Tailscale IP SSOT (post-WP1)

- **The SSOT file is node-local and not in the backup.** A fresh node
  must regenerate it via `_system/update-tailscale-ip.sh` after
  Tailscale is up (handled by `bootstrap.sh` step 3a and the
  `tailscaled` drop-in). Operators restoring from backup must not
  copy `tailscale.env` between nodes — see `RESTORE.md` step 5a.
- **`${TAILSCALE_IP:?…}` will fail loudly when the file is missing
  or empty.** This is intentional (fail closed), but operators who
  re-arrange `/opt/homelab/env-file/` permissions can accidentally
  trigger it on a non-broken node.

## Security / secrets (carried forward)

- **UFW does not control Docker-published ports.** A Compose port
  bound to `0.0.0.0` or `::` can remain internet-reachable;
  `check-node.sh` only reports that exposure. The bootstrap
  deliberately does not install `ufw-docker` or rewrite Docker's
  iptables chains.
- **Tailscale's online exit-node status is strong routing evidence**
  but does not independently verify every destination or the public
  IP. The optional public-IP and S3 probes can be unavailable or
  filtered; failures no longer roll back an otherwise verified
  exit-node session.
- **Choosing `--no-public-ssh` before confirming a working Tailscale
  path can still lock the operator out.** The script keeps any
  existing public SSH rule when verification fails, but a first-run
  explicit lockdown has no public fallback by design.
- **The recovery marker proves that setup recorded a second
  repository key and rotation verifies a supplied recovery password**;
  it cannot prove that the human will retain the offline secret
  afterward.
- **S3 credentials are stored root-only but are not automatically
  scoped to one node's prefix.** Operators must create appropriately
  limited credentials where their provider supports it.
- **The scripts assume the expected Ubuntu/Debian command set and
  behavior** of `ufw`, `systemd`, Docker, restic, and Tailscale.
  Other distributions require supervised testing and may need manual
  adjustments.
- **`RESTIC_PASSWORD` and recovery-password environment variables can
  be exposed by an operator's process environment or command
  invocation** if used carelessly. Prefer password-manager files and
  the documented root-only paths.
- **If the Cloudflared apt package is unavailable, the fallback
  downloads the latest official architecture-specific binary over
  HTTPS without pinning a release.** Operators wanting pinned upgrades
  should manage that separately. Cloudflared stays in core this
  iteration; the move to an addon is backlog.
- **The Beszel `.env` file is inside `/opt/stacks/`** so it gets
  included in the encrypted restic backup. That is intentional — the
  file is mode 600 root-only, and restoring it from backup restores
  the agent's credentials. Operators who consider the agent token
  sensitive enough to exclude from backup must move the stack out of
  `/opt/stacks/` themselves; the bootstrap does not provide an
  exclude path.

The project is therefore "ready for careful testing on throwaway
machines," not fully trustworthy or production-ready.
