#!/bin/bash
# setup-restic.sh — Lobaro primary backup setup (AGENT.md §3 WP2).
#
# Sets up /etc/restic/ secrets, the lobaro restic-backup-docker Compose stack
# at /opt/stacks/restic-backup/, and pins the repository UUID to
# /etc/restic/repo-id.
#
# Safety properties:
#   - The host restic binary remains installed; this script never removes it.
#   - /etc/restic/env is written with printf + safe quoting (no shell
#     expansion of secrets).
#   - /etc/restic/env.docker is written RAW (no shell quoting) for Compose
#     env_file: — Compose does not interpret shell metacharacters there.
#   - RESTIC_PASSWORD is NEVER placed in Compose environment, .env files,
#     or env_file. RESTIC_PASSWORD_FILE=/etc/restic/password is used
#     instead, and the whole /etc/restic directory is mounted read-only.
#   - A freshly generated repository password must be confirmed by the
#     operator BEFORE anything is written or the repository is initialized.
#   - Host-side `restic init` runs BEFORE the container starts, defeating
#     the lobaro auto-init behavior.
#   - Re-runs keep the existing password, repo, repo-id, and container;
#     they only regenerate missing artifacts (env.docker, .env, the
#     Compose file when drifted).
#   - The host-native systemd path (backup.sh + restic-backup.{service,
#     timer}) is NOT installed by default. It lives in
#     addons/restic-host-native/install.sh and is mutually exclusive with
#     the lobaro container (WP5 fills in the addon).

set -euo pipefail

echo "=== Lobaro restic backup setup (WP2) ==="
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

# Host restic helper — uses /etc/restic/env for credentials and never inherits
# env. Mirrors the goal.md-era behaviour so health checks (host `restic
# snapshots`) keep working unchanged after this rewrite.
run_restic() {
  # shellcheck disable=SC2086
  $SUDO bash -c 'source "$1"; homelab_load_restic_env /etc/restic/env; exec restic "${@:2}"' _ "$SCRIPT_DIR/lib.sh" "$@"
}

# B3: run_restic with stderr captured to a file. The init/open checks
# below classify failures by reading the captured blob. Caller must
# $SUDO-rm the tmpfile. Returns the restic exit code.
run_restic_capture() {
  local err_tmp="$1"
  shift
  $SUDO bash -c 'source "$1"; homelab_load_restic_env /etc/restic/env; exec restic "${@:2}" 2>"$3"' _ "$SCRIPT_DIR/lib.sh" "$err_tmp" "$@"
}

# B3: classify a restic error blob into a single actionable hint.
# Echoes a one-line cause. Used by both the "init" and "open" checks.
classify_restic_failure() {
  local err="$1"
  if grep -qiE 'invalid (credentials|access key|aws|signature)|s3: .*signature|authentication' <<<"$err"; then
    echo "AUTH failed: check AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (signature/authentication error from S3)"
  elif grep -qiE 'no such host|connection refused|i/o timeout|network is unreachable|no route to host|getaddrinfo' <<<"$err"; then
    echo "ENDPOINT unreachable: cannot reach the S3 host (need exit node? wrong S3_ENDPOINT?)"
  elif grep -qiE 'no such bucket|nosuchbucket|404' <<<"$err"; then
    echo "BUCKET missing: the named bucket does not exist on the endpoint"
  elif grep -qiE 'wrong password|decrypt|invalid password' <<<"$err"; then
    echo "WRONG PASSWORD: the repository refused the supplied RESTIC_PASSWORD"
  elif grep -qiE 'repository does not exist|is not a repository' <<<"$err"; then
    echo "REPO missing: the bucket/prefix exists but is not a restic repository"
  else
    echo "UNKNOWN: see restic error output below"
  fi
}

