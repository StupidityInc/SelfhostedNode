# Homelab Node Bootstrap

Opinionated bootstrap for personal homelab nodes that use:

- Docker Compose stacks under `/opt/stacks`
- The **lobaro `restic-backup-docker` container** as the primary backup
  mechanism (one encrypted repository per node)
- Tailscale for the management / mesh network, with a node-local IP
  single-source-of-truth file at `/opt/homelab/env-file/tailscale.env`
- UFW default-deny with the Tailscale interface allowed
- Optional Cloudflare Tunnel on server nodes
- Optional Tailscale exit-node routing for pure-compute clients
- Optional **addons** for non-default features (Beszel monitoring agent,
  host-native restic systemd path)

See **Architecture** below for the post-WP5 layout.

## Roles

| Role     | Public exposure                    | Typical use                           |
|----------|------------------------------------|---------------------------------------|
| `server` | Yes (Cloudflare Tunnel preferred)  | Entry point, reverse proxy, exit node |
| `client` | No                                 | Pure compute, internet via exit node  |

## Quick start

```bash
# On a fresh Ubuntu Server
git clone <your-private-repo> # or scp the files
cd homelab-bootstrap
chmod +x *.sh

# Server that will also be an exit node
sudo ./bootstrap.sh --role=server --node-name=edge-1 --advertise-exit-node --install-cloudflared

# Client that routes internet through the server
sudo ./bootstrap.sh --role=client --node-name=compute-1 --use-exit-node=edge-1
```

`--node-name` is **required**: it becomes the Tailscale hostname, the
container hostname in the lobaro stack, the `RESTIC_TAG` baked into the
cron, the recommended bucket/prefix, and the `NODE_NAME` in
`/etc/homelab/node.env`. Generic names (`ubuntu`, `debian`,
`localhost`, `server`, …) are refused. Interactively you get a
hostname-derived suggestion to confirm; non-interactively the flag is
mandatory.

`--node-name` is **immutable after the first run**. `bootstrap.sh`
refuses to change it because the restic tag drives `restic forget --tag`
and silently changing it would strand old snapshots forever.

You can also run interactively (the script will prompt for role and
node name).

### Non-interactive mode

```bash
export TS_AUTHKEY="tskey-auth-..."
sudo ./bootstrap.sh --yes \
  --role=client --node-name=compute-1 \
  --use-exit-node=edge-1 --ts-authkey="$TS_AUTHKEY"
```

`--yes` (or `HOMELAB_NONINTERACTIVE=1`) skips confirmations. Dangerous
steps still require their explicit flags: `--no-public-ssh` *is* the
confirmation for removing public SSH. For unattended restic setup
export `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT`,
`BUCKET` (and optionally `RESTIC_PASSWORD`; otherwise one is generated
and printed once. To add a recovery key non-interactively, also provide
`RESTIC_RECOVERY_PASSWORD_FILE`).

### Interactive mode

On a TTY, `bootstrap.sh` prompts for optional choices (cloudflared,
Beszel agent, advertise/use exit node, host-native → lobaro migration)
instead of requiring the operator to remember flag names. All defaults
are `No`; explicit flags always override any prompt. Step order is
unchanged: exit-node is still applied last with probe + rollback;
migrate still owns step 6b; addons still dispatch after core.

Precedence for each optional choice (first match wins):

1. `--yes` / `HOMELAB_NONINTERACTIVE=1` / non-TTY stdin → never prompt.
2. Explicit flag for that option → no prompt.
3. Already installed and runtime-healthy → silent skip.
4. Interactive prompt (TTY only; `--interactive` forces it when
   `--yes` is also set, but never overrides rule 1).
5. Safe default (`false` / empty).

`--interactive` is the only new flag and is documented in `--help`.
The host-native restic addon has no interactive prompt by design —
it is mutually exclusive with lobaro and a "yes" mid-bootstrap would
land both schedulers. Use `--install-restic-host-native` (or
`--migrate-from-host-native` to go the other way).

## Architecture

