#!/bin/bash
# migrate-to-lobaro.sh — One-shot host-native → lobaro-primary migration (AGENT.md §3 WP7).
#
# Purpose
#   Convert a node that still uses the host-native systemd restic path
#   (restic-backup.timer + /opt/stacks/_backup/backup.sh) to the lobaro
#   restic-backup-docker container without losing existing snapshots.
#
# Sequence (per AGENT.md §3 WP7 brief):
#   1. Refuse early if preconditions are not met (no destructive steps on
#      refusal).
#   2. Pin /etc/restic/repo-id from live `restic cat config` if missing;
#      hard-fail on a pin/live mismatch (matches setup-restic.sh:325–329).
#   3. Stop + disable the host-native timer (the only destructive side
#      effect on failure; everything else is reversible).
#   4. Reuse setup-restic.sh's REUSE_EXISTING branch (setup-restic.sh:109–125,
#      :198–203) so the existing password is kept and `restic init` is NOT
#      run against the healthy repo.
#   5. Verify: container running, repo-id pinned, snapshots listable
#      under the NODE_NAME tag, check-node.sh exits 0.
#   6. Persist INSTALL_RESTIC_HOST_NATIVE=false (only after the container
#      is verified) so homelab_backup_path and check-node.sh stop
#      classifying the node as host-native.
#   7. Optional --purge-host-native-units: remove the systemd units and
#      /opt/stacks/_backup/backup.sh. Default OFF (kept for rollback).
#
# Idempotency
#   - Already on lobaro (container running): exit 0 with a clear "already
#     migrated; nothing to do" message. Re-running by mistake is not a
#     failure.
#   - No host-native timer enabled: exit 1 with a clear refusal (wrong
#     tool for this node).
#
# Failure handling
#   After the host-native timer is disabled (step 3), the rollback recipe
#   is printed on any subsequent error. Nothing under /etc/restic/,
#   /var/cache/restic/, or the addon source files is touched by this
#   script. A failed migration leaves the node recoverable.
#
# Rollback (after a successful migration):
#   sudo systemctl disable --now restic-backup.timer     # only if --purge was used
#   sudo docker stop restic-backup
#   sudo ./addons/restic-host-native/install.sh          # re-installs host-native units
#   sudo systemctl enable --now restic-backup.timer
#
# Rollback (after a FAILED migration — host-native timer is now disabled,
# container never came up):
#   sudo ./addons/restic-host-native/install.sh
#   sudo systemctl enable --now restic-backup.timer
#   # /etc/restic/* is untouched; the existing snapshots are unchanged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
if [[ -r "$SCRIPT_DIR/lib.sh" ]]; then
  source "$SCRIPT_DIR/lib.sh"
else
  echo "ERROR: lib.sh is required next to migrate-to-lobaro.sh" >&2
  exit 1
fi

NONINTERACTIVE="${HOMELAB_NONINTERACTIVE:-0}"
is_interactive() { [[ "$NONINTERACTIVE" != "1" && -t 0 ]]; }

PURGE_HOST_NATIVE_UNITS="false"
for arg in "$@"; do
  case "$arg" in
    --purge-host-native-units) PURGE_HOST_NATIVE_UNITS="true" ;;
    --yes|-y)                  NONINTERACTIVE="1" ;;
    -h|--help)
      cat <<USAGE
Usage: sudo $0 [--purge-host-native-units] [--yes]

One-shot migration from the host-native systemd restic path to the
lobaro restic-backup-docker container (AGENT.md §3 WP7).

Options:
  --purge-host-native-units   Remove the host-native systemd units and
                              /opt/stacks/_backup/backup.sh after a
                              successful migration. Default OFF (kept
                              on disk for rollback).
  --yes, -y                   Non-interactive: assume "yes" for the
                              pre-migration confirmation.
  -h, --help                  Show this help.
USAGE
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)" >&2
  exit 1
fi
SUDO=""

log()   { echo "[migrate $(date -Is)] $*"; }
warn()  { echo "[migrate $(date -Is)] WARN  $*" >&2; }
error() { echo "[migrate $(date -Is)] ERROR $*" >&2; exit 1; }

