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
- `/opt/homelab/env-file/tailscale.env` exists, mode 644, holds
  `TAILSCALE_IP=100.x.y.z` matching `tailscale ip -4`. (Set up by
  bootstrap step 3a; refreshed every 15 minutes by
  `update-tailscale-ip.timer`.)
- `systemctl list-timers update-tailscale-ip.timer` shows the timer
  scheduled.
- `docker ps --filter name=restic-backup` shows the lobaro container
  running (post-WP2).
- The host-native systemd units are **not** present:
  `systemctl is-enabled restic-backup.timer` exits non-zero. The
  `_backup/backup.sh` file may exist (it lives in the repo) but no
  timer auto-runs it.
- The bootstrap log in /tmp contains no `tskey-` string: `grep -c tskey /tmp/homelab-bootstrap-*.log` → `0`.

In the Tailscale admin console: approve `vps-a` as exit node.

## 2. Manual backup – snapshot appears (lobaro container)

The primary backup mechanism is the lobaro container's BusyBox cron
(UTC, derived from `NODE_NAME`). To force a backup window without
waiting for the cron:

```bash
sudo docker exec restic-backup /bin/backup
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --latest 1'
```

Expect: one snapshot tagged `vps-a`. `sudo /opt/stacks/_backup/check-node.sh`
reports "Newest snapshot is 0h old" and exits `0` (`echo $?`). The
"Restic backup" section also shows `Backup path: lobaro container`
and `/etc/restic/repo-id matches live repository`.

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
- `/opt/homelab/env-file/tailscale.env` is populated on vps-b (step 3a)
  and its `TAILSCALE_IP` matches `tailscale ip -4`.

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
- `systemctl show -p ExecMainStatus restic-backup.service` (only relevant
  when the host-native addon is installed) — confirms no unnecessary
  restart of `tailscaled` occurred when UFW was unchanged.
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
The "Tailscale IP SSOT" section reports `Tailscale IP SSOT file present
and valid: 100.x.y.z` AND `Tailscale IP SSOT matches live tailscale IP`.

On vps-b (using exit node): → "Using exit node: vps-a …", public IP differs
from `DIRECT_PUBLIC_IP_AT_SETUP`, exit `0`. The "Tailscale IP SSOT"
section passes for vps-b too.

```bash
sudo tailscale set --exit-node=          # detach without updating node.env
sudo /opt/stacks/_backup/check-node.sh   # → FAIL: expected exit node vps-a not active; exit 1
sudo tailscale set --exit-node=vps-a --exit-node-allow-lan-access=true
```

Staleness:
```bash
sudo STALE_HOURS=0 /opt/stacks/_backup/check-node.sh   # → FAIL "BACKUPS ARE STALE", exit 1
```

The check must also fail when `/etc/restic/repo-id` no longer matches
the live `restic cat config --json` (see section 14 below), when the
Tailscale IP SSOT file is missing/invalid/stale (see section 15), or
when the lobaro container is stopped while `BACKUP_PATH=lobaro`.

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
- The lobaro container picks up the new password on the next cron
  tick without a restart (the whole `/etc/restic` directory is
  mounted read-only; the script's atomic `mv` is visible to the
  next invocation). Confirm with
  `sudo docker exec restic-backup /bin/backup && sudo bash -c
  'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --latest 1'`.
- If the host-native addon is also installed:
  `systemctl is-active restic-backup.timer` → `active` (timer was
  restarted). `sudo /opt/stacks/_backup/backup.sh` still succeeds.

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
sudo docker exec restic-backup /bin/backup
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

## 13. Addon: Beszel agent

Prerequisites: a manually running Beszel hub on the monitoring node,
with its UI reachable through Tailscale, and a system `KEY` plus
`TOKEN` copied from the hub UI. Uptime Kuma is not part of this test;
install it manually on the monitoring node only.

