#!/bin/bash
set -euo pipefail

# =============================================================================
# Homelab Node Bootstrap
# -----------------------------------------------------------------------------
# Sets up a node as either "server" or "client" with:
#   - Directory skeleton (/opt/stacks + backup tooling)
#   - Tailscale (with optional exit-node support)
#   - UFW hardening (default deny, Tailscale-only access)
#   - Restic → S3-compatible backup (one repo per node)
#   - Optional Cloudflare Tunnel on server nodes
#   - Optional Beszel agent connected to a manually managed hub
#
# Design goals:
#   - Safe ordering (minimize lockout risk):
#       UFW rules are added and VERIFIED before the firewall is enabled, and
#       exit-node routing is applied LAST (after UFW, restic and connectivity
#       are confirmed) with a probe + automatic rollback.
#   - Idempotent where practical: re-runs converge state, never destroy data.
#     Existing /opt/stacks ownership is never recursively rewritten.
#   - Explicit node identity, persisted in /etc/homelab/node.env.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/homelab-bootstrap-$(date +%Y%m%d-%H%M%S).log"
NODE_ENV_DIR="/etc/homelab"
NODE_ENV_FILE="$NODE_ENV_DIR/node.env"
SCRIPT_VERSION="5"
CLOUDFLARED_APT_LIST="/etc/apt/sources.list.d/cloudflared.list"
CLOUDFLARED_KEYRING="/usr/share/keyrings/cloudflare-main.gpg"
# Beszel agent was moved to addons/beszel-agent/install.sh in WP5. The
# Beszel stack directory + compose template constants now live in that
# addon — bootstrap.sh no longer touches /opt/stacks/beszel-agent.
ADDONS_DIR="$SCRIPT_DIR/addons"
BESZEL_ADDON="$ADDONS_DIR/beszel-agent/install.sh"
RESTIC_HOST_NATIVE_ADDON="$ADDONS_DIR/restic-host-native/install.sh"

if [[ ! -r "$SCRIPT_DIR/lib.sh" ]]; then
  printf 'ERROR: lib.sh is required next to bootstrap.sh\n' >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

# ---------- Helpers ----------
log()   { echo "[$(date -Is)] $*" | tee -a "$LOG_FILE"; }
info()  { log "INFO  $*"; }
warn()  { log "WARN  $*"; }
error() { log "ERROR $*"; exit 1; }

NONINTERACTIVE="${HOMELAB_NONINTERACTIVE:-0}"
ASSUME_YES="false"
INTERACTIVE="false"

# Force interactive prompts for optional choices even when --yes is set.
# Has NO effect under HOMELAB_NONINTERACTIVE=1 or a non-TTY stdin — those
# three non-interactive guards always win, by design. Explicit flags for a
# given option still override any prompt.
is_interactive() {
  [[ "$ASSUME_YES" != "true" && "$NONINTERACTIVE" != "1" && -t 0 ]]
}

# Thin wrapper so existing call sites (Proceed with bootstrap?,
# exit-node apply, public-SSH lockdown) keep their y/N contract.
# Bootstrap's local is_interactive() additionally honours --interactive,
# which homelab_confirm() does not. The wrapper bridges that gap.
confirm() {
  local prompt="${1:-Continue?}" default="${2:-n}"
  if [[ "$ASSUME_YES" == "true" || "$NONINTERACTIVE" == "1" || ! -t 0 ]]; then
    [[ "$default" =~ ^[Yy]$ ]]
    return $?
  fi
  homelab_confirm "$prompt" "$default"
}

# Detect whether this node already has a live host-native restic timer
# (and no running lobaro container). Used to decide whether the
# host-native → lobaro migration prompt is appropriate. Mirrors the
# staleness guard already applied to the persisted INSTALL_RESTIC_HOST_NATIVE
# flag in the load phase: a timer that survived a previous run.
host_native_timer_detected() {
  $SUDO systemctl is-enabled restic-backup.timer >/dev/null 2>&1
}

# Collect the operator's intent for optional choices. Sets the same
# per-run REQUESTED_THIS_RUN variables the explicit flags set. Runs
# early (after role/node-name resolution) but applies later, so the
# step order — exit-node last, migrate owns 6b, addons after core —
# stays load-bearing. No side effects from this function.
#
# Precedence per option:
#   1. explicit flag      → REQUESTED_THIS_RUN already true
#   2. already installed  → silent skip (no prompt, no flag flip)
#   3. interactive prompt → REQUESTED_THIS_RUN = (y/n)
#   4. safe default       → false / empty
collect_optional_intent() {
  # 1) cloudflared (server only).
  if [[ "$ROLE" == "server" \
    && "$CLOUDFLARED_REQUESTED_THIS_RUN" != "true" \
    && "$INSTALL_CLOUDFLARED" != "true" \
    && ! cloudflared_is_usable \
    && wants_optional_prompts ]]; then
    if homelab_confirm "Install cloudflared (Cloudflare Tunnel client)?" n; then
      CLOUDFLARED_REQUESTED_THIS_RUN="true"
    fi
  fi

  # 2) Beszel agent. Skip when already running or the compose file exists.
  if [[ "$BESZEL_AGENT_REQUESTED_THIS_RUN" != "true" \
    && "$INSTALL_BESZEL_AGENT" != "true" \
    && wants_optional_prompts ]]; then
    if $SUDO docker ps -a --filter name=^beszel-agent$ --format '{{.Names}}' 2>/dev/null \
         | grep -q '^beszel-agent$' \
      || $SUDO test -f "/opt/stacks/beszel-agent/docker-compose.yml"; then
      :   # already deployed; silent skip
    elif homelab_confirm "Install Beszel agent?" n; then
      BESZEL_AGENT_REQUESTED_THIS_RUN="true"
    fi
  fi

  # NOTE: the host-native restic addon intentionally has NO interactive
  # prompt. On a fresh node the lobaro container is not running yet when
  # collect_optional_intent runs, so a "yes" would land both schedulers on
  # the same node unless extra gating was added. Keep --install-restic-host-native
  # as the only way to opt in, and let --migrate-from-host-native (with its
  # own gate) carry the reverse direction.

  # 3) Advertise exit node (server only). Skip when already advertised
  #    via persisted state — re-running must not toggle this implicitly.
  if [[ "$ROLE" == "server" \
    && "$ADVERTISE_EXIT_NODE" != "true" \
    && wants_optional_prompts ]]; then
    if homelab_confirm "Advertise this node as a Tailscale exit node?" n; then
      ADVERTISE_EXIT_NODE="true"
    fi
  fi

  # 4) Use exit node. Skip on persisted state so a re-run does not flip
  #    routing silently. The prompt is shown primarily for clients, but
  #    we do not role-gate it (a server may legitimately want one).
  if [[ -z "$USE_EXIT_NODE" && wants_optional_prompts ]]; then
    local reply
    reply="$(homelab_ask 'Use an exit node? (name or IP, empty for none)' '')"
    if [[ -n "$reply" ]]; then
      USE_EXIT_NODE="$reply"
      info "Use-exit-node intent recorded: '$USE_EXIT_NODE' (applied later, after UFW + restic)"
    fi
  fi

  # 5) Migrate host-native → lobaro. Only when the timer is detected AND
  #    lobaro is not already running. Already-migrated nodes: silent skip.
  if [[ "$MIGRATE_FROM_HOST_NATIVE_THIS_RUN" != "true" \
    && wants_optional_prompts ]]; then
    local lobaro_running="false"
    if command -v docker >/dev/null 2>&1 \
      && docker inspect -f '{{.State.Running}}' restic-backup 2>/dev/null \
         | grep -q '^true$'; then
      lobaro_running="true"
    fi
    if [[ "$lobaro_running" == "true" ]]; then
      :   # already on lobaro; silent skip
    elif host_native_timer_detected; then
      if homelab_confirm "Migrate host-native restic → lobaro on this node?" n; then
        MIGRATE_FROM_HOST_NATIVE_THIS_RUN="true"
      fi
    fi
  fi
}