The post-WP5 layout treats the lobaro container as the primary backup
mechanism and pushes everything that is **not** a core safety step into
an opt-in addon under `addons/<name>/install.sh`.

```
┌────────────────────────────────────────────────────────────────────┐
│  /opt/homelab/env-file/tailscale.env        # Tailscale IP SSOT     │
│      written by _system/update-tailscale-ip.sh                      │
│      refreshed by update-tailscale-ip.timer (every 15 min)          │
│      re-run after every tailscaled (re)start                        │
├────────────────────────────────────────────────────────────────────┤
│  /etc/homelab/node.env                      # identity + INSTALL_*  │
│      ROLE, NODE_NAME, USE_EXIT_NODE, KEEP_PUBLIC_SSH,                │
│      INSTALL_BESZEL_AGENT, INSTALL_RESTIC_HOST_NATIVE, …             │
├────────────────────────────────────────────────────────────────────┤
│  /etc/restic/                               # secrets (root 600)    │
│      env                                     # shell-quoted (lib.sh)│
│      env.docker                              # raw (Compose env_file)│
│      password                                                              │
│      repo-id                                 # 32-char hex UUID pin │
│      recovery-key.present                    # marker only           │
├────────────────────────────────────────────────────────────────────┤
│  /opt/stacks/                                # backed-up tree       │
│      _backup/                                # host tooling (no     │
│      │     check-node.sh, lib.sh, change-restic-password.sh,        │
│      │     RESTORE.md; backup.sh present but dormant)               │
│      _system/                                # update-tailscale-ip  │
│      restic-backup/                          # PRIMARY BACKUP       │
│      │     docker-compose.yml (lobaro, hostname=$NODE_NAME)         │
│      │     .env (non-secrets: BACKUP_CRON, RESTIC_FORGET_ARGS, …)   │
│      beszel-agent/                           # addon (when installed)│
└────────────────────────────────────────────────────────────────────┘
```

The lobaro container (at `/opt/stacks/restic-backup/`) is the source of
truth for backups:

- The container's BusyBox cron runs the backup window (`BACKUP_CRON`)
  and the weekly integrity check (`CHECK_CRON`). Both are stable
  per-node UTC expressions derived from `NODE_NAME` (see
  `setup-restic.sh:cron_from_node_name`).
- `/etc/restic` is mounted read-only as a **directory** (not per-file)
  so an atomic `mv /etc/restic/password` is visible to the next
  container invocation without a restart.
- The container reads the password from
  `RESTIC_PASSWORD_FILE=/etc/restic/password`. The password **never**
  appears in Compose `environment:` or in the stack `.env` — Compose
  gets only `RESTIC_PASSWORD_FILE` plus the raw `env_file:` contents of
  `/etc/restic/env.docker`.
- The container's hostname is `NODE_NAME`; its tag is `NODE_NAME`;
  both are also what `check-node.sh` looks for in the snapshot list.

### Addons

Four pieces that used to live inline in `bootstrap.sh` (or in
`beszel-agent/` templates) are now addons:

| Addon | Repo path | Runtime path (when installed) |
|-------|-----------|-------------------------------|
| Beszel hub | `addons/beszel-hub/install.sh` | `/opt/stacks/beszel-hub/` (Tailscale-bind by default) |
| Beszel agent | `addons/beszel-agent/install.sh` | `/opt/stacks/beszel-agent/` |
| Host-native restic | `addons/restic-host-native/install.sh` | `/opt/stacks/_backup/backup.sh` + `/etc/systemd/system/restic-backup.{service,timer}` |
| Cloudflared | `addons/cloudflared/install.sh` | `/opt/stacks/cloudflared/` (Docker container) |

`bootstrap.sh` only invokes an addon when an explicit opt-in flag was
set THIS run (`--beszel-agent`, `--beszel-hub`, `--beszel-both`,
`--install-cloudflared`, or `--install-restic-host-native`). A
plain re-run with no flags is a no-op for addons. Step 9 of
`bootstrap.sh` ("Addon dispatch") is the only place addons are
invoked, and it runs **after** core safety has converged (Tailscale up,
UFW verified, lobaro container running, exit-node applied).

