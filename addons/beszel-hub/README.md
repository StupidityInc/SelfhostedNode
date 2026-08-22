# addons/beszel-hub/

Deploys the Beszel **hub** (server UI + data store) as a Docker
Compose project at `/opt/stacks/beszel-hub/`. Pairs with the
[Beszel agent](../beszel-agent/) addon which connects each node's
stats to this hub.

## Source

- `install.sh` — installer (addons contract: validate → atomic write →
  start → verify → persist).
- `docker-compose.yml.tmpl` — Compose template; placeholders
  `__BESZEL_HUB_BIND__` and `__BESZEL_HUB_PORT__` are substituted at
  install time from the addon (the runtime `.env` is the source of
  truth for the actual values).

## Behaviour

- **Bind address**: `BESZEL_HUB_BIND` (default: Tailscale IP from
  `/opt/homelab/env-file/tailscale.env`, fallback 127.0.0.1). The addon
  refuses to default to 0.0.0.0 — if you want LAN access, set
  `BESZEL_HUB_BIND=0.0.0.0` explicitly and accept the WARN (Docker
  published ports bypass UFW).
- **Port**: `BESZEL_HUB_PORT` (default 8090).
- **Permissions** (F3): stack dir 755, `docker-compose.yml` 644,
  `.env` 600, `beszel_data` 755. See `addons/README.md` "Permissions
  policy".
- **Image**: `henrygd/beszel:latest`. The `latest` tag is intentional;
  upstream keeps a stable release cadence and the hub rarely needs
  pinning. Operators who want a pinned version can edit
  `docker-compose.yml` after install.
- **No secrets in env_file**: the hub does not require an auth token
  (admin account is created in the UI; the local SQLite-style data
  store is in `./beszel_data/`). The only values in `.env` are the
  bind address, port, and an optional public URL hint for the
  operator.

## Pre-flight (required before running)

1. `/opt/homelab/env-file/tailscale.env` should exist (bootstrap step
   3a writes it). Without it the hub binds to 127.0.0.1 — fine for
   testing, inconvenient for fleet use.
2. Port `BESZEL_HUB_PORT` (default 8090) must be free on the chosen
   bind address. UFW does NOT need a rule for the Tailscale-side
   access (Tailscale traffic is on `tailscale0` which is already
   allowed by step 4 of bootstrap).
3. If the operator wants LAN access, set
   `BESZEL_HUB_BIND=<LAN-ip>` before running. No firewall change
   required on a Tailscale-only setup.

## Mutual exclusion

- A `beszel-hub` container already running on the same node: the
  addon refuses (`addon_assert_not_running`). Re-run with no flags is
  a no-op (compose up is idempotent).
- The Beszel **agent** on the same node: handled by
  `addons/beszel-agent/install.sh` which refuses a local hub unless
  `BESZEL_ALLOW_SAME_HOST_HUB_URL=true` is set. When
  `bootstrap.sh --beszel-both` is used, the bootstrap dispatcher
  auto-derives the URL from the Tailscale IP and exports the
  override.

## Re-run safety

- `install(1)` overwrites the compose file atomically (same content
  on re-runs; bind/port only change when the operator changes
  `.env`).
- The `.env` is **regenerated** on every run, but the addon reads
  existing keys first so a manual edit survives unless the operator
  passes new env vars. Mode 600, root-owned.
- `docker compose up -d` is idempotent.
- `addon_persist_flag INSTALL_BESZEL_HUB true` upserts the key in
  `/etc/homelab/node.env` (no duplicate lines).
- The data volume at `./beszel_data` is never touched.

## After install

```
sudo docker ps --filter name=beszel-hub
sudo docker compose --env-file /opt/stacks/beszel-hub/.env \
  -f /opt/stacks/beszel-hub/docker-compose.yml ps
```

Open the UI in a browser (use the printed `http://<bind>:<port>` URL
or the Tailscale MagicDNS name + port). Create an admin account, then
**Add System** in the UI to get a public `KEY` and `TOKEN` for each
agent. Run `addons/beszel-agent/install.sh` on each agent node, or
`./bootstrap.sh --beszel-agent` at bootstrap time.

## Token / credentials

The Beszel hub does NOT need an external token — it stores its own
admin password (hashed) in `./beszel_data/`. The agent gets its
`KEY` and `TOKEN` from the hub UI at "Add System" time. This is
intentional and matches upstream's design.

The hub's `.env` is intentionally tiny (bind, port, optional
`BESZEL_PUBLIC_URL` hint). Backup up `/opt/stacks/beszel-hub/` keeps
the runtime state, but the durable record is the admin account + the
agent list inside the hub's own data store.
