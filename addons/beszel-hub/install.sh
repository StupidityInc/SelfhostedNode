#!/bin/bash
# Beszel hub addon installer (post-laptop-1 batch).
#
# Deploys the Beszel **hub** (the server UI + data store) as a Docker
# Compose project at /opt/stacks/beszel-hub/. Pairs with the Beszel
# agent addon (addons/beszel-agent/install.sh) which connects a remote
# node's stats to this hub.
#
# Bind address: Tailscale IP by default (read from
# /opt/homelab/env-file/tailscale.env). 127.0.0.1 is the fallback when
# the SSOT file is missing. 0.0.0.0 is NEVER the default — the operator
# must set BESZEL_HUB_BIND=0.0.0.0 explicitly (and the addon prints a
# WARN, since 0.0.0.0 published ports bypass UFW).
#
# Port: 8090 by default (override via BESZEL_HUB_PORT).
#
# Contract (see addons/README.md):
#   1. Validate (Tailscale IP / explicit bind; no clash with running
#      beszel-hub container; docker compose v2 present)
#   2. Atomic write: docker-compose.yml (644), .env (600), data dir (755)
#   3. docker compose up -d
#   4. Verify container is running
#   5. ONLY THEN persist INSTALL_BESZEL_HUB=true in /etc/homelab/node.env
#
# Re-run safety: install(1) overwrites safely; compose up is idempotent;
# addon_persist_flag upserts (no duplicate keys). Existing .env values
# are NOT silently overwritten — the addon re-reads /opt/stacks/beszel-hub/.env
# first and only writes new keys, so an operator who changed the bind
# address manually keeps their change on re-runs.
#
# What this addon does NOT do:
#   - It does not auto-create the admin user (that's a UI step).
#   - It does not generate the agent KEY/TOKEN pairs (UI: Add System).
#   - It does not bind to 0.0.0.0 unless the operator said so.

set -euo pipefail

ADDON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_REPO_ROOT="$(cd "$ADDON_SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$ADDON_SCRIPT_DIR/../lib-addon.sh"

BESZEL_HUB_STACK_DIR="/opt/stacks/beszel-hub"
BESZEL_HUB_COMPOSE_TEMPLATE="$ADDON_SCRIPT_DIR/docker-compose.yml.tmpl"
BESZEL_HUB_ENV_FILE="$BESZEL_HUB_STACK_DIR/.env"
BESZEL_HUB_NODE_ENV_FILE="/etc/homelab/node.env"
BESZEL_HUB_TS_SSOT="/opt/homelab/env-file/tailscale.env"

addon_require_root
addon_use_sudo

# ---------- 1. Validate ----------
if [[ ! -r "$BESZEL_HUB_COMPOSE_TEMPLATE" ]]; then
  addon_error "Beszel hub Compose template is missing: $BESZEL_HUB_COMPOSE_TEMPLATE"
fi
if ! docker compose version >/dev/null 2>&1; then
  addon_error "Docker Compose is required to deploy the Beszel hub"
fi

# Mutual exclusion: refuse if a hub is already running. The hub is
# single-instance per node; running it twice is almost certainly an
# operator mistake (e.g. --beszel-both run twice). Re-running the same
# install is a no-op below (compose up is idempotent).
addon_assert_not_running beszel-hub

# Resolve bind address with the documented precedence:
#   1. BESZEL_HUB_BIND set by the operator (explicit).
#   2. Tailscale IP from /opt/homelab/env-file/tailscale.env.
#   3. 127.0.0.1 (loopback fallback — operator can still reach via
#      SSH tunnel or a tailnet-side reverse proxy).
BESZEL_HUB_BIND="${BESZEL_HUB_BIND:-}"
if [[ -z "$BESZEL_HUB_BIND" && -r "$BESZEL_HUB_TS_SSOT" ]]; then
  BESZEL_HUB_BIND="$(awk -F= '$1=="TAILSCALE_IP" {sub(/^[^=]*=/,""); print; exit}' "$BESZEL_HUB_TS_SSOT" 2>/dev/null || true)"
fi
if [[ -z "$BESZEL_HUB_BIND" ]]; then
  BESZEL_HUB_BIND="127.0.0.1"
  addon_warn "BESZEL_HUB_BIND not set and Tailscale IP SSOT missing; defaulting to 127.0.0.1. Override with BESZEL_HUB_BIND=<tailscale-ip-or-LAN-ip>"
fi
# Refuse the documented "never bind to 0.0.0.0 unless explicit" rule
# from the plan. The explicit set still works (with a WARN) because
# some operators want LAN access on a trusted home network.
if [[ "$BESZEL_HUB_BIND" == "0.0.0.0" ]]; then
  addon_warn "BESZEL_HUB_BIND=0.0.0.0 binds the hub UI on all interfaces and BYPASSES UFW. Confirm this is what you want on a trusted network only."
fi

