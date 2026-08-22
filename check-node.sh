#!/bin/bash
set -euo pipefail

# Homelab node health & exit-node checker
# Run on any bootstrapped node to get a quick status overview.
#
# Exit code: 0 = no hard failures, 1 = at least one FAIL (usable in monitoring).
# Warnings do not affect the exit code.
#
# Tunables (environment):
#   STALE_HOURS=36               max allowed age of the newest snapshot
#   CHECK_NODE_SKIP_SPEEDTEST=1  skip the rough download-speed test

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILURES=0
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; FAILURES=$((FAILURES + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_LOADED="false"
if [[ ! -r "$SCRIPT_DIR/lib.sh" ]]; then
  fail "lib.sh is missing next to check-node.sh"
else
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib.sh"
  LIB_LOADED="true"
fi

if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  # -n: fail fast instead of hanging on a password prompt (monitoring-safe).
  # Run this script with sudo for complete checks.
  SUDO="sudo -n"
fi

# ---------- Persisted node identity (written by bootstrap.sh) ----------
ROLE=""
NODE_NAME=""
USE_EXIT_NODE=""
EXIT_NODE_APPLIED=""
ADVERTISE_EXIT_NODE=""
DIRECT_PUBLIC_IP_AT_SETUP=""
KEEP_PUBLIC_SSH=""
INSTALL_BESZEL_AGENT=""
INSTALL_BESZEL_HUB=""
INSTALL_CLOUDFLARED=""
INSTALL_RESTIC_HOST_NATIVE=""
NODE_ENV_READABLE="false"
if [[ "$LIB_LOADED" == "true" ]] && $SUDO test -r /etc/homelab/node.env 2>/dev/null; then
  if ! homelab_load_kv_sudo "$SUDO" /etc/homelab/node.env "${HOMELAB_NODE_ENV_KEYS[@]}"; then
    fail "Cannot safely read /etc/homelab/node.env"
  else
    NODE_ENV_READABLE="true"
  fi
else
  fail "/etc/homelab/node.env is missing or unreadable"
fi

echo "=== Homelab Node Health Check ==="
echo "Host: $(hostname)  |  $(date -Is)"
if [[ "$NODE_ENV_READABLE" == "true" ]]; then
  echo "Identity: node='$NODE_NAME' role='$ROLE' (from /etc/homelab/node.env)"
fi
echo

# ---------- Tailscale ----------
echo "── Tailscale ──"
USING_EXIT_NODE="false"
if ! command -v tailscale >/dev/null 2>&1; then
  fail "tailscale binary not found"
else
  if tailscale status >/dev/null 2>&1; then
    ok "Tailscale is running"
    echo "  IPs: $(tailscale ip -4 2>/dev/null | tr '\n' ' ')"

    TS_JSON="$(tailscale status --json 2>/dev/null || echo '{}')"

    # --- This node AS an exit node ---
    # .Self.ExitNodeOption is true only when the node offers itself AND the
    # exit node is approved in the admin console.
    ADVERTISING="$(tailscale get advertise-exit-node 2>/dev/null || $SUDO tailscale get advertise-exit-node 2>/dev/null || echo "unknown")"
    IS_APPROVED_EXIT="$(jq -r '.Self.ExitNodeOption // false' <<<"$TS_JSON" 2>/dev/null || echo "false")"
    if [[ "$IS_APPROVED_EXIT" == "true" ]]; then
      ok "This node IS an exit node (advertised + approved, peers may use it)"
    elif [[ "$ADVERTISING" == "true" ]]; then
      warn "This node advertises as exit node but is NOT approved yet (approve it in the Tailscale admin console)"
    elif [[ "$ADVERTISE_EXIT_NODE" == "true" ]]; then
      warn "node.env says this node should advertise as exit node, but tailscale disagrees (check 'tailscale get advertise-exit-node')"
    else
      ok "This node is not an exit node"
    fi

    # --- This node USING an exit node ---
    # .ExitNodeStatus is present only when an exit node is currently in use.
    EXPECTED_EXIT_NODE="${EXIT_NODE_APPLIED:-$USE_EXIT_NODE}"
    EXIT_ID="$(jq -r '.ExitNodeStatus.ID // empty' <<<"$TS_JSON" 2>/dev/null || true)"
    if [[ -n "$EXIT_ID" && "$EXIT_ID" != "null" ]]; then
      USING_EXIT_NODE="true"
      EXIT_NAME="$(jq -r --arg id "$EXIT_ID" '[.Peer[]? | select(.ID==$id) | (.HostName // .DNSName // .ID)][0] // "unknown"' <<<"$TS_JSON" 2>/dev/null || echo "unknown")"
      EXIT_ONLINE="$(jq -r '.ExitNodeStatus.Online // false' <<<"$TS_JSON" 2>/dev/null || echo "unknown")"
      EXIT_IPS="$(jq -r '.ExitNodeStatus.TailscaleIPs // [] | map(. | split("/")[0]) | join(" ")' <<<"$TS_JSON" 2>/dev/null || true)"
      EXIT_TARGET_MATCH="true"
      if [[ -n "$EXPECTED_EXIT_NODE" && "$EXPECTED_EXIT_NODE" != "$EXIT_ID" \
        && "$EXPECTED_EXIT_NODE" != "$EXIT_NAME" && " $EXIT_IPS " != *" $EXPECTED_EXIT_NODE "* ]]; then
        EXIT_TARGET_MATCH="false"
        fail "Active exit node '$EXIT_NAME' does not match expected '$EXPECTED_EXIT_NODE'"
      fi
      if [[ "$EXIT_ONLINE" == "true" && "$EXIT_TARGET_MATCH" == "true" ]]; then
        ok "Using exit node: $EXIT_NAME ($EXIT_IPS, online)"
      elif [[ "$EXIT_ONLINE" != "true" ]]; then
        fail "Using exit node: $EXIT_NAME ($EXIT_IPS) but it appears OFFLINE"
      fi
    else
      if [[ -n "$EXPECTED_EXIT_NODE" ]]; then
        fail "node.env says this node should use exit node '$EXPECTED_EXIT_NODE', but none is active"
        warn "  fix with: sudo tailscale set --exit-node='$EXPECTED_EXIT_NODE' --exit-node-allow-lan-access=true"
      elif [[ "$ROLE" == "client" ]]; then
        fail "Client has no exit-node intent or active exit-node route"
      else
        warn "No exit node currently in use"
      fi
    fi
  else
    fail "Tailscale is installed but not connected / status failed"
  fi
fi
echo

# ---------- Tailscale IP SSOT (AGENT.md §3 WP1) ----------
echo "── Tailscale IP SSOT ──"
TS_SSOT_FILE="/opt/homelab/env-file/tailscale.env"
TS_SSOT_IP=""
TS_SSOT_VALID="false"
TS_SSOT_PRESENT="false"
if $SUDO test -r "$TS_SSOT_FILE" 2>/dev/null; then
  TS_SSOT_PRESENT="true"
  line="$($SUDO head -n 1 "$TS_SSOT_FILE" 2>/dev/null || true)"
  line="${line%$'\r'}"
  if [[ "$line" =~ ^TAILSCALE_IP=(.*)$ ]]; then
    raw="${BASH_REMATCH[1]}"
    if [[ "$raw" =~ ^\'(.*)\'$ ]]; then
      raw="${BASH_REMATCH[1]}"
    elif [[ "$raw" =~ ^\"(.*)\"$ ]]; then
      raw="${BASH_REMATCH[1]}"
    fi
    TS_SSOT_IP="$raw"
  fi
  if [[ "$LIB_LOADED" == "true" ]] && homelab_validate_tailscale_ip "$TS_SSOT_IP"; then
    TS_SSOT_VALID="true"
    ok "Tailscale IP SSOT file present and valid: $TS_SSOT_IP"
  else
    fail "Tailscale IP SSOT file exists but value is invalid: '${TS_SSOT_IP:-<empty>}'"
  fi
else
  fail "Tailscale IP SSOT file missing: $TS_SSOT_FILE"
fi

# Cross-reference the file against the live tailscale IP when the daemon is up.
# We only WARN (not fail) when Tailscale is genuinely down — the SSOT file is
# allowed to lag until Tailscale reconnects.
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  LIVE_TS_IP="$(tailscale ip -4 2>/dev/null | awk '/^100\.(6[4-9]|7[0-9]|8[0-9]|9[0-9]|10[0-9]|11[0-9]|12[0-7])\./ {print; exit}')"
  if [[ -n "$LIVE_TS_IP" ]]; then
    if [[ "$LIVE_TS_IP" == "$TS_SSOT_IP" ]]; then
      ok "Tailscale IP SSOT matches live tailscale IP ($LIVE_TS_IP)"
    else
      if [[ "$TS_SSOT_VALID" == "true" ]]; then
        fail "Tailscale IP SSOT ($TS_SSOT_IP) disagrees with live tailscale IP ($LIVE_TS_IP)"
      else
        warn "Live tailscale IP is $LIVE_TS_IP but the SSOT file is invalid; a successful update-tailscale-ip.sh run will repair it"
      fi
    fi
  else
    warn "tailscale is up but no CGNAT IPv4 was returned"
  fi
fi
echo

# ---------- Network path ----------
echo "── Outbound connectivity ──"
PUBLIC_IP="$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "unreachable")"
if [[ "$PUBLIC_IP" != "unreachable" ]]; then
  ok "Public IPv4 visible as: $PUBLIC_IP"
  if [[ "$USING_EXIT_NODE" == "true" ]]; then
    # Truthfulness check: while routing via an exit node, our public IP should
    # NOT be this node's own direct IP (captured at bootstrap, before any
    # exit-node routing). We can't query the exit node's public IP from here –
    # the operator should recognize the exit node's IP above.
    if [[ -n "$DIRECT_PUBLIC_IP_AT_SETUP" && "$PUBLIC_IP" == "$DIRECT_PUBLIC_IP_AT_SETUP" ]]; then
      warn "Public IP equals this node's own pre-exit-node IP ($DIRECT_PUBLIC_IP_AT_SETUP) – exit node may not be routing"
      warn "  (can also be a false positive if the ISP re-assigned the same IP; verify manually)"
    else
      ok "Public IP differs from this node's direct IP – consistent with exit-node routing"
    fi
  fi
else
  fail "Cannot reach ifconfig.me (no working internet path?)"
fi

# Quick latency to common targets
for target in 1.1.1.1 8.8.8.8; do
  if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
    RTT=$(ping -c 1 -W 2 "$target" 2>/dev/null | grep -oP 'time=\K[0-9.]+' || echo "?")
    ok "Ping $target: ${RTT} ms"
  else
    fail "Ping $target failed"
  fi
done
echo

# ---------- UFW ----------
echo "── Firewall (UFW) ──"
if command -v ufw >/dev/null 2>&1; then
  STATUS=$($SUDO ufw status 2>/dev/null | head -n 1 || echo "unknown")
  if echo "$STATUS" | grep -qi active; then
    ok "UFW is active"
    if ! $SUDO ufw status 2>/dev/null | grep -q 'tailscale0'; then
      fail "UFW is active but the tailscale0 allow rule is MISSING"
    fi
    # Compare public SSH with the persisted desired state when available.
    if $SUDO ufw status 2>/dev/null | grep -E '22/tcp|OpenSSH' | grep -v tailscale0 >/dev/null; then
      if [[ "$KEEP_PUBLIC_SSH" == "false" ]]; then
        fail "Public SSH rule is present although node.env records lockdown"
      else
        warn "Public SSH rules still present (safe default)"
      fi
    elif [[ "$KEEP_PUBLIC_SSH" == "true" ]]; then
      fail "node.env expects public SSH to remain available, but no public SSH rule is present"
    else
      ok "No public SSH rules detected (locked down)"
    fi
  else
    fail "UFW does not appear active"
  fi
else
  fail "ufw not installed"
fi
echo

# ---------- Restic / Backup ----------
echo "── Restic backup ──"
if $SUDO test -f /etc/restic/env 2>/dev/null; then
  ok "/etc/restic/env exists"
else
  fail "/etc/restic/env missing – restic not configured on this node"
fi

# --- Backup path detection (lobaro vs host-native addon vs none vs both) ---
# WP5: prefer the persisted INSTALL_RESTIC_HOST_NATIVE flag (from /etc/homelab/node.env);
# the unit-file heuristic in homelab_backup_path stays as a fallback when the
# flag is unset or false. See AGENT.md §3 WP5.
BACKUP_PATH="$(homelab_backup_path "$SUDO" "${INSTALL_RESTIC_HOST_NATIVE:-}" 2>/dev/null || echo "none")"
case "$BACKUP_PATH" in
  lobaro)
    ok "Backup path: lobaro container"
    ;;
  host-native)
    if [[ "${INSTALL_RESTIC_HOST_NATIVE:-}" == "true" ]]; then
      ok "Backup path: host-native (restic-host-native addon, flag persisted)"
    else
      ok "Backup path: host-native (restic-backup.timer detected, no INSTALL_RESTIC_HOST_NATIVE flag)"
    fi
    ;;
  both)
    warn "Backup path: BOTH lobaro container AND host-native timer are active (mutually exclusive)"
    ;;
  *)
    fail "No backup path active (lobaro container not running AND restic-backup.timer not enabled)"
    ;;
esac

# --- Lobaro container health (only meaningful when lobaro is in the mix) ---
LOBARO_RUNNING="false"
if command -v docker >/dev/null 2>&1; then
  LOBARO_RUNNING="$($SUDO docker inspect -f '{{.State.Running}}' restic-backup 2>/dev/null || echo "false")"
fi
if [[ "$BACKUP_PATH" == "lobaro" || "$BACKUP_PATH" == "both" ]]; then
  if [[ "$LOBARO_RUNNING" == "true" ]]; then
    ok "restic-backup container is running"
  else
    fail "restic-backup container is not running (start with: sudo docker compose --env-file /opt/stacks/restic-backup/.env -f /opt/stacks/restic-backup/docker-compose.yml up -d)"
  fi
fi

# --- Container error log secondary signal (cheap; WARN only) ---
# Only inspect when the container is running. One grep, last 200 lines.
# Pattern is intentionally narrow to avoid benign stderr noise from the
# lobaro image (which BusyBox-cron'd services often emit).
if [[ "$LOBARO_RUNNING" == "true" ]] && command -v docker >/dev/null 2>&1; then
  CONTAINER_ERR_COUNT="$($SUDO docker logs restic-backup --tail 200 2>/dev/null \
    | grep -cE '(^|[^A-Za-z])(ERROR|FATAL|Error:)' || true)"
  if [[ "${CONTAINER_ERR_COUNT:-0}" -gt 0 ]]; then
    warn "restic-backup container log mentions $CONTAINER_ERR_COUNT error-like line(s) in the last 200 lines (review with: sudo docker logs restic-backup --tail 200)"
  fi
fi

# --- Host-native timer checks (only when the addon is enabled) ---
HOST_NATIVE_ENABLED="false"
if $SUDO systemctl is-enabled restic-backup.timer >/dev/null 2>&1; then
  HOST_NATIVE_ENABLED="true"
fi
if [[ "$HOST_NATIVE_ENABLED" == "true" ]]; then
  if $SUDO systemctl is-enabled restic-backup.timer >/dev/null 2>&1; then
    ok "restic-backup.timer is enabled"
  else
    fail "restic-backup.timer is enabled (per detection) but is-enabled check failed"
  fi
  if $SUDO systemctl is-active --quiet restic-backup.timer 2>/dev/null; then
    ok "restic-backup.timer is running"
  else
    fail "restic-backup.timer is not running (start with: sudo systemctl enable --now restic-backup.timer)"
  fi
  $SUDO systemctl list-timers --all --no-pager restic-backup.timer 2>/dev/null | sed 's/^/  /' || true

  BACKUP_RESULT="$($SUDO systemctl show -p Result --value restic-backup.service 2>/dev/null || true)"
  case "$BACKUP_RESULT" in
    failed|timeout|exit-code|signal|core-dump|resources|watchdog|oom-kill)
      fail "Last restic-backup.service run ended with Result=$BACKUP_RESULT"
      ;;
    "" )
      warn "Could not inspect the last restic-backup.service result"
      ;;
  esac
