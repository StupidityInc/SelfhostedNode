#!/bin/bash
set -euo pipefail

# Homelab restic backup script
# Backs up the entire /opt/stacks/ tree to an S3-compatible repository.
# Designed to be self-contained and portable with the stacks.
#
# Node identity comes from /etc/homelab/node.env (written by bootstrap.sh) –
# this file is installed verbatim and NEVER rewritten per node.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "$SCRIPT_DIR/lib.sh" ]]; then
  echo "ERROR: lib.sh is required next to backup.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ $EUID -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo -n"
fi

# ---------- Node identity ----------
NODE_NAME=""
if [[ -f /etc/homelab/node.env ]]; then
  if ! homelab_load_kv_sudo "$SUDO" /etc/homelab/node.env NODE_NAME; then
    echo "ERROR: cannot read /etc/homelab/node.env (run this script with sudo)" >&2
    exit 1
  fi
fi
NODE_NAME="${NODE_NAME:-}"
if [[ -z "$NODE_NAME" ]]; then
  echo "ERROR: NODE_NAME unknown (/etc/homelab/node.env missing or incomplete)." >&2
  echo "Re-run bootstrap.sh once to persist node identity. Refusing to back up" >&2
  echo "with an unknown tag: the tag also drives 'restic forget --tag', so a" >&2
  echo "silently-changing tag would strand old snapshots forever." >&2
  exit 1
fi
TAG="$NODE_NAME"

# ---------- Credentials and repository settings ----------
if ! $SUDO test -r /etc/restic/env 2>/dev/null; then
  echo "ERROR: /etc/restic/env not found or not readable (run this script with sudo)" >&2
  exit 1
fi

AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_DEFAULT_REGION=""
RESTIC_REPOSITORY=""
RESTIC_PASSWORD_FILE=""
RESTIC_CACHE_DIR=""
if ! homelab_load_kv_sudo "$SUDO" /etc/restic/env "${HOMELAB_RESTIC_ENV_KEYS[@]}"; then
  echo "ERROR: cannot read /etc/restic/env (run this script with sudo)" >&2
  exit 1
fi
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR

if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
  echo "ERROR: RESTIC_REPOSITORY is not set" >&2
  exit 1
fi

# Writable cache even under systemd sandboxing (ProtectHome/ProtectSystem)
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"

# ---------- Mutual exclusion with timer/manual runs and password rotation ----------
LOCK_DIR="/run/restic"
if ! mkdir -p "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: cannot create $LOCK_DIR (run this script with sudo)" >&2
  exit 1
fi
exec 9>"$LOCK_DIR/backup.lock"
if ! flock -n 9; then
  echo "ERROR: another backup or password rotation is in progress ($LOCK_DIR/backup.lock)" >&2
  exit 1
fi

echo "=== restic backup started at $(date -Is) ==="
echo "Node: $NODE_NAME"
echo "Repository: $RESTIC_REPOSITORY"

# Optional: run any pre-backup hooks that services may drop here later
shopt -s nullglob
if [[ -d /opt/stacks/_backup/pre ]]; then
  for hook in /opt/stacks/_backup/pre/*.sh; do
    if [[ -x "$hook" ]]; then
      echo "Running pre-backup hook: $hook"
      "$hook"
    fi
  done
fi
shopt -u nullglob

# Backup the entire stacks tree
restic backup /opt/stacks \
  --tag "$TAG" \
  --exclude-caches \
  --verbose

echo "=== Applying retention policy ==="
restic forget \
  --tag "$TAG" \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune

echo "=== Backup finished at $(date -Is) ==="
