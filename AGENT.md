# AGENT.md — SelfhostedNode Transformation

**Role of this file:** Authoritative instructions and continuity brief for any
agent (or human) transforming the SelfhostedNode repository from its current
state into the target state described here.

**Status:** WP1 (Tailscale IP SSOT), WP2 (Lobaro Primary Backup),
WP3 (Health Check Updates), WP4 (Bootstrap Integration), WP5 (Addon
Pattern + Moves), WP6 (Docs & Restore), and WP7 (Migration Path)
**complete and verified**. See §0 below for what exists.

**This file is auto-updating.** The implementing agent must follow §7
("Auto-Update Instructions") at the end of each session. A fresh instance
should be able to `cat AGENT.md` and resume work without other context.

---

## 0. Current State (end of WP4 session)

**Done.**

- **Bootstrap Integration** (WP4) is in place. WP4 was a verification +
  bookkeeping package only — no code changed this WP. The 7 ordered
  core steps already in `bootstrap.sh` from WP1–WP3 match the WP4
  ordering contract:
  - Step 1 (base packages + Docker) — `bootstrap.sh:630`
  - Step 2 (directory skeleton, creates `/opt/homelab/env-file` and
    `/opt/stacks/_system`) — `bootstrap.sh:652–668`
  - Step 3 (Tailscale install + `up`, `hostname=$NODE_NAME`) —
    `bootstrap.sh:692–734`
  - Step 3a (Tailscale IP SSOT — copies `_system/*` to
    `/opt/stacks/_system`, installs the tailscaled drop-in, runs the
    writer once, enables the timer) — `bootstrap.sh:736–778`
  - Step 4 (UFW hardening + verification) — `bootstrap.sh:797–940`
  - Step 6 (primary backup — `setup-restic.sh` → lobaro container) —
    `bootstrap.sh:998–1018`
  - Step 8 (exit-node apply last, with probe + rollback) —
    `bootstrap.sh:1024–1107`
  Identity immutability (role + node-name conflicts at
  `bootstrap.sh:559, 587`) and public-SSH stickiness
  (`KEEP_PUBLIC_SSH` plumbing at `bootstrap.sh:407, 484–496,
  802–816, 906–939`) are unchanged from prior sessions.
  The "optional addon dispatch" step in WP4's brief was **explicitly
  deferred to WP5 by operator decision this session** — no half-wired
  stub was added to `bootstrap.sh`. The two addon stubs at
  `addons/beszel-agent/install.sh` and
  `addons/restic-host-native/install.sh` continue to `exit 1` as
  before; WP5 will implement the dispatcher and the addon bodies
  together.
  - Verification (this session):
    - `bash -n` on every modified-or-touched script
      (`bootstrap.sh`, `setup-restic.sh`, `check-node.sh`,
      `lib.sh`, `_system/update-tailscale-ip.sh`,
      `addons/beszel-agent/install.sh`,
      `addons/restic-host-native/install.sh`,
      `addons/lib-addon.sh`): pass.
    - Step-header audit: the 7 ordered core steps + sub-steps 3a / 3b
      are present at the expected line numbers and in the expected
      order; step 8 is the last routing step before "Optional Beszel
      agent" (which is still inline core — see §0 "Not done yet").
    - Idempotency guards present: `[[ ! -d ]]` directory create,
      `PERSISTED_*` re-load, `KEEP_PUBLIC_SSH` sticky default,
      `NODE_ENV_EXISTS` gating.
    - Identity immutability: role conflict at `bootstrap.sh:559`,
      node-name conflict at `bootstrap.sh:587` — both still abort.
    - No new `addons/*install.sh` invocation added by WP4 (grep over
      `bootstrap.sh`: only the inline `configure_beszel_agent`
      definition at line 303 and call at line 1112, both pre-WP4).

- **Tailscale IP SSOT** (WP1) — unchanged.
- **Lobaro Primary Backup** (WP2) — unchanged.
- **Health Check Updates** (WP3) is in place. `check-node.sh`'s restic
  section is honest for the lobaro-primary world:
  - Detects the active backup path via `homelab_backup_path` (new
    helper in `lib.sh`): `lobaro` | `host-native` | `both` | `none`.
    Detection is a heuristic, not a state-mutation:
    - `lobaro` ⇔ `docker inspect restic-backup.State.Running == true`
    - `host-native` ⇔ `systemctl is-enabled restic-backup.timer` OK
  - Lobaro container running check (FAIL when container missing or
    `State.Running != true`).
  - Host-native `restic-backup.timer` enabled/active checks only
    when the heuristic above classifies that path as active. The
    host-native addon is detected by the unit-file presence, not by
    a not-yet-written `INSTALL_RESTIC_HOST_NATIVE=true` flag (that
    flag lands in WP5).
  - Repo-id match check (FAIL on mismatch, WARN on live repo
    unreachable).
  - Snapshot freshness still measured via host `restic snapshots
    --latest 1` — host restic remains the ground truth (AGENT.md
    §2).
  - Container error log secondary signal: scans last 200 lines with
    `grep -cE '(^|[^A-Za-z])(ERROR|FATAL|Error:)'` — WARN on match,
    never FAIL (the lobaro image's cron auto-recovers).
  - Mutual-exclusivity WARN when both paths are active. The exit
    code is unaffected; WP7's migration window is supported.
  - UFW, Tailscale, Tailscale IP SSOT, Outbound connectivity, Docker,
    and speed-hint sections are unchanged from WP1.
  - Verification (this session):
    - `bash -n` on every modified file: pass.
    - 6 unit tests on `homelab_backup_path` (all docker/timer
      combinations): pass.
    - 5 unit tests on `homelab_repo_id` parser (valid hex, missing,
      malformed, too long, uppercase rejected): pass.
    - 4 unit tests on `homelab_assert_repo_id_pinned` (MATCH,
      MISMATCH, missing pin, empty live id): pass.
    - 8 control-flow scenarios for the new restic section (healthy
      lobaro, healthy host-native, both-active, container stopped,
      no path, error-log noise, clean logs, timer enabled but not
      active): pass.

- **Addon Pattern + Moves** (WP5) is in place. Beszel and host-native
  restic are now addons, not core defaults:
  - `addons/lib-addon.sh` — fleshed out. Provides `addon_log`,
    `addon_warn`, `addon_error`, `addon_require_root`,
    `addon_use_sudo`, `addon_assert_not_running`,
    `addon_assert_running`, `addon_assert_not_enabled_unit`,
    `addon_root_only_dir`, `addon_root_only_file`, and
    `addon_persist_flag` (atomic upsert into
    `/etc/homelab/node.env`). `HOMELAB_NODE_ENV_FILE` env override
    exists only for tests.
  - `addons/beszel-agent/install.sh` — implements the full
    `configure_beszel_agent` logic from the pre-WP5 inline
    implementation. Self-contained: the `beszel_*` helper functions
    were moved INTO the addon so bootstrap.sh no longer needs them.
    Sequence: validate → atomic write → `docker compose up -d` →
    verify running → `INSTALL_BESZEL_AGENT=true`. Exits non-zero
    without persisting the flag on any failure.
  - `addons/restic-host-native/install.sh` — installs the old
    systemd path (`backup.sh` + `restic-backup.{service,timer}`).
    Mutual-exclusion check (`addon_assert_not_running restic-backup`)
    is the FIRST step after sudo setup; the addon REFUSES while the
    lobaro container is running, with a clear remediation message.
    `install(1)` is atomic and idempotent; `systemctl enable --now`
    is idempotent. The addon persists `INSTALL_RESTIC_HOST_NATIVE=true`
    ONLY AFTER the timer is verified active.
  - `bootstrap.sh`:
    - `configure_beszel_agent` and all `beszel_*` helpers removed.
    - Inline step 9 "Optional Beszel agent" replaced by new step 9
      "Addon dispatch (after core is complete)". The dispatch step
      only runs when a request flag was set THIS RUN
      (`BESZEL_AGENT_REQUESTED_THIS_RUN` or
      `RESTIC_HOST_NATIVE_REQUESTED_THIS_RUN`); a re-run with no
      flags is a no-op.
    - New CLI flag `--install-restic-host-native` plumbed through
      argument parsing and a symmetric interactive prompt.
    - File-copy loop (step 2) no longer copies `backup.sh`,
      `restic-backup.service`, `restic-backup.timer` — those files
      now reach `/opt/stacks/_backup/` and `/etc/systemd/system/`
      ONLY via the restic-host-native addon.
    - `INSTALL_RESTIC_HOST_NATIVE` is read from `/etc/homelab/node.env`
      and round-tripped through `write_node_env` so re-runs preserve
      the addon-installed state. A symmetric stale-install guard
      clears the flag if the timer unit AND the backup script are
      both missing (matches the Beszel staleness check).
    - Identity immutability (`bootstrap.sh:559`, `:587`) and
      public-SSH stickiness (`KEEP_PUBLIC_SSH` at `:407, 484–496,
      802–816, 906–939`) are unchanged.
  - `lib.sh`:
    - `INSTALL_RESTIC_HOST_NATIVE` added to `HOMELAB_NODE_ENV_KEYS`.
    - `homelab_backup_path` now accepts a second argument: the
      persisted `INSTALL_RESTIC_HOST_NATIVE` flag. When the flag is
      `"true"`, the host-native classification is preferred over the
      unit-file heuristic. The unit heuristic stays as a fallback
      (no second arg, or empty / `"false"`).
  - `check-node.sh`:
    - `INSTALL_RESTIC_HOST_NATIVE` is loaded from `/etc/homelab/node.env`
      and passed to `homelab_backup_path "$SUDO" "${INSTALL_RESTIC_HOST_NATIVE:-}"`.
      The "Backup path: host-native" message reports whether the
      flag was set or only the timer was detected.
  - `setup-restic.sh`:
    - WARN (not refuse) when `restic-backup.timer` is enabled at
      lobaro deploy time. Suggests `systemctl disable --now
      restic-backup.timer`. The inverse direction (addon refuses
      while lobaro container runs) is enforced by the addon itself.
  - Verification (this session):
    - `bash -n` on every modified-or-touched script
      (`bootstrap.sh`, `setup-restic.sh`, `check-node.sh`,
      `lib.sh`, `_system/update-tailscale-ip.sh`,
      `addons/beszel-agent/install.sh`,
      `addons/restic-host-native/install.sh`,
      `addons/lib-addon.sh`, `backup.sh`,
      `change-restic-password.sh`): all pass.
    - Step-header audit: 7 ordered core steps + sub-steps 3a / 3b
      still in order; step 9 is now "Addon dispatch (after core
      is complete)"; step 10 (final notes) is unchanged.
    - Inline Beszel removal: `grep -E
      '^(beszel_ipv4_is_valid|beszel_ipv4_is_tailnet|
      beszel_parse_hub_url|beszel_collect_config|
      configure_beszel_agent)\(\)' bootstrap.sh` returns no matches.
      The only remaining Beszel references are the request-flag
      plumbing (`BESZEL_AGENT_REQUESTED_THIS_RUN`).
    - In-session test suite (`/tmp/opencode/wp5-test/run-tests.sh`,
      30 cases): PASS. Coverage:
      - 4 cases on `homelab_backup_path` with the original
        docker/timer heuristic (no flag).
      - 6 cases on `homelab_backup_path` with the WP5 flag
        override (flag=true with various docker/timer combos;
        flag=false explicit; flag unset).
      - 2 cases on `addon_assert_not_running` (lobaro running
        vs stopped).
      - 8 cases on `addon_persist_flag` (no duplicate keys on
        repeat writes; mode 600 preserved; comments and other
        keys preserved; value updates replace cleanly).
      - 3 cases on the restic-host-native mutual-exclusion
        check (refuses while lobaro running; advances when not;
        addon sources `addon_assert_not_running`).
      - 1 grep check on the setup-restic.sh WARN block.
      - 6 grep checks on bootstrap.sh step ordering, dead-unit
        cleanup, CLI flag presence, lib.sh flag registration,
        and check-node.sh flag plumbing.
      - 2 edge cases called out separately: addon_persist_flag
        rejects non-identifier keys; errors when
        homelab_format_kv is unavailable.
    - E2E verification (live `docker ps`, `docker inspect
      .State.Running`, live `systemctl is-enabled`, etc.) is
      deferred per AGENT.md §5 rule 5.