# ---------- Node name: explicit, validated, never silently defaulted ----------
REQUESTED_NODE_NAME="$(printf '%s' "${NODE_NAME:-}" | tr '[:upper:]' '[:lower:]')"
PERSISTED_NODE_NAME=""
if $SUDO test -f /etc/homelab/node.env; then
  NODE_NAME=""
  if ! homelab_load_kv_sudo "$SUDO" /etc/homelab/node.env NODE_NAME; then
    echo "ERROR: cannot read /etc/homelab/node.env" >&2
    exit 1
  fi
  PERSISTED_NODE_NAME="$(printf '%s' "$NODE_NAME" | tr '[:upper:]' '[:lower:]')"
  if [[ -n "$REQUESTED_NODE_NAME" && "$REQUESTED_NODE_NAME" != "$PERSISTED_NODE_NAME" ]]; then
    echo "ERROR: NODE_NAME '$REQUESTED_NODE_NAME' conflicts with persisted node identity '$PERSISTED_NODE_NAME'." >&2
    echo "Refusing to change the restic tag, container hostname, and retention identity." >&2
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
if ! homelab_validate_node_name "$NODE_NAME"; then
  echo "ERROR: invalid or too-generic node name: '$NODE_NAME'" >&2
  exit 1
fi

STACK_DIR="/opt/stacks/restic-backup"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
ENV_FILE="$STACK_DIR/.env"
TEMPLATE_FILE="$SCRIPT_DIR/setup-restic.lobaro.yml.tmpl"

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

# Helper: write a raw KEY=VALUE line for /etc/restic/env.docker.
# No quoting; values containing newlines are rejected (those would break
# Compose env_file parsing). The first '=' is the separator; everything
# after is the value verbatim. This matches what lobaro/restico expects
# for env_file values.
homelab_format_kv_docker() {
  local key="$1" val="$2"
  if [[ "$val" == *$'\n'* ]]; then
    echo "ERROR: refusing to write newline in $key" >&2
    return 1
  fi
  if [[ "$val" == *$'\r'* ]]; then
    echo "ERROR: refusing to write CR in $key" >&2
    return 1
  fi
  printf '%s=%s\n' "$key" "$val"
}

if [[ "$REUSE_EXISTING" == "true" ]]; then
  RESTIC_REPOSITORY=""
  homelab_load_kv_sudo "$SUDO" /etc/restic/env RESTIC_REPOSITORY
  REPO="$RESTIC_REPOSITORY"
  echo "Keeping existing /etc/restic/env and /etc/restic/password."
  echo "Repository: $REPO"
else
  # ---------- Repository password ----------
  if $SUDO test -f /etc/restic/password; then
    echo "Existing /etc/restic/password found – keeping it (env files will be rewritten around it)."
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
          echo "ERROR: passwords DO NOT MATCH. Aborting BEFORE writing anything or touching the repository." >&2
          echo "       Hint: copy-paste from your password manager to avoid typos." >&2
          echo "       Nothing was changed. Re-run this script to try again." >&2
          exit 1
        fi
        echo "Password accepted."
      else
        echo "WARNING: non-interactive mode – the password above is your only offline copy."
        echo "         Store it securely. (Or provide RESTIC_PASSWORD via environment instead.)"
      fi
    fi
    PASSWORD_TMP="$($SUDO mktemp /etc/restic/.password.XXXXXX)"
    printf '%s\n' "$PASSWORD" | $SUDO tee "$PASSWORD_TMP" >/dev/null
    $SUDO chmod 600 "$PASSWORD_TMP"
    $SUDO mv "$PASSWORD_TMP" /etc/restic/password
    unset PASSWORD
  fi

  # ---------- Environment file (shell-quoted, used by systemd + lib.sh) ----------
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

