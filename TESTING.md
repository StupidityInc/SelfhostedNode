# Test plan (throwaway VPS)

Verifies the critical safety properties: no lockout, exit-node works, rollback
works, re-run is safe, backup appears, health check is truthful.

## Prerequisites

- Two throwaway Ubuntu 24.04 VPSes (`vps-a` = server, `vps-b` = client), SSH via public IP.
- A Tailscale account with an auth key (`TS_AUTHKEY`).
- An S3-compatible bucket + API token (e.g. Cloudflare R2).
- This repo copied to both VPSes.

## 1. Server bootstrap – no lockout, forwarding verified

```bash
sudo ./bootstrap.sh --role=server --node-name=vps-a --advertise-exit-node
# provide S3 credentials when prompted; type back the generated restic password
```

Expect:
- `/etc/sysctl.d/99-homelab-exitnode.conf` exists; `sysctl net.ipv4.ip_forward` and
  `net.ipv6.conf.all.forwarding` both print `1`.
- `sudo ufw status` shows `Status: active` with `22/tcp` (or OpenSSH), `tailscale0`,
  `41641/udp`.
- **Your SSH session stays up; a NEW ssh session to the public IP still works.**
- `/etc/homelab/node.env` exists (mode 600) with `ROLE=server`, `NODE_NAME=vps-a`.
- `systemctl list-timers restic-backup.timer` shows the timer as scheduled (enabled **and** active).
- The bootstrap log in /tmp contains no `tskey-` string: `grep -c tskey /tmp/homelab-bootstrap-*.log` → `0`.

In the Tailscale admin console: approve `vps-a` as exit node.

## 2. Manual backup – snapshot appears

```bash
sudo /opt/stacks/_backup/backup.sh
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --latest 1'
```

Expect: one snapshot tagged `vps-a`. `sudo /opt/stacks/_backup/check-node.sh`
reports "Newest snapshot is 0h old" and exits `0` (`echo $?`).

## 3. Client bootstrap – exit node applied last, with probe

```bash
sudo ./bootstrap.sh --role=client --node-name=vps-b --use-exit-node=vps-a
```

Expect:
- Exit node is applied only after UFW + restic steps; Tailscale reports the
  requested exit node online. The public-IP probe reports the new IP when the
  echo endpoint is available.
- `curl -4 ifconfig.me` on vps-b shows **vps-a's** public IP.
- `sudo tailscale status --json | jq .ExitNodeStatus.Online` → `true`.
- If S3 was unreachable before the exit node, the deferred restic retry succeeds now.

## 4. Rollback proof – bad exit node must not stick

```bash
# temporarily disable the exit-node route approval, or use a bogus peer name:
sudo tailscale set --exit-node=
sudo ./bootstrap.sh --role=client --node-name=vps-b --use-exit-node=definitely-not-a-node
```

Expect: `.ExitNodeStatus.ID`/`.Online` evidence is missing or offline, the probe
fails → script rolls back →
`sudo tailscale get exit-node` prints **empty** → script exits non-zero →
`curl -4 ifconfig.me` works again via the direct path.

Then restore the good state: `sudo ./bootstrap.sh --role=client --node-name=vps-b --use-exit-node=vps-a`.

## 5. Re-run safety

```bash
# plant a canary with non-root ownership inside the existing tree
sudo -u "$USER" mkdir -p /opt/stacks/canary && sudo -u "$USER" touch /opt/stacks/canary/file
sudo ./bootstrap.sh --role=server --node-name=vps-a --advertise-exit-node   # on vps-a
```

Expect:
- `stat -c '%U' /opt/stacks/canary/file` → still your user (no recursive ownership rewrite).
- `sudo ufw status numbered` → each rule appears exactly once.
- `sudo tailscale get hostname` → `vps-a`.
- `--role=client` on vps-a must be **refused** (role conflict).
- `--node-name=some-other-name` on vps-a must be **refused** (identity conflict).
- `systemctl show -p ExecMainStatus restic-backup.service` confirms no unnecessary restart of `tailscaled` occurred when UFW was unchanged.
- restic password unchanged: `sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --latest 1'` still works.

### 5a. Sticky lockdown and Tailscale-only re-run

```bash
# From a separate laptop, prove the Tailscale SSH path first.
ssh "$USER@$(tailscale ip -4 vps-a | head -1)"
sudo ./bootstrap.sh --role=server --node-name=vps-a --no-public-ssh
sudo ufw status numbered

# Re-run without --no-public-ssh, ideally from the Tailscale-only SSH session.
sudo ./bootstrap.sh --role=server --node-name=vps-a
sudo ufw status numbered
```

Expect:
- `node.env` contains `KEEP_PUBLIC_SSH=false`.
- The re-run does not add `OpenSSH` or `22/tcp` back.
- The re-run does not restart `tailscaled` when UFW rules are unchanged; the
  Tailscale-only SSH session stays up.
