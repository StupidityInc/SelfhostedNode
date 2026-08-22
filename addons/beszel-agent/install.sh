#!/bin/bash
# Beszel agent addon installer (AGENT.md §3 WP5).
#
# Deploys the Beszel agent (NOT the hub) and connects it to a manually
# managed hub running on another node. Host networking for host statistics,
# loopback-only listener, no published ports, root-owned .env at mode 600.
#
# Contract (see addons/README.md):
#   1. Validate inputs + hub reachability
#   2. Atomic write of docker-compose.yml and .env (root-owned, 644/600)
#   3. docker compose up -d
#   4. Verify the container is running
#   5. ONLY THEN persist INSTALL_BESZEL_AGENT=true in /etc/homelab/node.env
#
# Re-run safety: if beszel-agent is already running with the same .env,
# steps 2-4 are no-ops (compose up is idempotent; the verify step passes;
# addon_persist_flag upserts). The .env is regenerated on every run, so the
# last-write-wins model keeps credentials consistent across re-runs.
#
# Required env (collected interactively or via export):
#   BESZEL_HUB_URL         Tailscale-reachable hub URL (or same-host override)
#   BESZEL_AGENT_KEY       Public key from the hub UI
#   BESZEL_AGENT_TOKEN     Token from the hub UI
#   BESZEL_SYSTEM_NAME     Optional display name (defaults to /etc/homelab/node.env NODE_NAME)
#   BESZEL_ALLOW_SAME_HOST_HUB_URL  Set true for a same-host hub (no Tailscale)

set -euo pipefail

ADDON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_REPO_ROOT="$(cd "$ADDON_SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$ADDON_SCRIPT_DIR/../lib-addon.sh"

BESZEL_AGENT_STACK_DIR="/opt/stacks/beszel-agent"
BESZEL_AGENT_COMPOSE_TEMPLATE="$ADDON_REPO_ROOT/beszel-agent/docker-compose.yml"
BESZEL_NODE_ENV_FILE="/etc/homelab/node.env"

addon_require_root
addon_use_sudo

# ---------- Helpers copied from bootstrap.sh (kept self-contained per WP5) ----------
beszel_same_host_override() {
  case "${BESZEL_ALLOW_SAME_HOST_HUB_URL,,}" in
    1|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}

beszel_ipv4_is_valid() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

beszel_ipv4_is_tailnet() {
  local ip="$1" a b c d
  beszel_ipv4_is_valid "$ip" || return 1
  IFS=. read -r a b c d <<<"$ip"
  (( a == 100 && b >= 64 && b <= 127 ))
}