Addons are mutually exclusive with the lobaro path **on install**:
`addons/restic-host-native/install.sh` refuses (exit non-zero) if
`docker inspect -f '{{.State.Running}}' restic-backup` is `true`. The
inverse direction is enforced by `setup-restic.sh` as a WARN (not a
refuse) so re-runs and migration windows are not blocked.

**Permissions (post-laptop-1 batch):** every stack dir is 755
root:root, the `docker-compose.yml` is 644, and the `.env` is 600.
Identity dirs (`/etc/homelab/`) and secrets dirs (`/etc/restic/`)
stay 700. The `addon_root_only_dir` helper defaults to 755; callers
that need 700 for a secret-only dir must pass the mode explicitly.
Full matrix in `addons/README.md` "Permissions policy".

### Tailscale IP single source of truth

`/opt/homelab/env-file/tailscale.env` is the only file that holds the
node's Tailscale IP for stack consumers. It is written atomically by
`/opt/stacks/_system/update-tailscale-ip.sh` (installed by bootstrap
step 3a), refreshed every 15 minutes by `update-tailscale-ip.timer`,
and re-run by the `tailscaled.service.d/override.conf` drop-in after
every Tailscale restart.

Stacks consume it via `env_file:` or `--env-file`:

```yaml
# docker-compose.yml
services:
  app:
    env_file:
      - /opt/homelab/env-file/tailscale.env
      - .env
    ports:
      - "${TAILSCALE_IP:?TAILSCALE_IP missing — run update-tailscale-ip.sh}:8080:80"
```

or

```bash
docker compose \
  --env-file /opt/homelab/env-file/tailscale.env \
  -f /opt/stacks/app/docker-compose.yml up -d
```

The Tailscale IP machinery **never** mutates a stack's `.env` file. It
only writes the SSOT file under `/opt/homelab/`. MagicDNS names
(`edge-1.tailnet.ts.net`) remain the preferred value for `SITE_URL`,
browser access, and inter-service URLs; `TAILSCALE_IP` is only for
bind addresses.

## How the safe ordering works

`bootstrap.sh` is one orchestrator with load-bearing order. Do not
split it into independently runnable phase scripts.

1. **Packages + Docker** — `apt-get install`, then the official
   `get.docker.com` script if Docker is missing.
2. **Directory skeleton** — creates `/opt/stacks/`, `/opt/stacks/_backup/`,
   `/opt/stacks/_system/`, `/opt/homelab/env-file/`, `/etc/restic/`.
   Existing directories are **never** `chown -R`'d; only newly created
   ones get an owner.
3. **Tailscale (no exit-node routing yet)** — `tailscale up
   --hostname=$NODE_NAME`. The auth key is passed to `tailscale` but
   never written to the bootstrap log.
3a. **Tailscale IP SSOT** — copies `_system/*` into
   `/opt/stacks/_system/`, installs the `tailscaled` drop-in that
   re-runs the writer after every restart, enables the 15-min
   `update-tailscale-ip.timer`, runs the writer once. After this step,
   `/opt/homelab/env-file/tailscale.env` is populated.
3b. **Server exit-node prerequisite: IP forwarding** — server nodes
   with `--advertise-exit-node` get `net.ipv4.ip_forward=1` and
   `net.ipv6.conf.all.forwarding=1` via
   `/etc/sysctl.d/99-homelab-exitnode.conf`, applied and **verified**
   before UFW runs. A silent black-hole is a hard error.
4. **UFW hardening (fail closed, never lock the operator out)** —
   default deny + allow `tailscale0` + `41641/udp`. The persisted
   `KEEP_PUBLIC_SSH` choice (default: open until verified) decides
   whether `OpenSSH` / `22/tcp` is allowed before `ufw --force enable`.
   The post-enable state is verified, and `tailscaled` is restarted
   only when UFW actually changed or this is a new node.