# Prompts optional choices on a TTY. Used by collect_optional_intent().
# Defaults to off (no nag) on non-TTY stdin. Honors --interactive when a
# TTY is available, but never overrides the three non-interactive guards.
wants_optional_prompts() {
  homelab_is_tty || return 1
  [[ "$NONINTERACTIVE" == "1" ]] && return 1
  if [[ "$ASSUME_YES" == "true" ]]; then
    [[ "$INTERACTIVE" == "true" ]]
    return $?
  fi
  return 0
}

# Make --yes visible to lib.sh helpers that live in subprocesses
# (addons, setup-restic.sh) so their prompts follow the same rules.
export HOMELAB_ASSUME_YES="false"
[[ "$ASSUME_YES" == "true" ]] && export HOMELAB_ASSUME_YES="true"

need_root_or_sudo() {
  if [[ $EUID -eq 0 ]]; then
    SUDO=""
  else
    SUDO="sudo"
    if ! command -v sudo >/dev/null; then
      error "This script needs root or sudo"
    fi
  fi
  # The human operating the machine (correct under both sudo and plain root)
  REAL_USER="${SUDO_USER:-$USER}"
}

cloudflared_cleanup_apt() {
  # These paths are managed by this bootstrap, and must not survive a failed
  # repository setup to break a later global apt update.
  if ! $SUDO rm -f "$CLOUDFLARED_APT_LIST" "$CLOUDFLARED_KEYRING"; then
    warn "Could not remove Cloudflare apt metadata; future apt updates may still need manual cleanup"
  fi
  return 0
}

cloudflared_source_suite() {
  [[ -r "$CLOUDFLARED_APT_LIST" ]] || return 1
  awk '$1 == "deb" { print $4; exit }' "$CLOUDFLARED_APT_LIST" 2>/dev/null
}

cloudflared_release_available() {
  local suite="$1"
  [[ -n "$suite" ]] || return 1
  curl -fsSL --max-time 10 \
    "https://pkg.cloudflare.com/cloudflared/dists/$suite/Release" \
    >/dev/null 2>&1
}

cloudflared_is_usable() {
  command -v cloudflared >/dev/null 2>&1 \
    && cloudflared --version >/dev/null 2>&1
}

cloudflared_cleanup_stale_apt() {
  local suite=""
  if [[ -r "$CLOUDFLARED_APT_LIST" ]]; then
    suite="$(cloudflared_source_suite || true)"
    if ! cloudflared_release_available "$suite"; then
      warn "Removing stale or unsupported Cloudflare apt source (suite=${suite:-unknown})"
      cloudflared_cleanup_apt
    fi
  elif [[ -e "$CLOUDFLARED_APT_LIST" || -e "$CLOUDFLARED_KEYRING" ]]; then
    warn "Removing unreadable or orphaned Cloudflare apt metadata"
    cloudflared_cleanup_apt
  fi
}

install_cloudflared_binary() {
  local arch asset url tmp
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64) asset="cloudflared-linux-amd64" ;;
    i386)  asset="cloudflared-linux-386" ;;
    arm64) asset="cloudflared-linux-arm64" ;;
    armhf|armel) asset="cloudflared-linux-arm" ;;
    *)
      warn "No official cloudflared binary mapping for architecture '$arch'; skipping"
      return 1
      ;;
  esac

  url="https://github.com/cloudflare/cloudflared/releases/latest/download/$asset"
  if ! tmp="$(mktemp)"; then
    warn "Could not create a temporary file for the cloudflared binary"
    return 1
  fi
  if ! curl -fsSL --retry 2 "$url" -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! $SUDO install -m 0755 "$tmp" /usr/local/bin/cloudflared; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  cloudflared_is_usable
}

install_cloudflared_apt() {
  if ! curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | $SUDO tee "$CLOUDFLARED_KEYRING" >/dev/null; then
    cloudflared_cleanup_apt
    return 1
  fi
  # Cloudflare documents the "any" suite for all Debian-based distributions.
  if ! printf '%s\n' \
    "deb [signed-by=$CLOUDFLARED_KEYRING] https://pkg.cloudflare.com/cloudflared any main" \
    | $SUDO tee "$CLOUDFLARED_APT_LIST" >/dev/null; then
    cloudflared_cleanup_apt
    return 1
  fi
  if ! $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
    cloudflared_cleanup_apt
    return 1
  fi
  if ! $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared; then
    cloudflared_cleanup_apt
    return 1
  fi
  cloudflared_is_usable
}

# Beszel agent (WP5): all helper functions and configure_beszel_agent()
# moved to addons/beszel-agent/install.sh. bootstrap.sh no longer touches
# /opt/stacks/beszel-agent — the addon installer handles validation,
# file writes, container startup, verification, and INSTALL_BESZEL_AGENT
# persistence. See AGENT.md §3 WP5.

GENERIC_NODE_NAMES="ubuntu debian localhost server client homelab node vps host linux default unknown"

# Normalize to lowercase, require DNS-label-safe, reject generic names.
validate_node_name() {
  local name="$1" g
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    return 1
  fi
  for g in $GENERIC_NODE_NAMES; do
    [[ "$name" == "$g" ]] && return 1
  done
  return 0
}

# ---------- Defaults / Config ----------
ROLE=""                       # server | client
NODE_NAME=""
USE_EXIT_NODE=""              # for clients: name/IP of exit node
ADVERTISE_EXIT_NODE="false"   # for servers
INSTALL_CLOUDFLARED="false"  # successfully applied state
CLOUDFLARED_REQUESTED_THIS_RUN="false"  # explicit request; never persisted
INSTALL_BESZEL_AGENT="false"  # successfully applied state
BESZEL_AGENT_REQUESTED_THIS_RUN="false"  # explicit request; never persisted
INSTALL_RESTIC_HOST_NATIVE="false"  # successfully applied state (read-only here)
RESTIC_HOST_NATIVE_REQUESTED_THIS_RUN="false"  # explicit request; never persisted
MIGRATE_FROM_HOST_NATIVE_THIS_RUN="false"  # explicit request; never persisted (WP7)
KEEP_PUBLIC_SSH="true"        # safety default – only tighten later
TS_AUTHKEY="${TS_AUTHKEY:-}"  # optional non-interactive Tailscale join
BESZEL_HUB_URL="${BESZEL_HUB_URL:-}"
BESZEL_AGENT_KEY="${BESZEL_AGENT_KEY:-}"
BESZEL_AGENT_TOKEN="${BESZEL_AGENT_TOKEN:-}"
BESZEL_SYSTEM_NAME="${BESZEL_SYSTEM_NAME:-}"
BESZEL_ALLOW_SAME_HOST_HUB_URL="${BESZEL_ALLOW_SAME_HOST_HUB_URL:-false}"
EXIT_NODE_LAN_ACCESS="true"   # homelab default: stay reachable from LAN
DIRECT_PUBLIC_IP_AT_SETUP=""
FLAG_ROLE_SET="false"
FLAG_NODE_NAME_SET="false"
NODE_ENV_EXISTS="false"
PERSISTED_ROLE=""
PERSISTED_NODE_NAME=""
PERSISTED_USE_EXIT_NODE=""
PERSISTED_EXIT_NODE_APPLIED=""
PERSISTED_ADVERTISE_EXIT_NODE=""
PERSISTED_INSTALL_CLOUDFLARED=""
PERSISTED_INSTALL_BESZEL_AGENT=""
PERSISTED_INSTALL_RESTIC_HOST_NATIVE=""
PERSISTED_EXIT_NODE_LAN_ACCESS=""
PERSISTED_DIRECT_PUBLIC_IP_AT_SETUP=""
PERSISTED_KEEP_PUBLIC_SSH=""
PERSISTED_TAILSCALE_FIREWALL_VERIFIED=""