- If lockdown could not be verified on the first attempt, public SSH may remain
  open for safety and the health check must report the mismatch rather than lie.

## 6. Unsupported cloudflared suite must not brick bootstrap

On a throwaway server with restic credentials already configured, plant the
source left by the old implementation:

```bash
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared resolute main' \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
sudo install -m 0644 /dev/null /usr/share/keyrings/cloudflare-main.gpg
```

Run a plain re-run with the same node name, without the cloudflared flag:

```bash
sudo ./bootstrap.sh --yes --role=server --node-name=vps-a
```

Expect:

- The stale `cloudflared.list` and `cloudflare-main.gpg` are removed before
  the first global `apt-get update`; the unsupported `resolute` Release error
  does not abort bootstrap.
- UFW remains in its persisted state, including `KEEP_PUBLIC_SSH=false` when
  the node was previously locked down; the re-run does not reopen public SSH.
- Restic setup continues and the restic timer remains enabled and active.
- `/etc/homelab/node.env` does not gain `INSTALL_CLOUDFLARED=true` merely from
  the stale source or a failed previous request.

Then explicitly request installation:

```bash
sudo ./bootstrap.sh --yes --role=server --node-name=vps-a --install-cloudflared
```

Expect Cloudflare's documented `any` suite to be attempted. If apt fails, the
Cloudflare list and keyring are removed, the official binary is attempted, and
the bootstrap still reaches restic. `INSTALL_CLOUDFLARED=true` is persisted
only when `cloudflared --version` can be found successfully; otherwise the
script warns and leaves it false.

## 7. Health check truthfulness (all four exit-node states + staleness)

On vps-a (advertising + approved): `sudo /opt/stacks/_backup/check-node.sh`
→ "This node IS an exit node", "No exit node currently in use", exit `0`.

On vps-b (using exit node): → "Using exit node: vps-a …", public IP differs
from `DIRECT_PUBLIC_IP_AT_SETUP`, exit `0`.

```bash
sudo tailscale set --exit-node=          # detach without updating node.env
sudo /opt/stacks/_backup/check-node.sh   # → FAIL: expected exit node vps-a not active; exit 1
sudo tailscale set --exit-node=vps-a --exit-node-allow-lan-access=true
```

Staleness:
```bash
sudo STALE_HOURS=0 /opt/stacks/_backup/check-node.sh   # → FAIL "BACKUPS ARE STALE", exit 1
```

The check must also fail when `systemctl show -p Result --value
restic-backup.service` reports `failed`, `timeout`, or another failed result,
even if an older manual snapshot is still within the freshness window.

## 8. Password rotation safety

Run the recovery-key lifecycle in section 10 first. Rotation intentionally
refuses to proceed when no recovery marker and verified second key exist.

```bash
sudo cp /etc/restic/password /tmp/old-pass
sudo /opt/stacks/_backup/change-restic-password.sh    # type the new password back
```

Expect:
- Old password now invalid:
-  `sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_load_restic_env /etc/restic/env; RESTIC_PASSWORD_FILE=/tmp/old-pass restic snapshots'` → exit code `12` (wrong password).
- New password works: `sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots'` lists snapshots.
- `systemctl is-active restic-backup.timer` → `active` (timer was restarted).
- `sudo /opt/stacks/_backup/backup.sh` still succeeds after rotation.

## 9. Public SSH removal (optional, do last)

```bash
ssh "$USER@$(tailscale ip -4 vps-a | head -1)"   # from your laptop, prove tailscale SSH works
sudo ./bootstrap.sh --role=server --node-name=vps-a --advertise-exit-node --no-public-ssh
```

Expect: rules removed only after the tailscale0 rule is re-verified; public-IP
SSH now refused; Tailscale SSH keeps working.

## 10. Recovery key lifecycle

During initial interactive restic setup, choose to add a recovery key, save it
in the password manager, and confirm it when prompted. Verify:

```bash
sudo test -f /etc/restic/recovery-key.present
sudo stat -c '%a %U:%G' /etc/restic/recovery-key.present
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic key list'
```

Expect: the marker exists but contains no recovery secret, and the repository
has at least two keys. For a non-interactive setup, provide
`RESTIC_RECOVERY_PASSWORD_FILE=/path/to/offline-recovery-file`; the marker is
written only after `restic key add` succeeds.

Copy the recovery password to a temporary root-only file, rotate the main
password, and verify the recovery key remains usable:

```bash
sudo install -m 600 /path/to/recovery-password /tmp/recovery-password
sudo env RESTIC_RECOVERY_PASSWORD_FILE=/tmp/recovery-password \
  /opt/stacks/_backup/change-restic-password.sh
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_load_restic_env /etc/restic/env; RESTIC_PASSWORD= RESTIC_PASSWORD_FILE=/tmp/recovery-password restic snapshots'
sudo rm -f /tmp/recovery-password
```