The Beszel installer is now an addon (`addons/beszel-agent/install.sh`).
After WP5, `bootstrap.sh --beszel-agent` only sets a request flag; the
addon installer itself collects credentials and does the install during
step 9 ("Addon dispatch") — i.e. **after** core safety has converged.
This changes timing (the prompts now appear late in the bootstrap run)
but the resulting container is identical to the pre-WP5 inline version.

### 13a. Opt-in and preflight failures

Run a normal non-interactive bootstrap without `--beszel-agent`:

```bash
sudo ./bootstrap.sh --yes --role=client --node-name=beszel-test
```

Expect: no `/opt/stacks/beszel-agent/` is created and `node.env` does
not record `INSTALL_BESZEL_AGENT=true`. The addon-dispatch step is
skipped entirely when no addon flag was set.

Then test missing required values via the addon directly (the addon
runs in non-interactive mode when `HOMELAB_NONINTERACTIVE=1` or `--yes`
was set):

```bash
sudo env BESZEL_HUB_URL="http://100.64.0.1:8090" \
  BESZEL_AGENT_KEY="test-key" \
  HOMELAB_NONINTERACTIVE=1 \
  ./addons/beszel-agent/install.sh
```

Expect: addon exits non-zero before creating the Beszel directory or
`.env` and clearly reports the missing token. No half-empty secret file
is left behind.

Then repeat with all required values but a public address:

```bash
sudo env \
  BESZEL_HUB_URL="http://203.0.113.10:8090" \
  BESZEL_AGENT_KEY="test-key" \
  BESZEL_AGENT_TOKEN="test-token" \
  HOMELAB_NONINTERACTIVE=1 \
  ./addons/beszel-agent/install.sh
```

Expect: addon rejects the public hub URL before creating the Beszel
directory or `.env`.

### 13b. Successful agent setup

Use the real values from the manually managed hub:

```bash
sudo env \
  BESZEL_HUB_URL="http://<tailscale-name-or-100.x-ip>:8090" \
  BESZEL_AGENT_KEY="<public-key-from-hub>" \
  BESZEL_AGENT_TOKEN="<token-from-hub>" \
  HOMELAB_NONINTERACTIVE=1 \
  ./addons/beszel-agent/install.sh
```

Expect:

- `/opt/stacks/beszel-agent/docker-compose.yml` and `.env` exist.
- `stat -c '%U:%G %a' /opt/stacks/beszel-agent/.env` prints `root:root 600`.
- `node.env` contains `INSTALL_BESZEL_AGENT=true` only after the
  container is verified running. Re-grep after the run:
  `grep INSTALL_BESZEL_AGENT /etc/homelab/node.env`.
- `docker ps --filter name=beszel-agent` shows a running container.
- `docker inspect -f '{{.HostConfig.NetworkMode}}' beszel-agent` prints `host`.
- The container has no Docker-published port mapping and `ufw status`
  has no new Beszel rule.
- The agent appears healthy in the hub UI and uses the node name when
  no display name was supplied.
- No `BESZEL_AGENT_TOKEN` text appears in the addon log / bootstrap
  log / container env (the addon writes the file as root-owned 600 and
  never echoes the value).

### 13c. Re-run safety

Re-run the addon with no flag changes and confirm `INSTALL_BESZEL_AGENT`
appears exactly once in `/etc/homelab/node.env`:

```bash
sudo ./addons/beszel-agent/install.sh
grep -c '^INSTALL_BESZEL_AGENT=' /etc/homelab/node.env   # → 1
```

The existing healthy container stays running and `beszel_agent_data`
is unchanged. Re-run with changed credentials (export new env vars)
to intentionally rotate credentials; the addon re-writes `.env`,
restarts Compose, and re-verifies the container before persisting the
same `INSTALL_BESZEL_AGENT=true` line (atomic upsert; no duplicates).

For a same-host hub only, verify the explicit exception:

```bash
sudo env BESZEL_ALLOW_SAME_HOST_HUB_URL=true \
  BESZEL_HUB_URL="http://127.0.0.1:8090" \
  BESZEL_AGENT_KEY="<public-key-from-hub>" \
  BESZEL_AGENT_TOKEN="<token-from-hub>" \
  HOMELAB_NONINTERACTIVE=1 \
  ./addons/beszel-agent/install.sh
```

Do not use that override for a hub on another node.

## 14. Repo-id pin mismatch (lobaro-primary)

`/etc/restic/repo-id` is the 32-char hex UUID pinned at
`restic init` time. `check-node.sh` and `homelab_assert_repo_id_pinned`
both refuse a live repository whose UUID disagrees with the pin.

On a healthy node:

```bash
sudo cat /etc/restic/repo-id                                 # the pinned UUID
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_assert_repo_id_pinned'
echo $?                                                      # → 0
sudo /opt/stacks/_backup/check-node.sh                       # → exit 0
```

Corrupt the pin and confirm both checks fail with a clear mismatch
message:

```bash
sudo cp /etc/restic/repo-id /tmp/repo-id-bak
sudo bash -c 'echo "deadbeefdeadbeefdeadbeefdeadbeef" > /etc/restic/repo-id'
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_assert_repo_id_pinned'
echo $?                                                      # → 1
sudo /opt/stacks/_backup/check-node.sh                       # → exit 1, repo-id mismatch line
sudo mv /tmp/repo-id-bak /etc/restic/repo-id
sudo /opt/stacks/_backup/check-node.sh                       # → exit 0 again
```

A network outage that prevents `restic cat config --json` from
reading the live id is a WARN, not a FAIL (the check cannot tell
"network down" from "creds wrong"). A confirmed MISMATCH is a hard
FAIL.

## 15. Tailscale IP SSOT validation

The file `/opt/homelab/env-file/tailscale.env` must hold a single
`TAILSCALE_IP=100.x.y.z` line where the IP is a valid Tailscale CGNAT
IPv4 (100.64.0.0/10). `check-node.sh` fails when the file is missing,
invalid, or disagrees with `tailscale ip -4`.

```bash
sudo ls -la /opt/homelab/env-file/tailscale.env
sudo cat   /opt/homelab/env-file/tailscale.env
sudo systemctl list-timers update-tailscale-ip.timer
sudo /opt/stacks/_backup/check-node.sh                       # → "Tailscale IP SSOT … PASS"
```

Drop the file and confirm:

```bash
sudo mv /opt/homelab/env-file/tailscale.env /tmp/ts-env-bak
sudo /opt/stacks/_backup/check-node.sh                       # → FAIL: Tailscale IP SSOT file missing
sudo /opt/stacks/_system/update-tailscale-ip.sh
sudo /opt/stacks/_backup/check-node.sh                       # → exit 0 again
```

Corrupt the value and confirm:

```bash
sudo cp /opt/homelab/env-file/tailscale.env /tmp/ts-env-bak
sudo bash -c 'echo TAILSCALE_IP=192.168.1.1 > /opt/homelab/env-file/tailscale.env'
sudo /opt/stacks/_backup/check-node.sh                       # → FAIL: Tailscale IP SSOT file exists but value is invalid
sudo cp /tmp/ts-env-bak /opt/homelab/env-file/tailscale.env
sudo /opt/stacks/_backup/check-node.sh                       # → exit 0 again
```

Stopping Tailscale should NOT immediately fail the SSOT section
(the writer only refreshes the file; the check tolerates a stale file
when `tailscale status` returns non-zero, and warns instead).

## 16. Addon: host-native restic

The host-native systemd path is opt-in. Install it via the addon
after stopping the lobaro container:

```bash
docker ps --filter name=restic-backup                       # running
sudo ./addons/restic-host-native/install.sh                  # must REFUSE (see §17)
docker stop restic-backup
sudo ./addons/restic-host-native/install.sh                  # now installs
```