# ---------- Persisted state from a previous run -------------------------------
# Needs $SUDO: node.env is 0600 root, and non-root invocations must not die here.
need_root_or_sudo
if [[ -f "$NODE_ENV_FILE" ]]; then
  NODE_ENV_EXISTS="true"
  ROLE=""
  NODE_NAME=""
  USE_EXIT_NODE=""
  EXIT_NODE_APPLIED=""
  ADVERTISE_EXIT_NODE=""
  INSTALL_CLOUDFLARED=""
  INSTALL_BESZEL_AGENT=""
  INSTALL_RESTIC_HOST_NATIVE=""
  EXIT_NODE_LAN_ACCESS=""
  DIRECT_PUBLIC_IP_AT_SETUP=""
  KEEP_PUBLIC_SSH=""
  TAILSCALE_FIREWALL_VERIFIED=""
  if ! homelab_load_kv_sudo "$SUDO" "$NODE_ENV_FILE" "${HOMELAB_NODE_ENV_KEYS[@]}"; then
    error "Could not read persisted node state: $NODE_ENV_FILE"
  fi
  PERSISTED_ROLE="$ROLE"
  PERSISTED_NODE_NAME="$(printf '%s' "$NODE_NAME" | tr '[:upper:]' '[:lower:]')"
  PERSISTED_USE_EXIT_NODE="$USE_EXIT_NODE"
  PERSISTED_EXIT_NODE_APPLIED="$EXIT_NODE_APPLIED"
  PERSISTED_ADVERTISE_EXIT_NODE="$ADVERTISE_EXIT_NODE"
  PERSISTED_INSTALL_CLOUDFLARED="$INSTALL_CLOUDFLARED"
  PERSISTED_INSTALL_BESZEL_AGENT="$INSTALL_BESZEL_AGENT"
  PERSISTED_INSTALL_RESTIC_HOST_NATIVE="$INSTALL_RESTIC_HOST_NATIVE"
  PERSISTED_EXIT_NODE_LAN_ACCESS="$EXIT_NODE_LAN_ACCESS"
  PERSISTED_DIRECT_PUBLIC_IP_AT_SETUP="$DIRECT_PUBLIC_IP_AT_SETUP"
  PERSISTED_KEEP_PUBLIC_SSH="$KEEP_PUBLIC_SSH"
  PERSISTED_TAILSCALE_FIREWALL_VERIFIED="$TAILSCALE_FIREWALL_VERIFIED"

  # Existing state is the default for a re-run. In particular, a lockdown
  # decision remains closed unless the state is intentionally changed outside
  # this script; there is no accidental public-SSH reopen on a plain re-run.
  ROLE="$PERSISTED_ROLE"
  NODE_NAME="$PERSISTED_NODE_NAME"
  USE_EXIT_NODE="$PERSISTED_USE_EXIT_NODE"
  ADVERTISE_EXIT_NODE="${PERSISTED_ADVERTISE_EXIT_NODE:-false}"
  INSTALL_CLOUDFLARED="${PERSISTED_INSTALL_CLOUDFLARED:-false}"
  if [[ "$INSTALL_CLOUDFLARED" == "true" ]] \
    && ! cloudflared_is_usable; then
    warn "Persisted cloudflared state was true, but the command is missing; clearing stale install intent"
    INSTALL_CLOUDFLARED="false"
  fi
  INSTALL_BESZEL_AGENT="${PERSISTED_INSTALL_BESZEL_AGENT:-false}"
  # WP5: bootstrap no longer touches /opt/stacks/beszel-agent — the addon
  # owns it. Treat a stale INSTALL_BESZEL_AGENT=true as bogus only when
  # nothing in the runtime matches (no container, no compose file).
  if [[ "$INSTALL_BESZEL_AGENT" == "true" ]] \
    && ! $SUDO docker ps -a --filter name=^beszel-agent$ --format '{{.Names}}' 2>/dev/null \
         | grep -q '^beszel-agent$' \
    && ! $SUDO test -f "/opt/stacks/beszel-agent/docker-compose.yml"; then
    warn "Persisted Beszel agent state was true, but no beszel-agent container or Compose file exists; clearing stale install intent"
    INSTALL_BESZEL_AGENT="false"
  fi
  INSTALL_RESTIC_HOST_NATIVE="${PERSISTED_INSTALL_RESTIC_HOST_NATIVE:-false}"
  # Symmetric guard for the host-native addon. If a previous run persisted
  # the flag but neither the timer unit nor the backup script exist on disk
  # any more, the persisted state is bogus — clear it so re-runs do not
  # silently re-claim a non-existent addon.
  if [[ "$INSTALL_RESTIC_HOST_NATIVE" == "true" ]] \
    && ! $SUDO systemctl is-enabled restic-backup.timer >/dev/null 2>&1 \
    && ! $SUDO test -x /opt/stacks/_backup/backup.sh; then
    warn "Persisted host-native restic state was true, but restic-backup.timer is not enabled and /opt/stacks/_backup/backup.sh is missing; clearing stale install intent"
    INSTALL_RESTIC_HOST_NATIVE="false"
  fi
  EXIT_NODE_LAN_ACCESS="${PERSISTED_EXIT_NODE_LAN_ACCESS:-true}"
  DIRECT_PUBLIC_IP_AT_SETUP="$PERSISTED_DIRECT_PUBLIC_IP_AT_SETUP"
  KEEP_PUBLIC_SSH="${PERSISTED_KEEP_PUBLIC_SSH:-}"
  TAILSCALE_FIREWALL_VERIFIED="$PERSISTED_TAILSCALE_FIREWALL_VERIFIED"

  # Older state files did not record lockdown. If UFW is already active and
  # has no public SSH rule, preserve that observed safe state during migration.
  if [[ -z "$KEEP_PUBLIC_SSH" ]]; then
    KEEP_PUBLIC_SSH="true"
    if command -v ufw >/dev/null 2>&1 && homelab_ufw_is_active "$SUDO" \
      && ! homelab_ufw_has_public_ssh "$SUDO"; then
      KEEP_PUBLIC_SSH="false"
      info "Existing UFW state has no public SSH rule; preserving lockdown while migrating node.env"
    fi
  fi
fi

# ---------- Argument parsing ----------
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --role=server|client       Required (unless persisted from a previous run).
  --node-name=NAME           Required. Stable, unique node name (used as
                             Tailscale hostname and restic backup tag).
                             Generic names like 'ubuntu' are refused.
  --advertise-exit-node      (server) Advertise this node as Tailscale exit node
  --use-exit-node=NAME       (client) Route internet via this exit node.
                             Applied LAST, after UFW/restic/connectivity are
                             verified, with probe + automatic rollback.
  --install-cloudflared      (server) Install and prepare Cloudflare Tunnel
  --beszel-agent             Opt in to a Beszel agent connected to a manual
                              hub (addons/beszel-agent/install.sh, dispatched
                              after exit-node apply)
  --install-restic-host-native
                              Opt in to the host-native restic systemd path
                              (addons/restic-host-native/install.sh). Mutually
                              exclusive with the lobaro container; the addon
                              refuses while the restic-backup container is
                              running.
  --migrate-from-host-native   One-shot host-native → lobaro migration on an
                              EXISTING node. Disables the host-native timer,
                              pins /etc/restic/repo-id, reuses
                              setup-restic.sh to deploy the lobaro container
                              against the same repo (no re-init), verifies,
                              and persists INSTALL_RESTIC_HOST_NATIVE=false.
                              Idempotent: re-running on an already-migrated
                              node is a no-op. See MIGRATION.md.
  --no-public-ssh            After Tailscale is verified, remove public SSH rules.
                              In non-interactive mode this flag IS the confirmation.
  --public-ssh               Explicitly reopen/keep public SSH (overrides lockdown).
  --ts-authkey=KEY           Non-interactive Tailscale auth key (never logged)
  --yes                      Non-interactive: assume "yes" for confirmations
                              (dangerous steps still need their explicit flags)
  --interactive              Force interactive prompts for optional choices
                              (cloudflared, Beszel, advertise/use exit node,
                              host-native → lobaro migration). Has NO effect
                              under --yes, HOMELAB_NONINTERACTIVE=1, or a
                              non-TTY stdin — those three guards always win.
                              Explicit flags still override any prompt.
  -h, --help                 Show this help