fi

# --- Repo-id match (when /etc/restic/repo-id is present) ---
# Independent of which backup path is active: the pin is a property of the
# repo, not the scheduler. Read the pin, compare to live `restic cat config`.
if $SUDO test -r "$HOMELAB_REPO_ID_FILE" 2>/dev/null && [[ -r "$SCRIPT_DIR/lib.sh" ]]; then
  set +e
  REPO_ID_REPORT="$($SUDO bash -c '
    source "$1"
    HOMELAB_REPO_ID=""
    homelab_repo_id
    if [[ -z "$HOMELAB_REPO_ID" ]]; then
      echo "BAD_PIN"
      exit 0
    fi
    PIN="$HOMELAB_REPO_ID"
    # Load credentials via the safe non-sourcing loader so `restic cat
    # config` sees RESTIC_REPOSITORY + RESTIC_PASSWORD_FILE + AWS_*.
    # homelab_load_restic_env is a no-op when /etc/restic/env is missing.
    homelab_load_restic_env /etc/restic/env
    if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
      echo "NO_ENV"
      exit 0
    fi
    raw_live="$(restic cat config --json 2>/dev/null)" || {
      echo "LIVE_UNREACHABLE"
      exit 0
    }
    LIVE="$(printf "%s" "$raw_live" | jq -r ".id // empty" 2>/dev/null || true)"
    if [[ -z "$LIVE" ]]; then
      echo "LIVE_NO_ID"
      exit 0
    fi
    if [[ "$LIVE" != "$PIN" ]]; then
      echo "MISMATCH pin=$PIN live=$LIVE"
      exit 0
    fi
    echo "MATCH $PIN"
  ' _ "$SCRIPT_DIR/lib.sh" 2>/dev/null)"
  set -e
  case "$REPO_ID_REPORT" in
    MATCH*)
      ok "/etc/restic/repo-id matches live repository"
      ;;
    MISMATCH*)
      fail "/etc/restic/repo-id mismatch (${REPO_ID_REPORT#MISMATCH })"
      ;;
    BAD_PIN)
      fail "/etc/restic/repo-id exists but is not a 64-char lowercase hex restic id"
      ;;
    NO_ENV)
      fail "/etc/restic/repo-id is pinned but /etc/restic/env is missing or empty – cannot verify the pin"
      ;;
    LIVE_UNREACHABLE)
      warn "Could not read live repository config to verify repo-id pin (network? credentials?)"
      ;;
    LIVE_NO_ID)
      fail "Live restic repository returned no id; cannot verify repo-id pin"
      ;;
    *)
      warn "Repo-id pin verification inconclusive: '$REPO_ID_REPORT'"
      ;;
  esac