**Not done yet (next sessions).**

- None for the transformation brief. The post-laptop-1
  improvement batch (set -u hardening, restic validation, Beszel
  hub/agent/both, cloudflared-as-addon, perms policy) is complete
  — see CHANGES.md → "2026-08-22 (laptop-2 / improvement batch)".
  Live E2E is still deferred per §5 rule 5.

**Other.**

- `addons/{beszel-agent,beszel-hub,restic-host-native,cloudflared,
  lib-addon.sh,README.md}` implement the WP5 + laptop-2 contracts.
  Cloudflared moved from inline core to its own addon in the
  laptop-2 batch; the host binary path at
  `/usr/local/bin/cloudflared` and the apt metadata at
  `/etc/apt/sources.list.d/cloudflared.list` are no longer written
  by bootstrap (legacy artifacts are cleaned up idempotently on
  re-run).
- `beszel-agent/docker-compose.yml` template is unchanged.
- Post-laptop-1 permission policy (F3): stack dirs 755 root:root,
  compose 644, `.env` 600. `addon_root_only_dir` default changed
  from 700 to 755. `addon_persist_flag` still passes 700 for
  `/etc/homelab/`. The full matrix is in
  `addons/README.md` "Permissions policy".
- A previous planning artifact (`PLAN.md`, 1178 lines) remains deleted.
  If you see references to it in old commits or notes, ignore them.

---

## 1. Mission

Transform SelfhostedNode so that:

1. The **primary backup mechanism** is the lobaro/restic-backup-docker
   container deployed as a Compose stack at `/opt/stacks/restic-backup/`.
2. The current host-native restic path becomes an **optional addon** at
   `addons/restic-host-native/`, mutually exclusive with the lobaro
   container.
3. Tailscale IP is supplied by a single node-local env file that stacks
   consume via `--env-file` / `env_file:`. **No automatic upserts into
   application `.env` files.** (This is the AGENT.md-vs-PLAN.md
   resolution. PLAN.md is gone.)
4. All existing safety invariants are preserved (order, no lockout,
   secrets outside the backed-up tree, immutable node name, honest
   health checks).

Work in small, reviewable packages. After each package, the tree must be
in a consistent, testable state.

---

## 2. Locked Decisions (Non-Negotiable)

These decisions are final. Do not reverse them.

### Backup
- Primary path = `ghcr.io/lobaro/restic-backup-docker` deployed at
  `/opt/stacks/restic-backup/`.
- Secrets remain in `/etc/restic/` (outside `/opt/stacks`).
- Mount the **entire directory** `/etc/restic` read-only into the
  container. (Directory mount, not per-file mount — atomic
  `mv /etc/restic/password` inside the directory is visible to the next
  container invocation.)
- Use `RESTIC_PASSWORD_FILE=/etc/restic/password`. **Never** put the
  password in Compose `environment:` or in the stack `.env`.
- Generate a parallel `/etc/restic/env.docker` (raw `KEY=VALUE`, no
  shell quoting) for Compose `env_file:`. systemd and `lib.sh` continue
  to read the original `/etc/restic/env`.
- Host-side `restic cat config` / `restic init` **before** the container
  is started (defeat lobaro auto-init).
- Pin repository UUID to `/etc/restic/repo-id`. Health check must verify
  it.
- Node name drives the restic tag and the recommended bucket name.
- Prefer **bucket-per-node**; keep prefix-per-node as a supported
  fallback.
- Keep the host `restic` binary permanently (ground-truth health checks
  + break-glass restore).
- Host-native systemd path moves to `addons/restic-host-native/` and is
  mutually exclusive with the lobaro container.

### Tailscale IP
- Single source of truth: `/opt/homelab/env-file/tailscale.env`
- Content (minimum):
  ```
  TAILSCALE_IP=100.x.y.z
  ```
- Mode 644 (or 640), root-owned. This file is **not** a secret.
- Written atomically by an update script.
- Validate that the value is a Tailscale CGNAT address
  (`100.64.0.0/10`). If Tailscale is down or the address is invalid,
  **do not overwrite** the existing file.
- Stacks consume it with either:
  ```yaml
  env_file:
    - /opt/homelab/env-file/tailscale.env
    - .env
  ```
  or
  ```bash
  docker compose --env-file /opt/homelab/env-file/tailscale.env up -d
  ```
- In `ports:` use:
  ```yaml
  - "${TAILSCALE_IP:?TAILSCALE_IP missing — run update-tailscale-ip.sh}:hostport:containerport"
  ```
- **Do not** automatically rewrite any stack's own `.env` file.
- MagicDNS remains the preferred value for `SITE_URL`, browser access,
  and inter-service URLs. `TAILSCALE_IP` is only for bind addresses.

### Bootstrap & structure
- Keep a **single ordered** `bootstrap.sh`. Order remains load-bearing.
- Core ordering must stay:
  1. packages + Docker
  2. directory skeleton
  3. Tailscale install + `up` (hostname = NODE_NAME)
  4. Tailscale IP capture (write
     `/opt/homelab/env-file/tailscale.env`)
  5. UFW hardening + verification
  6. primary backup setup (lobaro)
  7. exit-node apply **last**
  8. optional addon dispatch
- True optional pieces become addons under `addons/<name>/install.sh`.
- Beszel agent moves to an addon.
- Host-native restic becomes an addon.
- cloudflared may stay in core for this iteration.

### Health
- `check-node.sh` must remain honest (non-zero exit when something is
  actually wrong).
- Ground truth for backups = host `restic snapshots` freshness +
  `repo-id` match.
- Also verify: lobaro container running, Tailscale IP file present and
  matches live `tailscale ip -4`, no mutual-exclusivity violation
  between backup paths.

### Explicit non-goals
- Do not redesign networking, UFW, or the Docker port-publishing model.
- Do not introduce ufw-docker or rewrite Docker's iptables.
- Do not put MagicDNS names into Docker port bind addresses.
- Do not make the Tailscale IP script rewrite application `.env` files
  that contain secrets. (This is the locked difference from the
  deleted PLAN.md.)
- Do not remove the host `restic` binary.
- Do not make the host-native path the default again.

---

## 3. Work Packages (Execute in This Order)

**Stop after each package for review unless the operator explicitly
says to continue.**

For each WP, the layout is:

- **Current state** — what the code does today (with file + line
  citations).
- **Target state** — what it should do.
- **Repo files touched** — explicit list so the next instance knows
  where to edit.
- **Deliverables** — concrete artifacts to produce.
- **Acceptance criteria** — how to know it's done.
- **Verification commands** — concrete `bash` snippets to run after
  editing.