Environment:
  TS_AUTHKEY                 Same as --ts-authkey
  BESZEL_HUB_URL             Tailscale-reachable Beszel hub URL (required with --beszel-agent)
  BESZEL_AGENT_KEY           Beszel public agent key (required with --beszel-agent)
  BESZEL_AGENT_TOKEN         Beszel agent token (required with --beszel-agent)
  BESZEL_SYSTEM_NAME         Optional Beszel display name (defaults to --node-name)
  BESZEL_ALLOW_SAME_HOST_HUB_URL=true
                             Explicitly allow a non-Tailscale hub URL for a same-host hub
  HOMELAB_NONINTERACTIVE=1   Same as --yes

Precedence for each optional choice (first match wins):
  1. --yes / HOMELAB_NONINTERACTIVE=1 / non-TTY stdin  → never prompt
  2. Explicit flag for that option                      → no prompt
  3. Already installed and runtime-healthy              → silent skip
  4. Interactive prompt (TTY only, --interactive forces it when --yes is set)
  5. Safe default (false / empty)

State persisted across runs: $NODE_ENV_FILE
EOF
  exit 0
}

for arg in "$@"; do
  case $arg in
    --role=*)              ROLE="${arg#*=}"; FLAG_ROLE_SET="true" ;;
    --node-name=*)         NODE_NAME="${arg#*=}"; FLAG_NODE_NAME_SET="true" ;;
    --advertise-exit-node) ADVERTISE_EXIT_NODE="true" ;;
    --use-exit-node=*)     USE_EXIT_NODE="${arg#*=}" ;;
    --install-cloudflared) CLOUDFLARED_REQUESTED_THIS_RUN="true" ;;
    --beszel-agent)        BESZEL_AGENT_REQUESTED_THIS_RUN="true" ;;
    --install-restic-host-native) RESTIC_HOST_NATIVE_REQUESTED_THIS_RUN="true" ;;
    --migrate-from-host-native)  MIGRATE_FROM_HOST_NATIVE_THIS_RUN="true" ;;
    --no-public-ssh)       KEEP_PUBLIC_SSH="false" ;;
    --public-ssh)          KEEP_PUBLIC_SSH="true" ;;
    --ts-authkey=*)        TS_AUTHKEY="${arg#*=}" ;;
    --yes)                 ASSUME_YES="true"; NONINTERACTIVE="1" ;;
    --interactive)         INTERACTIVE="true" ;;
    -h|--help)             usage ;;
    *)                     error "Unknown argument: $arg" ;;
  esac
done

# ---------- Pre-flight ----------
if [[ -n "$PERSISTED_ROLE" ]]; then
  info "Previous bootstrap state found ($NODE_ENV_FILE): role=$PERSISTED_ROLE node=${PERSISTED_NODE_NAME:-unknown} last run=${LAST_BOOTSTRAP_RUN:-unknown}"
  if [[ "$FLAG_ROLE_SET" == "true" && "$ROLE" != "$PERSISTED_ROLE" ]]; then
    error "Role conflict: this node was bootstrapped as '$PERSISTED_ROLE', you passed --role=$ROLE. Refusing to flip roles."
  fi
fi

if [[ -z "$ROLE" ]]; then
  if is_interactive; then
    echo "Select node role:"
    echo "  1) server  – internet-facing, can host exit-node / Cloudflare Tunnel"
    echo "  2) client  – pure compute, internet via exit-node, no public exposure"
    read -r -p "Choice [1/2]: " choice
    case $choice in
      1) ROLE="server" ;;
      2) ROLE="client" ;;
      *) error "Invalid choice" ;;
    esac
  else
    error "--role=server|client is required in non-interactive mode"
  fi
fi

if [[ "$ROLE" != "server" && "$ROLE" != "client" ]]; then
  error "Role must be 'server' or 'client'"
fi

# Node name: required, explicit, validated. Never silently derived for anything
# important – interactively we *suggest* the hostname, the operator confirms it.
NODE_NAME="$(printf '%s' "$NODE_NAME" | tr '[:upper:]' '[:lower:]')"
if [[ -n "$PERSISTED_NODE_NAME" && "$NODE_NAME" != "$PERSISTED_NODE_NAME" ]]; then
  error "Node-name conflict: this node was bootstrapped as '$PERSISTED_NODE_NAME', but '$NODE_NAME' was requested. Refusing to change identity because it drives restic tags and retention."
fi
if [[ -z "$NODE_NAME" ]]; then
  if is_interactive; then
    suggestion="$(hostname -s | tr '[:upper:]' '[:lower:]')"
    read -r -p "Node name (stable, unique; suggestion: '$suggestion'): " input_name
    NODE_NAME="${input_name:-$suggestion}"
    NODE_NAME="$(printf '%s' "$NODE_NAME" | tr '[:upper:]' '[:lower:]')"
  else
    error "--node-name=NAME is required in non-interactive mode (no silent hostname default)"
  fi
fi
if ! validate_node_name "$NODE_NAME"; then
  error "Invalid or too-generic node name: '$NODE_NAME'. Use lowercase letters/digits/dashes, not one of: $GENERIC_NODE_NAMES"
fi

info "=== Homelab Bootstrap ==="
info "Role      : $ROLE"
info "Node name : $NODE_NAME"
info "Log file  : $LOG_FILE"
echo

# WP8: collect intent for all optional choices in one phase. Sets the same
# per-run REQUESTED_THIS_RUN variables the explicit flags set. No side
# effects — install paths still run at their correct steps (exit-node last,
# migrate owns step 6b, addons after core).
collect_optional_intent

if ! confirm "Proceed with bootstrap?"; then
  info "Aborted by user"
  exit 0
fi

# A failed older run may have left an unsupported suite behind. Remove it
# before the first global apt update, even when this run has no cloudflared flag.
cloudflared_cleanup_stale_apt

# ---------- 1. Base packages ----------
info "Installing base packages..."
$SUDO apt-get update -qq
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ca-certificates gnupg lsb-release ufw jq bc restic openssl \
  > >(tee -a "$LOG_FILE") 2>&1 || {
    error "Failed to install base packages. Check the log: $LOG_FILE"
  }

# Docker (official convenience script is fine for personal nodes)
if ! command -v docker >/dev/null 2>&1; then
  info "Installing Docker..."
  if ! curl -fsSL https://get.docker.com | $SUDO sh; then
    error "Docker installation failed. See log: $LOG_FILE"
  fi
else
  info "Docker already installed"
fi
if [[ "$REAL_USER" != "root" ]]; then
  $SUDO usermod -aG docker "$REAL_USER" || warn "Could not add $REAL_USER to docker group (non-fatal)"
fi

# ---------- 2. Directory skeleton ----------
# Never mutate an existing /opt/stacks tree: create missing directories only,
# and chown exactly the directories we created (never recursive).
info "Ensuring directory skeleton exists (no ownership changes to existing dirs)..."
for d in /opt/stacks /opt/stacks/_backup /opt/stacks/_backup/pre /opt/stacks/_system; do
  if [[ ! -d "$d" ]]; then
    $SUDO mkdir -p "$d"
    $SUDO chown "$REAL_USER:$REAL_USER" "$d"
    info "Created $d (owner: $REAL_USER)"
  fi
done
# /opt/homelab/env-file holds the Tailscale IP SSOT (AGENT.md §2).
# mode 755 so non-root consumers can read it via env_file:/--env-file.
$SUDO mkdir -p /opt/homelab/env-file
$SUDO chmod 755 /opt/homelab/env-file
$SUDO mkdir -p /etc/restic "$NODE_ENV_DIR"
$SUDO chmod 700 /etc/restic

# Copy static files if present next to this script. WP5 stopped copying
# backup.sh + restic-backup.{service,timer} — those are now owned by the
# restic-host-native addon and only installed when explicitly opted in.
# change-restic-password.sh stays in the always-on baseline because the
# lobaro container and the host-native addon both consume it.
COPIED=0
for f in RESTORE.md change-restic-password.sh check-node.sh lib.sh; do
  if [[ -f "$SCRIPT_DIR/$f" ]]; then
    $SUDO cp "$SCRIPT_DIR/$f" /opt/stacks/_backup/
    COPIED=$((COPIED + 1))
  else
    warn "Optional file not found next to bootstrap.sh: $f"
  fi