fi

# --- Snapshot freshness – host restic is still the ground truth (AGENT.md §2) ---
if $SUDO test -r /etc/restic/env 2>/dev/null && [[ -r "$SCRIPT_DIR/lib.sh" ]]; then
  set +e
  NEWEST_SNAP="$($SUDO bash -c 'source "$1"; homelab_restic snapshots --json --latest 1 2>/dev/null' _ "$SCRIPT_DIR/lib.sh" | jq -r '.[0].time // empty' 2>/dev/null)"
  set -e
  if [[ -z "$NEWEST_SNAP" ]]; then
    fail "No snapshots found (or repository unreachable / wrong credentials)"
  else
    STALE_HOURS="${STALE_HOURS:-36}"
    NOW_EPOCH="$(date +%s)"
    SNAP_EPOCH="$(date -d "$NEWEST_SNAP" +%s 2>/dev/null || echo 0)"
    if [[ "$SNAP_EPOCH" == "0" ]]; then
      warn "Could not parse snapshot timestamp '$NEWEST_SNAP'"
    else
      AGE_H=$(( (NOW_EPOCH - SNAP_EPOCH) / 3600 ))
      if (( AGE_H > STALE_HOURS )); then
        fail "Newest snapshot is ${AGE_H}h old (> ${STALE_HOURS}h) – BACKUPS ARE STALE"
      else
        ok "Newest snapshot is ${AGE_H}h old (limit ${STALE_HOURS}h)"
      fi
    fi
  fi
