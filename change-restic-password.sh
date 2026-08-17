#!/bin/bash
set -euo pipefail

# Change the restic repository password for this node.
#
# Safe flow (the repository key and /etc/restic/password can never diverge):
#   1. Stop the backup timer and take the shared backup lock (no concurrent runs).
#   2. Generate/collect a new password; interactive runs require confirmation.
#   3. Write it to a TEMP file, run `restic key passwd --new-password-file=...`.
#   4. VERIFY the new password actually opens the repository.
#   5. Only then atomically replace /etc/restic/password.
# The timer is always restarted on exit, even on failure.

if [[ $EUID -ne 0 ]]; then
  echo "This script rewrites /etc/restic/password and needs root. Re-running via sudo..." >&2
  exec sudo bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -r "$SCRIPT_DIR/lib.sh" ]]; then
  echo "ERROR: lib.sh is required next to change-restic-password.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"

if [[ ! -f /etc/restic/env || ! -f /etc/restic/password ]]; then
  echo "ERROR: /etc/restic/env or /etc/restic/password missing – restic not configured?" >&2
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: openssl not installed (needed for password generation)." >&2
  echo "Install it with: sudo apt-get install -y openssl" >&2
  exit 1
fi

if ! restic key passwd --help 2>&1 | grep -q -- '--new-password-file'; then
  echo "ERROR: this restic version lacks 'key passwd --new-password-file'." >&2
  echo "Upgrade restic first (e.g. 'sudo restic self-update' or a newer package)." >&2
  exit 1
fi

homelab_load_restic_env /etc/restic/env

export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"

# Do not rotate the only known key. The marker says the operator recorded a
# recovery key; the repository key count confirms it still exists. We also
# verify that recovery key before changing the main password.
if ! homelab_recovery_key_recorded; then
  echo "ERROR: no recovery-key marker exists. Add and save a recovery key before rotating the main password." >&2
  exit 1
fi
KEY_COUNT="$(restic key list --json 2>/dev/null | jq -r 'length' 2>/dev/null || echo 0)"
if [[ ! "$KEY_COUNT" =~ ^[0-9]+$ ]] || (( KEY_COUNT < 2 )); then
  echo "ERROR: repository has fewer than two keys; refusing rotation without a verified recovery path." >&2
  exit 1
fi

RECOVERY_VERIFY_FILE=""
if [[ -n "${RESTIC_RECOVERY_PASSWORD_FILE:-}" ]]; then
  if [[ ! -r "$RESTIC_RECOVERY_PASSWORD_FILE" ]]; then
    echo "ERROR: RESTIC_RECOVERY_PASSWORD_FILE is not readable." >&2
    exit 1
  fi
  RECOVERY_VERIFY_FILE="$(mktemp /etc/restic/.recovery-verify.XXXXXX)"
  cat "$RESTIC_RECOVERY_PASSWORD_FILE" > "$RECOVERY_VERIFY_FILE"
elif [[ -n "${RESTIC_RECOVERY_PASSWORD:-}" ]]; then
  RECOVERY_VERIFY_FILE="$(mktemp /etc/restic/.recovery-verify.XXXXXX)"
  printf '%s\n' "$RESTIC_RECOVERY_PASSWORD" > "$RECOVERY_VERIFY_FILE"
elif [[ "${HOMELAB_NONINTERACTIVE:-0}" != "1" && -t 0 ]]; then
  RECOVERY_VERIFY_FILE="$(mktemp /etc/restic/.recovery-verify.XXXXXX)"
  chmod 600 "$RECOVERY_VERIFY_FILE"
  read -r -s -p "Enter the saved recovery password to verify it before rotation: " RECOVERY_VERIFY
  echo
  printf '%s\n' "$RECOVERY_VERIFY" > "$RECOVERY_VERIFY_FILE"
  unset RECOVERY_VERIFY
else
  echo "ERROR: non-interactive rotation requires RESTIC_RECOVERY_PASSWORD_FILE or RESTIC_RECOVERY_PASSWORD." >&2
  exit 1
fi
chmod 600 "$RECOVERY_VERIFY_FILE"
if ! RESTIC_PASSWORD= RESTIC_PASSWORD_FILE="$RECOVERY_VERIFY_FILE" restic cat config >/dev/null 2>&1; then
  rm -f "$RECOVERY_VERIFY_FILE"
  RECOVERY_VERIFY_FILE=""
  echo "ERROR: supplied recovery password does not open the repository; nothing was changed." >&2
  exit 1
fi
echo "Verified a recovery key before rotation."

# ---------- Stop the timer, guarantee restart via trap ----------
TIMER_WAS_ACTIVE="false"
TMPPASS=""
cleanup() {
  if [[ "$TIMER_WAS_ACTIVE" == "true" ]]; then
    systemctl start restic-backup.timer || echo "WARNING: could not restart restic-backup.timer" >&2
  fi
  if [[ -n "$TMPPASS" && -f "$TMPPASS" ]]; then
    rm -f "$TMPPASS"
  fi
  if [[ -n "$RECOVERY_VERIFY_FILE" && -f "$RECOVERY_VERIFY_FILE" ]]; then
    rm -f "$RECOVERY_VERIFY_FILE"
  fi
}
trap cleanup EXIT

