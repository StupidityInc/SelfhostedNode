#!/bin/bash
# Cloudflared tunnel addon installer (post-laptop-1 batch).
#
# Deploys Cloudflare's `cloudflared` as a Docker container running in
# `network_mode: host` (the tunnel protocol needs raw UDP/TCP access).
# Single Compose project at /opt/stacks/cloudflared/. Token-auth only —
# no `cloudflared tunnel login` step is required (the operator
# provisions a tunnel in the Cloudflare dashboard and copies the
# token).
#
# Why Docker instead of the host binary:
#   - The official `cloudflare/cloudflared` Docker image is the most
#     consistently maintained install path on Ubuntu (the .deb
#     sometimes lags).
#   - Single source of truth at /opt/stacks/cloudflared/ — same
#     restic-able location as every other stack.
#   - Matches the addons contract (validate → atomic write → start →
#     verify → persist INSTALL_CLOUDFLARED=true). No host-binary
#     path under /usr/local/bin/cloudflared is touched.
#
# Contract (see addons/README.md):
#   1. Validate (token present, docker compose v2, no clash with an
#      already-running cloudflared container)
#   2. Atomic write: docker-compose.yml (644), .env (600) with the
#      tunnel token, config dir (755)
#   3. docker compose up -d
#   4. Verify container is running
#   5. ONLY THEN persist INSTALL_CLOUDFLARED=true in /etc/homelab/node.env
#
# Re-run safety: install(1) overwrites safely; compose up is idempotent;
# addon_persist_flag upserts. The .env is regenerated each run but the
# token is preserved when the operator supplied it via env vars or via
# an existing .env.

set -euo pipefail

ADDON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_REPO_ROOT="$(cd "$ADDON_SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$ADDON_SCRIPT_DIR/../lib-addon.sh"

CLOUDFLARED_STACK_DIR="/opt/stacks/cloudflared"
CLOUDFLARED_COMPOSE_TEMPLATE="$ADDON_SCRIPT_DIR/docker-compose.yml.tmpl"
CLOUDFLARED_ENV_FILE="$CLOUDFLARED_STACK_DIR/.env"
CLOUDFLARED_NODE_ENV_FILE="/etc/homelab/node.env"

addon_require_root
addon_use_sudo

# ---------- 1. Validate ----------
if [[ ! -r "$CLOUDFLARED_COMPOSE_TEMPLATE" ]]; then
  addon_error "Cloudflared Compose template is missing: $CLOUDFLARED_COMPOSE_TEMPLATE"
fi
if ! docker compose version >/dev/null 2>&1; then
  addon_error "Docker Compose is required to deploy the cloudflared container"
fi

# Mutual exclusion: refuse if cloudflared is already running. Re-runs
# of the same install (no flags) fall through to the idempotent
# compose up below.
addon_assert_not_running cloudflared

# Token collection. Non-interactive requires CLOUDFLARE_TUNNEL_TOKEN;
# interactive prompts with read -s. We never echo the token.
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" && -r "$CLOUDFLARED_ENV_FILE" ]]; then
  # Reuse the existing token from a previous install — keeps the
  # re-run safe (no secret regeneration).
  CLOUDFLARE_TUNNEL_TOKEN="$(awk -F= '$1=="CLOUDFLARE_TUNNEL_TOKEN" {sub(/^[^=]*=/,""); print; exit}' "$CLOUDFLARED_ENV_FILE" 2>/dev/null || true)"