beszel_parse_hub_url() {
  local url="$1" authority port
  BESZEL_HUB_HOST=""
  BESZEL_HUB_HOST_IS_IPV4="false"
  BESZEL_HUB_HOST_IS_IPV6="false"
  if [[ ! "$url" =~ ^https?://([^/?#]+)/*$ ]]; then
    return 1
  fi
  authority="${BASH_REMATCH[1]}"
  [[ "$authority" != *"@"* ]] || return 1

  if [[ "$authority" =~ ^\[([0-9A-Fa-f:]+)\](:([0-9]+))?$ ]]; then
    BESZEL_HUB_HOST="${BASH_REMATCH[1]}"
    BESZEL_HUB_HOST_IS_IPV6="true"
    port="${BASH_REMATCH[3]:-}"
  elif [[ "$authority" =~ ^([A-Za-z0-9][A-Za-z0-9.-]*)(:([0-9]+))?$ ]]; then
    BESZEL_HUB_HOST="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-}"
    if [[ "$BESZEL_HUB_HOST" =~ ^[0-9.]+$ ]]; then
      beszel_ipv4_is_valid "$BESZEL_HUB_HOST" || return 1
      BESZEL_HUB_HOST_IS_IPV4="true"
    fi
  else
    return 1
  fi

  if [[ -n "$port" ]] && (( port < 1 || port > 65535 )); then
    return 1
  fi
  [[ -n "$BESZEL_HUB_HOST" ]]
}

beszel_validate_hub_url_syntax() {
  local host
  beszel_parse_hub_url "$BESZEL_HUB_URL" || return 1
  host="$BESZEL_HUB_HOST"

  if beszel_same_host_override; then
    return 0
  fi
  if [[ "$BESZEL_HUB_HOST_IS_IPV4" == "true" ]]; then
    beszel_ipv4_is_tailnet "$host"
    return
  fi
  if [[ "$BESZEL_HUB_HOST_IS_IPV6" == "true" ]]; then
    [[ "$host" == fd7a:115c:a1e0:* ]]
    return
  fi
  case "${host,,}" in
    localhost|localhost.localdomain|0.0.0.0) return 1 ;;
  esac
  return 0
}

beszel_validate_hub_url_reachability() {
  local resolved address
  beszel_parse_hub_url "$BESZEL_HUB_URL" || return 1
  if beszel_same_host_override; then
    addon_warn "BESZEL_HUB_URL uses the explicit same-host override; verify that the hub listens on this host"
    return 0
  fi
  if [[ "$BESZEL_HUB_HOST_IS_IPV4" == "true" ]]; then
    beszel_ipv4_is_tailnet "$BESZEL_HUB_HOST"
    return
  fi
  if [[ "$BESZEL_HUB_HOST_IS_IPV6" == "true" ]]; then
    [[ "$BESZEL_HUB_HOST" == fd7a:115c:a1e0:* ]]
    return
  fi

  resolved="$(getent ahostsv4 "$BESZEL_HUB_HOST" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [[ -n "$resolved" ]] || return 1
  while IFS= read -r address; do
    if beszel_ipv4_is_tailnet "$address"; then
      return 0
    fi
  done <<<"$resolved"
  return 1
}

addon_collect_beszel_config() {
  local interactive=1
  if [[ "${HOMELAB_NONINTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
    interactive=0
  fi

  if (( interactive )); then
    if [[ -z "${BESZEL_HUB_URL:-}" ]]; then
      read -r -p "Beszel hub URL (Tailscale address): " BESZEL_HUB_URL
    fi
    if [[ -z "${BESZEL_AGENT_KEY:-}" ]]; then
      read -r -p "Beszel agent public key: " BESZEL_AGENT_KEY
    fi
    if [[ -z "${BESZEL_AGENT_TOKEN:-}" ]]; then
      read -r -s -p "Beszel agent token: " BESZEL_AGENT_TOKEN
      echo
    fi
  fi

  BESZEL_HUB_URL="${BESZEL_HUB_URL:-}"
  BESZEL_AGENT_KEY="${BESZEL_AGENT_KEY:-}"
  BESZEL_AGENT_TOKEN="${BESZEL_AGENT_TOKEN:-}"

  if [[ -z "$BESZEL_HUB_URL" || -z "$BESZEL_AGENT_KEY" || -z "$BESZEL_AGENT_TOKEN" ]]; then
    addon_error "BESZEL_HUB_URL, BESZEL_AGENT_KEY, and BESZEL_AGENT_TOKEN are all required (export them or run interactively)"
  fi

  # Default the display name to the persisted NODE_NAME when available.
  if [[ -z "${BESZEL_SYSTEM_NAME:-}" && -r "$BESZEL_NODE_ENV_FILE" ]]; then
    local name
    name="$(awk -F= '$1=="NODE_NAME" {sub(/^[^=]*=/,""); print; exit}' "$BESZEL_NODE_ENV_FILE" 2>/dev/null || true)"
    if [[ -n "$name" ]]; then
      BESZEL_SYSTEM_NAME="$name"
    fi
  fi
  BESZEL_SYSTEM_NAME="${BESZEL_SYSTEM_NAME:-}"

  if [[ -z "$BESZEL_SYSTEM_NAME" ]]; then
    addon_error "BESZEL_SYSTEM_NAME could not be derived (no NODE_NAME in /etc/homelab/node.env and no override given)"
  fi

  if [[ "$BESZEL_HUB_URL$BESZEL_AGENT_KEY$BESZEL_AGENT_TOKEN$BESZEL_SYSTEM_NAME" == *$'\n'* \
    || "$BESZEL_HUB_URL$BESZEL_AGENT_KEY$BESZEL_AGENT_TOKEN$BESZEL_SYSTEM_NAME" == *$'\r'* ]]; then
    addon_error "Beszel configuration values must be single-line"
  fi
  if ! beszel_validate_hub_url_syntax; then
    addon_error "BESZEL_HUB_URL must use a Tailscale IP (100.64.0.0/10), Tailscale-resolving hostname, or the explicit same-host override (BESZEL_ALLOW_SAME_HOST_HUB_URL=true)"
  fi
}

# ---------- 1. Validate ----------
if [[ ! -r "$BESZEL_AGENT_COMPOSE_TEMPLATE" ]]; then
  addon_error "Beszel agent Compose template is missing: $BESZEL_AGENT_COMPOSE_TEMPLATE"
fi
addon_collect_beszel_config
if ! beszel_validate_hub_url_reachability; then
  addon_error "BESZEL_HUB_URL does not resolve to a Tailscale address from this node: $BESZEL_HUB_URL. Use a MagicDNS name or 100.x Tailscale address, or set BESZEL_ALLOW_SAME_HOST_HUB_URL=true for a same-host hub"
fi
if ! docker compose version >/dev/null 2>&1; then
  addon_error "Docker Compose is required to deploy the Beszel agent"
fi

# ---------- 2. Atomic write ----------
addon_root_only_dir "$BESZEL_AGENT_STACK_DIR" 700

# Copy the compose template into the stack dir. install(1) sets mode + owner
# in one syscall; the file is idempotent — same content on re-runs.
install -m 0644 "$BESZEL_AGENT_COMPOSE_TEMPLATE" "$BESZEL_AGENT_STACK_DIR/docker-compose.yml"

# .env: only secrets/credentials + display name. Mode 600, root-owned.
# Use homelab_format_kv from lib.sh so values containing '=' or spaces are
# quoted safely. addon_root_only_file writes atomically (tmpfile + mv).
{
  homelab_format_kv BESZEL_HUB_URL     "$BESZEL_HUB_URL"
  homelab_format_kv BESZEL_AGENT_KEY   "$BESZEL_AGENT_KEY"
  homelab_format_kv BESZEL_AGENT_TOKEN "$BESZEL_AGENT_TOKEN"
  homelab_format_kv BESZEL_SYSTEM_NAME "$BESZEL_SYSTEM_NAME"
} | addon_root_only_file "$BESZEL_AGENT_STACK_DIR/.env" 600

# ---------- 3. Start ----------
addon_log "Starting the Beszel agent (credentials are not logged)..."
if ! docker compose --env-file "$BESZEL_AGENT_STACK_DIR/.env" \
  -f "$BESZEL_AGENT_STACK_DIR/docker-compose.yml" up -d; then
  addon_error "docker compose up -d failed for the Beszel agent; runtime state was not changed"
fi

# ---------- 4. Verify running ----------
sleep 2
RUNNING="$(docker inspect -f '{{.State.Running}}' beszel-agent 2>/dev/null || echo "false")"
if [[ "$RUNNING" != "true" ]]; then
  addon_error "beszel-agent container is not running after Compose startup"
fi

# ---------- 5. Persist flag ----------
addon_persist_flag INSTALL_BESZEL_AGENT true
addon_log "Beszel agent installed and verified running; INSTALL_BESZEL_AGENT=true persisted."