else
  fail "Cannot safely read /etc/restic/env or the installed lib.sh – skipping snapshot freshness check"
fi
echo

# ---------- Beszel (addon-installed) ----------
# Post-laptop-1: hub + agent are both addons. Surface a missing container
# when the persisted flag is true (parity with the restic addon check).
echo "── Beszel (addon) ──"
if [[ "$INSTALL_BESZEL_HUB" == "true" ]]; then
  if command -v docker >/dev/null 2>&1; then
    HUB_RUNNING="$($SUDO docker inspect -f '{{.State.Running}}' beszel-hub 2>/dev/null || echo "false")"
    if [[ "$HUB_RUNNING" == "true" ]]; then
      ok "beszel-hub container is running"
    else
      fail "beszel-hub container is not running (node.env says installed; start with: sudo docker compose --env-file /opt/stacks/beszel-hub/.env -f /opt/stacks/beszel-hub/docker-compose.yml up -d)"
    fi
  else
    fail "node.env says INSTALL_BESZEL_HUB=true but Docker is missing"
  fi
fi
if [[ "$INSTALL_BESZEL_AGENT" == "true" ]]; then
  if command -v docker >/dev/null 2>&1; then
    AGENT_RUNNING="$($SUDO docker inspect -f '{{.State.Running}}' beszel-agent 2>/dev/null || echo "false")"
    if [[ "$AGENT_RUNNING" == "true" ]]; then
      ok "beszel-agent container is running"
    else
      fail "beszel-agent container is not running (node.env says installed; start with: sudo docker compose --env-file /opt/stacks/beszel-agent/.env -f /opt/stacks/beszel-agent/docker-compose.yml up -d)"
    fi
  else
    fail "node.env says INSTALL_BESZEL_AGENT=true but Docker is missing"
  fi
