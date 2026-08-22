#!/bin/bash
# Host-native restic addon installer (AGENT.md §3 WP5).
#
# Re-installs the OLD systemd-based restic backup path that the main
# bootstrap used in the goal.md era. It is mutually exclusive with the
# lobaro container (which is the primary backup after WP2). WP5 reverses
# the dead-copy default: WP2 stopped installing these units by default;
# this addon is the ONLY way to put them back on a node.
#
# Contract (see addons/README.md):
#   1. Validate (refuse if lobaro container is running; secrets in place)
#   2. Atomic install: backup.sh -> /opt/stacks/_backup/, units -> /etc/systemd/system/
#   3. systemctl daemon-reload + enable --now restic-backup.timer
#   4. Verify the timer is active
#   5. ONLY THEN persist INSTALL_RESTIC_HOST_NATIVE=true in /etc/homelab/node.env
#
# Re-run safety: install(1) overwrites files safely; systemctl enable --now
# is idempotent. The verify step catches "previous install but timer now
# dead" and errors out cleanly. The data volume at /var/cache/restic is
# never touched.
#
# The host restic binary is installed by setup-restic.sh (always-on
# baseline per AGENT.md §2); this addon only installs the scheduler and
# backup script.

set -euo pipefail

ADDON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_REPO_ROOT="$(cd "$ADDON_SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
source "$ADDON_SCRIPT_DIR/../lib-addon.sh"

BACKUP_SCRIPT_SRC="$ADDON_REPO_ROOT/backup.sh"
BACKUP_SCRIPT_DST="/opt/stacks/_backup/backup.sh"
SERVICE_SRC="$ADDON_REPO_ROOT/restic-backup.service"
TIMER_SRC="$ADDON_REPO_ROOT/restic-backup.timer"
SERVICE_DST="/etc/systemd/system/restic-backup.service"
TIMER_DST="/etc/systemd/system/restic-backup.timer"

addon_require_root
addon_use_sudo

# ---------- 1. Validate ----------
# Mutual exclusion: refuse while the lobaro container is the running backup
# path. Per AGENT.md §2 and WP5 brief, the inverse check (lobaro refuses if
# host-native timer is enabled) lives in setup-restic.sh as a WARN so it
# doesn't block re-runs / migration windows.
addon_assert_not_running restic-backup

for f in "$BACKUP_SCRIPT_SRC" "$SERVICE_SRC" "$TIMER_SRC"; do
  if [[ ! -r "$f" ]]; then
    addon_error "Required source file is missing: $f"
  fi
done

# /etc/restic/env must already exist — setup-restic.sh (the lobaro path)
# writes it during step 6 of bootstrap, and this addon piggybacks on the
# same secrets directory. Refuse early rather than starting the timer
# against an unconfigured repository.
if ! [[ -r /etc/restic/env ]]; then
  addon_error "/etc/restic/env is missing. Run bootstrap.sh (which calls setup-restic.sh) once before installing this addon."
fi
if ! command -v restic >/dev/null 2>&1; then
  addon_error "restic binary is not installed. Run bootstrap.sh (or apt-get install restic) before installing this addon."
fi

# /opt/stacks/_backup must exist and be writable; bootstrap step 2 creates
# it. If a manual install path put it elsewhere, bail rather than guess.
if ! [[ -d /opt/stacks/_backup ]]; then
  addon_error "/opt/stacks/_backup is missing. Run bootstrap.sh once to create the directory skeleton."
fi

# ---------- 2. Atomic install ----------
# backup.sh: copy to /opt/stacks/_backup with mode 700 (matches pre-WP2
# behaviour; bootstrap still chmods this to 700 on re-runs).
addon_log "Installing $BACKUP_SCRIPT_DST (mode 700)"
install -m 0700 "$BACKUP_SCRIPT_SRC" "$BACKUP_SCRIPT_DST"

# systemd units: mode 644, root-owned, into /etc/systemd/system (overrides
# any package-installed units of the same name).
addon_log "Installing $SERVICE_DST"
install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"
addon_log "Installing $TIMER_DST"
install -m 0644 "$TIMER_SRC"  "$TIMER_DST"

# ---------- 3. Reload + enable ----------
$ADDON_SUDO systemctl daemon-reload
if ! $ADDON_SUDO systemctl enable --now restic-backup.timer; then
  addon_error "systemctl enable --now restic-backup.timer failed"
fi

# ---------- 4. Verify ----------
if ! $ADDON_SUDO systemctl is-active --quiet restic-backup.timer; then
  addon_error "restic-backup.timer is not active after enable --now"
fi

# ---------- 5. Persist flag ----------
addon_persist_flag INSTALL_RESTIC_HOST_NATIVE true
addon_log "Host-native restic backup installed and verified running; INSTALL_RESTIC_HOST_NATIVE=true persisted."
addon_log "First scheduled run will trigger at the timer's next OnCalendar window (timer default: 03:00 + per-node randomized offset)."