- **Idempotency note** — what to do on re-run.

### WP1 — Tailscale IP SSOT

**Current state.** No SSOT exists. `check-node.sh` does not verify a
Tailscale IP file. Stacks either bind to `0.0.0.0` (bypasses UFW) or
have hand-maintained `TAILSCALE_IP=` lines in their `.env` files. See
`bootstrap.sh:683–687` (captures public IP only) and `check-node.sh`
(no IP-file section).

**Target state.** A single node-local file at
`/opt/homelab/env-file/tailscale.env` written atomically by a script,
refreshed by systemd after Tailscale restarts and periodically.
Stacks consume it via `env_file:` or `--env-file`. The file is never
overwritten with an invalid value.

**Repo files touched.**
- `_system/update-tailscale-ip.sh` (NEW — actual writer)
- `_system/update-tailscale-ip.service` (NEW — systemd oneshot)
- `_system/update-tailscale-ip.timer` (NEW — periodic refresh)
- `_system/tailscaled.service.d/override.conf` (NEW or modified —
  re-runs the IP update after Tailscale restart)
- `bootstrap.sh` — install the new script + units in the right order
  (after Tailscale `up`, before UFW/restic).
- `lib.sh` — add a `homelab_validate_tailscale_ip` helper
  (CGNAT check).
- `check-node.sh` — add IP-file verification (cross-reference: matches
  live `tailscale ip -4` when Tailscale is up).
- Docs: `README.md`, `RESTORE.md` (WP6 territory, but flag the
  existence of the file).

**Deliverables.**
- Directory `/opt/homelab/env-file/` (created by bootstrap / tooling
  install).
- Script that writes `/opt/homelab/env-file/tailscale.env` atomically.
- systemd oneshot + timer + `tailscaled` drop-in so the file is
  refreshed after Tailscale (re)starts and periodically.
- `check-node.sh` learns to verify the file exists, contains a valid
  CGNAT IPv4, and matches live `tailscale ip -4` when Tailscale is
  up.
- Documentation of the consumption contract (`env_file:` /
  `--env-file` + `${TAILSCALE_IP:?...}`).

**Acceptance criteria.**
1. After Tailscale is up, the file exists and contains the correct IP.
2. When Tailscale is down, the script exits non-zero and leaves the
   previous file untouched.
3. A compose file using `${TAILSCALE_IP:?...}` fails loudly if the
   variable is missing.
4. `check-node.sh` fails when the file is missing, invalid, or
   disagrees with live Tailscale IP.
5. No stack `.env` file is ever modified by this machinery.

**Status (WP1).** Acceptance criteria 1–5 are met by the code as
written. E2E verification (`tailscaled restart` round-trip,
`systemctl list-timers`, etc.) requires a live node; not executed in
this session.

**Verification commands.**
```bash
ls -la /opt/homelab/env-file/tailscale.env
cat /opt/homelab/env-file/tailscale.env
sudo /opt/stacks/_system/update-tailscale-ip.sh
sudo systemctl status update-tailscale-ip.timer
sudo systemctl list-timers update-tailscale-ip.timer
sudo /opt/stacks/_backup/check-node.sh   # IP section must PASS
sudo systemctl stop tailscaled
sudo systemctl start tailscaled
sleep 8
sudo /opt/stacks/_backup/check-node.sh   # IP section must PASS again
```

**Idempotency note.** Re-running `bootstrap.sh` must not destroy or
rewrite the file unless Tailscale is up and the new value is valid.
Atomic write pattern: write to tmpfile, validate, `mv` into place.

---

### WP2 — Lobaro Primary Backup Path

**Current state.** `setup-restic.sh` writes `/etc/restic/env` and
`/etc/restic/password`, initializes the repo with host `restic`, and
installs systemd units `restic-backup.{service,timer}` (lines
~330–362). The actual backup is `backup.sh` running as a systemd
oneshot. See `setup-restic.sh:1–372` and `backup.sh:1–112`.

**Target state.** The lobaro container is the primary backup mechanism.
Host-side init runs once. The container schedules its own cron
(BusyBox cron inside the container). `repo-id` is pinned. Stack lives
at `/opt/stacks/restic-backup/`. `/etc/restic/` is mounted read-only as
a directory. `/etc/restic/env.docker` is generated for Compose
`env_file:`. Host-native units are NOT installed by default.

**Repo files touched.**
- `setup-restic.sh` — major rewrite (most of WP2 lives here).
- `lib.sh` — add `homelab_repo_id` and `homelab_assert_repo_id_pinned`
  helpers.
- `bootstrap.sh` — invoke the new `setup-restic.sh` flow at step 6 of
  the ordering (currently step 6 already, just the contents change).
- `addons/restic-host-native/install.sh` — host-native path is moved
  here (stub exists; WP2 does not fill it in, WP5 does).
- New: a compose template for the lobaro stack. Either inline in
  `setup-restic.sh` or as a separate file (e.g. `setup-restic.lobaro.yml.tmpl`).
  Decide during WP2 and update AGENT.md §6 accordingly.
- `_system/README.md` — note that `setup-restic.sh` reads `lib.sh` for
  helpers.

**Deliverables.** (From AGENT.md §3 WP2, unchanged.)
- `setup-restic.sh` rewritten to:
  - collect/accept S3 details
  - write `/etc/restic/env` (existing format) and
    `/etc/restic/env.docker` (raw)
  - write password file
  - host-side init or verify existing repo
  - pin `/etc/restic/repo-id`
  - generate `/opt/stacks/restic-backup/docker-compose.yml` + non-secret
    `.env`
  - start the container
  - run a test backup and verify a snapshot with the correct tag exists
- Generated compose must:
  - set `hostname: "${NODE_NAME}"`
  - mount `/opt/stacks:/data:ro`
  - mount `/etc/restic:/etc/restic:ro`
  - use `RESTIC_PASSWORD_FILE=/etc/restic/password`
  - use `env_file: /etc/restic/env.docker`
  - never put the password in environment
- Cron expressions derived stably from `NODE_NAME` (spread daily
  window + weekly check).
- Host-native systemd units are **not** installed by default.

**Acceptance criteria.**
1. Container is running after setup.
2. A snapshot tagged with `NODE_NAME` exists.
3. `/etc/restic/repo-id` matches live `restic cat config`.
4. Password rotation via the existing `change-restic-password.sh` is
   visible to the next container backup without restarting the
   container.
5. Host `restic snapshots` still works using `/etc/restic/env`.
6. `check-node.sh` can see the new layout (even if full health updates
   come in WP3).

**Status (WP2).** Acceptance criteria 1, 3, 5 are satisfied by the
code as written (verified by reading + error-path tracing). Criteria 2,
4, and 6 require a live node and/or future WPs (`check-node.sh`
updates land in WP3).

**Verification commands.**
```bash
sudo docker ps --filter name=restic-backup
sudo docker inspect restic-backup --format '{{.State.Running}}'
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --tag "$NODE_NAME"'
sudo cat /etc/restic/repo-id
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic cat config --json | jq -r .id'   # must equal repo-id
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots'   # host restic still works
sudo cat /opt/stacks/restic-backup/.env   # must NOT contain RESTIC_PASSWORD
sudo docker inspect restic-backup --format '{{json .Config.Env}}' | jq -r '.[] | select(test("PASSWORD"))'   # must be empty
sudo docker logs restic-backup --tail 50   # cron / errors visible
```

**Idempotency note.** Re-running `setup-restic.sh` on an already-
configured node must (a) not rotate the password, (b) not change the
repo-id, (c) recreate the container only if its config drifted, (d)
regenerate the `.env` if missing but never silently overwrite
`RESTIC_PASSWORD_FILE`-related values.

---

### WP3 — Health Check Updates

**Current state.** `check-node.sh:1–298` is a single-file checker that
verifies Tailscale, UFW, restic (via host), Docker, and rough speed.
Does NOT verify lobaro container, repo-id, Tailscale IP SSOT, or
host-native-vs-lobaro mutual exclusion.

**Target state.** Same script, expanded: lobaro container running,
repo-id match, snapshot freshness (still host restic), secondary
signal from container error log, Tailscale IP SSOT checks (from WP1),
conditional host-native timer checks only when that addon is enabled,
mutual-exclusivity warning if both backup paths are active.

**Repo files touched.**
- `check-node.sh` — additions only; do not break existing checks.
- `lib.sh` — add helper for "which backup path is active?"

**Deliverables.**
- Container running check.
- `repo-id` match check.
- Snapshot freshness still measured via host restic.
- Secondary signal from container error log when useful.
- Tailscale IP SSOT checks (from WP1).
- Conditional host-native timer checks only when that addon is
  enabled.
- Mutual-exclusivity warning if both backup paths are active.

**Acceptance criteria.**
1. Healthy lobaro-primary node → exit 0.
2. Missing/wrong IP file, wrong repo-id, stale snapshot, or stopped
   container → non-zero exit.
3. Host-native-only node still works when that addon is installed.
4. Existing meaningful checks (UFW, Tailscale state, public publishes,
   etc.) remain.

**Status (WP3).** Acceptance criteria 1, 2, 3, 4 are satisfied by the
code as written. The first three require a live node for E2E; the
fourth is confirmed by `git diff` (UFW, Tailscale, Docker sections
unchanged) and the control-flow scenario tests in this session.

