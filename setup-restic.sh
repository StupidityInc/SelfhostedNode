#!/bin/bash
set -euo pipefail

# One-time (or re-runnable) setup helper for restic on a homelab node.
# Designed to be called from bootstrap.sh or run standalone.
# Secrets end up in /etc/restic/ (mode 600/700). They are NEVER stored inside /opt/stacks.
#
# Safety properties:
#   - /etc/restic/env is written with printf (no shell-expansion mangling of
#     secrets containing $, backticks, etc.)
#   - A freshly generated repository password must be typed back by the
#     operator BEFORE anything is written or the repository is initialized.
#   - Re-runs keep existing password/env by default (idempotent).
#   - Optional second recovery key (stored offline by the operator only).

echo "=== restic + S3-compatible backup setup ==="
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "$SCRIPT_DIR/lib.sh" ]]; then
  echo "ERROR: lib.sh is required next to setup-restic.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

NONINTERACTIVE="${HOMELAB_NONINTERACTIVE:-0}"
is_interactive() { [[ "$NONINTERACTIVE" != "1" && -t 0 ]]; }

if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
  command -v sudo >/dev/null || { echo "ERROR: needs root or sudo" >&2; exit 1; }
fi

# Run restic as root with the on-disk env. Going through the FILE (not
# inherited environment) makes this robust against sudo env stripping.
run_restic() {
  # lib.sh parses KEY=VALUE without evaluating secret contents.
  $SUDO bash -c 'source "$1"; homelab_load_restic_env /etc/restic/env; exec restic "${@:2}"' _ "$SCRIPT_DIR/lib.sh" "$@"
}

GENERIC_NODE_NAMES="ubuntu debian localhost server client homelab node vps host linux default unknown"
validate_node_name() {
  local name="$1" g
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1
  for g in $GENERIC_NODE_NAMES; do [[ "$name" == "$g" ]] && return 1; done
  return 0
}

# ---------- Node name: explicit, validated, never silently defaulted ----------
REQUESTED_NODE_NAME="$(printf '%s' "${NODE_NAME:-}" | tr '[:upper:]' '[:lower:]')"
PERSISTED_NODE_NAME=""
if [[ -f /etc/homelab/node.env ]]; then
  NODE_NAME=""
  if ! homelab_load_kv_sudo "$SUDO" /etc/homelab/node.env NODE_NAME; then
    echo "ERROR: cannot read /etc/homelab/node.env" >&2
    exit 1
  fi
  PERSISTED_NODE_NAME="$(printf '%s' "$NODE_NAME" | tr '[:upper:]' '[:lower:]')"
  if [[ -n "$REQUESTED_NODE_NAME" && "$REQUESTED_NODE_NAME" != "$PERSISTED_NODE_NAME" ]]; then
    echo "ERROR: NODE_NAME '$REQUESTED_NODE_NAME' conflicts with persisted node identity '$PERSISTED_NODE_NAME'." >&2
    echo "Refusing to change the restic tag and retention identity." >&2
    exit 1
  fi
fi
NODE_NAME="${REQUESTED_NODE_NAME:-$PERSISTED_NODE_NAME}"
if [[ -z "$NODE_NAME" ]]; then
  if is_interactive; then
    suggestion="$(hostname -s | tr '[:upper:]' '[:lower:]')"
    read -r -p "Node name / repository prefix (suggestion: '$suggestion'): " input_name
    NODE_NAME="$(printf '%s' "${input_name:-$suggestion}" | tr '[:upper:]' '[:lower:]')"
  else
    echo "ERROR: NODE_NAME is required (export NODE_NAME or run bootstrap.sh first)." >&2
    exit 1
  fi
fi
if ! validate_node_name "$NODE_NAME"; then
  echo "ERROR: invalid or too-generic node name: '$NODE_NAME'" >&2
  exit 1
fi

# ---------- Configuration ----------
S3_ENDPOINT="${S3_ENDPOINT:-}"
BUCKET="${BUCKET:-}"
PREFIX="${PREFIX:-$NODE_NAME}"
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

CREDS_GIVEN="false"
if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" && -n "$BUCKET" && -n "$S3_ENDPOINT" ]]; then
  CREDS_GIVEN="true"
