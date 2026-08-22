# addons/restic-host-native/

Re-installs the **host-native systemd path** as a fallback / testing
option. After WP2, the lobaro container is the primary backup. This
addon is for operators who explicitly want the old behaviour on a
specific node (e.g. for testing, or while a port is being ironed out
of the container path).

## Source files (already at repo root)

| File | Role |
|------|------|
| `backup.sh` | Host-native backup script (backs up `/opt/stacks`). |
| `restic-backup.service` | systemd oneshot unit. |
| `restic-backup.timer` | Daily timer, 03:00 + per-node random offset. |
| `change-restic-password.sh` | Safe password rotation (used by both paths). |

`install.sh` copies these to the runtime paths and enables the timer.

## Mutual exclusion (CRITICAL)

This addon is **mutually exclusive** with the lobaro container
(`restic-backup` container managed by the primary `setup-restic.sh`
flow after WP2).

The installer MUST refuse to run while the lobaro container is
running:

```bash
docker ps --filter name=restic-backup --format '{{.Names}}'
# If non-empty: refuse.
```

The inverse direction (lobaro refuses if host-native timer is enabled)
is enforced by `setup-restic.sh` as a **WARN**, not a refuse, so
operators are not blocked during the WP7 migration window. The
suggested remediation is:

```bash
sudo systemctl disable --now restic-backup.timer
```

If you want to switch FROM host-native TO lobaro, uninstall this
addon first (`sudo systemctl disable --now restic-backup.timer`),
then re-run `setup-restic.sh` to deploy the container. WP7 documents
the migration path.

## Re-run safety

`install.sh` is re-runnable:

- `install(1)` overwrites the three target files atomically (`backup.sh`,
  `restic-backup.service`, `restic-backup.timer`).
- `systemctl enable --now restic-backup.timer` is idempotent.
- `addon_persist_flag INSTALL_RESTIC_HOST_NATIVE true` upserts the
  key in `/etc/homelab/node.env` (no duplicate lines).
- The data volume at `/var/cache/restic` is never touched.
- The repos in `/etc/restic/env` and `/etc/restic/password` are read
  but never modified.

## Why not just keep this as the default?

See AGENT.md §2 (locked decisions) and §0 (current state). Host-native
is kept as an addon for flexibility, but the lobaro container is
primary because:

- Container scheduling survives host reboots more reliably
  (`Persistent=true` semantics differ, but container restart on boot
  is more predictable).
- Container can be updated atomically.
- Repository integrity check (`restic check`) is built in via
  `CHECK_CRON`.
- Backup is decoupled from the host's systemd sandbox.
