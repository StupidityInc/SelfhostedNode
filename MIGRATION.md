# Migrating a host-native node to lobaro-primary

This is the **WP7 migration recipe** for nodes that were deployed with the
old host-native systemd restic path (restic-backup.timer +
`/opt/stacks/_backup/backup.sh`) before the WP1–WP5 transformation.

If your node is already on the lobaro container, this file is not for you
— the container is the steady state and this script is a one-time
one-shot migration tool.

## Prerequisites

1. The node is currently using the host-native restic path
   (`systemctl is-enabled restic-backup.timer` returns success).
2. `/etc/restic/env` and `/etc/restic/password` are present on the node.
3. The node has been bootstrapped at least once (`/etc/homelab/node.env`
   exists with a `NODE_NAME`).
4. You have the restic repository password (or a recovery key) recorded.
5. You can reach the S3 endpoint from the node (directly or via a
   Tailscale exit node — see `RESTORE.md` step 0).
6. You can run `sudo` on the node.

## Pre-flight sanity check

Before running the migration, prove the source data is reachable and
labelled correctly:

```bash
# Confirm the host-native timer is the active path
sudo systemctl status restic-backup.timer
sudo systemctl is-enabled restic-backup.timer

# List the existing snapshots under the node's tag
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --tag "$NODE_NAME"'
```

If `restic snapshots --tag "$NODE_NAME"` returns zero snapshots, the
node has never run a successful backup and the migration will not
preserve anything. The helper will still proceed (the lobaro container
will create the first snapshot on its next cron window), but the
"existing snapshots remain" guarantee is a no-op.

## Run the migration

From the repo working directory (the directory that contains
`bootstrap.sh`, `setup-restic.sh`, `lib.sh`, and `migrate-to-lobaro.sh`):

```bash
sudo ./migrate-to-lobaro.sh
```

The helper will:

1. Refuse early if preconditions are not met (no destructive steps on
   refusal).
2. Pin `/etc/restic/repo-id` from live `restic cat config` if missing;
   hard-fail on a pin/live mismatch.
3. Stop and disable the host-native timer (`systemctl disable --now
   restic-backup.timer`).
4. Reuse `setup-restic.sh`'s `REUSE_EXISTING` branch — the existing
   password is kept and `restic init` is **not** run against the
   healthy repo.
5. Verify the lobaro container is running, the repo-id pin matches the
   live repository, and the pre-existing snapshots are still readable
   under the `NODE_NAME` tag.
6. Run `check-node.sh` (informational only).
7. Persist `INSTALL_RESTIC_HOST_NATIVE=false` in
   `/etc/homelab/node.env`.
8. Leave the host-native unit files on disk (default) so a rollback is
   a one-liner. Pass `--purge-host-native-units` to remove them.

Non-interactive mode (e.g. an Ansible playbook):

```bash
sudo HOMELAB_NONINTERACTIVE=1 ./migrate-to-lobaro.sh
```

To also remove the dormant unit files:

```bash
sudo HOMELAB_NONINTERACTIVE=1 ./migrate-to-lobaro.sh --purge-host-native-units
```

## Idempotency

- **Already on lobaro** (container running): the helper exits **0** with
  a clear "already migrated; nothing to do" message. Re-running by
  mistake does not look like a failure.
- **No host-native timer enabled** (no `restic-backup.timer`): the
  helper exits **1** with a clear refusal — this is the wrong tool for
  this node. Use `setup-restic.sh` directly to deploy / refresh lobaro
  from scratch.
- **Mid-migration failure**: the host-native timer is now disabled and
  the lobaro container did not start. The helper prints the exact
  rollback recipe before exiting 1.

## Post-migration

```bash
# Health check (must exit 0)
sudo /opt/stacks/_backup/check-node.sh

# Confirm the container is the active backup path
sudo systemctl status restic-backup.timer           # must show: inactive (dead)
sudo docker inspect -f '{{.State.Running}}' restic-backup   # must show: true
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --tag "$NODE_NAME"'

# Force a manual backup now (otherwise wait for the container's BusyBox cron window)
sudo docker exec restic-backup /bin/backup
```

The first new snapshot created by the container will appear in the same
list as the existing snapshots, tagged with `NODE_NAME`. The lobaro
image runs its cron in **UTC** (`BACKUP_CRON` is derived from `NODE_NAME`).

## Rollback

### Rollback after a successful migration

Stop the lobaro container and re-install the host-native addon:

```bash
sudo docker stop restic-backup
sudo ./addons/restic-host-native/install.sh
sudo systemctl enable --now restic-backup.timer
```

The host-native unit files and `/opt/stacks/_backup/backup.sh` are kept
on disk by default (use `--purge-host-native-units` on the original
migration to remove them; without them, the addon installer copies
fresh copies from the repo root).

### Rollback after a FAILED migration

If the helper exits non-zero after the host-native timer is disabled
but before the container starts:

```bash
sudo ./addons/restic-host-native/install.sh
sudo systemctl enable --now restic-backup.timer
```

`/etc/restic/*`, `/var/cache/restic/`, and the addon source files are
never touched by the migration helper. Existing snapshots on S3 are
unchanged. The repository is intact; only the scheduler was disabled.

## Driving the migration from bootstrap.sh

If you are re-running `bootstrap.sh` on an existing host-native node and
want the migration to happen during the bootstrap (so the node converges
in a single command), pass:

```bash
sudo ./bootstrap.sh --role=<role> --node-name=<node-name> \
  --migrate-from-host-native
```

This dispatches `migrate-to-lobaro.sh` after step 6 (restic setup) and
before step 7 (state persistence), as a thin wrapper. The helper's own
idempotency rules still apply.

## What this script does NOT do

- It does **not** change `NODE_NAME`. The tag and hostname are
  immutable (the helper reads `NODE_NAME` from `/etc/homelab/node.env`
  and propagates it through `setup-restic.sh` to the lobaro container).
- It does **not** move S3 data between buckets or prefixes. The
  repository URL is taken verbatim from `/etc/restic/env` and the
  helper never calls `restic init` against an existing repo, so existing
  snapshots remain on the same prefix.
- It does **not** write to the stack `.env` file for the Tailscale IP
  SSOT (AGENT.md §2). The Tailscale IP machinery is untouched.
- It does **not** start, stop, or reconfigure any stack other than
  `restic-backup`. Other Compose projects under `/opt/stacks/` are
  unaffected.
- It does **not** roll back the host-native state automatically on
  failure. The rollback recipe is printed to stderr so the operator can
  apply it.