fi

EXISTING_CONFIG="false"
if $SUDO test -f /etc/restic/env && $SUDO test -f /etc/restic/password; then
  EXISTING_CONFIG="true"
fi

REUSE_EXISTING="false"
if [[ "$EXISTING_CONFIG" == "true" && "$CREDS_GIVEN" == "false" ]]; then
  if is_interactive; then
    read -r -p "Existing restic configuration found in /etc/restic – keep it? [Y/n] " reply
    if [[ ! "$reply" =~ ^[Nn]$ ]]; then
      REUSE_EXISTING="true"
    fi
  else
    REUSE_EXISTING="true"
    echo "Non-interactive: keeping existing /etc/restic configuration."
  fi
fi

if [[ "$REUSE_EXISTING" == "false" ]]; then
  # ---------- Interactive collection if missing ----------
  if [[ "$CREDS_GIVEN" == "false" ]]; then
    if ! is_interactive; then
      echo "ERROR: S3 credentials required in non-interactive mode." >&2
      echo "Export: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_ENDPOINT, BUCKET (and NODE_NAME)." >&2
      exit 1
    fi
    echo "S3 credentials and bucket are required."
    echo "You can also pre-set them via environment variables:"
    echo "  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_ENDPOINT, BUCKET, NODE_NAME"
    echo
    read -r -p "S3 Endpoint (e.g. https://xxxx.r2.cloudflarestorage.com): " S3_ENDPOINT
    read -r -p "Bucket name: " BUCKET
    read -r -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID
    read -r -s -p "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
    echo
    PREFIX="$NODE_NAME"
  fi

  echo
  echo "Configuration summary"
  echo "  Node / prefix : $NODE_NAME"
  echo "  Endpoint      : $S3_ENDPOINT"
  echo "  Bucket        : $BUCKET"
  echo "  Prefix        : $PREFIX"
  echo

  if is_interactive; then
    read -r -p "Continue with this configuration? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
fi

# ---------- Install restic + openssl if needed ----------
if ! command -v restic >/dev/null 2>&1; then
  echo "Installing restic..."
  $SUDO apt-get update -qq
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y restic
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "Installing openssl (needed for password generation)..."
  $SUDO apt-get update -qq
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
fi
restic version

# ---------- Secrets directory + cache directory ----------
$SUDO mkdir -p /etc/restic /var/cache/restic
$SUDO chmod 700 /etc/restic /var/cache/restic

if [[ "$REUSE_EXISTING" == "true" ]]; then
  RESTIC_REPOSITORY=""
  homelab_load_kv_sudo "$SUDO" /etc/restic/env RESTIC_REPOSITORY
  REPO="$RESTIC_REPOSITORY"
  echo "Keeping existing /etc/restic/env and /etc/restic/password."
  echo "Repository: $REPO"
else
  # ---------- Repository password ----------
  if $SUDO test -f /etc/restic/password; then
    echo "Existing /etc/restic/password found – keeping it (env file will be rewritten around it)."
  else
    PASSWORD="${RESTIC_PASSWORD:-}"
    if [[ -z "$PASSWORD" ]]; then
      echo
      echo "Generating a strong restic repository password..."
      # 32 bytes → ~43 char base64
      PASSWORD="$(openssl rand -base64 32)"
      echo
      echo "IMPORTANT: This password encrypts the entire backup repository."
      echo "Save it in your password manager NOW:"
      echo "----------------------------------------"
      echo "$PASSWORD"
      echo "----------------------------------------"
      echo
      if is_interactive; then
        read -r -s -p "Type/paste the password back to prove you saved it: " CONFIRM
        echo
        if [[ "$CONFIRM" != "$PASSWORD" ]]; then
          echo "ERROR: mismatch. Aborting BEFORE writing anything or touching the repository." >&2
          echo "Nothing was changed. Re-run this script to try again." >&2
          exit 1
        fi
      else
        echo "WARNING: non-interactive mode – the password above is your only offline copy."
        echo "         Store it securely. (Or provide RESTIC_PASSWORD via environment instead.)"
      fi
    fi
    printf '%s\n' "$PASSWORD" | $SUDO tee /etc/restic/password >/dev/null
    $SUDO chmod 600 /etc/restic/password
    unset PASSWORD
  fi

  # ---------- Environment file (safe quoting, no shell expansion of secret content) ----------
  REPO="s3:${S3_ENDPOINT}/${BUCKET}/${PREFIX}"

  ENV_TMP="$($SUDO mktemp /etc/restic/.env.XXXXXX)"
  {
    homelab_format_kv AWS_ACCESS_KEY_ID "$AWS_ACCESS_KEY_ID"
    homelab_format_kv AWS_SECRET_ACCESS_KEY "$AWS_SECRET_ACCESS_KEY"
    homelab_format_kv AWS_DEFAULT_REGION "${AWS_DEFAULT_REGION:-auto}"
    homelab_format_kv RESTIC_REPOSITORY "$REPO"
    homelab_format_kv RESTIC_PASSWORD_FILE /etc/restic/password
    homelab_format_kv RESTIC_CACHE_DIR /var/cache/restic
  } | $SUDO tee "$ENV_TMP" >/dev/null

  $SUDO chmod 600 "$ENV_TMP"
  $SUDO mv "$ENV_TMP" /etc/restic/env

  echo "Wrote /etc/restic/env"
  echo "Repository string: $REPO"