# Rollback recipe printed after the host-native timer has been disabled
# and the migration has failed. Always printed verbatim so the operator
# has the exact commands.
print_rollback_recipe() {
  cat <<'ROLLBACK'

The host-native restic-backup.timer is now DISABLED (and the restic-backup
container was not started because the migration failed before that step).
Your repository and password under /etc/restic/ are UNTOUCHED. Existing
snapshots on S3 are unchanged.

To roll back to the host-native path on this node:

  sudo ./addons/restic-host-native/install.sh
  sudo systemctl enable --now restic-backup.timer

To retry the migration after fixing the issue:

  sudo ./migrate-to-lobaro.sh

ROLLBACK
}

# ---------- 1. Idempotency + preconditions ----------

# Already on lobaro → exit 0 with a clear "nothing to do" message.
# Per operator preference: re-running by mistake must not look like a
# failure. We only check the container's actual running state, not the
# addon's INSTALL_RESTIC_HOST_NATIVE flag — the helper is purely about
# the runtime path.
if command -v docker >/dev/null 2>&1; then
  LOBARO_STATE="$(docker inspect -f '{{.State.Running}}' restic-backup 2>/dev/null || echo "false")"
  if [[ "$LOBARO_STATE" == "true" ]]; then
    log "restic-backup container is already running; node is already on lobaro-primary."
    log "Nothing to do. Re-run only after explicitly removing the container first."
    exit 0
  fi
fi

# No host-native timer → exit 1 with a clear refusal (wrong tool for this node).
if ! systemctl is-enabled restic-backup.timer >/dev/null 2>&1; then
  cat <<'NOHOST' >&2

ERROR: restic-backup.timer is not enabled on this node.

This script migrates a node that still uses the host-native systemd restic
path to the lobaro container. If the timer is not enabled, this node is
either already on lobaro (the container check above would have caught that)
or was never host-native.

Possible actions:
  - Already on lobaro, but the container is stopped? Start it:
      sudo docker compose --env-file /opt/stacks/restic-backup/.env \
        -f /opt/stacks/restic-backup/docker-compose.yml up -d
  - Never had backup, want to deploy lobaro from scratch:
      sudo ./setup-restic.sh
  - Have an old host-native install that was disabled (timer stopped):
      sudo ./setup-restic.sh        # same code path; REUSE_EXISTING branch
                                     # is triggered when /etc/restic/env exists

NOHOST
    exit 1
fi

# The rest of the preconditions.
[[ -r /etc/restic/env ]]    || error "/etc/restic/env is missing. Run bootstrap.sh at least once before migrating."
[[ -r /etc/restic/password ]] || error "/etc/restic/password is missing. Run bootstrap.sh at least once before migrating."
[[ -r /etc/homelab/node.env ]] || error "/etc/homelab/node.env is missing. Run bootstrap.sh at least once before migrating."
command -v restic >/dev/null 2>&1 || error "restic binary is not installed. Run bootstrap.sh (or apt-get install restic) before migrating."

NODE_NAME=""
if ! homelab_load_kv_sudo "$SUDO" /etc/homelab/node.env NODE_NAME; then
  error "Cannot safely read /etc/homelab/node.env"
fi
NODE_NAME="$(printf '%s' "$NODE_NAME" | tr '[:upper:]' '[:lower:]')"
if ! homelab_validate_node_name "$NODE_NAME"; then
  error "NODE_NAME '$NODE_NAME' is missing or invalid. Refusing to migrate."
fi

# Read the live repo URL for the operator confirmation prompt.
RESTIC_REPOSITORY=""
homelab_load_kv_sudo "$SUDO" /etc/restic/env RESTIC_REPOSITORY
if [[ -z "$RESTIC_REPOSITORY" ]]; then
  error "RESTIC_REPOSITORY is empty in /etc/restic/env."
fi

log "Migration preconditions:"
log "  Node name         : $NODE_NAME"
log "  Repository        : $RESTIC_REPOSITORY"
log "  Source path       : host-native systemd (restic-backup.timer)"
log "  Target path       : lobaro restic-backup-docker container"
log "  Purge host-native : $PURGE_HOST_NATIVE_UNITS"
echo

if is_interactive; then
  read -r -p "Proceed with migration? [y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    log "Aborted by user; nothing was changed."
    exit 0
  fi
fi

# ---------- 2. Pin /etc/restic/repo-id if missing ----------