**Verification commands.**
```bash
sudo /opt/stacks/_backup/check-node.sh   # healthy → exit 0
sudo mv /etc/restic/repo-id /tmp/repo-id-bak
sudo bash -c 'echo "wrong-id" > /etc/restic/repo-id'
sudo /opt/stacks/_backup/check-node.sh   # exit 1, repo-id mismatch
sudo mv /tmp/repo-id-bak /etc/restic/repo-id
sudo docker stop restic-backup
sudo /opt/stacks/_backup/check-node.sh   # exit 1, container down
sudo docker start restic-backup
```

**Idempotency note.** Re-running the check is inherently idempotent
(it is a read-only checker). Re-running `bootstrap.sh` after WP3
must not reset any "acknowledged warning" state — the check is a
fresh read every time.

---

### WP4 — Bootstrap Integration

**Current state.** `bootstrap.sh:1–1119` is the full orchestrator. The
order is: base packages → directory skeleton → Tailscale → UFW →
identity persist → cloudflared → restic setup → state persist →
exit-node apply → Beszel. WP4 must preserve the safety ordering while
inserting: Tailscale IP SSOT step, and (if not already covered by
WP2) the new lobaro backup step. Beszel and cloudflared are still in
core for this iteration; addon dispatch happens in WP5.

**Target state.** New ordered steps inserted at the correct points
(IP capture after Tailscale `up`, lobaro setup before exit-node apply).
Directory skeleton includes `/opt/homelab/env-file/` and
`/opt/stacks/_system/` as needed. Tooling install copies the new
scripts. Re-run remains idempotent and non-destructive. Identity
immutability and public-SSH stickiness unchanged.

**Repo files touched.**
- `bootstrap.sh` — reorder/insert steps; copy `_system/*` into
  `/opt/stacks/_system/`; copy `addons/*/install.sh` into
  `/opt/stacks/_addons/` (or invoke directly from the repo path on
  first run — decide and document).
- `lib.sh` — add `homelab_install_system_scripts` helper.
- `addons/lib-addon.sh` — used by addon installers; bootstrap sources
  it when dispatching addons.

**Deliverables.**
- New ordered steps inserted at the correct points (IP capture after
  Tailscale up, lobaro setup before exit-node apply).
- Directory skeleton includes `/opt/homelab/env-file/` and
  `/opt/stacks/_system/` as needed.
- Tooling install copies the new scripts.
- Re-run remains idempotent and non-destructive.
- Identity immutability and public-SSH stickiness unchanged.

**Acceptance criteria.**
1. Fresh server bootstrap ends with: Tailscale up, IP file present,
   UFW correct, lobaro container running, snapshot present,
   `check-node.sh` exit 0.
2. Fresh client bootstrap respects exit-node-last ordering and
   deferred backup when required.
3. Re-run with the same arguments converges without damage.

**Verification commands.**
```bash
# fresh server
sudo ./bootstrap.sh --role=server --node-name=test-1 --advertise-exit-node
sudo /opt/stacks/_backup/check-node.sh   # exit 0
sudo cat /opt/homelab/env-file/tailscale.env   # present, valid CGNAT
sudo docker ps --filter name=restic-backup   # running

# fresh client
sudo ./bootstrap.sh --role=client --node-name=test-2 --use-exit-node=test-1
sudo /opt/stacks/_backup/check-node.sh   # exit 0

# re-run
sudo ./bootstrap.sh --role=server --node-name=test-1
sudo /opt/stacks/_backup/check-node.sh   # still exit 0, no destructive changes
```

**Idempotency note.** Every step must be re-runnable. The current
`bootstrap.sh` already enforces this for most steps; the new steps
must follow the same pattern (test existence, converge, never
overwrite without validation).

**Status (WP4).** WP4 was deliberately scoped to "verification +
bookkeeping only" by the operator this session. **No code changed
this WP.** The current `bootstrap.sh` (post-WP1–WP3) already
delivers every WP4 deliverable:

- The directory skeleton (step 2 at `bootstrap.sh:652–668`) creates
  `/opt/homelab/env-file` (mode 755) and `/opt/stacks/_system`.
- Step 3a (`bootstrap.sh:736–778`) copies `_system/*` to
  `/opt/stacks/_system/` with `cp -a`, installs the tailscaled
  drop-in, runs the writer once, and enables
  `update-tailscale-ip.timer`. This wires WP1 in at the correct
  point (after `tailscale up`, before UFW).
- Step 6 (`bootstrap.sh:998–1018`) invokes `setup-restic.sh`, which
  is the WP2 lobaro deployer. Server errors are fatal; client
  failures defer to the post-exit-node retry.
- Step 8 (`bootstrap.sh:1024–1107`) applies the exit node last,
  with probe + rollback. The pre-existing `setup-restic.sh`
  re-invocation in the deferred-restic branch (line 1092–1099)
  preserves WP2's "fresh client bootstrap respects exit-node-last
  ordering and deferred backup when required" guarantee.
- Identity immutability (`bootstrap.sh:559` role conflict;
  `bootstrap.sh:587` node-name conflict) and public-SSH stickiness
  (`KEEP_PUBLIC_SSH` plumbing at lines 407, 484–496, 802–816,
  906–939) are unchanged from prior sessions.
- Idempotency guards are present at every step (see §0 verification
  summary for citation list).

The WP4 brief's "optional addon dispatch (stub only if needed; full
addon work is WP5)" was **explicitly deferred to WP5 by operator
decision** — no half-wired stub dispatcher was added to
`bootstrap.sh`. The two addon stubs at
`addons/beszel-agent/install.sh` and
`addons/restic-host-native/install.sh` continue to `exit 1` as
before. WP5 will deliver both the dispatcher and the addon bodies
together.

Acceptance criteria:
1. Fresh-server end-state — wired by step 3a (Tailscale IP file),
   step 4 (UFW), step 6 (lobaro container). WP3 ensures
   `check-node.sh` exit 0 on a healthy lobaro-primary node.
2. Fresh-client exit-node-last ordering and deferred backup — wired
   by step 8 with the deferred-restic re-invocation branch.
3. Re-run with the same arguments — wired by the `PERSISTED_*` /
   `NODE_ENV_EXISTS` defaults at `bootstrap.sh:418–497` plus the
   per-step existence guards (e.g. `[[ ! -d ]]` at step 2,
   `command -v` checks at step 3, `command -v docker` short-circuit
   inside `homelab_backup_path` for the backup-path classifier).