fi

# ---------- Initialize repository ----------
echo
echo "Checking repository (initializing if needed)..."
if run_restic cat config >/dev/null 2>&1; then
  echo "Repository already initialized."
else
  if ! run_restic init; then
    echo "ERROR: repository init failed (network path? credentials? endpoint?)." >&2
    echo "If S3 is only reachable via a Tailscale exit node, enable that first and re-run." >&2
    exit 1
  fi
  echo "Repository initialized successfully."
fi

# ---------- Optional: second recovery key ----------
# Interactive setup generates and confirms a key. Non-interactive setup accepts
# RESTIC_RECOVERY_PASSWORD or RESTIC_RECOVERY_PASSWORD_FILE so automation can
# supply a key that the operator already stored offline. Only a marker is kept
# on the node; the recovery secret never is.
record_recovery_key() {
  local marker_tmp
  marker_tmp="$($SUDO mktemp /etc/restic/.recovery-key.present.XXXXXX)"
  {
    printf 'RECOVERY_KEY_PRESENT=true\n'
    printf 'RECORDED_AT=%s\n' "$(date -Is)"
  } | $SUDO tee "$marker_tmp" >/dev/null
  $SUDO chmod 600 "$marker_tmp"
  $SUDO mv "$marker_tmp" "$HOMELAB_RECOVERY_KEY_MARKER"
}

RECOVERY=""
RECOVERY_REQUESTED="false"
if [[ -n "${RESTIC_RECOVERY_PASSWORD:-}" ]]; then
  RECOVERY="$RESTIC_RECOVERY_PASSWORD"
  RECOVERY_REQUESTED="true"
elif [[ -n "${RESTIC_RECOVERY_PASSWORD_FILE:-}" ]]; then
  if ! $SUDO test -r "$RESTIC_RECOVERY_PASSWORD_FILE"; then
    echo "ERROR: RESTIC_RECOVERY_PASSWORD_FILE is not readable." >&2
    exit 1
  fi
  RECOVERY="$($SUDO cat "$RESTIC_RECOVERY_PASSWORD_FILE")"
  RECOVERY_REQUESTED="true"
elif ! $SUDO test -f "$HOMELAB_RECOVERY_KEY_MARKER" && is_interactive; then
  echo
  echo "Optional: add a second RECOVERY key to the repository."
  echo "It is shown once and NEVER stored on this node. Save it offline (password manager)."
  echo "It survives password rotation and can rescue the repo if /etc/restic/password is lost."
  read -r -p "Add a recovery key now? [y/N] " rk_reply
  if [[ "$rk_reply" =~ ^[Yy]$ ]]; then
    RECOVERY="$(openssl rand -base64 32)"
    echo "----------------------------------------"
    echo "$RECOVERY"
    echo "----------------------------------------"
    read -r -s -p "Type/paste the recovery password back to prove you saved it: " RK_CONFIRM
    echo
    if [[ "$RK_CONFIRM" != "$RECOVERY" ]]; then
      echo "Mismatch – skipping recovery key (repository unchanged)."
      RECOVERY=""
    else
      RECOVERY_REQUESTED="true"
    fi
    unset RK_CONFIRM
  fi