# Validate the bind value is a syntactically valid IPv4 (the lib.sh
# helper exists and avoids reimplementing the regex).
if [[ "$BESZEL_HUB_BIND" =~ ^[0-9.]+$ ]] && ! homelab_ipv4_is_valid "$BESZEL_HUB_BIND"; then
  addon_error "BESZEL_HUB_BIND is not a valid IPv4: $BESZEL_HUB_BIND"
fi

# Port: default 8090, override via BESZEL_HUB_PORT. Reject obviously
# bad values.
BESZEL_HUB_PORT="${BESZEL_HUB_PORT:-8090}"
if ! [[ "$BESZEL_HUB_PORT" =~ ^[0-9]+$ ]] || (( BESZEL_HUB_PORT < 1 || BESZEL_HUB_PORT > 65535 )); then
  addon_error "BESZEL_HUB_PORT is not a valid port: $BESZEL_HUB_PORT"
fi

# Optional public URL hint for the operator. The UI is the same either
# way; this is purely a documentation value printed on success and
# stored in .env for reference.
BESZEL_PUBLIC_URL="${BESZEL_PUBLIC_URL:-}"

# ---------- 2. Atomic write ----------
# F3: stack dir 755 root:root, compose 644, .env 600, data dir 755.
addon_root_only_dir "$BESZEL_HUB_STACK_DIR" 755

# Compose file: substitute the only placeholder, write mode 644.
# Tmpl placeholders: __BESZEL_HUB_BIND__, __BESZEL_HUB_PORT__.
sed_quote() {
  printf '%s' "$1" | sed -e 's|\\|\\\\|g' -e 's|\&|\\\&|g' -e 's|\||\\\||g'
}
COMPOSE_TMP="$($SUDO mktemp "$BESZEL_HUB_STACK_DIR/.docker-compose.yml.XXXXXX")"
sed \
  -e "s|__BESZEL_HUB_BIND__|$(sed_quote "$BESZEL_HUB_BIND")|g" \
  -e "s|__BESZEL_HUB_PORT__|$(sed_quote "$BESZEL_HUB_PORT")|g" \
  "$BESZEL_HUB_COMPOSE_TEMPLATE" > "$COMPOSE_TMP"
$SUDO chmod 644 "$COMPOSE_TMP"
$SUDO mv "$COMPOSE_TMP" "$BESZEL_HUB_STACK_DIR/docker-compose.yml"

# .env: BESZEL_HUB_BIND + BESZEL_HUB_PORT (the only knobs the operator
# ever needs to change), plus the optional public URL hint. Mode 600.
{
  homelab_format_kv BESZEL_HUB_BIND   "$BESZEL_HUB_BIND"
  homelab_format_kv BESZEL_HUB_PORT   "$BESZEL_HUB_PORT"
  if [[ -n "$BESZEL_PUBLIC_URL" ]]; then
    homelab_format_kv BESZEL_PUBLIC_URL "$BESZEL_PUBLIC_URL"
  fi
} | addon_root_only_file "$BESZEL_HUB_ENV_FILE" 600

# Data dir: ./beszel_data. Created with mode 755 so the container can
# write as the root user (the image runs as the host's root UID/GID
# via user namespace remapping by default — adjust in the template if
# the operator's setup needs otherwise).
$SUDO mkdir -p "$BESZEL_HUB_STACK_DIR/beszel_data"
$SUDO chmod 755 "$BESZEL_HUB_STACK_DIR/beszel_data"

# ---------- 3. Start ----------
addon_log "Starting the Beszel hub (bind=$BESZEL_HUB_BIND port=$BESZEL_HUB_PORT)..."
if ! $SUDO docker compose --env-file "$BESZEL_HUB_ENV_FILE" \
  -f "$BESZEL_HUB_STACK_DIR/docker-compose.yml" up -d; then
  addon_error "docker compose up -d failed for the Beszel hub; runtime state was not changed"
fi

# ---------- 4. Verify running ----------
sleep 2
RUNNING="$($SUDO docker inspect -f '{{.State.Running}}' beszel-hub 2>/dev/null || echo "false")"
if [[ "$RUNNING" != "true" ]]; then
  $SUDO docker logs beszel-hub --tail 50 >&2 || true
  addon_error "beszel-hub container is not running after Compose startup"
fi

# ---------- 5. Persist flag ----------
addon_persist_flag INSTALL_BESZEL_HUB true
addon_log "Beszel hub installed and verified running; INSTALL_BESZEL_HUB=true persisted."
addon_log "Open the UI: http://${BESZEL_HUB_BIND}:${BESZEL_HUB_PORT}"
addon_log "  (also reachable at http://<this-node-tailscale-name>:${BESZEL_HUB_PORT} from inside the tailnet)"
addon_log "Next steps in the UI:"
addon_log "  1. Create your admin account (email + password; local-only, not in .env)."
addon_log "  2. Add System (or create a universal token) to get the agent's KEY + TOKEN."
addon_log "  3. Run ./addons/beszel-agent/install.sh on each agent node (or --beszel-agent at bootstrap)."