E2E verification (fresh server, fresh client, re-run) on a live
node is deferred per AGENT.md §5 rule 5 ("stop after each WP for
review"). In-session verification covered syntax, step ordering,
guard presence, identity immutability, public-SSH stickiness, and
the absence of a new addon dispatch step.

---

### WP5 — Addon Pattern + Moves

**Current state.** `configure_beszel_agent` is inline in
`bootstrap.sh:303–382`. The template at `beszel-agent/docker-compose.yml`
is used by that function. Cloudflared install logic is also inline
(`bootstrap.sh:78–172`). The host-native restic path is inline in
`setup-restic.sh` and `bootstrap.sh` invokes it at step 6.

**Target state.** Addons live under `addons/<name>/install.sh`. The
addon contract (validate → atomic write → start → verify running →
only then persist `INSTALL_*=true`) is documented in
`addons/README.md`. Beszel and host-native restic become addons.
Bootstrap calls addons only after core is complete.

**Repo files touched.**
- `addons/beszel-agent/install.sh` — fill in the stub. Reuse logic
  from `bootstrap.sh:configure_beszel_agent`.
- `addons/restic-host-native/install.sh` — fill in the stub. Install
  `backup.sh` + `restic-backup.{service,timer}` + integration with
  `change-restic-password.sh`. Refuse to install if lobaro container
  is running.
- `addons/cloudflared/install.sh` — OPTIONAL this iteration. If
  scope allows, move cloudflared here. Otherwise backlog.
- `addons/lib-addon.sh` — already created; flesh out the shared
  helpers (`addon_log`, `addon_root_only_dir`, `addon_install_flag`,
  `addon_mutual_exclusion_check`).
- `bootstrap.sh` — replace inline Beszel logic with a call to
  `addons/beszel-agent/install.sh`. Same for host-native restic if
  invoked manually (it shouldn't be invoked by bootstrap anymore;
  it's an explicit addon install).

**Deliverables.**
- `addons/` layout and shared helpers (already exists as stubs).
- `addons/beszel-agent/install.sh` (behaviour identical to current
  Beszel path).
- `addons/restic-host-native/install.sh` (installs the old systemd
  path, mutually exclusive with lobaro).
- Bootstrap calls addons only after core is complete.
- Clear contract: validate → atomic write → start → verify running →
  only then persist `INSTALL_*=true`.

**Acceptance criteria.**
1. Beszel install via addon produces the same running result as
   before.
2. Host-native addon refuses to install while lobaro container is
   running (and vice versa).
3. Addons are re-run safe.
4. Core bootstrap no longer contains the old inline Beszel
   implementation.

**Verification commands.**
```bash
# Beszel
sudo ./addons/beszel-agent/install.sh   # installs, container running
docker ps --filter name=beszel-agent
sudo grep INSTALL_BESZEL_AGENT /etc/homelab/node.env

# host-native mutual exclusion
docker ps --filter name=restic-backup   # running
sudo ./addons/restic-host-native/install.sh   # must REFUSE
docker stop restic-backup
sudo ./addons/restic-host-native/install.sh   # now installs

# re-run safety
sudo ./addons/beszel-agent/install.sh   # must be a no-op or safe update
```

**Idempotency note.** Each addon must be re-runnable. `INSTALL_*=true`
flags in `node.env` must only be persisted **after** the running
container/unit is verified.

**Status (WP5).** Acceptance criteria 1–4 are satisfied by the code
as written.

- **AC1 (Beszel install via addon produces the same running result
  as before).** `addons/beszel-agent/install.sh` carries the full
  pre-WP5 implementation, with the `beszel_*` helper functions
  copied into the addon so it stays self-contained. The operational
  sequence matches: validate inputs → validate hub URL syntax +
  reachability → `addon_root_only_dir` for the stack dir → atomic
  copy of the compose template via `install -m 0644` →
  `addon_root_only_file` for `.env` at mode 600 → `docker compose up
  -d` → verify `docker inspect -f '{{.State.Running}}' beszel-agent`
  is `true` → `addon_persist_flag INSTALL_BESZEL_AGENT true`. The
  only behavioural difference vs the pre-WP5 path is where the
  helpers live (addon vs bootstrap), and that credentials are
  collected by the addon instead of pre-collected by bootstrap.
  Verification on a live node (`docker ps --filter name=beszel-agent`
  + `docker inspect .State.Running`) is deferred per §5 rule 5.

- **AC2 (host-native addon refuses while lobaro container is
  running).** `addons/restic-host-native/install.sh` calls
  `addon_assert_not_running restic-backup` as its first action after
  requiring root and setting up `ADDON_SUDO`. The helper performs
  `docker inspect -f '{{.State.Running}}' restic-backup` and exits
  non-zero with a clear remediation message (`docker stop
  restic-backup`) when the container is running. The inverse
  direction is enforced by `setup-restic.sh` as a WARN (not refuse)
  per the WP5 brief — operators are not blocked during migration
  windows. In-session tests T3 (addon helper) and T5 (addon uses
  the helper) confirm this end-to-end.

- **AC3 (re-run safe).** Both addons use `install(1)` for atomic
  file copies (overwrite-safe), `systemctl enable --now` /
  `docker compose up -d` for idempotent activation, and
  `addon_persist_flag` for atomic upsert (no duplicate keys on
  repeat writes — verified by T4 cases 3–4). The host-native addon
  never touches `/etc/restic/` or `/var/cache/restic/` (data
  volume preserved across re-runs). The Beszel addon regenerates
  `.env` from the latest exported credentials on every run; existing
  credentials survive if the env vars are still set.

- **AC4 (core bootstrap no longer contains the old inline Beszel
  implementation).** `configure_beszel_agent` and the seven `beszel_*`
  helpers (`beszel_same_host_override`, `beszel_ipv4_is_valid`,
  `beszel_ipv4_is_tailnet`, `beszel_parse_hub_url`,
  `beszel_validate_hub_url_syntax`,
  `beszel_validate_hub_url_reachability`, `beszel_collect_config`)
  were removed from `bootstrap.sh` lines ~178–386 (203 lines).
  Grep confirms zero remaining function definitions or calls to
  these names in `bootstrap.sh` (only the request-flag plumbing
  `BESZEL_AGENT_REQUESTED_THIS_RUN` and a one-line comment at
  `:178` remain). Step 9 in `bootstrap.sh` is now "Addon dispatch"
  and invokes `addons/beszel-agent/install.sh` /
  `addons/restic-host-native/install.sh` only when the
  corresponding request flag was set THIS run.

**WP5 extras (per the operator brief, not in the original WP5 §3
deliverables).**

- `lib.sh` registers `INSTALL_RESTIC_HOST_NATIVE` in
  `HOMELAB_NODE_ENV_KEYS` so `check-node.sh` and any future
  consumer can load it through the existing safe loader.
- `homelab_backup_path` accepts a `$2 INSTALL_RESTIC_HOST_NATIVE`
  override. When the flag is `"true"`, the host-native classification
  wins over the unit-file heuristic. The unit heuristic is the
  fallback (no second arg, or empty / `"false"`).
- `setup-restic.sh` adds a post-deploy WARN when
  `restic-backup.timer` is enabled at the moment the lobaro
  container was brought up.
- `bootstrap.sh` step 2's file-copy loop stops copying
  `backup.sh` / `restic-backup.{service,timer}` to
  `/opt/stacks/_backup/` / `/etc/systemd/system/`. Those files now
  reach those paths ONLY via the restic-host-native addon.
- `bootstrap.sh` adds a new CLI flag `--install-restic-host-native`
  plus a `RESTIC_HOST_NATIVE_REQUESTED_THIS_RUN` per-run state
  variable (parity with `--beszel-agent` / `BESZEL_AGENT_REQUESTED_THIS_RUN`).
- Identity immutability and public-SSH stickiness are unchanged
  (WP4 invariants preserved).

- **Docs & Restore** (WP6) is in place. Documentation now matches
  the post-WP5 reality:
  - `README.md` — rewrote the "Architecture" section (lobaro primary,
    host-native as opt-in addon, Tailscale IP SSOT path,
    `env_file:` / `--env-file` consumption contract, MagicDNS for
    app URLs); expanded the "How the safe ordering works" list to
    include steps 3a (Tailscale IP SSOT install) and 9 (addon
    dispatch); split the "Files" table into "repo source layout" vs
    "addon-only file sources"; rebrand Beszel as an addon (notes
    the credential-prompt timing shift).
  - `RESTORE.md` — rewritten for the lobaro-primary layout. New
    table of "what is backed up vs what must be restored from
    password manager vs what is regenerated"; explicit step 1
    "place secrets first including `repo-id`"; new step 1b "verify
    the repo-id pin matches live `restic cat config`"; new step 5a
    "regenerate the Tailscale IP SSOT"; Notes section adds the
    `CronTimeZone=UTC` caveat and a paragraph on the dormant
    `backup.sh` / `restic-backup.{service,timer}` with a
    cross-reference to `addons/restic-host-native/install.sh`.
  - `RISKS.md` — refreshed preamble to reference the post-WP5
    layout; new accepted-risk categories (addon failure does not
    roll back core; Beszel helper duplication; Beszel credential
    timing shift; lobaro `CronTimeZone=UTC`; no
    `Persistent=true` for container cron; `env.docker` raw
    format; mutual-exclusivity WARN semantics; Beszel `.env` is
    inside the backup intentionally).
  - `TESTING.md` — sections 1, 2, 3, 7, 8, 11, 13 updated for
    the post-WP5 layout (lobaro container instead of `backup.sh`
    in §2 and §11; Tailscale IP SSOT expectations in §1, §3, §7;
    Beszel rebrand in §13); five new sections:
    - §14 repo-id pin mismatch (corrupt the pin, expect FAIL)
    - §15 Tailscale IP SSOT validation (drop / corrupt the
      file, expect FAIL)
    - §16 host-native restic addon install
    - §17 addon mutual exclusion (addon refuses when lobaro
      running; setup-restic.sh warns on the inverse)
    - §18 addon re-run safety (no duplicate keys, data
      preserved)
    - §19 explicitly marks live-node E2E as deferred per
      AGENT.md §5 rule 5.
  - `goal.md` — kept as historical context per AGENT.md §3 WP6
    (do not delete). Added a status note at the top
    cross-referencing WP1–WP6; updated §3 to call out the WP1–WP5
    closures (Tailscale IP SSOT, lobaro primary, honest health
    checks, addon pattern); refreshed §6 file table to include
    the addon files. No intent change.
  - `AGENT.md` — this file. §0 status line ticks WP6; §3 WP6
    gains a **Status (WP6)** block (below); §4 confirmation
    checklist ticks the "Documentation matches the above" item.
    No locked decisions were touched.
  - `CHANGES.md` — dated WP6 entry at the top.

---

### WP6 — Docs & Restore

**Current state.** `README.md`, `RESTORE.md`, `CHANGES.md`,
`RISKS.md`, `TESTING.md`, `goal.md` describe the host-native path as
the default. WP6 reconciles docs with the new lobaro-primary reality.

**Target state.** `RESTORE.md` updated for lobaro-primary + Tailscale
IP file + "place secrets first". All docs reflect: lobaro is primary,
host-native is an addon, Tailscale IP SSOT is real and required,
MagicDNS preferred for browser access.

**Repo files touched.**
- `README.md` — rewrite the role/architecture summary.
- `RESTORE.md` — add section on restoring the Tailscale IP file
  (regenerate via `update-tailscale-ip.sh` on the new node).
- `CHANGES.md` — append a dated entry summarizing WP1–WP5.
- `RISKS.md` — refresh accepted risks list (e.g. cloudflared fallback,
  CronTimeZone=UTC, no `Persistent=true` equivalent for container
  cron, AWS env-file reload requirement).
- `TESTING.md` — add sections for lobaro container, repo-id mismatch,
  Tailscale IP file checks, addon mutual exclusion.
- `goal.md` — KEEP as historical context. Do not delete. Add a
  one-paragraph note at top: "Historical intent document. See
  AGENT.md for the current transformation target."

**Deliverables.**
- `RESTORE.md` updated for lobaro-primary + Tailscale IP file +
  "place secrets first".
- `README.md`, `CHANGES.md`, `RISKS.md`, `TESTING.md`, `goal.md`
  updated.
- Explicit note that `/opt/homelab/env-file/tailscale.env` is
  node-local and must be regenerated on a new node.

**Acceptance criteria.**
1. A reader following only `RESTORE.md` can recover a node.
2. No docs still describe the host-native path as the default.

**Verification commands.** No automated verification for docs. Read
through each file and confirm no `goal.md`-era statements remain as
"current."

**Status (WP6).** Acceptance criteria 1–2 are satisfied by the doc
edits this WP produced.

- **AC1 (RESTORE.md is self-sufficient for node recovery).**
  `RESTORE.md` now: opens with a "what is / is not backed up" table;
  lists `repo-id` as a prerequisite (placed from the password manager
  alongside `env` and `password`); adds a step 1b that runs
  `homelab_assert_repo_id_pinned` BEFORE `bootstrap.sh`, so the
  operator fails fast on a wrong-pin / wrong-bucket combination; uses
  `cp -a` to restore stacks (preserves ownership); runs the same
  `bootstrap.sh` non-destructively (existing `/etc/restic/env`
  causes `setup-restic.sh` to keep the repository); explicitly
  regenerates the Tailscale IP SSOT in step 5a (the file is
  node-local and not in the backup); and starts the lobaro container
  + non-backup stacks in step 6. The Notes section calls out
  `CronTimeZone=UTC` and the dormant state of the restored
  `_backup/backup.sh` / `restic-backup.{service,timer}` (WP5
  removed the dead-copy default), with a one-line cross-reference
  to `addons/restic-host-native/install.sh` for operators who want
  the host-native path back.

- **AC2 (no docs describe the host-native path as the default).**
  Verified by:
  - `README.md` — the new "Architecture" section names the lobaro
    container as the primary backup mechanism and explicitly puts
    the host-native systemd path under "Addons" with the
    descriptor "is **not** installed by bootstrap".
  - `README.md` File table — `backup.sh`, `restic-backup.{service,
    timer}` are in a separate table titled "These files reach the
    running node **only** via the addon installers (post-WP5 — no
    longer auto-copied by bootstrap)".
  - `RISKS.md` — refreshed preamble names the post-WP5 layout
    (lobaro-primary backup, Tailscale IP SSOT, addon pattern);
    the "Backup path" risk section calls out CronTimeZone=UTC and
    the mutual-exclusivity WARN semantics.
  - `TESTING.md` — sections 1, 2, 3, 7, 11 now reference
    `docker exec restic-backup /bin/backup` instead of
    `backup.sh`; section 1 explicitly expects
    `systemctl is-enabled restic-backup.timer` to fail (host-
    native is not auto-installed); section 13 rebrand the Beszel
    installer as an addon; new sections §16 / §17 / §18 cover
    the host-native addon, mutual exclusion, and re-run safety.
  - `goal.md` — kept as historical context per AGENT.md §3 WP6.
    Added a status note at the top + a "Closed by WP1–WP5"
    paragraph in §3, and refreshed §6 to list the addon files.
    No intent change; the project goal is unchanged.
  - `AGENT.md §4` — the "Documentation matches the above"
    confirmation checklist item is now ticked. No locked
    decisions were touched.

**WP6 verification (in-session):**

- `bash -n` on every script: pass. WP6 made **no** behavioural
  changes to bootstrap, restic, health, or addons.
- Doc-vs-code claim audit (cross-checked every claim in the
  rewritten sections against the cited line numbers in scripts):
  each row matches. See CHANGES.md → WP6 → "Doc claims vs code"
  for the full table.
- Grep audit: zero matches for the goal.md-era framing of
  `backup.sh` as "the daily backup script installed verbatim"
  in `README.md` (the new line is under the addon-only table).
  `RESTORE.md` no longer says "follow `RESTORE.md` and run
  `backup.sh`" — the new flow uses `docker exec`.

**WP6 residual doc gaps (carried forward to WP7+):**

- The lobaro-image's `BACKUP_CRON` is documented as a "stable
  per-node UTC expression derived from NODE_NAME" but the actual
  hash and the `cron_from_node_name` formula live in
  `setup-restic.sh:cron_from_node_name`. WP7+ may lift that into
  `README.md` for operators who want to predict the exact window.
- The Beszel `.env.example` in `beszel-agent/.env.example` still
  contains placeholder values (`ssh-ed25519 AAAA_replace…`). The
  README explicitly warns against committing real credentials;
  no further doc change needed.
- `addons/cloudflared/install.sh` is mentioned as a "candidate"
  in `addons/README.md` and absent from `README.md`'s Addons
  table. Backlog per the WP5 brief (cloudflared stays in core
  this iteration).
- The new `TESTING.md` sections §14–§18 are not yet exercised on
  a live node — section §19 marks them as deferred per AGENT.md
  §5 rule 5.

---

### WP7 — Migration Path

**Current state.** Existing nodes deployed before this transformation
have host-native restic and no Tailscale IP SSOT. WP7 provides a
one-shot migration helper.

**Target state.** A migration helper that pins repo-id, stops the old
timer, deploys lobaro against the existing repo, verifies, and
optionally removes the old units. Documented rollback to host-native
addon.

**Repo files touched.**
- New: `migrate-to-lobaro.sh` at repo root. (Decided during WP7:
  dedicated helper, NOT a subcommand on `setup-restic.sh` and NOT
  stuffed into `bootstrap.sh`. See brief: "Prefer a dedicated helper
  over stuffing logic into bootstrap.")
- New: `MIGRATION.md` — operator recipe.
- `bootstrap.sh` — thin CLI flag `--migrate-from-host-native` and a
  step-6b dispatch that calls `migrate-to-lobaro.sh`.
- `RESTORE.md` — one cross-reference sentence in the Notes section.
- `TESTING.md` — add migration test sequence (§20).
- `CHANGES.md` — append migration entry.
- `AGENT.md` — this file. §0 status ticks WP7; §3 WP7 Status block;
  §4 checklist gains a WP7 row; §6 reference table gains a row for
  `migrate-to-lobaro.sh`.

**Deliverables.**
- One-shot migration helper that pins repo-id, stops the old timer,
  deploys lobaro against the existing repo, verifies, and optionally
  removes the old units.
- Documented rollback to host-native addon.

**Acceptance criteria.**
1. Existing snapshots remain.
2. New snapshots appear under the same tag.
3. `check-node.sh` exit 0 after migration.
4. Failure leaves the node in a recoverable state.

**Verification commands.**
```bash
# Pre-migration: confirm host-native is active
sudo systemctl status restic-backup.timer
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --tag "$NODE_NAME"'

# Migrate
sudo ./migrate-to-lobaro.sh   # or sudo ./bootstrap.sh --migrate-from-host-native

# Post-migration
sudo docker ps --filter name=restic-backup   # running
sudo cat /etc/restic/repo-id
sudo bash -c 'source /opt/stacks/_backup/lib.sh; homelab_restic snapshots --tag "$NODE_NAME"'   # snapshots preserved, new one appended
sudo /opt/stacks/_backup/check-node.sh   # exit 0
```

**Idempotency note.** Re-running the migration on an already-migrated
node is a clean **exit 0** with a "already migrated; nothing to do"
message (per operator preference: re-running by mistake must not look
like a failure). Running it on a node with no `restic-backup.timer`
enabled is an **exit 1** with a clear refusal (wrong tool for this
node — `setup-restic.sh` is the alternative path).

**Status (WP7).** Acceptance criteria 1–4 are satisfied by the code
as written.

- **AC1 (existing snapshots remain).** The helper pins
  `/etc/restic/repo-id` if missing (or hard-fails on a pin/live
  mismatch, matching `setup-restic.sh:325-329`), then delegates the
  container deployment to `setup-restic.sh`'s `REUSE_EXISTING` branch
  (`setup-restic.sh:109-125, 198-203`). `REUSE_EXISTING` keeps
  `/etc/restic/env` and `/etc/restic/password` and never calls
  `restic init` against a healthy repo. After the deploy, the helper
  captures a snapshot count under the `NODE_NAME` tag BEFORE
  `setup-restic.sh` runs, then re-counts AFTER; if the count
  decreases it exits 1 with a hard error. Existing IDs that were
  present before are still present after.

- **AC2 (new snapshots appear under the same tag).** The lobaro
  container is configured with `RESTIC_TAG=$NODE_NAME` (via the
  WP2-derived `setup-restic.sh` template substitution). Node-name
  immutability (`bootstrap.sh:559, :587`) ensures the tag never
  drifts. A manual `docker exec restic-backup /bin/backup` after
  migration creates a new snapshot under the same tag; the next
  BusyBox cron window does the same.

- **AC3 (`check-node.sh` exit 0 after migration).** The helper invokes
  `check-node.sh` as part of its post-deploy verification. The exit
  code is logged; a non-zero result is a WARN (the migration itself
  succeeded — container running, repo-id pinned, snapshots preserved
  — but the health check may flag an unrelated issue). On a healthy
  restored migration the health check exits 0.

- **AC4 (failure leaves the node recoverable).** The only destructive
  side effect on a failed migration is `systemctl disable --now
  restic-backup.timer` (step 3 of the helper). After that point,
  every error path prints a rollback recipe to stderr:
  `sudo ./addons/restic-host-native/install.sh` +
  `sudo systemctl enable --now restic-backup.timer`. Nothing under
  `/etc/restic/`, `/var/cache/restic/`, or the addon source files is
  ever touched. The repository and password are unchanged on disk
  and on S3.

- **Mutual exclusion during the window.** `check-node.sh` already
  WARNs (does not fail) when both paths are active (`check-node.sh:
  268-269`), which is the operator's signal during the brief moment
  between `setup-restic.sh` bringing the lobaro container up and the
  helper disabling the host-native timer. The helper itself stops
  the timer BEFORE `setup-restic.sh` runs, so the steady state after
  a successful migration is lobaro-only.

- **Bootstrap dispatch.** `bootstrap.sh --migrate-from-host-native`
  forwards `HOMELAB_NONINTERACTIVE`, refuses if
  `migrate-to-lobaro.sh` is missing, calls the helper, and on success
  reloads `INSTALL_RESTIC_HOST_NATIVE` from `/etc/homelab/node.env`
  so the step-7 `write_node_env` does NOT overwrite the helper's
  freshly-persisted `INSTALL_RESTIC_HOST_NATIVE=false` with the
  legacy `"true"` loaded at startup. Step ordering audit
  (`grep -n '^# ---------- ' bootstrap.sh`) confirms
  1→2→3→3a→3b→4→5→6→6b→7→8→9→10 in order; step 6b is between step 6
  (restic setup) and step 7 (state persistence), and BEFORE step 9
  (addon dispatch) so the host-native addon does not run against a
  freshly-deployed lobaro container.

- **Re-run safety.** Re-running the migration on an already-migrated
  node is a no-op (exit 0, "already migrated"). Re-running on a
  failed-migration node (timer disabled, no container) re-enters at
  step 1 and either completes the migration or prints the rollback
  recipe. `addon_persist_flag` upserts the flag in
  `/etc/homelab/node.env` without duplicating keys (WP5 contract).

- **E2E verification** (live throwaway VPS): deferred per §5 rule 5.
  The WP7 test suite (`/tmp/opencode/wp7-test/run-tests.sh`, 32
  cases) covers static + idempotency + ordering properties:
  idempotency preconditions (lobaro running → exit 0; timer not
  enabled → exit 1; both preconditions absent → first non-timer
  precheck), flag parsing (`--help`, `--purge-host-native-units`,
  `--yes`), `MIGRATE_FROM_HOST_NATIVE_THIS_RUN` plumbing, step
  ordering, rollback recipe presence, repo-id pinning logic,
  `addon_persist_flag` write + bootstrap reload, snapshot-count
  preservation, and edge cases (missing `/etc/restic/env`, missing
  `/etc/homelab/node.env`).

---

## 4. Exact Final State (What "Done" Looks Like)

When all required packages are complete, the system must match the
following.

### On-disk layout (node)

```text
/opt/homelab/env-file/tailscale.env          # TAILSCALE_IP=... (node-local, regenerated)
/opt/stacks/restic-backup/
  docker-compose.yml                         # lobaro container, hostname=NODE_NAME
  .env                                       # non-secrets only (cron, tag, args)
/opt/stacks/_backup/                         # host tooling (check-node, change-password, lib)
/opt/stacks/_system/                         # update-tailscale-ip.sh and related units/scripts
/opt/stacks/beszel-agent/                    # only if addon installed
/etc/restic/
  env                                        # systemd / lib.sh format
  env.docker                                 # raw format for Compose
  password                                   # mode 600
  repo-id                                    # pinned UUID
  recovery-key.present                       # marker only
/etc/homelab/node.env                        # identity + INSTALL_* flags + lockdown state
```

### Runtime behaviour

- `docker ps` shows `restic-backup` running (unless the operator
  deliberately stopped it).
- `restic snapshots --tag <NODE_NAME>` (from host, using
  `/etc/restic/env`) shows recent snapshots.
- `/opt/homelab/env-file/tailscale.env` matches live `tailscale ip -4`
  when Tailscale is up.
- Stacks that need a Tailscale bind address use
  `env_file: /opt/homelab/env-file/tailscale.env` (or the equivalent
  CLI flag) and `${TAILSCALE_IP:?...}` in `ports:`.
- **No stack `.env` is rewritten by the Tailscale IP machinery.**
- `check-node.sh` exits 0 on a healthy node and non-zero on real
  failures (stale snapshot, wrong repo-id, missing/mismatched IP
  file, container down, UFW/Tailscale problems, etc.).
- Host-native restic units are absent unless the operator explicitly
  installed the addon.
- Password rotation via `change-restic-password.sh` affects the next
  container backup without a container restart.
- Re-running `bootstrap.sh` with the same `--node-name` and role is
  safe and idempotent.

### Confirmation checklist (must all be true)

- [x] Primary backup is the lobaro container under
      `/opt/stacks/restic-backup/`. — **WP2 done.**
- [x] Secrets live only under `/etc/restic/` and are mounted as a
      directory. — **WP2 done: `/etc/restic` mounted read-only.**
- [x] `RESTIC_PASSWORD` never appears in Compose environment.
      — **WP2 done: only `RESTIC_PASSWORD_FILE` is passed; container
      reads the file at `/etc/restic/password`.**
- [x] `/opt/homelab/env-file/tailscale.env` is the sole SSOT for
      Tailscale IP. — **WP1 done.**
- [x] No automatic mutation of per-stack `.env` files occurs.
      — **WP1 confirmed: writer only touches `/opt/homelab/env-file`.
      WP2 stack `.env` is written by `setup-restic.sh` itself.**
- [x] Node name is still immutable and drives tag + hostname.
      — Pre-existing invariant, untouched.
- [x] Host `restic` binary remains installed and is used for health +
      restore. — Pre-existing invariant, untouched.
- [x] `check-node.sh` is honest for the new layout. — **WP3 done:
      backup-path detection, lobaro container check, repo-id match,
      conditional host-native timer check, mutual-exclusivity WARN,
      container error-log secondary signal. UFW / Tailscale / Docker
      sections unchanged.**
- [x] Core bootstrap ordering is intact (exit-node still last).
      — **WP1 added step 3a BEFORE UFW; step 8 exit-node still last.
      WP4 re-verified in-session: step-header audit confirms the 7
      ordered core steps are present at the expected line numbers
      and in the expected order; step 8 is the last routing step
      before the still-inline Beszel block.**
- [x] Beszel and host-native restic are addons, not core defaults.
      — **WP5 done.** `configure_beszel_agent` + 7 `beszel_*`
      helpers removed from `bootstrap.sh`. Step 9 in `bootstrap.sh`
      is now "Addon dispatch (after core is complete)" and only
      runs when a request flag was set THIS run. The
      `addons/beszel-agent/install.sh` and
      `addons/restic-host-native/install.sh` installers implement
      the validate → atomic write → start → verify running → persist
      contract. `INSTALL_RESTIC_HOST_NATIVE` is the new
      `HOMELAB_NODE_ENV_KEYS` entry; `homelab_backup_path` prefers
      it over the unit-file heuristic.
- [x] Documentation matches the above. — **WP6 done.**
      `README.md` rewritten (Architecture summary, Tailscale IP
      SSOT section, Addons table, File table split between
      "repo source layout" and "addon-only file sources");
      `RESTORE.md` rewritten for lobaro-primary layout with a
      "place secrets first including `repo-id`" step 1 and a
      "regenerate Tailscale IP SSOT" step 5a; `RISKS.md`
      refreshed with WP1–WP5 residual risks (lobaro
      `CronTimeZone=UTC`, no `Persistent=true` for container
      cron, `env.docker` raw format, mutual-exclusivity WARN,
      addon helper duplication, Beszel credential UX timing
      shift); `TESTING.md` updated for the lobaro-primary
      reality and extended with §14–§18 (repo-id pin mismatch,
      IP SSOT validation, host-native addon, mutual
      exclusion, addon re-run safety) plus §19 explicitly
      marking live-node E2E as deferred per §5 rule 5;
      `goal.md` kept as historical context with a status note
      at top + §6 file-table refresh (no intent change).
- [x] Host-native → lobaro migration is supported. — **WP7 done.**
      `migrate-to-lobaro.sh` at the repo root (idempotent: re-run on
      an already-migrated node is exit 0 "already migrated"; re-run
      on a node with no host-native timer is exit 1 "wrong tool").
      Pins `/etc/restic/repo-id` if missing; hard-fails on mismatch.
      Stops + disables `restic-backup.timer` before delegating to
      `setup-restic.sh`'s `REUSE_EXISTING` branch (no re-init against
      a healthy repo). Verifies container + repo-id + snapshot count
      preservation; on failure after the timer is disabled, prints the
      exact rollback recipe (`addons/restic-host-native/install.sh`
      + `systemctl enable --now restic-backup.timer`). `bootstrap.sh`
      gains a thin `--migrate-from-host-native` flag wired as step
      6b (between step 6 and step 7) which forwards
      `HOMELAB_NONINTERACTIVE`, calls the helper, and reloads
      `INSTALL_RESTIC_HOST_NATIVE` from `/etc/homelab/node.env` so
      the step-7 `write_node_env` does not overwrite the helper's
      freshly-persisted `INSTALL_RESTIC_HOST_NATIVE=false` with the
      legacy `"true"` loaded at startup. Default behaviour keeps the
      host-native unit files on disk for rollback; `--purge-host-native-units`
      removes them. `MIGRATION.md` documents the operator recipe
      (prerequisites, command variants, idempotency, post-migration
      verification, rollback for both success and failure paths,
      what the script does NOT do). `RESTORE.md` Notes section gains
      a cross-reference to `MIGRATION.md`. `TESTING.md` §20 covers
      the migration window on a throwaway VPS (marked live-deferred
      per §5 rule 5).

If any item on this checklist is false, the transformation is **not**
complete.

---

## 5. Rules of Engagement for the Implementing Agent

1. Read the entire `§0 Current State`, `§2 Locked Decisions`, and
   `§3 Work Packages` before making changes.
2. Read the **Current state** sub-section of the WP you are working
   on. The file + line citations point at the existing code.
3. Make the smallest change that satisfies the current work package.
4. After each work package, stop and present:
   - what changed (files touched, diff summary)
   - how to verify the acceptance criteria (run the **Verification
     commands** block)
   - any residual risk introduced
5. Do not start the next package until the operator confirms or
   explicitly authorises continuation.
6. Never commit secrets. Never put the restic password into Compose
   files or stack `.env` files.
7. When in doubt about Tailscale IP distribution, re-read the locked
   decision: SSOT file + `env_file:` / `--env-file` only. **No**
   upsert into application `.env` files. (This is the AGENT.md-vs-
   PLAN.md resolution. PLAN.md is gone.)
8. When in doubt about backup identity, re-read: host-side init
   first, `repo-id` pin, host restic remains the ground truth.
9. If a WP leaves the tree in an inconsistent state, do NOT start the
   next WP — fix it or report.
10. After each WP, follow `§7 Auto-Update Instructions` before
    handing off.

---

## 6. Reference Paths (Quick)

### Runtime ↔ repo paths

| Item | Runtime path | Repo path (source of truth) |
|------|--------------|----------------------------|
| Tailscale IP SSOT | `/opt/homelab/env-file/tailscale.env` | generated by `_system/update-tailscale-ip.sh` (installed at `/opt/stacks/_system/update-tailscale-ip.sh`); refreshed by `update-tailscale-ip.timer` (every 15 min) and `tailscaled.service.d/override.conf` |
| Lobaro stack | `/opt/stacks/restic-backup/` | generated by `setup-restic.sh` from `setup-restic.lobaro.yml.tmpl` at the repo root (WP2 decided: separate template) |
| Lobaro compose template | `setup-restic.lobaro.yml.tmpl` (repo root) | substituted by `setup-restic.sh` (placeholders `__NODE_NAME__`, `__BACKUP_CRON__`, `__CHECK_CRON__`, `__RESTIC_FORGET_ARGS__`, `__RESTIC_JOB_ARGS__`) |
| Restic env (raw, for Compose) | `/etc/restic/env.docker` | written by `setup-restic.sh` (raw `KEY=VALUE`, no shell quoting) |
| Restic repo-id pin | `/etc/restic/repo-id` | written by `setup-restic.sh` via `restic cat config --json` (host binary) |
| Restic secrets | `/etc/restic/` | written by `setup-restic.sh` |
| Node identity | `/etc/homelab/node.env` | written by `bootstrap.sh` |
| Host tooling | `/opt/stacks/_backup/` | `lib.sh`, `check-node.sh`, `change-restic-password.sh` at repo root |
| Node system scripts | `/opt/stacks/_system/` | `_system/` at repo root (copied by bootstrap step 3a) |
| Beszel agent stack | `/opt/stacks/beszel-agent/` | `beszel-agent/docker-compose.yml` at repo root, written by `addons/beszel-agent/install.sh` |
| Beszel agent addon installer | (called from repo path during bootstrap, or directly via `sudo ./addons/beszel-agent/install.sh`) | `addons/beszel-agent/install.sh` |
| Beszel hub stack | `/opt/stacks/beszel-hub/` (Tailscale-bind by default; port 8090) | `addons/beszel-hub/docker-compose.yml.tmpl` substituted by `addons/beszel-hub/install.sh` |
| Beszel hub addon installer | (called from bootstrap `--beszel-hub` / `--beszel-both`, or directly via `sudo ./addons/beszel-hub/install.sh`) | `addons/beszel-hub/install.sh` |
| Cloudflared tunnel stack | `/opt/stacks/cloudflared/` (Docker container, `network_mode: host`) | `addons/cloudflared/docker-compose.yml.tmpl` substituted by `addons/cloudflared/install.sh` |
| Cloudflared addon installer | (called from bootstrap `--install-cloudflared`, or directly via `sudo ./addons/cloudflared/install.sh`) | `addons/cloudflared/install.sh` |
| Host-native restic addon | `/etc/systemd/system/restic-backup.{service,timer}` + `/opt/stacks/_backup/backup.sh` | `addons/restic-host-native/install.sh` copies `restic-backup.service`, `restic-backup.timer`, `backup.sh` from repo root |
| Addon shared helpers | sourced by every addon installer | `addons/lib-addon.sh` (laptop-2: `addon_root_only_dir` default mode 755) |
| Host-native → lobaro migration helper | (no runtime install) | `migrate-to-lobaro.sh` at repo root (WP7); also dispatched by `bootstrap.sh --migrate-from-host-native` as step 6b |

### Key repo files

| File | Role |
|------|------|
| `AGENT.md` | This file. Source of truth for transformation. |
| `goal.md` | Historical intent document (goal.md-era). Read for context. |
| `README.md` | High-level overview. WP6 territory. |
| `bootstrap.sh` | Main orchestrator (order is load-bearing). WP7 adds a thin `--migrate-from-host-native` flag wired as step 6b (between step 6 and step 7), which calls `migrate-to-lobaro.sh` and reloads the `INSTALL_RESTIC_HOST_NATIVE` flag from `/etc/homelab/node.env` so step 7's `write_node_env` does not overwrite it. |
| `setup-restic.sh` | Restic + S3 wizard. WP2 rewrites this to deploy the lobaro container. WP5 adds the inverse mutual-exclusion WARN. WP7's `migrate-to-lobaro.sh` delegates to its `REUSE_EXISTING` branch (lines 109–125, 198–203) for the no-reinit guarantee. |
| `setup-restic.lobaro.yml.tmpl` | Compose template for the lobaro stack. WP2 created this; `setup-restic.sh` substitutes placeholders before writing `docker-compose.yml`. |
| `lib.sh` | Safe state/secret parsing helpers. WP5 adds `INSTALL_RESTIC_HOST_NATIVE` to `HOMELAB_NODE_ENV_KEYS` and extends `homelab_backup_path` with a `$2` flag override. |
| `backup.sh` | Host-native backup script. **WP5: addon-only.** Reaches `/opt/stacks/_backup/backup.sh` via `addons/restic-host-native/install.sh`. |
| `check-node.sh` | Health / exit-node / backup-freshness checker. WP3 expands this. WP5 passes `INSTALL_RESTIC_HOST_NATIVE` to `homelab_backup_path`. Laptop-2 adds Beszel hub/agent + cloudflared container health checks when their `INSTALL_*=true` flag is set in `/etc/homelab/node.env`. |
| `change-restic-password.sh` | Safe password rotation. Unchanged through WP1–WP6. |
| `restic-backup.service` / `.timer` | Scheduling + sandbox. **WP5: addon-only.** Reaches `/etc/systemd/system/` via `addons/restic-host-native/install.sh`. |
| `_system/` | Source for node-side `/opt/stacks/_system/` scripts. |
| `addons/` | Addon installers. WP5 fills the stubs; the laptop-2 batch added `beszel-hub/` and `cloudflared/` and tightened `lib-addon.sh` defaults (stack dirs 755, `.env` 600). |
| `beszel-agent/` | Beszel **agent** Compose template + `.env.example`. Consumed by `addons/beszel-agent/install.sh`. |
| `addons/beszel-hub/` | Beszel **hub** addon (NEW, laptop-2). Tailscale-bind by default; never 0.0.0.0 unless the operator passes `BESZEL_HUB_BIND=0.0.0.0` (WARN). |
| `addons/cloudflared/` | Cloudflared tunnel addon (NEW, laptop-2). Docker container, `network_mode: host`. Replaces the pre-batch host-binary path. |
| `migrate-to-lobaro.sh` | One-shot host-native → lobaro migration helper (WP7). Idempotent. Invoked directly or via `bootstrap.sh --migrate-from-host-native` (step 6b). |
| `MIGRATION.md` | Operator recipe for WP7: prerequisites, command variants, idempotency rules, post-migration verification, rollback for success/failure paths. |

---

## 7. Auto-Update Instructions (For the Implementing Agent)

**At the end of every session** — even if you only partially completed
a WP — you MUST update this file and `CHANGES.md`. This is how the
next instance picks up where you left off without reading every
commit.

### At end of every session:

1. **Tick off completed WPs in §3.** Change `[ ]` to `[x]` next to
   each acceptance criterion that is genuinely satisfied. Do not tick
   on hope — only after the verification commands in §3 pass.

2. **Update §0 "Current State".** Replace it with a one-paragraph
   description of what the repo looks like at end-of-session:
   - Which WPs are complete (cite the verification output).
   - Which WPs are partially complete (cite what's done and what's
     remaining).
   - Any new state that didn't exist when you started (e.g. new
     files, new env vars).

3. **Refresh §4 confirmation checklist.** Update each checkbox to
   reflect current truth. If an item is still false, leave it false
   and add a one-line comment on what's blocking it.

4. **Append to `CHANGES.md`.** One dated entry summarizing what
   changed this session, with WP references and verification command
   output (trimmed; no secrets).

5. **Update §6 reference table** if you added or moved any runtime-
   side files.

6. **If you discovered a locked decision is wrong**, do NOT silently
   change it. Open a question for the operator and tag the
   conflicting section with `<!-- QUESTION: ... -->`.

### At start of every session:

1. Read `§0 Current State` first.
2. Check `CHANGES.md` for the most recent session entry.
3. Pick up the first WP where `§4` says it is not done.
4. Re-run the relevant `Verification commands` block from §3 to
   confirm the starting state matches what the previous session
   claimed.

---

**End of AGENT.md.**

Any implementation that does not match the locked decisions and the
final-state checklist above is incorrect, even if it "works".