Expect: rotation refuses if there is no marker, fewer than two repository keys,
or the supplied recovery password cannot open the repository. After a
successful rotation, the recovery-only snapshot command succeeds.

## 11. Special-character secret and backup

On a throwaway node/repository, configure an AWS secret containing literal
dollar signs, backticks, single and double quotes, and a backslash, with the
exact value recorded separately. Run setup, then inspect only through the safe
loader and perform a backup:

```bash
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_load_restic_env /etc/restic/env; printf "%s\\n" "$AWS_SECRET_ACCESS_KEY"'
sudo /opt/stacks/_backup/backup.sh
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --latest 1'
```

Expect: the printed value exactly matches the recorded value, no command
substitution occurs, and the backup/snapshot succeeds.

## 12. Restore ordering and ownership

On a throwaway replacement machine, follow `RESTORE.md` and verify from the
shell history that `/etc/restic/env` and `/etc/restic/password` were placed
before the `bootstrap.sh` invocation. Restore a snapshot with `cp -a`, then:

```bash
stat -c '%U:%G %a' /opt/stacks/<known-data-file>
```

Expect: bootstrap keeps the existing restic configuration, and restored stack
ownership is unchanged. There must be no recursive ownership rewrite in the
restore procedure.

## 13. Optional Beszel agent

Prerequisites: a manually running Beszel hub on the monitoring node, with its
UI reachable through Tailscale, and a system `KEY` plus `TOKEN` copied from the
hub UI. Uptime Kuma is not part of this test; install it manually on the
monitoring node only.

### 13a. Opt-in and preflight failures

Run a normal non-interactive bootstrap without `--beszel-agent`:

```bash
sudo ./bootstrap.sh --yes --role=client --node-name=beszel-test
```

Expect: no `/opt/stacks/beszel-agent/` is created and `node.env` does not
record `INSTALL_BESZEL_AGENT=true`.

Then test missing required values:

```bash
sudo env BESZEL_HUB_URL="http://100.64.0.1:8090" \
  BESZEL_AGENT_KEY="test-key" \
  ./bootstrap.sh --yes --role=client --node-name=beszel-test --beszel-agent
```

Expect: bootstrap exits non-zero before creating the Beszel directory or `.env`
and clearly reports the missing token. No half-empty secret file is left behind.

Then repeat with all required values but a public address:

```bash
sudo env \
  BESZEL_HUB_URL="http://203.0.113.10:8090" \
  BESZEL_AGENT_KEY="test-key" \
  BESZEL_AGENT_TOKEN="test-token" \
  ./bootstrap.sh --yes --role=client --node-name=beszel-test --beszel-agent
```

Expect: bootstrap rejects the public hub URL before creating the Beszel
directory or `.env`.

### 13b. Successful agent setup

Use the real values from the manually managed hub:

```bash
sudo env \
  BESZEL_HUB_URL="http://<tailscale-name-or-100.x-ip>:8090" \
  BESZEL_AGENT_KEY="<public-key-from-hub>" \
  BESZEL_AGENT_TOKEN="<token-from-hub>" \
  ./bootstrap.sh --yes --role=client --node-name=beszel-test --beszel-agent
```

Expect:

- `/opt/stacks/beszel-agent/docker-compose.yml` and `.env` exist.
- `stat -c '%U:%G %a' /opt/stacks/beszel-agent/.env` prints `root:root 600`.
- `node.env` contains `INSTALL_BESZEL_AGENT=true` only after the container is running.
- `docker ps --filter name=beszel-agent` shows a running container.
- `docker inspect -f '{{.HostConfig.NetworkMode}}' beszel-agent` prints `host`.
- The container has no Docker-published port mapping and `ufw status` has no new Beszel rule.
- The agent appears healthy in the hub UI and uses the node name when no display name was supplied.
- The bootstrap log contains none of the supplied token text.

### 13c. Re-run safety

Re-run without `--beszel-agent` and verify the existing healthy container stays
running and `beszel_agent_data` is unchanged. Re-run with `--beszel-agent` only
when intentionally changing its configuration; Compose must preserve the data
directory and `INSTALL_BESZEL_AGENT=true` must remain recorded only after a
successful start.

For a same-host hub only, verify the explicit exception:

```bash
sudo env BESZEL_ALLOW_SAME_HOST_HUB_URL=true \
  BESZEL_HUB_URL="http://127.0.0.1:8090" \
  BESZEL_AGENT_KEY="<public-key-from-hub>" \
  BESZEL_AGENT_TOKEN="<token-from-hub>" \
  ./bootstrap.sh --yes --role=server --node-name=beszel-test --beszel-agent
```

Do not use that override for a hub on another node.