done
info "Copied $COPIED support file(s) into /opt/stacks/_backup/"

$SUDO chmod 700 /opt/stacks/_backup/change-restic-password.sh 2>/dev/null || true
$SUDO chmod 755 /opt/stacks/_backup/check-node.sh 2>/dev/null || true

# Capture this node's own (direct, pre-exit-node) public IP for later
# truthfulness checks. Never overwrite a value persisted by an earlier run.
if [[ -z "$DIRECT_PUBLIC_IP_AT_SETUP" ]]; then
  DIRECT_PUBLIC_IP_AT_SETUP="$(curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null || true)"
fi

# ---------- 3. Tailscale (no exit-node routing yet!) ----------
info "Installing / configuring Tailscale..."

if ! command -v tailscale >/dev/null 2>&1; then
  info "Tailscale not found – installing..."
  if ! curl -fsSL https://tailscale.com/install.sh | $SUDO sh; then
    error "Tailscale installation failed. Check network and try again."
  fi
else
  info "Tailscale already installed ($(tailscale version 2>/dev/null | head -n1 || echo 'unknown version'))"
fi

TS_BACKEND_STATE="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // "NoState"' 2>/dev/null || echo "NoState")"

if [[ "$TS_BACKEND_STATE" == "Running" ]]; then
  info "Tailscale already connected – converging preferences via 'tailscale set'"
  $SUDO tailscale set --hostname="$NODE_NAME" || error "Failed to set Tailscale hostname"
  if [[ "$ROLE" == "server" && "$ADVERTISE_EXIT_NODE" == "true" ]]; then
    $SUDO tailscale set --advertise-exit-node=true || error "Failed to set --advertise-exit-node"
  fi
else
  TS_ARGS=(--hostname="$NODE_NAME")
  if [[ -n "$TS_AUTHKEY" ]]; then
    TS_ARGS+=(--auth-key="$TS_AUTHKEY")
  fi
  if [[ "$ROLE" == "server" && "$ADVERTISE_EXIT_NODE" == "true" ]]; then
    TS_ARGS+=(--advertise-exit-node)
  fi
  # NOTE: the auth key is passed to tailscale but NEVER written to the log.
  info "Running: tailscale up --hostname=$NODE_NAME $( [[ -n "$TS_AUTHKEY" ]] && echo '[auth key redacted]' ) $( [[ "$ROLE" == "server" && "$ADVERTISE_EXIT_NODE" == "true" ]] && echo '--advertise-exit-node' )"
  if ! $SUDO tailscale up "${TS_ARGS[@]}"; then
    error "tailscale up failed. Common causes: invalid auth key, network issue, or interactive login was cancelled."
  fi
fi

info "Waiting a few seconds for Tailscale to settle..."
sleep 5
if tailscale status >/dev/null 2>&1; then
  info "Tailscale is connected"
  tailscale status | head -n 8 || true
else
  warn "tailscale status returned non-zero – it may still be connecting. Continuing anyway."
fi

# ---------- 3a. Tailscale IP SSOT (AGENT.md §3 WP1) ----------
# Copy _system/* into /opt/stacks/_system/, install the tailscaled drop-in,
# enable the periodic refresh timer, and write the SSOT file once. This step
# runs AFTER `tailscale up` and BEFORE UFW/restic so the IP is available to
# every later step (and to the operator).
SYSTEM_SRC="$SCRIPT_DIR/_system"
SYSTEM_DST="/opt/stacks/_system"
TS_DROPIN_DIR="/etc/systemd/system/tailscaled.service.d"

if [[ -d "$SYSTEM_SRC" ]]; then
  $SUDO mkdir -p "$SYSTEM_DST"
  # Copy the writer + units + drop-in recursively, preserving *.d/ structure.
  # `cp -a` preserves timestamps; later units/drop-ins are still picked up
  # after daemon-reload.
  $SUDO cp -a "$SYSTEM_SRC/." "$SYSTEM_DST/"
  $SUDO chown -R root:root "$SYSTEM_DST"
  $SUDO chmod 755 "$SYSTEM_DST/update-tailscale-ip.sh"
  $SUDO chmod 644 "$SYSTEM_DST/update-tailscale-ip.service" \
    "$SYSTEM_DST/update-tailscale-ip.timer" \
    "$SYSTEM_DST/tailscaled.service.d/override.conf"

  # Install the tailscaled drop-in so the writer also runs after every
  # Tailscale restart.
  $SUDO mkdir -p "$TS_DROPIN_DIR"
  $SUDO install -m 644 "$SYSTEM_DST/tailscaled.service.d/override.conf" \
    "$TS_DROPIN_DIR/override.conf"

  $SUDO systemctl daemon-reload

  # Run the writer once now. If Tailscale just came up it should succeed; if
  # not, the timer will retry later.
  if $SUDO "$SYSTEM_DST/update-tailscale-ip.sh"; then
    info "Tailscale IP SSOT writer ran successfully"
  else
    warn "Tailscale IP SSOT writer did not produce a valid file yet (Tailscale may still be connecting)"
  fi

  # Periodic refresh.
  $SUDO systemctl enable --now update-tailscale-ip.timer
  info "Enabled update-tailscale-ip.timer (refreshes /opt/homelab/env-file/tailscale.env every 15 min)"
else
  warn "_system/ directory not found next to bootstrap.sh – skipping Tailscale IP SSOT setup"
fi

# ---------- 3b. Server exit-node prerequisite: IP forwarding ----------
if [[ "$ROLE" == "server" && "$ADVERTISE_EXIT_NODE" == "true" ]]; then
  info "Enabling IPv4/IPv6 forwarding (required to advertise an exit node)..."
  $SUDO tee /etc/sysctl.d/99-homelab-exitnode.conf > /dev/null <<'EOF'
# Required for Tailscale exit-node advertisement (managed by homelab bootstrap)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
  $SUDO sysctl --system >/dev/null 2>&1 || $SUDO sysctl -p /etc/sysctl.d/99-homelab-exitnode.conf >/dev/null
  FWD4="$($SUDO sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  FWD6="$($SUDO sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)"
  if [[ "$FWD4" != "1" || "$FWD6" != "1" ]]; then
    error "IP forwarding not effective (ipv4=$FWD4 ipv6=$FWD6). Exit node would silently blackhole traffic – aborting."
  fi
  info "IP forwarding verified (ipv4=1 ipv6=1)"
fi

# ---------- 4. UFW hardening (fail closed, never lock the operator out) ----------
info "Configuring UFW..."

UFW_BEFORE="$($SUDO ufw status verbose 2>/dev/null || true)"
$SUDO ufw default deny incoming
$SUDO ufw default allow outgoing

# A prior lockdown is sticky. Do not recreate a public SSH rule merely because
# this is a re-run; an existing rule may be removed below after a fresh check.
if [[ "$KEEP_PUBLIC_SSH" == "true" ]]; then
  # SSH rule is critical when public SSH is desired. Fall back to explicit 22/tcp.
  if ! $SUDO ufw allow OpenSSH comment 'Temporary public SSH - review later' >>"$LOG_FILE" 2>&1; then
    warn "'ufw allow OpenSSH' failed – falling back to explicit 22/tcp"
    if ! $SUDO ufw allow 22/tcp comment 'Temporary public SSH - review later' >>"$LOG_FILE" 2>&1; then
      error "Could not add ANY SSH allow rule. Aborting BEFORE enabling the firewall – no lockout risk."
    fi
  fi
else
  info "Public SSH lockdown is persisted; no public SSH rule will be added"
fi

# Tailscale rules are CRITICAL as well.
if ! $SUDO ufw allow in on tailscale0 comment 'Tailscale' >>"$LOG_FILE" 2>&1; then
  error "Could not add tailscale0 allow rule. Aborting BEFORE enabling the firewall – no lockout risk."
fi
$SUDO ufw allow 41641/udp comment 'Tailscale direct wireguard' >>"$LOG_FILE" 2>&1 || warn "Could not add 41641/udp rule (DERP relay still works – non-fatal)"