# ---------- env.docker (raw, for Compose env_file:) ----------
# Always (re-)generate env.docker to keep it in sync with env. It must NEVER
# contain the password (only RESTIC_PASSWORD_FILE, which is a path).
ENV_DOCKER_TMP="$($SUDO mktemp /etc/restic/.env.docker.XXXXXX)"
{
  # We have to read AWS_* and RESTIC_REPOSITORY out of /etc/restic/env via
  # the safe loader; never source the file as shell.
  AWS_ACCESS_KEY_ID_VAL=""
  AWS_SECRET_ACCESS_KEY_VAL=""
  AWS_DEFAULT_REGION_VAL=""
  RESTIC_REPOSITORY_VAL=""
  RESTIC_PASSWORD_FILE_VAL=""
  RESTIC_CACHE_DIR_VAL=""
  if $SUDO test -r /etc/restic/env; then
    homelab_load_kv_sudo "$SUDO" /etc/restic/env \
      AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION \
      RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR
    AWS_ACCESS_KEY_ID_VAL="$AWS_ACCESS_KEY_ID"
    AWS_SECRET_ACCESS_KEY_VAL="$AWS_SECRET_ACCESS_KEY"
    AWS_DEFAULT_REGION_VAL="${AWS_DEFAULT_REGION:-auto}"
    RESTIC_REPOSITORY_VAL="$RESTIC_REPOSITORY"
    RESTIC_PASSWORD_FILE_VAL="${RESTIC_PASSWORD_FILE:-/etc/restic/password}"
    RESTIC_CACHE_DIR_VAL="${RESTIC_CACHE_DIR:-/var/cache/restic}"
  fi
  homelab_format_kv_docker AWS_ACCESS_KEY_ID "$AWS_ACCESS_KEY_ID_VAL"
  homelab_format_kv_docker AWS_SECRET_ACCESS_KEY "$AWS_SECRET_ACCESS_KEY_VAL"
  homelab_format_kv_docker AWS_DEFAULT_REGION "$AWS_DEFAULT_REGION_VAL"
  homelab_format_kv_docker RESTIC_REPOSITORY "$RESTIC_REPOSITORY_VAL"
  # RESTIC_PASSWORD_FILE is referenced by the container via environment:
  # (see Compose template). Including it in env.docker too is harmless and
  # makes the file self-documenting. It is a path, not a secret.
  homelab_format_kv_docker RESTIC_PASSWORD_FILE "$RESTIC_PASSWORD_FILE_VAL"
  homelab_format_kv_docker RESTIC_CACHE_DIR "$RESTIC_CACHE_DIR_VAL"
} | $SUDO tee "$ENV_DOCKER_TMP" >/dev/null
$SUDO chmod 600 "$ENV_DOCKER_TMP"
$SUDO mv "$ENV_DOCKER_TMP" /etc/restic/env.docker
echo "Wrote /etc/restic/env.docker (raw KEY=VALUE for Compose env_file)"

# ---------- Initialize repository ----------
# B2/B3: capture stderr to classify the failure instead of a single
# generic "init failed" line. The classifier maps restic's error to
# one of {AUTH, ENDPOINT, BUCKET, WRONG PASSWORD, REPO, UNKNOWN} and
# prints an actionable hint per cause.
echo
echo "Checking repository (initializing if needed)..."
INIT_ERR_TMP="$($SUDO mktemp /tmp/homelab-restic-init.XXXXXX)"
trap 'rm -f "$INIT_ERR_TMP"' EXIT
if run_restic cat config >/dev/null 2>"$INIT_ERR_TMP"; then
  echo "Repository already initialized."
else
  if run_restic_capture "$INIT_ERR_TMP" init; then
    echo "Repository initialized successfully."
  else
    CAUSE="$(classify_restic_failure "$($SUDO cat "$INIT_ERR_TMP" 2>/dev/null || true)")"
    echo "ERROR: repository init failed." >&2
    echo "       Cause: $CAUSE" >&2
    echo "       If S3 is only reachable via a Tailscale exit node, enable that first and re-run." >&2
    if [[ "$CAUSE" == UNKNOWN* ]]; then
      echo "       restic error output:" >&2
      $SUDO cat "$INIT_ERR_TMP" | sed 's/^/         /' >&2 || true
    fi
    exit 1
  fi
fi

# B2: open-repo proof. Runs `restic cat config` again through the
# classifier. This is the "password accepted + repository reachable"
# proof the brief asks for: it covers the S3 auth path, the bucket
# reachability, the prefix, the password, and the repo state in one
# shot. Runs on EVERY path (REUSE_EXISTING and fresh) so a re-run that
# lost a credential surfaces a clear error before the operator is told
# "complete".
echo "Proving host restic can open the repository..."
OPEN_ERR_TMP="$($SUDO mktemp /tmp/homelab-restic-open.XXXXXX)"
trap 'rm -f "$INIT_ERR_TMP" "$OPEN_ERR_TMP"' EXIT
if run_restic_capture "$OPEN_ERR_TMP" cat config >/dev/null; then
  echo "Host restic opened the repository OK."
