# addons/cloudflared/

Deploys Cloudflare's `cloudflared` as a **Docker container**
(`network_mode: host`) at `/opt/stacks/cloudflared/`. Token-auth only
— no `cloudflared tunnel login` step is required.

## Why Docker, not the host binary

Upstream's official `cloudflare/cloudflared` Docker image is the
most consistently maintained install path on Ubuntu (the
`pkg.cloudflare.com/cloudflared` .deb sometimes lags). The container
also matches the addons contract (validate → atomic write → start →
verify → persist `INSTALL_CLOUDFLARED=true`) and lives in the
restored / restic-backed `/opt/stacks/` tree alongside every other
stack.

The previous bootstrap path installed a host binary at
`/usr/local/bin/cloudflared`. That path is no longer used; the
addon's container is the only supported install.

## Source

- `install.sh` — installer (addons contract: validate → atomic write →
  start → verify → persist).
- `docker-compose.yml.tmpl` — Compose template. No secret interpolation
  here: the tunnel token lives only in `.env` and is read by Compose's
  `env_file:` directive.

## Behaviour

- **Image**: `cloudflare/cloudflared:latest`. The `latest` tag is
  intentional; upstream keeps a stable release cadence. Operators who
  want a pinned version can edit `docker-compose.yml` after install.
- **Network mode**: `host` (required by the QUIC tunnel protocol).
- **Token**: `CLOUDFLARE_TUNNEL_TOKEN` (required). The addon prompts
  interactively with `read -s`; non-interactive requires the env var
  to be set. The token is written into `.env` at mode 600, never
  interpolated into the compose file.
- **Config persistence**: `./config` is bind-mounted at
  `/etc/cloudflared` so the cert + tunnel credential survive
  container restarts.
- **Permissions** (F3): stack dir 755, `docker-compose.yml` 644,
  `.env` 600, `config/` 755. See `addons/README.md` "Permissions
  policy".

## Pre-flight (required before running)

1. Provision a tunnel in the Cloudflare dashboard:
   - Zero Trust → Networks → Tunnels → **Create a tunnel**
   - Pick a name (e.g. `edge-1-home`); choose **Cloudflared** as the
     connector type.
   - Copy the **token** (long base64 string). That is
     `CLOUDFLARE_TUNNEL_TOKEN`.
2. The container runs in `network_mode: host` and uses outbound
   7844/UDP + 443/TCP to reach Cloudflare's edge. Bootstrap step 4
   sets `default allow outgoing`, so no UFW change is required.
3. The Docker host needs `/etc/resolv.conf` and the default
   `iptables`/`bridge` setup intact — no `ufw-docker` or
   custom-network tricks.

## Mutual exclusion

- A `cloudflared` container already running on the same node: the
  addon refuses (`addon_assert_not_running`). A re-run with no flags
  is a no-op (compose up is idempotent; the persisted state is
  reloaded).
- The Beszel hub and the restic backup path do not conflict.

## Re-run safety

- `install(1)` overwrites the compose file atomically (same content
  on re-runs).
- The `.env` is **regenerated** on every run, but the addon reads
  the existing token from the file when no env var is supplied —
  rotation requires an explicit new token. Mode 600, root-owned.
- `docker compose up -d` is idempotent.
- `addon_persist_flag INSTALL_CLOUDFLARED true` upserts the key in
  `/etc/homelab/node.env` (no duplicate lines).
- The data volume at `./config` is never touched (cert + credential
  state survive every re-run).

## Onboarding

After install:

```bash
sudo docker ps --filter name=cloudflared
sudo docker compose --env-file /opt/stacks/cloudflared/.env \
  -f /opt/stacks/cloudflared/docker-compose.yml logs --tail 50
```

A successful log line looks like:

```
INF Starting tunnel ...
INF Route via CNAME: <your-tunnel>.cfargotunnel.com
INF Connection established connIndex=0 ...
```

Public hostnames added in the Cloudflare dashboard (Public Hostname
tab) are now reachable through this node's tunnel. **No UFW rule is
needed** for inbound — `network_mode: host` means the cloudflared
process binds directly on the host's network stack. The brief warns
that this is intentional: outbound to Cloudflare's edge is the only
required network path.

## Token rotation

```bash
# 1. In the Cloudflare dashboard: Zero Trust → Tunnels → <tunnel> → Configure
#    → rotate the token.
# 2. Update the on-disk token:
sudo sed -i 's|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=<new-token>|' \
  /opt/stacks/cloudflared/.env
# 3. Re-run the addon (or just restart the container):
sudo docker compose --env-file /opt/stacks/cloudflared/.env \
  -f /opt/stacks/cloudflared/docker-compose.yml up -d
```

The token lives in `/opt/stacks/cloudflared/.env` (mode 600). It is
intentionally inside the restic-backed `/opt/stacks/` tree so a
restore on a new node works without operator intervention, but that
also means a stolen `/opt/stacks` backup can recover the tunnel.
Rotate after restore.

## Removing the old host binary

The pre-batch bootstrap installed `/usr/local/bin/cloudflared` and
wrote apt metadata to `/etc/apt/sources.list.d/cloudflared.list`.
After moving to this addon, operators can clean up the old binary
manually:

```bash
sudo rm -f /usr/local/bin/cloudflared
sudo rm -f /etc/apt/sources.list.d/cloudflared.list \
           /usr/share/keyrings/cloudflare-main.gpg
```

The addon does NOT auto-remove the old binary — that would be a
destructive change that risks breaking a working setup. The cleanup
is one line.