fi
if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
  if [[ "${HOMELAB_NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    addon_error "CLOUDFLARE_TUNNEL_TOKEN is required in non-interactive mode. Provision a tunnel in the Cloudflare dashboard and pass the token via env var or a CLOUDFLARE_TUNNEL_TOKEN_FILE."
  fi
  addon_log "No CLOUDFLARE_TUNNEL_TOKEN found. The token comes from the Cloudflare dashboard:"
  addon_log "  Zero Trust → Networks → Tunnels → Create a tunnel → copy the token"
  while [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; do
    read -r -s -p "Cloudflare tunnel token: " CLOUDFLARE_TUNNEL_TOKEN
    echo
    if [[ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
      echo "(empty; please paste the token or Ctrl-C to abort)" >&2
    fi
  done
fi
# Reject obvious junk. Tokens are long base64-ish strings; we just want
# a sanity check on length and character set so an operator typo fails
# loudly at install time rather than inside the container.
if (( ${#CLOUDFLARE_TUNNEL_TOKEN} < 20 )); then
  addon_error "CLOUDFLARE_TUNNEL_TOKEN looks too short (${#CLOUDFLARE_TUNNEL_TOKEN} chars); expected a long base64-style string"
fi
if [[ "$CLOUDFLARE_TUNNEL_TOKEN" == *$'\n'* || "$CLOUDFLARE_TUNNEL_TOKEN" == *$'\r'* ]]; then
  addon_error "CLOUDFLARE_TUNNEL_TOKEN must be single-line"
fi

# Optional: extra args appended to `cloudflared tunnel run` (e.g.
# `--metrics localhost:2000` or `--logfile /dev/stdout`).
CLOUDFLARED_EXTRA_ARGS="${CLOUDFLARED_EXTRA_ARGS:-}"

# ---------- 2. Atomic write ----------
# F3: stack dir 755, compose 644, .env 600, config dir 755.
addon_root_only_dir "$CLOUDFLARED_STACK_DIR" 755

# Compose template has no placeholders today (the tunnel token is read
# via env_file from .env, not interpolated into compose). Kept as a
# template for symmetry with the other addons in case placeholders are
# added later.
COMPOSE_TMP="$($SUDO mktemp "$CLOUDFLARED_STACK_DIR/.docker-compose.yml.XXXXXX")"
cp "$CLOUDFLARED_COMPOSE_TEMPLATE" "$COMPOSE_TMP"
$SUDO chmod 644 "$COMPOSE_TMP"
$SUDO mv "$COMPOSE_TMP" "$CLOUDFLARED_STACK_DIR/docker-compose.yml"

# .env: the token + optional extra args. Mode 600, root-owned.
{
  homelab_format_kv CLOUDFLARE_TUNNEL_TOKEN "$CLOUDFLARE_TUNNEL_TOKEN"
  if [[ -n "$CLOUDFLARED_EXTRA_ARGS" ]]; then
    homelab_format_kv CLOUDFLARED_EXTRA_ARGS "$CLOUDFLARED_EXTRA_ARGS"
  fi
} | addon_root_only_file "$CLOUDFLARED_ENV_FILE" 600

# Config dir: the cloudflared image stores tunnel credentials and
# certs at /etc/cloudflared. We bind-mount a host dir there so the
# state survives container restarts.
$SUDO mkdir -p "$CLOUDFLARED_STACK_DIR/config"
$SUDO chmod 755 "$CLOUDFLARED_STACK_DIR/config"

# ---------- 3. Start ----------
addon_log "Starting the cloudflared container..."
if ! $SUDO docker compose --env-file "$CLOUDFLARED_ENV_FILE" \
  -f "$CLOUDFLARED_STACK_DIR/docker-compose.yml" up -d; then
  addon_error "docker compose up -d failed for the cloudflared container; runtime state was not changed"
fi

# ---------- 4. Verify running ----------
sleep 2
RUNNING="$($SUDO docker inspect -f '{{.State.Running}}' cloudflared 2>/dev/null || echo "false")"
if [[ "$RUNNING" != "true" ]]; then
  $SUDO docker logs cloudflared --tail 50 >&2 || true
  addon_error "cloudflared container is not running after Compose startup"
fi

# ---------- 5. Persist flag ----------
addon_persist_flag INSTALL_CLOUDFLARED true
addon_log "Cloudflared tunnel installed and verified running; INSTALL_CLOUDFLARED=true persisted."
addon_log "Onboarding reminder:"
addon_log "  1. The tunnel token is already in /opt/stacks/cloudflared/.env (mode 600)."
addon_log "  2. Public hostnames you add in the Cloudflare dashboard are now reachable"
addon_log "     through this node's tunnel (no UFW change required — the container is in"
addon_log "     network_mode: host and outbound 7844/UDP is allowed by the default policy)."
addon_log "  3. To rotate the token: cloudflared tunnel token rotate in the dashboard, then"
addon_log "     update CLOUDFLARE_TUNNEL_TOKEN in /opt/stacks/cloudflared/.env and re-run"
addon_log "     this addon (or: docker compose up -d)."