else
  OPEN_ERR="$($SUDO cat "$OPEN_ERR_TMP" 2>/dev/null || true)"
  CAUSE="$(classify_restic_failure "$OPEN_ERR")"
  echo "ERROR: host restic cannot open the repository with the current /etc/restic/env." >&2
  echo "       Cause: $CAUSE" >&2
  echo "       Common remediation (in order of likelihood):" >&2
  echo "         1. Wrong RESTIC_PASSWORD (re-run and re-type, or supply RESTIC_PASSWORD=...)" >&2
  echo "         2. Wrong AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY" >&2
  echo "         3. Unreachable S3 endpoint (need exit node? wrong S3_ENDPOINT?)" >&2
  echo "         4. Wrong BUCKET / PREFIX (does the bucket exist and accept this prefix?)" >&2
  if [[ "$CAUSE" == UNKNOWN* ]]; then
    echo "       restic error output:" >&2
    printf '%s\n' "$OPEN_ERR" | sed 's/^/         /' >&2
  fi
  exit 1
fi
rm -f "$OPEN_ERR_TMP"

# ---------- Pin repo-id ----------
# Reads the live UUID via `restic cat config --json` and writes it to
# /etc/restic/repo-id. If a pinned id already exists and disagrees with
# the live one, this is a HARD error (we never silently accept a different
# repository).
homelab_repo_id
EXISTING_PIN="$HOMELAB_REPO_ID"
LIVE_ID="$(run_restic cat config --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
if [[ -z "$LIVE_ID" ]]; then
  echo "ERROR: could not read live repository id (network? credentials?)." >&2
  exit 1
fi
if [[ -n "$EXISTING_PIN" && "$EXISTING_PIN" != "$LIVE_ID" ]]; then
  echo "ERROR: pinned repo-id ($EXISTING_PIN) does not match live id ($LIVE_ID)." >&2
  echo "Refusing to silently accept a different repository." >&2
  exit 1
fi
if [[ "$EXISTING_PIN" != "$LIVE_ID" ]]; then
  PIN_TMP="$($SUDO mktemp /etc/restic/.repo-id.XXXXXX)"
  printf '%s\n' "$LIVE_ID" | $SUDO tee "$PIN_TMP" >/dev/null
  $SUDO chmod 644 "$PIN_TMP"
  $SUDO mv "$PIN_TMP" "$HOMELAB_REPO_ID_FILE"
  echo "Pinned repository UUID to $HOMELAB_REPO_ID_FILE ($LIVE_ID)"
fi