fi

if [[ "$RECOVERY_REQUESTED" == "true" ]]; then
  if $SUDO test -f "$HOMELAB_RECOVERY_KEY_MARKER"; then
    echo "A recovery-key marker already exists; leaving the repository keys unchanged."
  elif [[ "$RECOVERY" == *$'\n'* || -z "$RECOVERY" ]]; then
    echo "ERROR: recovery password must be non-empty and single-line." >&2
    exit 1
  elif restic key add --help 2>&1 | grep -q -- '--new-password-file'; then
    TMPRK="$($SUDO mktemp /etc/restic/.recovery-key.XXXXXX)"
    printf '%s\n' "$RECOVERY" | $SUDO tee "$TMPRK" >/dev/null
    $SUDO chmod 600 "$TMPRK"
    if run_restic key add --new-password-file="$TMPRK" >/dev/null; then
      record_recovery_key
      echo "Recovery key added. It exists ONLY in your password manager."
    else
      echo "WARNING: adding recovery key failed; no recovery marker was recorded." >&2
    fi
    $SUDO rm -f "$TMPRK"
  elif [[ "$NONINTERACTIVE" == "1" ]]; then
    echo "ERROR: this restic version lacks --new-password-file; cannot add a recovery key non-interactively." >&2
    exit 1
  else
    echo "(this restic version lacks --new-password-file; falling back to interactive prompt)"
    echo "Enter the recovery password shown above when prompted:"
    if run_restic key add; then
      record_recovery_key
      echo "Recovery key added. It exists ONLY in your password manager."
    else
      echo "WARNING: adding recovery key failed; no recovery marker was recorded." >&2
    fi
  fi
  unset RECOVERY
elif ! $SUDO test -f "$HOMELAB_RECOVERY_KEY_MARKER"; then
  echo "WARNING: no recovery-key marker exists. Set RESTIC_RECOVERY_PASSWORD_FILE on a later run before rotating the main password."
fi

# ---------- Install backup script + systemd units ----------
echo
echo "Installing backup script and systemd units..."

$SUDO mkdir -p /opt/stacks/_backup/pre

if [[ -f "$SCRIPT_DIR/backup.sh" ]]; then
  # Installed verbatim: backup.sh reads NODE_NAME from /etc/homelab/node.env.
  $SUDO cp "$SCRIPT_DIR/backup.sh" /opt/stacks/_backup/backup.sh
  $SUDO chmod 700 /opt/stacks/_backup/backup.sh
else
  echo "WARNING: backup.sh not found next to this script."
fi

if [[ -f "$SCRIPT_DIR/lib.sh" ]]; then
  $SUDO cp "$SCRIPT_DIR/lib.sh" /opt/stacks/_backup/lib.sh
  $SUDO chmod 644 /opt/stacks/_backup/lib.sh
fi

if [[ -f "$SCRIPT_DIR/restic-backup.service" ]]; then
  $SUDO cp "$SCRIPT_DIR/restic-backup.service" /etc/systemd/system/
fi
if [[ -f "$SCRIPT_DIR/restic-backup.timer" ]]; then
  $SUDO cp "$SCRIPT_DIR/restic-backup.timer" /etc/systemd/system/
fi

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now restic-backup.timer

echo
echo "Timer status:"
$SUDO systemctl list-timers restic-backup.timer --no-pager 2>/dev/null || true

echo
echo "=== Restic setup complete ==="
echo "Next steps:"
echo "  1. Manual backup:  sudo /opt/stacks/_backup/backup.sh"
echo "  2. List snapshots: sudo /opt/stacks/_backup/check-node.sh  (or: sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots')"
echo "  3. Timer is enabled and running (daily ~03:00 + stable per-node random offset)"
echo
echo "The repository password lives only in /etc/restic/password and your password manager."
echo "To rotate it later:        sudo /opt/stacks/_backup/change-restic-password.sh"
echo "To add a recovery key:     sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic key add'"
