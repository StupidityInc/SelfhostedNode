#!/bin/bash
# Shared helpers for addons/*. Source this file; do not execute it.
#
# Provides:
#   addon_log / addon_warn / addon_error
#   addon_require_root
#   addon_use_sudo                sets ADDON_SUDO to "" or "sudo"
#   addon_assert_not_running CONTAINER
#   addon_assert_running CONTAINER
#   addon_assert_not_enabled_unit UNIT
#   addon_root_only_dir PATH MODE   (default MODE = 755, post-laptop-1)
#   addon_root_only_file PATH MODE  (atomic write + chmod + mv; default 600)
#   addon_persist_flag NAME VALUE  (atomic upsert into /etc/homelab/node.env)
#
# Sourced by every addons/<name>/install.sh. Sibling addons must not modify
# the on-disk contract: every flag MUST be persisted ONLY AFTER the runtime
# artifact is verified running (see addons/README.md).
#
# Permissions default: stack dirs are 755 root:root; compose 644; .env 600.
# See addons/README.md "Permissions policy" for the full matrix.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "lib-addon.sh is meant to be sourced, not executed." >&2
  exit 1
fi

ADDON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_REPO_ROOT="$(cd "$ADDON_SCRIPT_DIR/.." && pwd)"

# Source lib.sh from the repo root if present. Provides homelab_format_kv
# (used by addon_persist_flag) and friends. Addons tolerate its absence
# (helpers that need it will warn and refuse).
if [[ -r "$ADDON_REPO_ROOT/lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "$ADDON_REPO_ROOT/lib.sh"
fi

addon_log()   { echo "[addon $(date -Is)] $*"; }
addon_warn()  { echo "[addon $(date -Is)] WARN  $*" >&2; }
addon_error() { echo "[addon $(date -Is)] ERROR $*" >&2; exit 1; }

addon_require_root() {
  if [[ $EUID -ne 0 ]]; then
    addon_error "Addon installer must run as root (use sudo)."
  fi
}

# Set ADDON_SUDO to "" when root, "sudo" otherwise. Call once at the top of
# the addon after addon_require_root, then prefix every privileged command.
addon_use_sudo() {
  if [[ $EUID -eq 0 ]]; then
    ADDON_SUDO=""
  else
    ADDON_SUDO="sudo"
    command -v sudo >/dev/null 2>&1 || addon_error "Addon installer needs root or sudo"
  fi
}

# Fail if a Docker container is currently running. Matches the WP5 mutual-
# exclusion rule: restic-host-native refuses while the lobaro container is
# running (and the inverse is enforced by setup-restic.sh as a WARN).
addon_assert_not_running() {
  local container="$1"
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")"
  if [[ "$running" == "true" ]]; then
    addon_error "Container '$container' is running; refusing to install. Stop it first: docker stop $container"
  fi
}

# Fail if a container is NOT running. Used after 'docker compose up -d' to
# confirm the new service actually came up.
addon_assert_running() {
  local container="$1"
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")"
  if [[ "$running" != "true" ]]; then
    addon_error "Container '$container' is not running after start."
  fi
}

# Fail if a systemd unit is enabled. Used by setup-restic.sh's inverse
# mutual-exclusion check (warn-only there), but exposed as a hard assertion
# for callers that want it.
addon_assert_not_enabled_unit() {
  local unit="$1"
  if systemctl is-enabled "$unit" >/dev/null 2>&1; then
    addon_error "systemd unit '$unit' is enabled; refusing to install. Disable first: systemctl disable --now $unit"
  fi
}

# Create a directory owned by root with the given mode (default 755).
# The default changed from 700 to 755 in the post-laptop-1 batch: stack
# directories (compose + .env + data) are now 755 root:root, with the
# compose file at 644 and secret-bearing .env at 600 (see addons/README.md
# "Permissions policy"). Callers that need a tighter mode for a
# secret-only directory MUST pass it explicitly.
# Does NOT recurse-chown an existing tree — that's an addon's responsibility
# if it wants different ownership.
addon_root_only_dir() {
  local path="$1" mode="${2:-755}"
  if [[ -d "$path" ]]; then
    chmod "$mode" "$path"
    return 0
  fi
  install -d -m "$mode" "$path"
}

# Atomic write of $1 (stdin) at $2 with mode $3 (default 600). tmpfile lives
# in the target directory so the final mv(1) is on the same filesystem.
addon_root_only_file() {
  local path="$1" mode="${2:-600}"
  local dir tmp
  dir="$(dirname "$path")"
  # F3: parent dir default is 755 (stack dir). The .env itself is 600.
  [[ -d "$dir" ]] || addon_root_only_dir "$dir" 755
  tmp="$(mktemp "$dir/.$(basename "$path").XXXXXX")"
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    addon_error "Failed to write to temporary file $tmp"
  fi
  chmod "$mode" "$tmp"
  mv "$tmp" "$path"
}

# Upsert a single KEY=VALUE line into /etc/homelab/node.env. Atomic via
# tmpfile + mv. Existing matching keys are replaced in place; other keys are
# preserved; the file is created with mode 600 if missing.
#
# This is the SOLE place addons should write /etc/homelab/node.env from.
# Callers MUST only call this AFTER the runtime artifact has been verified
# running (see addons/README.md contract).
addon_persist_flag() {
  local name="$1" value="$2"
  # HOMELAB_NODE_ENV_FILE override is for tests only; the default is the
  # canonical /etc/homelab/node.env path.
  local env_file="${HOMELAB_NODE_ENV_FILE:-/etc/homelab/node.env}"
  if ! command -v homelab_format_kv >/dev/null 2>&1; then
    addon_error "homelab_format_kv unavailable; refusing to persist $name (lib.sh missing?)"
  fi
  if ! homelab_is_ident "$name"; then
    addon_error "Refusing to persist invalid identifier: $name"
  fi
  local dir tmp new_line
  dir="$(dirname "$env_file")"
  # F3: /etc/homelab/ holds node.env (identity, INSTALL_* flags) and is
  # therefore 700 — not a stack dir. The default 755 only applies to
  # /opt/stacks/* paths.
  addon_root_only_dir "$dir" 700
  tmp="$(mktemp "$dir/.$(basename "$env_file").XXXXXX")"
  chmod 600 "$tmp"

  # Read existing file (if any), drop any prior line for the same key, then
  # append the freshly formatted one. The awk filter rewrites everything else
  # verbatim, so comments and other keys survive unchanged.
  if [[ -r "$env_file" ]]; then
    awk -v k="$name" 'BEGIN { FS="=" } $1 != k { print }' "$env_file" > "$tmp" || true
  fi
  new_line="$(homelab_format_kv "$name" "$value")" || addon_error "Failed to format $name"
  printf '%s\n' "$new_line" >> "$tmp"
  mv "$tmp" "$env_file"
  chmod 600 "$env_file"
}