# Enable (non-interactive)
if ! $SUDO ufw --force enable >>"$LOG_FILE" 2>&1; then
  error "Failed to enable UFW. Aborting to avoid leaving the system in a partial state."
fi

# Post-enable verification: if a critical rule is missing, DISABLE the firewall
# again rather than leaving the operator locked out. Public SSH is only critical
# when the persisted desired state says it should remain open.
UFW_RULES_NOW="$($SUDO ufw status 2>/dev/null || true)"
if [[ "$KEEP_PUBLIC_SSH" == "true" ]] && ! grep -qE '(22/tcp|OpenSSH)[[:space:]]+ALLOW' <<<"$UFW_RULES_NOW"; then
  $SUDO ufw --force disable >>"$LOG_FILE" 2>&1 || true
  error "SSH rule not active after 'ufw enable' – firewall DISABLED again to prevent lockout. Investigate UFW config."
fi
if ! grep -q 'tailscale0' <<<"$UFW_RULES_NOW"; then
  $SUDO ufw --force disable >>"$LOG_FILE" 2>&1 || true
  error "tailscale0 rule not active after 'ufw enable' – firewall DISABLED again to prevent lockout. Investigate UFW config."
fi
UFW_RULES_AFTER="$($SUDO ufw status verbose 2>/dev/null || true)"
UFW_RULES_CHANGED="false"
if [[ "$UFW_BEFORE" != "$UFW_RULES_AFTER" ]]; then
  UFW_RULES_CHANGED="true"
fi
if [[ "$KEEP_PUBLIC_SSH" == "true" ]]; then
  info "UFW active with verified SSH + tailscale0 rules"
else
  info "UFW active with verified tailscale0 rule; public SSH remains locked down"
fi

# Restart only when this run changed UFW, or on a genuinely new node where the
# Tailscale-through-firewall path has never been checked. This avoids dropping
# an established Tailscale-only SSH session on ordinary re-runs.
NEEDS_TAILSCALE_RESTART="$UFW_RULES_CHANGED"
if [[ "$NODE_ENV_EXISTS" == "false" && "$PERSISTED_TAILSCALE_FIREWALL_VERIFIED" != "true" ]]; then
  NEEDS_TAILSCALE_RESTART="true"
elif [[ "$NODE_ENV_EXISTS" == "true" && "$PERSISTED_TAILSCALE_FIREWALL_VERIFIED" != "true" ]]; then
  # An unverified existing node can still be checked without risking a
  # Tailscale-only session when public SSH is already closed.
  if homelab_ufw_has_public_ssh "$SUDO"; then
    NEEDS_TAILSCALE_RESTART="true"
  fi
fi
if [[ "$NEEDS_TAILSCALE_RESTART" == "true" ]]; then
  warn "Restarting tailscaled to verify Tailscale survives the changed firewall ruleset..."
  $SUDO systemctl restart tailscaled
  TS_BACK="false"
  for _ in $(seq 1 10); do
    if tailscale status >/dev/null 2>&1; then TS_BACK="true"; break; fi
    sleep 3
  done
  [[ "$TS_BACK" == "true" ]] || error "tailscaled did not recover after restart. UFW is up; investigate before removing SSH access."
  info "Tailscale is back after restart"
else
  if [[ "$PERSISTED_TAILSCALE_FIREWALL_VERIFIED" == "true" ]]; then
    info "UFW rules are unchanged and Tailscale was previously verified; not restarting tailscaled"
  else
    warn "UFW rules are unchanged; preserving the existing Tailscale-only session without a restart (firewall path remains unverified)"
  fi
fi

TAILSCALE_VERIFIED="false"
PEER_IP="$(tailscale status --json 2>/dev/null | jq -r '[.Peer[]? | select(.Online==true)][0].TailscaleIPs[0] // empty' 2>/dev/null || true)"
if [[ -n "$PEER_IP" ]]; then
  if tailscale ping --c 1 --timeout 5s "$PEER_IP" >/dev/null 2>&1; then
    TAILSCALE_VERIFIED="true"
    info "Tailscale peer ping OK ($PEER_IP) – Tailscale path verified through the firewall"
  else
    warn "Tailscale status is up but peer ping to $PEER_IP failed."
  fi
else
  warn "No online Tailscale peers exist yet – cannot prove Tailscale SSH path."
fi
if [[ "$TAILSCALE_VERIFIED" == "true" ]]; then
  TAILSCALE_FIREWALL_VERIFIED="true"
elif [[ "$PERSISTED_TAILSCALE_FIREWALL_VERIFIED" == "true" ]]; then
  TAILSCALE_FIREWALL_VERIFIED="true"
else
  TAILSCALE_FIREWALL_VERIFIED="false"
fi

info "Current UFW status:"
$SUDO ufw status verbose | tee -a "$LOG_FILE"

if [[ "$KEEP_PUBLIC_SSH" == "false" ]]; then
  if ! homelab_ufw_has_public_ssh "$SUDO"; then
    info "Public SSH is already locked down; leaving it closed"
  elif [[ "$TAILSCALE_VERIFIED" != "true" ]]; then
    warn "Tailscale path could not be fully verified – keeping the existing public SSH rule (safe default)."
    warn "Re-run after confirming a working Tailscale session to finish lockdown."
  else
    echo
    echo ">>> IMPORTANT – READ CAREFULLY <<<"
    echo "Open a NEW terminal/session and verify you can SSH using the Tailscale IP"
    echo "before continuing. If you cannot, answer 'N' and keep public SSH open."
    echo
    echo "Current Tailscale IPs:"
    tailscale ip -4 2>/dev/null || warn "Could not retrieve Tailscale IPs"
    echo
    if confirm "I have confirmed Tailscale SSH works and want to remove public SSH rules"; then
      $SUDO ufw delete allow OpenSSH >>"$LOG_FILE" 2>&1 || true
      $SUDO ufw delete allow 22/tcp >>"$LOG_FILE" 2>&1 || true
      # Verify the delete actually took effect (comment-matching can miss)
      if $SUDO ufw status | grep -qE '(22/tcp|OpenSSH)[[:space:]]+ALLOW'; then
        warn "Public SSH rule still present after delete attempt – remove it manually via: sudo ufw status numbered"
      fi
      # Paranoia: never remove the tailscale0 rule here
      if $SUDO ufw status | grep -q 'tailscale0'; then
        info "Public SSH rules removed (tailscale0 rule still present)"
        $SUDO ufw status verbose
      else
        error "tailscale0 rule vanished after SSH-rule removal – refusing to continue. Add public SSH back manually if needed."
      fi
    else
      warn "Keeping public SSH rules for safety. You can remove them later."
    fi
  fi
fi

# Persist the identity and firewall decision before restic setup. A later
# network/storage failure must not erase a first-run public-SSH lockdown.
EXIT_NODE_APPLIED=""
if [[ "$ROLE" == "client" && -n "$USE_EXIT_NODE" \
  && "$PERSISTED_EXIT_NODE_APPLIED" == "$USE_EXIT_NODE" ]]; then
  EXIT_NODE_APPLIED="$PERSISTED_EXIT_NODE_APPLIED"