5. **Role-specific extras** — server nodes may install cloudflared
   (apt + binary fallback, no pinned release). Cloudflared stays in
   core this iteration; the move to an addon is backlog.
6. **Restic setup** — `setup-restic.sh` writes `/etc/restic/{env,
   env.docker, password, repo-id}`, performs host-side `restic init`
   (defeats the lobaro auto-init), re-pins `repo-id` against the live
   repository, and brings the lobaro container up at
   `/opt/stacks/restic-backup/`. The first backup is async; the
   container's cron handles it.
7. **Persist desired state** — `write_node_env` saves
   `ROLE`, `NODE_NAME`, `USE_EXIT_NODE`, `EXIT_NODE_APPLIED`,
   `INSTALL_BESZEL_AGENT`, `INSTALL_RESTIC_HOST_NATIVE`,
   `KEEP_PUBLIC_SSH`, `TAILSCALE_FIREWALL_VERIFIED`, etc. to
   `/etc/homelab/node.env` atomically.
8. **Exit-node routing (LAST, with probe + rollback)** — clients with
   `--use-exit-node=<name>` get `tailscale set --exit-node=…` only
   after steps 1–7 have converged. Success requires Tailscale's
   `.ExitNodeStatus.Online` evidence for the requested node; failure
   rolls back via `tailscale set --exit-node=` and aborts.
9. **Addon dispatch (after core is complete)** — only when a
   per-run request flag was set (`BESZEL_AGENT_REQUESTED_THIS_RUN` or
   `RESTIC_HOST_NATIVE_REQUESTED_THIS_RUN`). Each addon installer
   performs validate → atomic write → start → verify running → only
   then persist `INSTALL_*=true` to `/etc/homelab/node.env`. A plain
   re-run with no addon flags skips this entire step.

Re-running `bootstrap.sh` is safe: it parses `/etc/homelab/node.env`
without evaluating values, converges Tailscale prefs via `tailscale
set`, re-verifies UFW, and never touches existing data or ownership.
Public SSH lockdown and node identity are sticky. Use `--public-ssh`
only for an explicit, intentional reopen. Refusing `--role` and
`--node-name` changes protects role and restic retention identity.

## Optional addons

### Beszel — hub / agent / both (addons)

Beszel is opt-in. There are two addons:

- `addons/beszel-hub/install.sh` — the **hub** (server UI + data
  store). Deployed to `/opt/stacks/beszel-hub/`. Binds to the
  Tailscale IP by default (read from
  `/opt/homelab/env-file/tailscale.env`); NEVER 0.0.0.0 unless
  `BESZEL_HUB_BIND=0.0.0.0` is explicit (the addon prints a WARN).
  Default port 8090 (`BESZEL_HUB_PORT` override). The first-run
  operator creates the admin account in the UI.
- `addons/beszel-agent/install.sh` — the **agent** on a remote
  node. Connects outbound to a hub URL. No inbound ports; no UFW
  changes.

The two addons are independent: you can install just the agent
(typical for fleet nodes that report to a hub elsewhere) or just
the hub (the monitoring node itself). For a single-node "test
everything on this box" install, use `--beszel-both` — it runs the
hub first, then the agent, with `BESZEL_HUB_URL` auto-derived from
the local Tailscale IP and `BESZEL_ALLOW_SAME_HOST_HUB_URL=true`
forced so the agent's same-host validation passes.

Bootstrap flags:

```bash
# Agent only (most common)
sudo ./bootstrap.sh --role=client --node-name=compute-1 \
  --beszel-agent --yes

# Hub only (monitoring node)
sudo ./bootstrap.sh --role=server --node-name=monitor-1 \
  --beszel-hub --yes

# Both on a single node
sudo ./bootstrap.sh --role=server --node-name=edge-1 \
  --beszel-both --yes
```

For non-interactive use, pass the agent credentials via env vars.
The hub URL must be a Tailscale IP or a hostname that resolves to
a Tailscale address:

```bash
sudo env \
  BESZEL_HUB_URL="http://vps-1:8090" \
  BESZEL_AGENT_KEY="ssh-ed25519 AAAA..." \
  BESZEL_AGENT_TOKEN="..." \
  ./bootstrap.sh --yes --role=client --node-name=compute-1 --beszel-agent
```

`BESZEL_SYSTEM_NAME` is optional and defaults to `NODE_NAME`. Loopback
or public hub URLs are rejected unless
`BESZEL_ALLOW_SAME_HOST_HUB_URL=true` is explicitly set for a hub
running on this same host (the agent installer also auto-refuses
when a local `beszel-hub` container is running, to prevent
silent loopback connections).

The agent collects its credentials (interactively or via env vars)
during step 9, after core safety has converged. The generated
`/opt/stacks/beszel-agent/.env` is root-owned with mode `600`. It is
intentionally inside `/opt/stacks`, so it is included in the encrypted
restic backup; never commit it or place real credentials in
`beszel-agent/.env.example`. The Compose project uses host networking
for interface statistics, listens only on `127.0.0.1:45876`, disables
the inbound SSH mode, and publishes no Docker ports or UFW rules.

The hub's `.env` holds only the bind address, port, and an optional
`BESZEL_PUBLIC_URL` hint. The hub does not need an external token
(admin password is created in the UI; agent KEY/TOKEN pairs come
from the hub's **Add System** flow).

Verify after bootstrap:

```bash
sudo docker ps --filter name=beszel-hub
sudo docker ps --filter name=beszel-agent
sudo /opt/stacks/_backup/check-node.sh
```

The agent should then appear healthy in the hub UI. Install Uptime
Kuma manually on the monitoring node only; it is not automated here.

### Cloudflared (addon)

Cloudflare's `cloudflared` is now a Docker container addon
(`addons/cloudflared/install.sh`). The previous host-binary path
(`/usr/local/bin/cloudflared`, apt source at
`/etc/apt/sources.list.d/cloudflared.list`) is no longer the
supported install — bootstrap cleans up any legacy apt metadata on
re-run, and new installs go through the addon.

To install:

```bash
sudo CLOUDFLARE_TUNNEL_TOKEN="<token-from-cloudflare-dashboard>" \
  ./bootstrap.sh --role=server --node-name=edge-1 \
  --install-cloudflared --yes
# or standalone:
sudo CLOUDFLARE_TUNNEL_TOKEN="<token>" \
  ./addons/cloudflared/install.sh
```

The token comes from the Cloudflare dashboard (Zero Trust →
Networks → Tunnels → Create a tunnel → copy the token). The addon
writes it to `/opt/stacks/cloudflared/.env` (mode 600). The
container runs in `network_mode: host` (required by the QUIC
tunnel protocol) and bind-mounts a `config/` directory for cert
persistence. Bootstrap's `default allow outgoing` policy covers
the outbound path to Cloudflare's edge; no UFW rule is required
for inbound.

Token rotation: rotate in the Cloudflare dashboard, then
`sudo sed -i 's|^CLOUDFLARE_TUNNEL_TOKEN=.*|...|' /opt/stacks/cloudflared/.env`
and `docker compose up -d` in the stack dir (or just re-run the
addon).

### Host-native restic (addon)

The host-native systemd path (`backup.sh` + `restic-backup.{service,
timer}`) is **not** installed by bootstrap. After WP5 it lives at
`addons/restic-host-native/install.sh`. To opt in (for example, while
testing the lobaro path or during a WP7 migration window):

```bash
sudo ./addons/restic-host-native/install.sh
```

The addon **refuses** while the lobaro container is running — the two
backup mechanisms are mutually exclusive at install time. Stop the
container first (`docker stop restic-backup`), install the addon, and
either leave the container stopped (host-native takes over) or do not
re-enable it (lobaro wins). `INSTALL_RESTIC_HOST_NATIVE=true` is
written to `/etc/homelab/node.env` only after the timer is verified
active; `check-node.sh` surfaces a missing timer as a FAIL.

## Docker and UFW (important!)

**Docker published ports bypass UFW.** Docker programs its own iptables
chains before UFW's, so `-p 8080:80` is reachable from the internet
even with a default-deny policy. This bootstrap deliberately does not
rewrite Docker's firewall rules. Instead:

- When using Cloudflare Tunnel on a server, bind services to
  `127.0.0.1` (e.g. `ports: ["127.0.0.1:8080:80"]`).
- When a service is only for the tailnet, bind it to the node's
  Tailscale IP via `${TAILSCALE_IP:?…}` from the SSOT file. **Never**
  bake the IP into a stack `.env`; the Tailscale IP machinery will not
  rewrite it for you.
- `check-node.sh` lists every container published on `0.0.0.0`/`::` so
  the exposure is at least visible.

## Files

The repo source layout:

| File / dir | Role |
|------------|------|
| `bootstrap.sh` | Main orchestrator. Order is load-bearing (see "How the safe ordering works"). |
| `setup-restic.sh` | Restic + S3 wizard. Deploys the lobaro container at `/opt/stacks/restic-backup/`. |
| `setup-restic.lobaro.yml.tmpl` | Compose template for the lobaro stack. Substituted by `setup-restic.sh` before install. |
| `lib.sh` | Safe state/secret parsing helpers. WP5 adds `INSTALL_RESTIC_HOST_NATIVE` to `HOMELAB_NODE_ENV_KEYS` and the `$2` flag override on `homelab_backup_path`. |
| `check-node.sh` | Health / exit-node / backup-freshness checker. Honest for the lobaro-primary layout (lobaro container running, `repo-id` match, Tailscale IP SSOT, conditional host-native timer, mutual-exclusivity WARN). |
| `change-restic-password.sh` | Safe restic password rotation. Used by both the lobaro and the host-native paths. |
| `_system/` | Source for node-side `/opt/stacks/_system/` (Tailscale IP SSOT writer, units, `tailscaled` drop-in). |
| `beszel-agent/` | Compose template + `.env.example` for the Beszel **agent**. Consumed by `addons/beszel-agent/install.sh`. |
| `addons/lib-addon.sh` | Shared helpers for `addons/*/install.sh`. `addon_log`, `addon_require_root`, `addon_use_sudo`, `addon_assert_not_running`, `addon_assert_running`, `addon_root_only_dir` (default mode **755**, post-laptop-1), `addon_root_only_file`, `addon_persist_flag` (atomic upsert into `/etc/homelab/node.env`). Permissions policy documented in `addons/README.md`. |
| `addons/beszel-agent/install.sh` | Beszel **agent** installer (addon). Refuses when a local `beszel-hub` container is running unless `BESZEL_ALLOW_SAME_HOST_HUB_URL=true` is set. |
| `addons/beszel-hub/install.sh` | Beszel **hub** installer (addon). Tailscale-IP bind by default; never 0.0.0.0 unless the operator passes `BESZEL_HUB_BIND=0.0.0.0` (with a WARN). Default port 8090. |
| `addons/cloudflared/install.sh` | Cloudflared tunnel installer (addon). Docker container, `network_mode: host`. Token via `CLOUDFLARE_TUNNEL_TOKEN` env var or `read -s` prompt. Replaces the pre-batch host-binary path. |
| `addons/restic-host-native/install.sh` | Host-native restic installer (addon). Refuses while the lobaro container is running. |
| `RESTORE.md` | Self-describing recovery instructions (lobaro-primary, repo-id-aware, Tailscale IP regeneration). |
| `CHANGES.md` | What was hardened and why, dated by work package. |
| `TESTING.md` | Throwaway-VPS verification plan. |
| `RISKS.md` | Explicit residual accepted risks for the post-WP5 layout. |
| `AGENT.md` | Authoritative instructions and continuity brief for the transformation (WP1–WP5). |

These files reach the running node **only** via the addon installers
(post-WP5 — no longer auto-copied by bootstrap):

| File | Reaches runtime path |
|------|----------------------|
| `backup.sh` | `/opt/stacks/_backup/backup.sh` via `addons/restic-host-native/install.sh` (mode 700). |
| `restic-backup.service` | `/etc/systemd/system/restic-backup.service` via the same addon. |
| `restic-backup.timer` | `/etc/systemd/system/restic-backup.timer` via the same addon. |

The restored `_backup/backup.sh` is **dormant** after a restore — see
`RESTORE.md` step 6.

Node-local state that does not live in this repo:

| Path | Contents |
|------|----------|
| `/etc/homelab/node.env` | ROLE, stable identity, applied tunnel/exit-node state, `INSTALL_BESZEL_AGENT`, `INSTALL_RESTIC_HOST_NATIVE`, lockdown metadata. Mode 600, root-owned. |
| `/opt/homelab/env-file/tailscale.env` | `TAILSCALE_IP=100.x.y.z`. Node-local, regenerated by `_system/update-tailscale-ip.sh`. NOT in backup. |
| `/etc/restic/env` | S3 credentials, repository, cache dir (mode 600). Shell-quoted; read by systemd + `lib.sh`. |
| `/etc/restic/env.docker` | Same data as `env`, raw `KEY=VALUE` for Compose `env_file:`. NOT a secret (no password). |
| `/etc/restic/password` | Repository password (mode 600). Read by `RESTIC_PASSWORD_FILE` inside the lobaro container. |
| `/etc/restic/repo-id` | 32-char lowercase hex UUID pinned at `restic init`. Hard mismatch is a FAIL in `check-node.sh`. |
| `/etc/restic/recovery-key.present` | Marker only — never the secret itself. |
| `/var/cache/restic` | Restic cache (writable by the lobaro container and the host-native systemd unit). |
| `/opt/stacks/restic-backup/` | The lobaro Compose project (PRIMARY backup). Not auto-created if `setup-restic.sh` was never run. |
| `/opt/stacks/beszel-agent/` | Beszel agent stack — only present when `addons/beszel-agent/install.sh` was run. Mode 755 dir, compose 644, `.env` 600. |
| `/opt/stacks/beszel-hub/` | Beszel hub stack — only present when `addons/beszel-hub/install.sh` was run. Mode 755 dir, compose 644, `.env` 600, `beszel_data/` 755. |
| `/opt/stacks/cloudflared/` | Cloudflared tunnel stack — only present when `addons/cloudflared/install.sh` was run. Mode 755 dir, compose 644, `.env` 600 (tunnel token), `config/` 755. |

## Observability

`sudo /opt/stacks/_backup/check-node.sh` exits non-zero when something
is actually broken. Sections (in script order):

- **Tailscale** — daemon status, hostname, advertised exit-node flag,
  expected vs active exit-node match.
- **Tailscale IP SSOT** — file present, value is a valid CGNAT IPv4,
  matches live `tailscale ip -4` when Tailscale is up.
- **Outbound connectivity** — public IPv4, latency to 1.1.1.1 / 8.8.8.8,
  truthfulness check that the exit-node IP differs from
  `DIRECT_PUBLIC_IP_AT_SETUP`.
- **Firewall (UFW)** — active, `tailscale0` allowed, public-SSH
  lockdown consistent with `KEEP_PUBLIC_SSH`.
- **Restic backup** — backup path (`lobaro` | `host-native` | `both`
  | `none`); `restic-backup` container running when lobaro is in the
  mix; `restic-backup.timer` enabled+active only when the host-native
  addon is the active path (preferred signal: persisted
  `INSTALL_RESTIC_HOST_NATIVE=true`, with the unit-file heuristic as
  fallback); `repo-id` match (FAIL on mismatch, WARN on live repo
  unreachable); snapshot freshness via host `restic snapshots
  --latest 1` (ground truth per `AGENT.md §2`); container error-log
  WARN as a secondary signal.
- **Docker** — daemon reachable, lists any container published on
  `0.0.0.0`/`::`.
- **Optional speed hint** — short Cloudflare download; skip with
  `CHECK_NODE_SKIP_SPEEDTEST=1`.

Wire it into any monitoring that can run a command and watch the exit
code.

## Backup timing

The lobaro container's BusyBox cron fires at `BACKUP_CRON` (UTC), a
stable per-node expression derived from `NODE_NAME` (see
`setup-restic.sh:cron_from_node_name`). `CHECK_CRON` runs a weekly
`restic check`. Both are baked into the Compose template via
`setup-restic.lobaro.yml.tmpl`. **The image runs cron in UTC**; the
template's `BACKUP_CRON` is therefore a UTC expression — operators in
non-UTC timezones must remember this when reading the schedule.

Unlike the host-native path, the lobaro container has **no systemd
`Persistent=true` semantics**: missed windows during container
downtime do not replay. `restart: unless-stopped` plus the BusyBox
cron daemon typically catch up at the next window.

The host-native addon (`restic-backup.timer`) preserves the
`Persistent=true` + `RandomizedDelaySec=2h` behaviour from the
goal.md era; see the addon README for details.

## Safety notes

- Public SSH is left open by default. Use `--no-public-ssh` only after
  you have confirmed Tailscale access from another machine.
- The restic password is generated once, must be typed back during
  interactive setup (or supplied explicitly in non-interactive mode),
  and is stored only in `/etc/restic/password`. Save it in your
  password manager along with the `repo-id` pin (32-char hex).
- Add a second recovery key that lives **only** in your password
  manager; `setup-restic.sh` offers this interactively and accepts
  `RESTIC_RECOVERY_PASSWORD_FILE` non-interactively. Password rotation
  refuses to proceed until a recovery key is recorded and successfully
  verified.
- Restic credentials remain under `/etc/restic`; the opt-in Beszel
  `.env` is a deliberate root-only exception under `/opt/stacks` and
  is encrypted by restic.
- `RESTIC_PASSWORD` is **never** written into Compose `environment:`
  or any stack `.env`. Compose receives only `RESTIC_PASSWORD_FILE`
  (a path) plus the raw contents of `/etc/restic/env.docker`.

## Typical multi-node flow

1. Bootstrap the first **server** node with `--advertise-exit-node`.
2. Approve the exit node in the Tailscale admin console.
3. Bootstrap **client** nodes with `--use-exit-node=<server-name>`.
4. Verify from a client: `curl -4 ifconfig.me` (should show the
   server's public IP).
5. Confirm the lobaro container is running and `restic snapshots
   --tag <node-name>` lists at least one snapshot.
6. Optional: install addons — `--beszel-agent`, or
   `--install-restic-host-native` for a host-native backup window.
   Mutual exclusion is enforced at install time.

## Upgrading these scripts on an existing node

Pull the new files and re-run `sudo ./bootstrap.sh` once **with the
same `--node-name`** (the tag drives `restic forget --tag`, so the name
must stay stable). The re-run:

- Creates `/etc/homelab/node.env` and `/etc/homelab/env-file/` if
  missing.
- Re-runs step 3a if the SSOT writer is missing, but does not overwrite
  the SSOT file when the existing value is still valid.
- Re-runs step 6 only if `/etc/restic/env` is missing — otherwise the
  existing repository, password, and `repo-id` are kept and only the
  Compose file + stack `.env` are (re)generated on drift.
- Skips step 9 (addon dispatch) unless a request flag was set this
  run. To upgrade an addon, re-run the addon installer directly.

## Changing the restic password later

```bash
sudo /opt/stacks/_backup/change-restic-password.sh
```

The script requires and verifies a recorded recovery key, locks
against concurrent backups, verifies the new password against the
repository, and only then atomically replaces the on-disk file. Because
the lobaro container reads `/etc/restic/password` via
`RESTIC_PASSWORD_FILE` and the whole directory is mounted read-only,
the next backup picks up the new password without a container restart.
Recovery keys added via `restic key add` keep working across rotation.
For supervised non-interactive rotation, provide
`RESTIC_RECOVERY_PASSWORD_FILE` and `RESTIC_NEW_PASSWORD_FILE`.

## License / ownership

Personal tooling. Adjust freely for your own nodes.