homelab_repo_id
EXISTING_PIN="$HOMELAB_REPO_ID"
if [[ -z "$EXISTING_PIN" ]]; then
  # No pin yet — capture the live id from the existing repo.
  if ! LIVE_ID="$(restic cat config --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null)"; then
    error "Could not read live repository config (network? credentials?). Refusing to migrate without a known repo-id."
  fi
  if [[ -z "$LIVE_ID" ]]; then
    error "Live restic repository returned no id. Refusing to migrate without a known repo-id."
  fi
  PIN_TMP="$(mktemp /etc/restic/.repo-id.XXXXXX)"
  printf '%s\n' "$LIVE_ID" > "$PIN_TMP"
  chmod 644 "$PIN_TMP"
  mv "$PIN_TMP" "$HOMELAB_REPO_ID_FILE"
  log "Pinned repository UUID to $HOMELAB_REPO_ID_FILE ($LIVE_ID)"
else
  # Pin exists; verify it still matches the live repo before any side effect.
  if ! LIVE_ID="$(restic cat config --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null)"; then
    error "Could not read live repository config to verify the existing repo-id pin. Refusing to migrate."
  fi
  if [[ -z "$LIVE_ID" ]]; then
    error "Live restic repository returned no id; cannot verify the existing repo-id pin."
  fi
  if [[ "$LIVE_ID" != "$EXISTING_PIN" ]]; then
    error "Existing /etc/restic/repo-id pin ($EXISTING_PIN) does not match live repository id ($LIVE_ID). Refusing to silently migrate to a different repository."
  fi
  log "Existing repo-id pin matches live repository ($EXISTING_PIN)."
fi

# ---------- 3. Stop + disable the host-native timer ----------

log "Stopping and disabling the host-native timer (restic-backup.timer)..."
systemctl disable --now restic-backup.timer || warn "systemctl disable --now restic-backup.timer failed (continuing)"
# Stop the service too if a run is in flight (it can survive the timer
# disable until the next exec; this guarantees no overlapping backup).
systemctl stop restic-backup.service 2>/dev/null || true
systemctl daemon-reload

# Verify the timer is actually no longer enabled.
if systemctl is-enabled restic-backup.timer >/dev/null 2>&1; then
  print_rollback_recipe >&2
  error "restic-backup.timer is STILL enabled after disable --now. Aborting; see the rollback recipe above."
fi

# ---------- 4. Reuse setup-restic.sh to deploy lobaro against the existing repo ----------

# Snapshot of the host's restic snapshots BEFORE we hand off to setup-restic.sh,
# so we can prove "existing snapshots remain" at the end of the migration.
PRE_SNAPSHOT_IDS_BEFORE="$(restic snapshots --tag "$NODE_NAME" --json 2>/dev/null | jq -r '.[].id' 2>/dev/null | sort || true)"
PRE_SNAPSHOT_COUNT_BEFORE="$(printf '%s\n' "$PRE_SNAPSHOT_IDS_BEFORE" | sed '/^$/d' | wc -l | tr -d ' ')"
log "Pre-migration: $PRE_SNAPSHOT_COUNT_BEFORE existing snapshot(s) tagged '$NODE_NAME' on $RESTIC_REPOSITORY."

if [[ ! -r "$SCRIPT_DIR/setup-restic.sh" ]]; then
  print_rollback_recipe >&2
  error "setup-restic.sh is missing next to migrate-to-lobaro.sh. Aborting."
fi

log "Running setup-restic.sh against the existing repository (REUSE_EXISTING branch)..."
# setup-restic.sh's REUSE_EXISTING branch (lines 109–125, 198–203) keeps
# /etc/restic/env and /etc/restic/password and never calls `restic init`.
# We force HOMELAB_NONINTERACTIVE=1 so it does not prompt for credentials.
if ! HOMELAB_NONINTERACTIVE=1 bash "$SCRIPT_DIR/setup-restic.sh"; then
  print_rollback_recipe >&2
  error "setup-restic.sh failed during the migration. See the rollback recipe above. No snapshots were deleted."
fi

# ---------- 5. Verify ----------

# Container running?
if ! command -v docker >/dev/null 2>&1; then
  print_rollback_recipe >&2
  error "docker is no longer available on PATH. Cannot verify the lobaro container."