# ---------- Cron expressions (stably derived from NODE_NAME) ----------
# Hash NODE_NAME to spread daily backups + weekly checks across the fleet
# without conflicting on a single S3 prefix. Output is a 5-field cron
# expression in UTC (the lobaro container uses BusyBox cron in UTC).
#
# Format: "MIN HOUR * * *" with MIN in 0..59 and HOUR in 0..23. The hash
# gives us a stable but per-node offset.
cron_from_node_name() {
  local node="$1" h sum hour minute
  h="$(printf '%s' "$node" | sha256sum | awk '{print $1}')"
  # Use the first 8 hex chars as an integer; mod by 24 for hour, mod by 60 for minute.
  sum=$((16#${h:0:8}))
  hour=$((sum % 24))
  minute=$(( (sum / 24) % 60 ))
  printf '%d %d * * *' "$minute" "$hour"
}
BACKUP_CRON_VAL="$(cron_from_node_name "$NODE_NAME")"
# Weekly check: same minute, fixed weekday. Use Sunday as the default.
# Spread the weekday by hashing the node name again.
check_h="$(printf '%s%s' "$NODE_NAME" "-check" | sha256sum | awk '{print $1}')"
CHECK_DOW=$((16#${check_h:0:2} % 7))   # 0=Sun .. 6=Sat
# Re-derive minute/hour for the check so it doesn't collide with backup.
check_sum=$((16#${check_h:0:8}))
check_hour=$((check_sum % 24))
check_minute=$(( (check_sum / 24) % 60 ))
CHECK_CRON_VAL="${check_minute} ${check_hour} * * ${CHECK_DOW}"

# ---------- Retention policy (RESTIC_FORGET_ARGS) ----------
# Conservative defaults that survive a single-node failure but don't grow
# unbounded. The value is substituted as a single YAML scalar into the
# Compose file (see setup-restic.lobaro.yml.tmpl:
# `RESTIC_FORGET_ARGS=__RESTIC_FORGET_ARGS__`) — it must therefore be ONLY
# the restic `forget` flags, NOT a Compose `-e "..."` fragment. An earlier
# version embedded the Compose `-e "..."` form here, which caused the
# container to receive a malformed RESTIC_FORGET_ARGS environment value
# and `restic forget` to fail in the lobaro log.
# Override before running setup-restic.sh by exporting RESTIC_FORGET_ARGS
# to a literal string of flags (no shell escaping required).
RESTIC_FORGET_ARGS_VAL="${RESTIC_FORGET_ARGS:---prune --keep-last 10 --keep-hourly 24 --keep-daily 7 --keep-weekly 52 --keep-monthly 120 --keep-yearly 100}"

# ---------- Per-backup extra args ----------
RESTIC_JOB_ARGS_VAL="${RESTIC_JOB_ARGS:-}"

# ---------- Generate /opt/stacks/restic-backup/ stack ----------
echo
echo "Generating lobaro Compose stack at $STACK_DIR..."

if [[ ! -r "$TEMPLATE_FILE" ]]; then
  echo "ERROR: template not found: $TEMPLATE_FILE" >&2
  exit 1
fi

# Atomic write: tmpfile in stack dir, sed-substitute, chmod, mv.
# F3: stack dir is 755 root:root (compose 644, .env 600). 700 was over-
# tight; docker-compose v2 has no group requirement.
$SUDO mkdir -p "$STACK_DIR"
$SUDO chmod 755 "$STACK_DIR"

# Substitution: escape `|` (sed delimiter), `&` (sed "matched text") and
# `\` in each value before inserting it via sed.
# Using `|` as the delimiter keeps the substitution readable; the values
# produced by cron_from_node_name never contain `|` but operator-supplied
# RESTIC_JOB_ARGS / RESTIC_FORGET_ARGS may.
sed_quote() {
  printf '%s' "$1" | sed -e 's|\\|\\\\|g' -e 's|\&|\\\&|g' -e 's|\||\\\||g'
}

COMPOSE_TMP="$($SUDO mktemp "$STACK_DIR/.docker-compose.yml.XXXXXX")"
sed \
  -e "s|__NODE_NAME__|$(sed_quote "$NODE_NAME")|g" \
  -e "s|__BACKUP_CRON__|$(sed_quote "$BACKUP_CRON_VAL")|g" \
  -e "s|__CHECK_CRON__|$(sed_quote "$CHECK_CRON_VAL")|g" \
  -e "s|__RESTIC_FORGET_ARGS__|$(sed_quote "$RESTIC_FORGET_ARGS_VAL")|g" \
  -e "s|__RESTIC_JOB_ARGS__|$(sed_quote "$RESTIC_JOB_ARGS_VAL")|g" \
  "$TEMPLATE_FILE" > "$COMPOSE_TMP"
$SUDO chmod 644 "$COMPOSE_TMP"
$SUDO mv "$COMPOSE_TMP" "$COMPOSE_FILE"
echo "Wrote $COMPOSE_FILE"

# ---------- Stack .env (non-secret tunables only) ----------
# Never contains the password. Holds only values that operators may want
# to override (e.g. RESTIC_JOB_ARGS, RESTIC_FORGET_ARGS). Compose reads
# /etc/restic/env.docker for the secrets.
ENV_TMP="$($SUDO mktemp "$STACK_DIR/.env.XXXXXX")"
{
  homelab_format_kv RESTIC_JOB_ARGS "$RESTIC_JOB_ARGS_VAL"
} | $SUDO tee "$ENV_TMP" >/dev/null
$SUDO chmod 600 "$ENV_TMP"
$SUDO mv "$ENV_TMP" "$ENV_FILE"
echo "Wrote $ENV_FILE"

# ---------- Start the container ----------
echo
echo "Starting the lobaro container..."
if ! $SUDO docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d; then
  echo "ERROR: docker compose up failed." >&2
  exit 1
fi

# ---------- Verify the container is actually running ----------
sleep 2
RUNNING="$($SUDO docker inspect -f '{{.State.Running}}' restic-backup 2>/dev/null || echo "false")"
if [[ "$RUNNING" != "true" ]]; then
  echo "ERROR: restic-backup container is not running after 'up -d'." >&2
  $SUDO docker logs restic-backup --tail 50 >&2 || true
  exit 1
fi
echo "restic-backup container is running."

# ---------- Mutual-exclusion WARN: host-native addon ----------
# WP5: setup-restic.sh installs the lobaro container as the primary backup.
# The host-native addon (addons/restic-host-native/install.sh) is mutually
# exclusive — its installer REFUSES to run while the lobaro container is
# running. The reverse direction is enforced here as a WARN, not a refuse,
# so re-runs and migration windows (WP7) are not blocked. The operator is
# told how to disable the host-native timer cleanly.
if $SUDO systemctl is-enabled restic-backup.timer >/dev/null 2>&1; then
  echo "WARN: restic-backup.timer is enabled — lobaro and host-native restic are mutually exclusive." >&2
  echo "      Disable the host-native timer with:  sudo systemctl disable --now restic-backup.timer" >&2
  echo "      Both paths may now run side-by-side; check-node.sh will also WARN about this." >&2
fi

# ---------- Verify the snapshot tag matches NODE_NAME ----------
echo
echo "Verifying the snapshot tag matches '$NODE_NAME'..."
# The container's first run is asynchronous (BusyBox cron). We can't block
# for the backup to finish here — that would couple bootstrap to network
# latency and S3 performance. The check below confirms we CAN list
# snapshots from the host using /etc/restic/env; it does NOT confirm that
# a new snapshot has already been created by the container.
if ! homelab_assert_repo_id_pinned; then
  echo "ERROR: repo-id pin verification failed." >&2
  exit 1
fi
echo "Repo-id pin matches live repository (${HOMELAB_REPO_ID_LIVE:-unknown})."
LATEST_TAG="$(run_restic snapshots --json --latest 1 2>/dev/null | jq -r '.[0].tags[]? // empty' 2>/dev/null | head -n1 || true)"
if [[ "$LATEST_TAG" != "$NODE_NAME" ]]; then
  echo "NOTE: no existing snapshot with tag '$NODE_NAME' yet. The container's"
  echo "      cron will create one on its first window. check-node.sh will"
  echo "      surface the missing tag if it persists."
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

echo
echo "=== Lobaro backup setup complete ==="
echo "Repository    : $REPO  (reachable)"
echo "Password      : /etc/restic/password  (mode 600, root-owned)"
PINNED_ID="$(cat /etc/restic/repo-id 2>/dev/null || echo '<missing>')"
echo "Repo-id pinned: $PINNED_ID"
echo "Backup schedule (UTC) : $BACKUP_CRON_VAL"
echo "Check schedule  (UTC) : $CHECK_CRON_VAL"
echo
echo "Next steps:"
echo "  1. Health check:    sudo /opt/stacks/_backup/check-node.sh"
echo "  2. List snapshots:  sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots'"
echo "  3. Container logs:  sudo docker logs restic-backup --tail 50"
echo
echo "The repository password lives only in /etc/restic/password and your password manager."
echo "To rotate it later:        sudo /opt/stacks/_backup/change-restic-password.sh"
echo "To add a recovery key:     sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic key add'"
echo
echo "The host-native systemd backup path is NOT installed by default. To install it"
echo "(mutually exclusive with the lobaro container), use:"
echo "  sudo ./addons/restic-host-native/install.sh"