Expect:

- `/opt/stacks/_backup/backup.sh` exists, mode 700, root-owned.
- `/etc/systemd/system/restic-backup.service` and `.timer` exist.
- `systemctl is-enabled restic-backup.timer` → `enabled`.
- `systemctl is-active restic-backup.timer` → `active`.
- `systemctl list-timers restic-backup.timer` shows the timer
  scheduled (03:00 + per-machine random offset).
- `/etc/homelab/node.env` contains `INSTALL_RESTIC_HOST_NATIVE=true`
  (atomic upsert; no duplicate `INSTALL_RESTIC_HOST_NATIVE=` line).
- `/opt/stacks/restic-backup/` is left dormant (no auto-removal).

`check-node.sh` now reports `Backup path: host-native (restic-host-native
addon, flag persisted)` and the host-native timer block runs (enabled
+ active + result).

## 17. Addon mutual exclusion

The host-native addon refuses to install while the lobaro container is
running. The inverse is enforced by `setup-restic.sh` as a WARN (not
refuse) so re-runs and migration windows are not blocked.

```bash
docker ps --filter name=restic-backup                       # running
sudo ./addons/restic-host-native/install.sh                  # → exit 1, "refusing to install"
docker stop restic-backup
sudo ./addons/restic-host-native/install.sh                  # → exit 0
```

Re-running `setup-restic.sh` while the host-native timer is enabled:

```bash
sudo /opt/stacks/_backup/setup-restic.sh
# → WARN: restic-backup.timer is enabled — lobaro and host-native restic are mutually exclusive.
#         Disable the host-native timer with:  sudo systemctl disable --now restic-backup.timer
sudo /opt/stacks/_backup/check-node.sh
# → "Backup path: BOTH lobaro container AND host-native timer are active (mutually exclusive)"
#   (WARN line; exit code is 0 — supports the WP7 migration window)
```

Both paths active simultaneously is a WARN, not a FAIL. The operator
decides which path is canonical for the node.

## 18. Addon re-run safety

Both addons are re-runnable. Re-runs must NOT:

- duplicate `INSTALL_*` keys in `/etc/homelab/node.env`,
- destroy the data volume at `/var/cache/restic`,
- recreate `beszel_agent_data`,
- rotate the restic password.

```bash
# Re-run the host-native addon (already installed)
sudo ./addons/restic-host-native/install.sh
grep -c '^INSTALL_RESTIC_HOST_NATIVE=' /etc/homelab/node.env      # → 1
systemctl is-active restic-backup.timer                            # → active
ls -la /var/cache/restic                                            # unchanged mtime / content

# Re-run the Beszel addon (already installed)
sudo ./addons/beszel-agent/install.sh
grep -c '^INSTALL_BESZEL_AGENT=' /etc/homelab/node.env             # → 1
docker inspect -f '{{.State.Running}}' beszel-agent                 # → true
```

A first-time bootstrap.sh re-run with no addon flags must skip
step 9 entirely — no addon dispatch, no `INSTALL_*` flags mutated:

```bash
sudo ./bootstrap.sh --role=client --node-name=vps-b --use-exit-node=vps-a
grep -c '^INSTALL_BESZEL_AGENT=' /etc/homelab/node.env             # → 0 (or unchanged from before)
grep -c '^INSTALL_RESTIC_HOST_NATIVE=' /etc/homelab/node.env       # → 0 (or unchanged)
```

## 19. Live-node E2E status

`[LIVE NODE — deferred per AGENT.md §5 rule 5]`. Sections 1, 2, 3, 4,
7, 8, 10, 11, 12, 14, 15, 16, 17, 18 all require either a live S3
endpoint (R2 / S3 / B2), a live Tailscale account, or both. In-session
logic was verified via static analysis, `bash -n`, and a 30-case
WP5 test suite (`/tmp/opencode/wp5-test/run-tests.sh`). A human
operator must execute these sections on throwaway VPSes before any
real-node deployment.