fi
echo

# ---------- Cloudflared (addon) ----------
# Post-laptop-1: cloudflared is a Docker container addon. The legacy
# host binary is no longer the supported install path.
echo "── Cloudflared (addon) ──"
if [[ "${INSTALL_CLOUDFLARED:-}" == "true" ]]; then
  if command -v docker >/dev/null 2>&1; then
    CF_RUNNING="$($SUDO docker inspect -f '{{.State.Running}}' cloudflared 2>/dev/null || echo "false")"
    if [[ "$CF_RUNNING" == "true" ]]; then
      ok "cloudflared container is running"
    else
      fail "cloudflared container is not running (node.env says installed; start with: sudo docker compose --env-file /opt/stacks/cloudflared/.env -f /opt/stacks/cloudflared/docker-compose.yml up -d)"
    fi
  else
    fail "node.env says INSTALL_CLOUDFLARED=true but Docker is missing"
  fi
fi
echo

# ---------- Docker ----------
echo "── Docker ──"
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "Docker is running"
    echo "  Containers: $(docker ps -q 2>/dev/null | wc -l) running"
    # Docker published ports BYPASS UFW. Warn about publicly-bound ports.
    EXPOSED="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E '(0\.0\.0\.0|\[::\])' || true)"
    if [[ -n "$EXPOSED" ]]; then
      warn "Containers publishing ports on ALL interfaces (Docker bypasses UFW!):"
      while IFS= read -r line; do echo "    $line"; done <<<"$EXPOSED"
      warn "  Prefer binding to 127.0.0.1 or the Tailscale IP, or use Cloudflare Tunnel."
    else
      ok "No container ports published on 0.0.0.0/::"
    fi
  else
    fail "Docker installed but daemon not reachable (permissions?)"
  fi