fi
write_node_env() {
  local tmp
  tmp="$($SUDO mktemp "$NODE_ENV_DIR/.node.env.XXXXXX")"
  {
    homelab_format_kv ROLE "$ROLE"
    homelab_format_kv NODE_NAME "$NODE_NAME"
    homelab_format_kv USE_EXIT_NODE "$USE_EXIT_NODE"
    homelab_format_kv EXIT_NODE_APPLIED "$EXIT_NODE_APPLIED"
    homelab_format_kv ADVERTISE_EXIT_NODE "$ADVERTISE_EXIT_NODE"
    homelab_format_kv INSTALL_CLOUDFLARED "$INSTALL_CLOUDFLARED"
    homelab_format_kv INSTALL_BESZEL_AGENT "$INSTALL_BESZEL_AGENT"
    homelab_format_kv INSTALL_RESTIC_HOST_NATIVE "$INSTALL_RESTIC_HOST_NATIVE"
    homelab_format_kv EXIT_NODE_LAN_ACCESS "$EXIT_NODE_LAN_ACCESS"
    homelab_format_kv DIRECT_PUBLIC_IP_AT_SETUP "$DIRECT_PUBLIC_IP_AT_SETUP"
    homelab_format_kv KEEP_PUBLIC_SSH "$KEEP_PUBLIC_SSH"
    homelab_format_kv TAILSCALE_FIREWALL_VERIFIED "$TAILSCALE_FIREWALL_VERIFIED"
    homelab_format_kv BOOTSTRAP_VERSION "$SCRIPT_VERSION"
    homelab_format_kv LAST_BOOTSTRAP_RUN "$(date -Is)"
  } | $SUDO tee "$tmp" >/dev/null
  $SUDO chmod 600 "$tmp"
  $SUDO mv "$tmp" "$NODE_ENV_FILE"
}
write_node_env
info "Persisted identity and firewall state to $NODE_ENV_FILE"

# ---------- 5. Role-specific extras ----------
if [[ "$ROLE" == "server" && "$CLOUDFLARED_REQUESTED_THIS_RUN" == "true" ]]; then
  info "Installing cloudflared..."
  if cloudflared_is_usable; then
    INSTALL_CLOUDFLARED="true"
  elif install_cloudflared_apt; then
    INSTALL_CLOUDFLARED="true"
  else
    warn "Cloudflare apt installation failed; trying the official cloudflared binary"
    cloudflared_cleanup_apt
    if install_cloudflared_binary; then
      INSTALL_CLOUDFLARED="true"
    else
      INSTALL_CLOUDFLARED="false"
      cloudflared_cleanup_apt
      warn "cloudflared could not be installed; continuing without it. Re-run with --install-cloudflared after fixing the package or network path."
    fi
  fi
  # Persist only the applied result, never a failed current-run request.
  write_node_env
  if [[ "$INSTALL_CLOUDFLARED" == "true" ]]; then
    info "cloudflared installed. You still need to run 'cloudflared tunnel login' and create a tunnel manually."
    info "See: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/tunnel-guide/"
  fi
fi

# ---------- 6. Restic setup ----------
# Skipped on --migrate-from-host-native: step 6b's migrate-to-lobaro.sh owns
# the deploy sequence (precondition check → pin repo-id → disable host-native
# timer → reuse setup-restic.sh's REUSE_EXISTING branch → verify → persist
# INSTALL_RESTIC_HOST_NATIVE=false). Running setup-restic.sh here would
# double-deploy lobaro against an already-initialized repo on host-native nodes.
#
# On clients this may fail if S3 is only reachable via the exit node (which is
# applied LAST, see below). In that case we defer and retry after the exit
# node is up. On servers a failure stays fatal.
RESTIC_OK="false"
if [[ "$MIGRATE_FROM_HOST_NATIVE_THIS_RUN" == "true" ]]; then
  info "Skipping step 6 setup-restic.sh: --migrate-from-host-native delegates to migrate-to-lobaro.sh in step 6b."
  # RESTIC_OK stays "false" — do not pretend step 6 ran. Step 6b is the
  # authoritative deploy on this path.
else
  if [[ -f "$SCRIPT_DIR/setup-restic.sh" ]]; then
    export NODE_NAME
    export HOMELAB_NONINTERACTIVE="$NONINTERACTIVE"
    info "Starting restic setup wizard..."
    if bash "$SCRIPT_DIR/setup-restic.sh"; then
      RESTIC_OK="true"
    elif [[ "$ROLE" == "server" ]]; then
      error "Restic setup failed. The rest of the bootstrap succeeded, but backups are not configured. You can re-run setup-restic.sh later."
    else
      warn "Restic setup failed (S3 may only be reachable via the exit node)."
      warn "Will retry AFTER the exit node is enabled and verified."
    fi
  else
    warn "setup-restic.sh not found next to bootstrap.sh – skipping automated restic setup"
    info "You can run the restic wizard manually later."
  fi
fi

# ---------- 6b. Migration: host-native → lobaro (AGENT.md §3 WP7) ----------
# Opt-in only; runs when --migrate-from-host-native was passed THIS run.
# Delegates all logic to migrate-to-lobaro.sh (dedicated helper). The helper
# is idempotent: re-running on an already-migrated node is a no-op exit 0;
# running on a node without a host-native timer refuses (wrong tool).
#
# Placement: AFTER step 6 (restic setup) so /etc/restic/{env,password}
# already exist, and BEFORE step 7 (write_node_env) so the persisted
# INSTALL_RESTIC_HOST_NATIVE=false from the helper lands in the same
# write. Also BEFORE step 9 (addon dispatch) so the host-native addon
# does not run against a freshly-deployed lobaro container.
if [[ "$MIGRATE_FROM_HOST_NATIVE_THIS_RUN" == "true" ]]; then
  if [[ ! -r "$SCRIPT_DIR/migrate-to-lobaro.sh" ]]; then
    error "migrate-to-lobaro.sh is missing next to bootstrap.sh. Refusing to set --migrate-from-host-native without the helper."
  fi
  info "Running host-native → lobaro migration helper..."
  # Forward HOMELAB_NONINTERACTIVE so the helper does not prompt twice.
  export HOMELAB_NONINTERACTIVE
  if ! bash "$SCRIPT_DIR/migrate-to-lobaro.sh"; then
    error "Migration helper failed. The host-native timer is now disabled; see MIGRATION.md for the rollback recipe. No snapshots were deleted."
  fi
  # The helper persisted INSTALL_RESTIC_HOST_NATIVE=false via addon_persist_flag.
  # Reload it from /etc/homelab/node.env so step 7's write_node_env does NOT
  # overwrite the helper's flag with the legacy "true" loaded at startup.
  INSTALL_RESTIC_HOST_NATIVE=""
  if homelab_load_kv_sudo "$SUDO" /etc/homelab/node.env INSTALL_RESTIC_HOST_NATIVE; then
    :
  fi
fi

# ---------- 7. Persist desired state after base/restic convergence ----------
write_node_env
info "Persisted node state to $NODE_ENV_FILE"