if systemctl is-active --quiet restic-backup.timer; then
  TIMER_WAS_ACTIVE="true"
  systemctl stop restic-backup.timer
  echo "Stopped restic-backup.timer (will be restarted on exit)."
fi

if systemctl is-active --quiet restic-backup.service; then
  echo "ERROR: restic-backup.service is running right now. Wait for it to finish." >&2
  exit 1
fi

# ---------- Mutual exclusion with backup.sh ----------
LOCK_DIR="/run/restic"
mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/backup.lock"
if ! flock -n 9; then
  echo "ERROR: a backup is in progress ($LOCK_DIR/backup.lock held). Try again later." >&2
  exit 1
fi

echo "=== Change restic repository password ==="
echo "Repository: ${RESTIC_REPOSITORY:-<unset>}"
echo
echo "A new strong password will be generated. Save it in your password manager."
echo "NOTE: the old password stops working immediately after the key change."
echo "      (Any separate recovery key added with 'restic key add' keeps working.)"
echo

# ---------- Generate + confirm BEFORE touching anything ----------
if [[ -n "${RESTIC_NEW_PASSWORD_FILE:-}" ]]; then
  if [[ ! -r "$RESTIC_NEW_PASSWORD_FILE" ]]; then
    echo "ERROR: RESTIC_NEW_PASSWORD_FILE is not readable." >&2
    exit 1
  fi
  NEW_PASS="$(cat "$RESTIC_NEW_PASSWORD_FILE")"
elif [[ -n "${RESTIC_NEW_PASSWORD:-}" ]]; then
  NEW_PASS="$RESTIC_NEW_PASSWORD"
elif [[ "${HOMELAB_NONINTERACTIVE:-0}" != "1" && -t 0 ]]; then
  NEW_PASS="$(openssl rand -base64 32)"
  echo "----------------------------------------"
  echo "$NEW_PASS"
  echo "----------------------------------------"
  read -r -s -p "Type/paste the NEW password back to prove you saved it: " CONFIRM
  echo
  if [[ "$CONFIRM" != "$NEW_PASS" ]]; then
    echo "ERROR: mismatch. Nothing was changed (repository and on-disk file untouched)." >&2
    exit 1
  fi
else
  echo "ERROR: non-interactive rotation requires RESTIC_NEW_PASSWORD_FILE or RESTIC_NEW_PASSWORD." >&2
  exit 1
fi
if [[ -z "$NEW_PASS" || "$NEW_PASS" == *$'\n'* ]]; then
  echo "ERROR: new password must be non-empty and single-line." >&2
  exit 1
fi

# ---------- Temp file with new password (same filesystem for atomic mv) ----------
TMPPASS="$(mktemp /etc/restic/.password.new.XXXXXX)"
printf '%s\n' "$NEW_PASS" > "$TMPPASS"
chmod 600 "$TMPPASS"
unset NEW_PASS CONFIRM

# ---------- Change the repository key ----------
if ! restic key passwd --new-password-file="$TMPPASS"; then
  echo "ERROR: 'restic key passwd' failed – repository key UNCHANGED," >&2
  echo "       /etc/restic/password UNCHANGED. Nothing diverged." >&2
  exit 1
fi

# ---------- Verify the new password BEFORE replacing the on-disk file ----------
if ! RESTIC_PASSWORD_FILE="$TMPPASS" restic cat config >/dev/null 2>&1; then
  echo "ERROR: verification failed – the new password does not open the repository!" >&2
  echo "The repository key WAS changed, but /etc/restic/password was left untouched." >&2
  echo "Recovery: write the password you just confirmed into /etc/restic/password" >&2
  echo "(mode 600), then re-run this script's verification:" >&2
  echo "  sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic cat config'" >&2
  exit 1
fi

# Confirm that the separate recovery key still opens the repository after the
# main key was changed, before replacing the node's main password file.
if ! RESTIC_PASSWORD= RESTIC_PASSWORD_FILE="$RECOVERY_VERIFY_FILE" restic cat config >/dev/null 2>&1; then
  echo "ERROR: recovery key no longer opens the repository after rotation." >&2
  echo "The repository key changed, but /etc/restic/password was left untouched." >&2
  echo "Use the verified recovery password to repair /etc/restic/password before retrying." >&2
  exit 1
fi

# ---------- Atomic replace (same filesystem) ----------
mv "$TMPPASS" /etc/restic/password
chmod 600 /etc/restic/password
TMPPASS=""

echo
echo "Password changed successfully:"
echo "  - repository key re-encrypted (old password is now invalid)"
echo "  - /etc/restic/password updated atomically and verified"
echo
echo "Remember to update your password manager."