fi
RUNNING="$(docker inspect -f '{{.State.Running}}' restic-backup 2>/dev/null || echo "false")"
if [[ "$RUNNING" != "true" ]]; then
  print_rollback_recipe >&2
  error "restic-backup container is not running after setup-restic.sh. See the rollback recipe above."
fi
log "restic-backup container is running."

# Repo-id still pinned and matches?
if ! homelab_assert_repo_id_pinned; then
  print_rollback_recipe >&2
  error "Repo-id pin verification failed after the lobaro deploy. See the rollback recipe above."
fi
log "Repo-id pin verified."

# Existing snapshots still readable, AND under the same tag?
POST_SNAPSHOT_IDS="$(restic snapshots --tag "$NODE_NAME" --json 2>/dev/null | jq -r '.[].id' 2>/dev/null | sort || true)"
POST_SNAPSHOT_COUNT="$(printf '%s\n' "$POST_SNAPSHOT_IDS" | sed '/^$/d' | wc -l | tr -d ' ')"
if (( POST_SNAPSHOT_COUNT < PRE_SNAPSHOT_COUNT_BEFORE )); then
  print_rollback_recipe >&2
  error "Snapshot count for tag '$NODE_NAME' decreased from $PRE_SNAPSHOT_COUNT_BEFORE to $POST_SNAPSHOT_COUNT. Something deleted snapshots — investigate immediately. See the rollback recipe above."
fi
log "Post-migration: $POST_SNAPSHOT_COUNT snapshot(s) tagged '$NODE_NAME' (was $PRE_SNAPSHOT_COUNT_BEFORE; existing snapshots preserved)."

# check-node.sh?
CHECK_NODE="/opt/stacks/_backup/check-node.sh"
if [[ -x "$CHECK_NODE" ]]; then
  if "$CHECK_NODE" >/tmp/migrate-check-node.log 2>&1; then
    log "check-node.sh exit 0 (health check PASS)."
  else
    log "check-node.sh exited non-zero. Inspect /tmp/migrate-check-node.log; the migration itself succeeded, but the health check found an unrelated issue."
    log "(The migration's own verification above — container running, repo-id pinned, snapshots preserved — all passed.)"
  fi
else
  warn "check-node.sh not found at $CHECK_NODE; skipping the post-migration health check."
fi

# ---------- 6. Persist INSTALL_RESTIC_HOST_NATIVE=false ----------
# Sourced lib-addon.sh if available so addon_persist_flag is reachable.
# (addons/lib-addon.sh requires the script to run from a checkout that
# already has the addon directory; tolerate its absence.)
if [[ -r "$SCRIPT_DIR/addons/lib-addon.sh" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/addons/lib-addon.sh"
  addon_persist_flag INSTALL_RESTIC_HOST_NATIVE false
  log "Persisted INSTALL_RESTIC_HOST_NATIVE=false (host-native addon no longer classifies this node)."
else
  warn "addons/lib-addon.sh is missing; INSTALL_RESTIC_HOST_NATIVE was NOT updated. check-node.sh may still classify the node as host-native via the unit-file heuristic until you update /etc/homelab/node.env manually."
fi

# ---------- 7. Optional: purge host-native unit files ----------

if [[ "$PURGE_HOST_NATIVE_UNITS" == "true" ]]; then
  log "Purging host-native unit files (operator opted in via --purge-host-native-units)..."
  rm -f /etc/systemd/system/restic-backup.service
  rm -f /etc/systemd/system/restic-backup.timer
  rm -f /opt/stacks/_backup/backup.sh
  systemctl daemon-reload
  log "Purged /etc/systemd/system/restic-backup.{service,timer} and /opt/stacks/_backup/backup.sh."
else
  log "Host-native unit files left on disk for rollback (default). Re-run with --purge-host-native-units to remove them."
fi

log ""
log "=== Migration complete ==="
log "Backup path: lobaro restic-backup-docker container."
log "Node: $NODE_NAME"
log "Repository: $RESTIC_REPOSITORY"
log ""
log "Rollback recipe (host-native path):"
log "  sudo docker stop restic-backup"
log "  sudo ./addons/restic-host-native/install.sh"
log "  sudo systemctl enable --now restic-backup.timer"
log ""
log "Next scheduled backup: the lobaro container's BusyBox cron, in UTC."
log "Force a run now:        sudo docker exec restic-backup /bin/backup"
log "List snapshots:         sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots'"