# ---------- 8. Exit-node routing – LAST, with probe + rollback ----------
if [[ "$ROLE" == "client" && -n "$USE_EXIT_NODE" ]]; then
  echo
  warn "About to route ALL internet traffic via exit node '$USE_EXIT_NODE'"
  warn "(LAN access stays allowed: --exit-node-allow-lan-access=true)."
  warn "If you are connected via the PUBLIC IP (not Tailscale), this session WILL drop."
  if confirm "Apply exit-node routing now?"; then
    if ! $SUDO tailscale set --exit-node="$USE_EXIT_NODE" --exit-node-allow-lan-access="$EXIT_NODE_LAN_ACCESS"; then
      EXIT_NODE_APPLIED=""
      write_node_env
      error "Failed to apply exit node via 'tailscale set'. Nothing was changed."
    fi
    info "Exit node applied. Probing connectivity..."
    sleep 5
    PROBE_OK="false"
    EXIT_NODE_ONLINE="false"
    TS_AFTER_EXIT="$($SUDO tailscale status --json 2>/dev/null || echo '{}')"
    EXIT_ID="$(jq -r '.ExitNodeStatus.ID // empty' <<<"$TS_AFTER_EXIT" 2>/dev/null || true)"
    EXIT_NODE_ONLINE="$(jq -r '.ExitNodeStatus.Online // false' <<<"$TS_AFTER_EXIT" 2>/dev/null || echo false)"
    EXIT_NAME_AFTER="$(jq -r --arg id "$EXIT_ID" '[.Peer[]? | select(.ID==$id) | (.HostName // .DNSName // .ID)][0] // empty' <<<"$TS_AFTER_EXIT" 2>/dev/null || true)"
    EXIT_IPS_AFTER="$(jq -r '.ExitNodeStatus.TailscaleIPs // [] | map(. | split("/")[0]) | join(" ")' <<<"$TS_AFTER_EXIT" 2>/dev/null || true)"
    EXIT_TARGET_MATCH="true"
    if [[ -n "$EXIT_ID" && "$USE_EXIT_NODE" != "$EXIT_ID" \
      && "$USE_EXIT_NODE" != "$EXIT_NAME_AFTER" && " $EXIT_IPS_AFTER " != *" $USE_EXIT_NODE "* ]]; then
      EXIT_TARGET_MATCH="false"
      warn "Probe found online exit node '$EXIT_NAME_AFTER', not requested '$USE_EXIT_NODE'"
    fi
    if [[ -n "$EXIT_ID" && "$EXIT_NODE_ONLINE" == "true" && "$EXIT_TARGET_MATCH" == "true" ]]; then
      PROBE_OK="true"
      info "Tailscale confirms the requested exit-node session is online (id=$EXIT_ID)"
    else
      warn "Probe failed: Tailscale does not show an online exit-node session for '$USE_EXIT_NODE' (id=${EXIT_ID:-none}, online=$EXIT_NODE_ONLINE)"
    fi
    NEW_PUBLIC_IP="$(curl -4 -s --max-time 10 https://ifconfig.me 2>/dev/null || true)"
    if [[ -z "$NEW_PUBLIC_IP" ]]; then
      warn "Public-IP echo service unavailable; relying on Tailscale's online exit-node evidence"
    fi
    # If restic is configured, also probe the S3 endpoint host.
    if $SUDO test -r /etc/restic/env; then
      RESTIC_REPOSITORY=""
      homelab_load_kv_sudo "$SUDO" /etc/restic/env RESTIC_REPOSITORY || true
      S3_HOST="${RESTIC_REPOSITORY#s3:https://}"
      S3_HOST="${S3_HOST#s3:http://}"
      S3_HOST="${S3_HOST%%/*}"
      if [[ -n "$S3_HOST" ]]; then
        if ! curl -4 -s --max-time 10 -o /dev/null "https://$S3_HOST"; then
          warn "S3 endpoint $S3_HOST was not reachable during the optional probe; not rolling back an otherwise online exit node"
        fi
      fi
    fi
    if [[ "$PROBE_OK" != "true" ]]; then
      warn "Rolling back exit node (tailscale set --exit-node=)"
      $SUDO tailscale set --exit-node= || true
      EXIT_NODE_APPLIED=""
      write_node_env
      error "Exit-node routing FAILED the connectivity probe and was rolled back. Is the exit node approved in the Tailscale admin console and online? Fix and re-run bootstrap."
    fi
    EXIT_NODE_APPLIED="$USE_EXIT_NODE"
    write_node_env
    if [[ -n "$NEW_PUBLIC_IP" ]]; then
      info "Connectivity through exit node OK – public IP is now: $NEW_PUBLIC_IP"
    else
      info "Exit-node routing verified by Tailscale; public-IP echo was unavailable"
    fi
    if [[ -n "$DIRECT_PUBLIC_IP_AT_SETUP" && "$NEW_PUBLIC_IP" == "$DIRECT_PUBLIC_IP_AT_SETUP" ]]; then
      warn "Public IP is identical to this node's own pre-exit-node IP – the exit node may not actually be routing traffic. Double-check in the admin console."
    fi
    # Deferred restic retry (S3 only reachable via exit node). Skipped on the
    # --migrate-from-host-native path: step 6b's helper already deployed
    # lobaro, so retrying setup-restic.sh here would re-run against an
    # already-initialized repo.
    if [[ "$RESTIC_OK" != "true" \
      && "$MIGRATE_FROM_HOST_NATIVE_THIS_RUN" != "true" \
      && -f "$SCRIPT_DIR/setup-restic.sh" ]]; then
      info "Retrying restic setup now that the exit node is active..."
      if bash "$SCRIPT_DIR/setup-restic.sh"; then
        RESTIC_OK="true"
      else
        error "Restic setup failed even with the exit node active. Run setup-restic.sh manually and check S3 reachability."
      fi
    fi
  else
    warn "Skipped exit-node routing. Internet keeps using the direct path."
    warn "Apply later with: sudo tailscale set --exit-node='$USE_EXIT_NODE' --exit-node-allow-lan-access=true"
  fi
elif [[ "$ROLE" == "client" && -z "$USE_EXIT_NODE" ]]; then
  warn "Client role selected but no --use-exit-node given."
  warn "This node will have Tailscale but no forced exit-node routing."
fi

# ---------- 9. Addon dispatch (after core is complete) ----------------------
# Addons are explicit opt-ins (--beszel-agent, --install-restic-host-native).
# Core safety — Tailscale, UFW, lobaro container, exit-node routing — has
# already converged above; an addon failure here aborts the bootstrap run
# but does NOT roll back the lobaro container, firewall, or Tailscale state.
# Re-run with the same flags after fixing the underlying issue.
#
# Each addon installer is responsible for its own INSTALL_* flag persistence
# (validate → atomic write → start → verify running → only then persist).
# bootstrap.sh only dispatches and surfaces failures.
dispatch_addon() {
  local addon_path="$1" addon_label="$2"
  if [[ ! -r "$addon_path" ]]; then
    error "Addon installer is missing: $addon_path"
  fi
  info "Dispatching addon: $addon_label ($addon_path)"
  if ! bash "$addon_path"; then
    error "Addon '$addon_label' failed. Core bootstrap succeeded; the failed addon did not roll back core state. Re-run with the same opt-in flag after fixing the issue."
  fi
  INSTALL_BESZEL_AGENT="${PERSISTED_INSTALL_BESZEL_AGENT:-false}"
  # Reload the persisted state so the final-notes block sees the freshly-
  # written INSTALL_* flag(s) without needing a second read pass.
  if [[ -f "$NODE_ENV_FILE" ]] && [[ "$LIB_LOADED" != "true" ]]; then
    # lib.sh is already sourced at the top; nothing to do.
    :
  fi
}

if [[ "$BESZEL_AGENT_REQUESTED_THIS_RUN" == "true" ]]; then
  dispatch_addon "$BESZEL_ADDON" "beszel-agent"
fi
if [[ "${RESTIC_HOST_NATIVE_REQUESTED_THIS_RUN:-false}" == "true" ]]; then
  dispatch_addon "$RESTIC_HOST_NATIVE_ADDON" "restic-host-native"
fi

# ---------- 10. Final notes ----------
cat <<EOF

=============================================================================
 Bootstrap complete
=============================================================================

Node role   : $ROLE
Node name   : $NODE_NAME
Stacks dir  : /opt/stacks
Restic conf : /etc/restic/
Node state  : $NODE_ENV_FILE
Tailscale IP: /opt/homelab/env-file/tailscale.env  (single source of truth)
Health check: /opt/stacks/_backup/check-node.sh (exit code != 0 means problems)

Next steps:
  1. Run health check:
       sudo /opt/stacks/_backup/check-node.sh
  2. The lobaro container schedules its own backups (UTC, spread per-node).
     To force a manual run:
       sudo docker exec restic-backup /bin/backup
  3. Check snapshots:
       sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots'
  4. (Server + exit-node) Approve the exit node in the Tailscale admin console
  5. (Client) Verify internet works through the exit node:
       curl -4 ifconfig.me
       # Public IP should be the exit node's public IP
  6. Consider removing public SSH later if you kept it open:
       sudo $0 --no-public-ssh   # after confirming Tailscale SSH works

EOF
if [[ "$INSTALL_BESZEL_AGENT" == "true" ]]; then
  cat <<EOF
Beszel agent:
   sudo docker compose --env-file /opt/stacks/beszel-agent/.env \\
     -f /opt/stacks/beszel-agent/docker-compose.yml ps
  Confirm the agent appears healthy in the manually managed Beszel hub UI.

EOF
fi
cat <<EOF

NOTE: Docker published ports BYPASS UFW. When exposing services, bind them to
127.0.0.1 or this node's Tailscale IP, or put them behind Cloudflare Tunnel.
check-node.sh will warn you about 0.0.0.0-published ports.

Log saved to: $LOG_FILE
=============================================================================
EOF
