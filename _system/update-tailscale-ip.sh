#!/bin/bash
# Writes /opt/homelab/env-file/tailscale.env from `tailscale ip -4`.
#
# This is the SOLE source of truth for Tailscale IPv4 on this node. Stacks
# consume it via `env_file:` or `--env-file`; bind addresses must use
# ${TAILSCALE_IP:?...}.
#
# Properties (AGENT.md §2 Tailscale IP):
#   - Atomic write (tmpfile + mv).
#   - File mode 644, root-owned. NOT a secret.
#   - Validates CGNAT (100.64.0.0/10). Refuses to write anything else.
#   - When Tailscale is down or the value is invalid, exits non-zero and
#     leaves the previous file untouched.
#   - When the value is unchanged from the current file, exits 0 with no
#     write (cheap re-run).
#   - Re-run safe.
#
# Invoked from:
#   - /opt/stacks/_system/update-tailscale-ip.service (systemd oneshot)
#   - /opt/stacks/_system/update-tailscale-ip.timer   (every 15 min)
#   - /etc/systemd/system/tailscaled.service.d/override.conf ExecStartPost=
#     (after every Tailscale restart)

set -euo pipefail

ENV_DIR="/opt/homelab/env-file"
ENV_FILE="$ENV_DIR/tailscale.env"
ENV_FILE_MODE="644"

log() { echo "[tailscale-ip $(date -Is)] $*"; }
warn() { echo "[tailscale-ip $(date -Is)] WARN  $*" >&2; }
error() { echo "[tailscale-ip $(date -Is)] ERROR $*" >&2; exit 1; }

# This script must run as root (it writes into /opt/homelab).
if [[ $EUID -ne 0 ]]; then
  error "Must run as root (use sudo)."
fi

# Ensure the target directory exists. Mode 755 so non-root consumers can
# read the file via `env_file:` / `--env-file`.
if [[ ! -d "$ENV_DIR" ]]; then
  install -d -m 755 "$ENV_DIR"
fi

# Confirm Tailscale is reachable. `tailscale ip -4` exits non-zero when the
# daemon is not running or not logged in.
if ! command -v tailscale >/dev/null 2>&1; then
  warn "tailscale binary not found; leaving $ENV_FILE untouched"
  exit 1
fi

# Prefer `tailscale ip -4` (one IPv4 per line). If tailscaled is not up
# this fails before we get to validation.
LIVE_IPS="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$LIVE_IPS" ]]; then
  warn "tailscale ip -4 returned no addresses (daemon down or not logged in); leaving $ENV_FILE untouched"
  exit 1
fi

# Pick the first address that is a valid Tailscale CGNAT IPv4.
NEW_IP=""
while IFS= read -r candidate; do
  candidate="${candidate%$'\r'}"
  [[ -n "$candidate" ]] || continue
  # Strip a CIDR suffix if tailscale printed one.
  candidate="${candidate%%/*}"
  if [[ "$candidate" =~ ^100\.([6-9][0-9]|1[01][0-9]|12[0-7])\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    # Verify each octet <= 255 (the regex above constrains b but not c/d).
    local_c="${BASH_REMATCH[2]}"
    local_d="${BASH_REMATCH[3]}"
    if [[ "$local_c" =~ ^[0-9]+$ ]] && (( local_c <= 255 )) \
       && [[ "$local_d" =~ ^[0-9]+$ ]] && (( local_d <= 255 )); then
      NEW_IP="$candidate"
      break
    fi
  fi
done <<<"$LIVE_IPS"

if [[ -z "$NEW_IP" ]]; then
  warn "No CGNAT Tailscale IPv4 found in: $(echo "$LIVE_IPS" | tr '\n' ' ')"
  warn "Leaving $ENV_FILE untouched"
  exit 1
fi

# Compare to the current file (if any) and skip the write when unchanged.
CURRENT_IP=""
if [[ -r "$ENV_FILE" ]]; then
  # Accept either raw KEY=VALUE or single-quoted forms (defensive).
  line="$(head -n 1 "$ENV_FILE" 2>/dev/null || true)"
  line="${line%$'\r'}"
  if [[ "$line" =~ ^TAILSCALE_IP=(.*)$ ]]; then
    raw="${BASH_REMATCH[1]}"
    # Strip a single layer of matching quotes.
    if [[ "$raw" =~ ^\'(.*)\'$ ]]; then
      raw="${BASH_REMATCH[1]}"
    elif [[ "$raw" =~ ^\"(.*)\"$ ]]; then
      raw="${BASH_REMATCH[1]}"
    fi
    CURRENT_IP="$raw"
  fi
fi

if [[ "$CURRENT_IP" == "$NEW_IP" ]]; then
  log "TAILSCALE_IP unchanged ($NEW_IP)"
  exit 0
fi

# Atomic write: tmpfile in same directory, chmod, mv into place.
TMP="$(mktemp "$ENV_DIR/.tailscale.env.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

printf 'TAILSCALE_IP=%s\n' "$NEW_IP" > "$TMP"
chmod "$ENV_FILE_MODE" "$TMP"
mv "$TMP" "$ENV_FILE"
trap - EXIT

if [[ -n "$CURRENT_IP" ]]; then
  log "Updated TAILSCALE_IP: $CURRENT_IP -> $NEW_IP"
else
  log "Wrote TAILSCALE_IP=$NEW_IP"
fi
exit 0