else
  fail "Docker not installed"
fi
echo

# ---------- Simple speed hint (optional) ----------
if [[ "${CHECK_NODE_SKIP_SPEEDTEST:-0}" != "1" ]]; then
  echo "── Rough download speed hint ──"
  echo "  (short test to Cloudflare – not a full speedtest)"
  SPEED=$(curl -s -o /dev/null -w '%{speed_download}' --max-time 8 https://speed.cloudflare.com/__down?bytes=10000000 2>/dev/null || echo "0")
  if [[ "$SPEED" != "0" && -n "$SPEED" ]]; then
    if command -v bc >/dev/null 2>&1; then
      MBIT=$(echo "scale=1; $SPEED * 8 / 1000000" | bc 2>/dev/null || echo "?")
      ok "Approx download: ${MBIT} Mbit/s (Cloudflare 10 MB test)"
    else
      ok "Download test succeeded (bc not available for Mbit/s conversion)"
    fi
  else
    warn "Speed test failed or timed out"
  fi
  echo
fi

echo "=== End of check ==="
if (( FAILURES > 0 )); then
  echo -e "${RED}RESULT: $FAILURES hard failure(s) – see ✗ lines above.${NC}"
  exit 1
fi
echo -e "${GREEN}RESULT: no hard failures.${NC}"
echo "Tip: run with 'sudo' for complete checks (UFW rules, restic freshness)."
echo "     Example: sudo /opt/stacks/_backup/check-node.sh"