## 20. Migration: host-native → lobaro (AGENT.md §3 WP7)

The migration is driven by `migrate-to-lobaro.sh` (or
`bootstrap.sh --migrate-from-host-native`). It runs after step 6
(restic setup) and before step 7 (state persistence) when invoked
through bootstrap.

Setup (synthesise the host-native starting state on a throwaway VPS):

```bash
# 1. Bootstrap a node to get /etc/homelab/node.env + Tailscale + UFW + Docker.
sudo ./bootstrap.sh --role=server --node-name=mig-vps --advertise-exit-node
# ... provide S3 creds; let the lobaro container start.

# 2. Stop + disable the lobaro container and the addon, then install the
#    host-native path manually. This synthesises a pre-WP5 node.
sudo docker stop restic-backup
sudo ./addons/restic-host-native/install.sh
sudo systemctl is-enabled restic-backup.timer   # → enabled
sudo systemctl is-active --quiet restic-backup.timer   # → 0 (active)
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --tag "$NODE_NAME"'
# → at least one snapshot, tagged mig-vps.

# 3. Force a second host-native snapshot so we can prove the
#    "existing snapshots remain" guarantee.
sudo /opt/stacks/_backup/backup.sh
```

Expect at this point:
- `docker ps --filter name=restic-backup` is empty (lobaro container stopped).
- `systemctl is-enabled restic-backup.timer` returns success.
- `systemctl is-active --quiet restic-backup.timer` returns 0.
- `/etc/homelab/node.env` has `INSTALL_RESTIC_HOST_NATIVE=true`.
- At least one restic snapshot exists under tag `mig-vps`.

Run the migration:

```bash
sudo HOMELAB_NONINTERACTIVE=1 ./migrate-to-lobaro.sh
```

Expect:
- Log line: "Pinned repository UUID to /etc/restic/repo-id (...)" or
  "Existing repo-id pin matches live repository (...)".
- Log line: "Stopping and disabling the host-native timer...".
- Log line: "Pre-migration: N existing snapshot(s) tagged 'mig-vps'...".
- Log line: "Running setup-restic.sh against the existing repository...".
- Log line: "restic-backup container is running.".
- Log line: "Repo-id pin verified.".
- Log line: "Post-migration: M snapshot(s) tagged 'mig-vps' (was N...)".
- Log line: "Persisted INSTALL_RESTIC_HOST_NATIVE=false...".
- Final line: "=== Migration complete ===".
- Exit code 0.

Post-migration:

```bash
sudo docker inspect -f '{{.State.Running}}' restic-backup   # → true
sudo systemctl is-enabled restic-backup.timer               # → disabled
sudo grep INSTALL_RESTIC_HOST_NATIVE /etc/homelab/node.env  # → false
sudo /opt/stacks/_backup/check-node.sh                       # → exit 0
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --tag mig-vps'
# All pre-existing snapshot IDs are still present.

sudo docker exec restic-backup /bin/backup
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --tag mig-vps'
# A new snapshot appeared, with the same tag.
```

Idempotency (re-run the migration):

```bash
sudo HOMELAB_NONINTERACTIVE=1 ./migrate-to-lobaro.sh
# → exits 0 with "already migrated; nothing to do".
```

Rollback after a successful migration:

```bash
sudo docker stop restic-backup
sudo ./addons/restic-host-native/install.sh
sudo systemctl enable --now restic-backup.timer
# → host-native path is back. Lobaro container is stopped. /etc/restic/*
#   is untouched.
```

`[LIVE NODE — deferred per AGENT.md §5 rule 5]`. In-session WP7 logic
was verified via static analysis, `bash -n`, and the WP7 test suite
(`/tmp/opencode/wp7-test/run-tests.sh`). A human operator must execute
this section on a throwaway VPS before deploying the migration helper
on a real node.
