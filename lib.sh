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
