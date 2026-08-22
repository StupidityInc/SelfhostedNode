#!/bin/bash
# Shared helpers for homelab-bootstrap scripts. Source this file; do not execute it.
# Safe KEY=VALUE load/store: values are never bash-expanded ($ ` and the like stay literal).

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "lib.sh is meant to be sourced, not executed." >&2
  exit 1
fi

HOMELAB_GENERIC_NODE_NAMES="ubuntu debian localhost server client homelab node vps host linux default unknown"

homelab_validate_node_name() {
  local name="$1" g
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || return 1
  for g in $HOMELAB_GENERIC_NODE_NAMES; do
    [[ "$name" == "$g" ]] && return 1
  done
  return 0
}

homelab_is_ident() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Format one KEY=VALUE line for systemd EnvironmentFile and our loader.
# Simple values stay unquoted. Otherwise single-quote (safe if sourced).
# Values containing a single quote are double-quoted with shell metacharacters escaped.
homelab_format_kv() {
  local key="$1" val="$2"
  if [[ "$val" == *$'\n'* ]]; then
    echo "ERROR: refusing to write newline in $key" >&2
    return 1
  fi
  if [[ "$val" =~ ^[A-Za-z0-9_./:@%+-]*$ ]]; then
    printf '%s=%s\n' "$key" "$val"
  elif [[ "$val" != *\'* ]]; then
    printf "%s='%s'\n" "$key" "$val"
  else
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    val="${val//\$/\\\$}"
    val="${val//\`/\\\`}"
    printf '%s="%s"\n' "$key" "$val"
  fi
}

homelab_unquote_val() {
  local val="$1" out="" ch escaped="false" i
  if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
    for ((i = 0; i < ${#val}; i++)); do
      ch="${val:i:1}"
      if [[ "$escaped" == "true" ]]; then
        out+="$ch"
        escaped="false"
      elif [[ "$ch" == "\\" ]]; then
        escaped="true"
      else
        out+="$ch"
      fi
    done
    [[ "$escaped" == "true" ]] && out+='\\'
    printf '%s' "$out"
  elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
    printf '%s' "$val"
  else
    printf '%s' "$val"
  fi
}

# Load KEY=VALUE lines into the current shell without expansion.
# Optional extra args are an allowlist of keys.
homelab_load_kv() {
  local file="$1"
  shift
  local allow=("$@")
  local line key val ok a
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    homelab_is_ident "$key" || continue
    if ((${#allow[@]} > 0)); then
      ok=false
      for a in "${allow[@]}"; do
        if [[ "$key" == "$a" ]]; then ok=true; break; fi
      done
      [[ "$ok" == true ]] || continue
    fi
    val="$(homelab_unquote_val "$val")"
    printf -v "$key" '%s' "$val"
  done < "$file"
}

# Load a root-only file. $1 = sudo command or empty when already root.
homelab_load_kv_sudo() {
  local sudo_cmd="$1" file="$2"
  shift 2
  if [[ -r "$file" ]]; then
    homelab_load_kv "$file" "$@"
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2086
  if ! $sudo_cmd cat "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  homelab_load_kv "$tmp" "$@"
  rm -f "$tmp"
}

HOMELAB_RESTIC_ENV_KEYS=(
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_DEFAULT_REGION
  RESTIC_REPOSITORY
  RESTIC_PASSWORD_FILE
  RESTIC_CACHE_DIR
)

HOMELAB_NODE_ENV_KEYS=(
  ROLE
  NODE_NAME
  USE_EXIT_NODE
  EXIT_NODE_APPLIED
  ADVERTISE_EXIT_NODE
  INSTALL_CLOUDFLARED
  INSTALL_BESZEL_AGENT
  INSTALL_RESTIC_HOST_NATIVE
  EXIT_NODE_LAN_ACCESS
  DIRECT_PUBLIC_IP_AT_SETUP
  KEEP_PUBLIC_SSH
  TAILSCALE_FIREWALL_VERIFIED
  BOOTSTRAP_VERSION
  LAST_BOOTSTRAP_RUN
)

homelab_load_restic_env() {
  local file="${1:-/etc/restic/env}"
  homelab_load_kv "$file" "${HOMELAB_RESTIC_ENV_KEYS[@]}"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR
  export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
}

homelab_restic() {
  homelab_load_restic_env /etc/restic/env
  restic "$@"
}

# True if UFW currently has a public SSH allow rule (not tailscale0-only).
homelab_ufw_has_public_ssh() {
  local sudo_cmd="${1:-}"
  # shellcheck disable=SC2086
  $sudo_cmd ufw status 2>/dev/null | grep -E '22/tcp|OpenSSH' | grep -v tailscale0 | grep -q ALLOW
}

homelab_ufw_is_active() {
  local sudo_cmd="${1:-}"
  # shellcheck disable=SC2086
  $sudo_cmd ufw status 2>/dev/null | grep -qi '^Status: active'
}

# True if $1 is a syntactically valid IPv4 address (a.b.c.d with each octet
# 0..255). Returns 0 for valid, 1 otherwise. No CIDR suffix allowed.
homelab_ipv4_is_valid() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

# True if $1 is a Tailscale CGNAT IPv4 (100.64.0.0/10). Used to validate the
# Tailscale IP SSOT file (AGENT.md §2 Tailscale IP). Returns 0 for valid,
# 1 otherwise. No CIDR suffix allowed.
homelab_validate_tailscale_ip() {
  local ip="$1" a b c d
  homelab_ipv4_is_valid "$ip" || return 1
  IFS=. read -r a b c d <<<"$ip"
  (( a == 100 && b >= 64 && b <= 127 ))
}

# Path to the pinned restic repository UUID. When the lobaro container is the
# primary backup path (AGENT.md §3 WP2), this file is created during the
# host-side `restic init` and verified on every run. See
# homelab_repo_id / homelab_assert_repo_id_pinned.
HOMELAB_REPO_ID_FILE="/etc/restic/repo-id"

# Read the pinned repo-id from /etc/restic/repo-id (first line, raw).
# Empties the variable when the file is missing or unreadable.
homelab_repo_id() {
  HOMELAB_REPO_ID=""
  if [[ -r "$HOMELAB_REPO_ID_FILE" ]]; then
    local line
    line="$(head -n 1 "$HOMELAB_REPO_ID_FILE" 2>/dev/null || true)"
    line="${line%$'\r'}"
    # 32-char lowercase hex; conservative validation. Reject anything else.
    if [[ "$line" =~ ^[0-9a-f]{32}$ ]]; then
      HOMELAB_REPO_ID="$line"
    fi
  fi
}

# Verify the pinned repo-id matches the live restic repository. Reads
# /etc/restic/env for credentials (use homelab_load_restic_env beforehand if
# you need to scope the load). Returns 0 when the IDs match; 1 when the pin
# is missing, the live repository is unreachable, or the IDs differ. Sets
# HOMELAB_REPO_ID_LIVE so callers can decide whether to fail or repair.
homelab_assert_repo_id_pinned() {
  homelab_repo_id
  if [[ -z "$HOMELAB_REPO_ID" ]]; then
    echo "ERROR: $HOMELAB_REPO_ID_FILE is missing or does not contain a 32-char hex UUID." >&2
    echo "       Refusing to operate without a pinned repo-id (AGENT.md §2 Backup)." >&2
    return 1
  fi
  if ! command -v restic >/dev/null 2>&1; then
    echo "ERROR: restic binary is required for repo-id verification." >&2
    return 1
  fi
  # Use the host restic with /etc/restic/env credentials. Caller must have
  # loaded the env already (typical in setup-restic.sh).
  if ! HOMELAB_REPO_ID_LIVE="$(restic cat config --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null)"; then
    echo "ERROR: could not read live repository config with host restic." >&2
    return 1
  fi
  if [[ -z "$HOMELAB_REPO_ID_LIVE" ]]; then
    echo "ERROR: live restic repository returned no id." >&2
    return 1
  fi
  if [[ "$HOMELAB_REPO_ID_LIVE" != "$HOMELAB_REPO_ID" ]]; then
    echo "ERROR: live repo id ($HOMELAB_REPO_ID_LIVE) does not match pinned id ($HOMELAB_REPO_ID)." >&2
    echo "       Refusing to silently accept a different repository." >&2
    return 1
  fi
  return 0
}

# Marker only — the recovery password itself is never written here.
HOMELAB_RECOVERY_KEY_MARKER="/etc/restic/recovery-key.present"

homelab_recovery_key_recorded() {
  local sudo_cmd="${1:-}"
  # shellcheck disable=SC2086
  $sudo_cmd test -f "$HOMELAB_RECOVERY_KEY_MARKER"
}

# systemd Result values that mean the last backup run did not succeed.
# "success" and an empty/never-run unit are not failures.
homelab_backup_unit_failed() {
  local result
  result="$(systemctl show -p Result --value restic-backup.service 2>/dev/null || echo "")"
  case "$result" in
    failed|timeout|exit-code|signal|core-dump|resources|watchdog|oom-kill)
      printf '%s' "$result"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Detect which backup path is active on this node (AGENT.md §3 WP3 / WP5).
# Always exits 0; prints one of:
#   "lobaro"      — the lobaro container is the running backup path
#   "host-native" — the host-native addon (restic-backup.timer) is enabled
#   "both"        — both paths are active (mutually exclusive; WARN in check-node)
#   "none"        — neither path is active (FAIL in check-node)
#
# Detection is heuristic, not state-mutation:
#   - "lobaro"      iff `docker inspect restic-backup.State.Running` is "true"
#   - "host-native" iff `systemctl is-enabled restic-backup.timer` succeeds
#
# WP5: callers may pass the persisted INSTALL_RESTIC_HOST_NATIVE flag as
# $2. When the flag is "true", the host-native classification is preferred
# over the unit-file heuristic — this catches the case where the timer was
# disabled but the operator has explicitly opted into the addon. The flag
# is also authoritative when set: a missing timer with flag=true classifies
# the node as host-native so check-node.sh can surface a missing-timer FAIL
# (operator installed the addon but it never came up). The unit heuristic
# remains as a fallback when no flag is passed.
#
# $1 = sudo prefix (matches homelab_ufw_* style)
# $2 = INSTALL_RESTIC_HOST_NATIVE override (optional: "" | "true" | "false")
homelab_backup_path() {
  local sudo_cmd="${1:-}"
  local flag_override="${2:-}"
  # shellcheck disable=SC2086
  $sudo_cmd command -v docker >/dev/null 2>&1 || true
  local lobaro="false"
  if command -v docker >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    if $sudo_cmd docker inspect -f '{{.State.Running}}' restic-backup 2>/dev/null \
      | grep -q '^true$'; then
      lobaro="true"
    fi
  fi

  # shellcheck disable=SC2086
  local hostnative="false"
  if $sudo_cmd systemctl is-enabled restic-backup.timer >/dev/null 2>&1; then
    hostnative="true"
  fi

  # WP5 flag-precedence: when the operator (or addon installer) has
  # persisted INSTALL_RESTIC_HOST_NATIVE=true, treat the host-native path
  # as authoritative. The timer check above still runs, so a flag=true
  # with a missing/disabled timer surfaces as 'host-native' — the caller
  # (check-node.sh) then surfaces the missing timer as a separate FAIL.
  if [[ "$flag_override" == "true" ]]; then
    hostnative="true"
  fi

  case "$lobaro,$hostnative" in
    true,true)   printf 'both' ;;
    true,false)  printf 'lobaro' ;;
    false,true)  printf 'host-native' ;;
    *)           printf 'none' ;;
  esac
  return 0
}
