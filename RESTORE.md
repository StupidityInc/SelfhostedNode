# Homelab stacks restore procedure (restic)

This file lives inside every backup of `/opt/stacks/`.
It is the self-describing recovery story for this node.

## What is backed up
- The entire `/opt/stacks/` directory
- All service folders (docker-compose.yml, .env, data bind mounts)
- This RESTORE.md and the backup tooling under `_backup/`

Docker images are **not** backed up (they are re-pulled on restore).

## Prerequisites
1. A fresh Linux machine (Ubuntu Server recommended)
2. The S3-compatible credentials for this node’s repository
3. The restic repository password (or the separate recovery key, if you made one)
4. Network access to the S3 endpoint (direct or via Tailscale exit node)

## 0. BREAK GLASS: S3 is only reachable via a Tailscale exit node

Some clients have no direct route to the S3 endpoint by design. If a plain
HTTPS connection to the endpoint fails on the replacement machine, do this
FIRST, before touching restic:

```bash
# 1. Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sudo sh

# 2. Join the tailnet (interactive login URL, or an auth key)
sudo tailscale up --hostname=restore-temp

# 3. Route internet via your exit node (name or 100.x IP of a server node)
sudo tailscale set --exit-node=<exit-node-name> --exit-node-allow-lan-access=true

# 4. Prove the path works before continuing
curl -4 -s --max-time 10 https://ifconfig.me          # should show the EXIT NODE's public IP
curl -4 -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://<your-s3-endpoint-host>

# 5. If the exit node does not work (not approved? offline?), roll back cleanly:
sudo tailscale set --exit-node=
```

Only continue with the steps below once step 4 succeeds. After the restore,
the full `bootstrap.sh` re-run will set the exit node up permanently.

## 1. Install restic and place secrets first

```bash
sudo apt update
sudo apt install -y restic
# or download the official binary from https://github.com/restic/restic/releases
```

Before running `bootstrap.sh` or its restic setup helper, recreate the secrets
directory and place this node's existing `/etc/restic/env` and
`/etc/restic/password` from your password manager. They are intentionally not
inside the stacks backup. Keep the files root-only:

```bash
sudo install -d -m 700 /etc/restic
sudo install -o root -g root -m 600 /path/from/password-manager/env /etc/restic/env
sudo install -o root -g root -m 600 /path/from/password-manager/password /etc/restic/password
```

If the main password is lost, the recovery password can temporarily be placed
at `/etc/restic/password` for the bootstrap/restore, then replaced with the
main password after the node is working. Do not leave a recovery key on disk
as the permanent node password.

## 2. Verify the repository

```bash
# In a root shell, export the values from the restored /etc/restic/env:
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="auto"
export RESTIC_REPOSITORY="s3:https://<endpoint>/<bucket>/<node-prefix>"
export RESTIC_PASSWORD_FILE=/etc/restic/password

restic snapshots
restic check
```

## 3. Restore the latest snapshot

```bash
mkdir -p /tmp/restore
restic restore latest --target /tmp/restore
```

To restore a specific snapshot:

```bash
restic snapshots          # note the ID
restic restore <ID> --target /tmp/restore
```

## 4. Place the stacks on the new machine

```bash
sudo mkdir -p /opt/stacks
sudo cp -a /tmp/restore/opt/stacks/. /opt/stacks/
```

`cp -a` preserves the ownership and permissions captured in the backup. Do not
recursively change ownership on restored stack data; it can break service users
and silently damage the restored ownership model.

## 5. Re-bootstrap the host

Run the current `bootstrap.sh` with the same role and node name so that Docker,
firewall, Tailscale, and base packages exist. The already-placed restic files
must be present before this step so the wizard keeps the existing repository:

```bash
sudo ./bootstrap.sh --role=<server-or-client> --node-name=<original-node-name>
```

Then:

```bash
# Make sure the user is in the docker group
sudo usermod -aG docker "$USER"
# log out / log in or newgrp docker
```

If the main repository password was temporarily replaced by a recovery key,
replace `/etc/restic/password` with the main password now and keep the recovery
key offline. If the main password is lost, use the recovery key you stored
offline during setup:

```bash
# Point restic at a file containing the recovery password instead:
export RESTIC_PASSWORD_FILE=/path/to/recovery-password-file
restic snapshots    # works with any valid key, including recovery keys
restic key list     # shows all keys on the repository
```

A recovery key is deliberately NOT stored on any node. If you have neither the
main password nor a recovery key, the repository is unrecoverable – that is
the point of client-side encryption.

## 6. Start services

```bash
cd /opt/stacks/<service-name>
docker compose pull
docker compose up -d
```

## Notes
- `.env` files are restored as normal files. They were only encrypted while inside the restic repository.
- The backup tooling (`_backup/backup.sh`) and this RESTORE.md travel with the data.
- For a brand-new node, prefer running the full `bootstrap.sh` from the private repo that contains these helpers.
- If this node normally uses a Tailscale exit node, restore network connectivity first or the S3 restore will fail.
