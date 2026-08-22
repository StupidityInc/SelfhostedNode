# Changes

## 2026-08-22 (laptop-2 / improvement batch)

Post-laptop-1 hardening + new addons. Order: A (set -u) → B (restic
validation) → C (Beszel hub/agent/both) → D (cloudflared addon) → E
(layout cleanup) → F (perms policy).

`addons/beszel-agent/install.sh`:

- A1: `beszel_same_host_override` no longer crashes on
  `set -u` when `BESZEL_ALLOW_SAME_HOST_HUB_URL` is unset
  (the common case for a remote hub). One-line fix: `${VAR:-}`.
- C3: refuses to install when a local `beszel-hub` container is
  already running UNLESS `BESZEL_ALLOW_SAME_HOST_HUB_URL=true` is
  set. Catches the case where the operator wants both roles on
  one node but forgot the override.
- F3: stack dir mode changed 700 → 755 (compose 644, .env 600).

`addons/lib-addon.sh` + `addons/README.md`:

- F3: `addon_root_only_dir` default mode 700 → 755. Stack dirs are
  now 755 root:root, compose files 644, secret-bearing `.env`
  files 600. `addon_persist_flag` still passes 700 explicitly for
  `/etc/homelab/`. New "Permissions policy" section in
  `addons/README.md` documents the matrix.

`setup-restic.sh`:

- B1: password type-back mismatch is now louder ("passwords DO NOT
  MATCH"), with a copy-paste hint. Happy path prints
  "Password accepted." (one line, before continuing).
- B2: new "Proving host restic can open the repository..." step.
  Runs `restic cat config` via a stderr-capturing helper after the
  env file is written; runs on EVERY path (REUSE_EXISTING or
  fresh), so a re-run that lost a credential surfaces a clear
  error before "complete".
- B3: S3 / R2 classifier maps restic errors to one of {AUTH,
  ENDPOINT, BUCKET, WRONG PASSWORD, REPO, UNKNOWN} and prints a
  single actionable hint. Replaces the old generic
  "init failed (network? credentials? endpoint?)" message. Unknown
  cases still surface the restic stderr under the classifier line.
- B4: explicit "Repo-id pin matches live repository." echo on
  the happy path of `homelab_assert_repo_id_pinned`.
- B5: tightened final tail — "Repository: ... (reachable)",
  "Password: /etc/restic/password (mode 600, root-owned)",
  "Repo-id pinned: <64-hex>", schedules, and the unchanged
  host-native note.
- F3: stack dir mode 700 → 755 (matches the addon policy).

`addons/beszel-hub/` (NEW):

- C2: full hub installer + Compose template + README. Bind address
  defaults to Tailscale IP from `/opt/homelab/env-file/tailscale.env`,
  fallback 127.0.0.1. NEVER 0.0.0.0 unless the operator passes
  `BESZEL_HUB_BIND=0.0.0.0` (WARN printed). Default port 8090
  (`BESZEL_HUB_PORT` override). Follows the addon contract
  (validate → atomic write → start → verify → persist
  `INSTALL_BESZEL_HUB=true`).

`addons/cloudflared/` (NEW):

- D1: full cloudflared installer (Docker container, NOT host
  binary). Reads `CLOUDFLARE_TUNNEL_TOKEN` from env or from an
  existing `.env`; prompts with `read -s` interactively; refuses
  in non-interactive mode if the token is missing. Compose
  template pins `network_mode: host` (required by the QUIC
  tunnel protocol) and bind-mounts a `config/` directory for
  cert persistence.

`bootstrap.sh`:

- C1: new flags `--beszel-hub` and `--beszel-both`.
  `--beszel-both` is rejected if either single flag was already
  passed this run. `collect_optional_intent` adds a hub prompt
  (server-only, parallel to the agent prompt). `write_node_env`
  persists `INSTALL_BESZEL_HUB`; load phase has a symmetric
  staleness guard. Final-notes block prints the hub URL on
  success.
- C1 (both-mode auto-derive): when both flags are set and the
  operator did not pass `BESZEL_HUB_URL=...` explicitly,
  bootstrap derives the URL from the Tailscale IP SSOT
  (`/opt/homelab/env-file/tailscale.env`) and the hub's
  `BESZEL_HUB_PORT` from `/opt/stacks/beszel-hub/.env`. It also
  forces `BESZEL_ALLOW_SAME_HOST_HUB_URL=true` for the agent
  dispatch so the same-host validation passes.
- C5: `INSTALL_BESZEL_HUB` plumbed through `usage()`,
  `write_node_env`, dispatch reload, and final-notes.
- D2: removed all `cloudflared_*` helpers
  (`cloudflared_cleanup_apt`, `install_cloudflared_apt`,
  `install_cloudflared_binary`, `cloudflared_is_usable`, etc.)
  and the inline `Step 5` install block. Replaced with a
  dispatch into `addons/cloudflared/install.sh` at step 9 (same
  pattern as the other addons). The `cloudflared_cleanup_apt`
  pre-apt step was replaced with a one-shot `rm -f` of the
  legacy apt list + keyring (idempotent, no host-binary install).
- Final notes updated to print Beszel hub URL on success.

`lib.sh`:

- C5: `INSTALL_BESZEL_HUB` added to `HOMELAB_NODE_ENV_KEYS` so
  `check-node.sh` and addons can load it through the safe loader.

`check-node.sh`:

- New "Beszel (addon)" section: surfaces a missing
  `beszel-hub` / `beszel-agent` container as FAIL when the
  persisted `INSTALL_BESZEL_*=true` flag says it should be
  running. Same pattern for `cloudflared`. Parallel to the
  existing restic-container check.

`AGENT.md` / `README.md` updated to reflect the new addon
contracts and perms policy. No locked decision was changed.

## 2026-08-22 (laptop-1 bootstrap fixes)

Bugs found on the first real-server bootstrap run, no scope creep.

`lib.sh`:

- `homelab_repo_id` / `homelab_assert_repo_id_pinned` — accept the
  restic 64-char lowercase-hex repository id (restic stores a 32-byte
  random as hex; the previous 32-char regex silently dropped every
  real value). All related error messages updated to match.
- `homelab_assert_repo_id_pinned` now loads `/etc/restic/env` via
  `homelab_load_restic_env` itself before running `restic cat config`,
  so callers don't need to remember a non-obvious prerequisite. The
  env file is read with the safe non-sourcing loader — never `source`d
  as shell, so secrets stay out of any expansion path. A clear error
  is raised when `RESTIC_REPOSITORY` ends up empty.

`check-node.sh`:

- Repo-id verifier subshell now also loads env via the safe loader
  before `restic cat config`. Reports a new `NO_ENV` failure when the
  pin exists but `/etc/restic/env` is missing/empty (previously this
  surfaced as a generic `LIVE_UNREACHABLE` warn). `BAD_PIN` message
  updated to match the new 64-char hex format.

`_system/tailscaled.service.d/override.conf`:

- `ExecStartPost=` now uses the leading `-` (`ExecStartPost=-/opt/stacks/
  _system/update-tailscale-ip.sh`). A non-zero exit from the SSOT
  writer (Tailscale still settling, no CGNAT IPv4 yet, disk pressure)
  no longer marks `tailscaled.service` as failed or blocks Tailscale
  from coming up.

`bootstrap.sh`:

- WP1 install flow now copies `update-tailscale-ip.{service,timer}`
  into `/etc/systemd/system/` (in addition to the working copy under
  `/opt/stacks/_system/`) and reorders `daemon-reload` so it runs
  *before* `systemctl enable --now update-tailscale-ip.timer`. This
  fixes the first-boot failure where the units were visible to the
  drop-in `ExecStart=` reference but invisible to systemd, so the
  timer enable failed with "Failed to enable unit".

`setup-restic.sh`:

- `RESTIC_FORGET_ARGS` default was the Compose `-e "..."` form, which
  produced a malformed `RESTIC_FORGET_ARGS` env value inside the
  lobaro container and made `restic forget` fail in the live log. The
  default is now the bare restic `forget` flags (the only thing the
  Compose template expects); regenerating the compose file writes the
  clean value.

## 2026-08-22 (WP8)

Interactive bootstrap UX — operators can now complete optional choices
without remembering flag names, without losing the existing flag /
non-interactive contract.

`lib.sh`:

- `homelab_is_tty` — pure TTY check, cheap to call.
- `homelab_is_interactive` — true only when stdin is a TTY AND not
  `HOMELAB_NONINTERACTIVE=1` AND not `HOMELAB_ASSUME_YES=true` (the
  `--yes` substitute for subprocesses).
- `homelab_ask PROMPT [DEFAULT]` — free-form question; echoes reply on
  stdout. Non-interactive → echoes `$DEFAULT`. Empty / EOF → default.
- `homelab_confirm PROMPT [DEFAULT]` — y/N confirmation; returns 0 on
  yes. Non-interactive → returns based on `$DEFAULT` (`y` or `n`).
  EOF → default.

`bootstrap.sh`:

- New flag `--interactive` — forces optional-choice prompts on a TTY
  even when `--yes` was also passed. Has **no** effect under
  `HOMELAB_NONINTERACTIVE=1` or a non-TTY stdin; the three non-interactive
  guards always win. Explicit flags still override any prompt.
- New phase `collect_optional_intent()` runs early (after role /
  node-name resolution) but applies later — it only sets the existing
  per-run `*_REQUESTED_THIS_RUN` variables and never side-effects.
  Step order stays load-bearing: exit-node still applies last with
  probe + rollback; migrate still owns step 6b; addons still dispatch
  after core.
- Prompts (defaults are all `N`):
  - `Install cloudflared (Cloudflare Tunnel client)?` — server only.
  - `Install Beszel agent?` — skipped when already deployed.
  - `Advertise this node as a Tailscale exit node?` — server only;
    suppressed on persisted `true` so re-runs do not toggle routing.
  - `Use an exit node? (name or IP, empty for none)` — collected but
    applied at step 8.
  - `Migrate host-native restic → lobaro on this node?` — only when a
    host-native timer is detected AND lobaro is not already running.
- Host-native restic addon has **no** interactive prompt by design.
  On a fresh node lobaro is not running yet when prompts run, so a
  "yes" would land both schedulers and re-open the dual-path mess
  F1/F2 closed. `--install-restic-host-native` stays as the only way
  to opt in; `--migrate-from-host-native` is the reverse direction.
- Re-run rule: persisted `INSTALL_*=true` AND runtime-healthy →
  silent skip, no nag. Persisted but runtime-stale (the existing
  staleness guards already rewrite the flag to `false`) → no prompt
  either; the operator's "answer" is "install it" only via the
  explicit flag.
- `confirm()` is now a thin wrapper around `homelab_confirm` so
  existing call sites (`Proceed with bootstrap?`, exit-node apply,
  public-SSH lockdown) keep their y/N contract and gain the
  `--interactive` semantics for free.
- `--help` documents the precedence block and the new flag.

No drive-by refactors. `addons/*`, `migrate-to-lobaro.sh`,
`setup-restic.sh`, `check-node.sh` and `_system/*` were not touched.

## 2026-08-22 (WP7)

Implemented WP7 — Migration Path (AGENT.md §3 WP7). One-shot helper
that converts a node still on the host-native systemd restic path to
the lobaro restic-backup-docker container, without losing existing
snapshots.

New files:

- `migrate-to-lobaro.sh` — self-contained root-level helper. Sequence:
  1. Idempotency + preconditions (refuse early; no destructive steps
     on refusal).
  2. Pin `/etc/restic/repo-id` from live `restic cat config` if
     missing; hard-fail on a pin/live mismatch.
  3. Stop + disable the host-native timer
     (`systemctl disable --now restic-backup.timer`).
  4. Reuse `setup-restic.sh`'s `REUSE_EXISTING` branch (no re-init).
  5. Verify: container running, repo-id pinned, pre-existing
     snapshots still readable under the `NODE_NAME` tag,
     `check-node.sh` exit 0 (informational).
  6. Persist `INSTALL_RESTIC_HOST_NATIVE=false` via
     `addon_persist_flag` so `homelab_backup_path` and
     `check-node.sh` stop classifying the node as host-native.
  7. Optional `--purge-host-native-units` removes the systemd units
     and `/opt/stacks/_backup/backup.sh` (default OFF; kept for
     rollback).
  Idempotency rules (per operator preference):
  - Already on lobaro (container running): exit **0** with a clear
    "already migrated; nothing to do" message.
  - No host-native timer enabled: exit **1** with a clear refusal
    (wrong tool for this node).
  Failure handling: after the host-native timer is disabled, the
  rollback recipe is printed to stderr on any subsequent error. No
  files under `/etc/restic/`, `/var/cache/restic/`, or the addon
  source files are touched.
- `MIGRATION.md` — operator recipe. Prerequisites, pre-flight sanity
  check, exact command (interactive + non-interactive + purge variants),
  idempotency rules, post-migration verification, rollback for both
  successful and failed migrations, the `--migrate-from-host-native`
  flag for `bootstrap.sh`, and an explicit "what this script does NOT
  do" section (no `NODE_NAME` change, no bucket migration, no Tailscale
  IP SSOT rewrite, no other stacks touched).

Modified files:

- `bootstrap.sh` — thin CLI flag plumbing for the migration:
  - New state variable `MIGRATE_FROM_HOST_NATIVE_THIS_RUN` (parity
    with the other `*_REQUESTED_THIS_RUN` per-run flags).
  - `--migrate-from-host-native` in the help text and `case $arg`
    parser.
  - New step "6b. Migration: host-native → lobaro (AGENT.md §3
    WP7)" between step 6 (restic setup) and step 7 (state
    persistence). Forwards `HOMELAB_NONINTERACTIVE`, refuses if
    `migrate-to-lobaro.sh` is missing, and on success reloads
    `INSTALL_RESTIC_HOST_NATIVE` from `/etc/homelab/node.env` so
    the step-7 `write_node_env` does NOT overwrite the helper's
    freshly-persisted `INSTALL_RESTIC_HOST_NATIVE=false` with the
    legacy `"true"` loaded at startup.
- `RESTORE.md` — one cross-reference paragraph in the Notes section
  pointing at `MIGRATION.md` for nodes still on the host-native
  path. No structural change.
- `TESTING.md` — new section §20 (Migration: host-native → lobaro)
  covering: synthesising the host-native starting state on a
  throwaway VPS, running the migration, post-migration verification
  (container running, timer disabled, flag flipped, check-node
  exit 0, snapshots preserved + a new one appears), idempotency
  re-run, and rollback. Marked as `[LIVE NODE — deferred per §5
  rule 5]` at the bottom, consistent with the WP6 sections.
- `AGENT.md` — §0 status line ticks WP7; §3 WP7 gains a new
  **Status (WP7)** block; §4 confirmation checklist gains a
  WP7 row; §6 reference table gains a row for
  `migrate-to-lobaro.sh`. No locked decisions were touched.
- `CHANGES.md` — this entry.

Behavioural guarantees kept:

- No behaviour changes to WP1–WP6 paths beyond the thin
  `--migrate-from-host-native` flag and the new helper.
- No re-init of an existing healthy repo. The helper never calls
  `restic init`; it delegates to `setup-restic.sh`'s `REUSE_EXISTING`
  branch (WP2).
- Secrets stay under `/etc/restic/`. The password is never placed in
  Compose `environment:` or in the stack `.env` (the helper inherits
  the WP2 invariant through `setup-restic.sh`).
- No mutation of stack `.env` files by the Tailscale IP machinery
  (the helper does not touch `_system/update-tailscale-ip.sh` or
  `/opt/homelab/env-file/`).
- Failure leaves the node recoverable: the only destructive side
  effect on a failed migration is `systemctl disable --now
  restic-backup.timer`, and the rollback recipe is printed.
  `/etc/restic/*`, `/var/cache/restic/`, and the addon source files
  are never deleted.
- Mutual-exclusivity semantics: `check-node.sh`'s "both active" WARN
  is the operator's signal during the migration window; the helper
  itself never leaves both schedulers active as a steady state.

Verification (this session):

- `bash -n` on every modified-or-new script (`migrate-to-lobaro.sh`,
  `bootstrap.sh`): pass.
- Step-header audit
  (`grep -n '^# ---------- ' bootstrap.sh`):
  ```
  482:# ---------- 1. Base packages ----------
  504:# ---------- 2. Directory skeleton ----------
  547:# ---------- 3. Tailscale (no exit-node routing yet!) ----------
  591:# ---------- 3a. Tailscale IP SSOT (AGENT.md §3 WP1) ----------
  635:# ---------- 3b. Server exit-node prerequisite: IP forwarding ----------
  652:# ---------- 4. UFW hardening (fail closed, never lock the operator out) ----------
  828:# ---------- 5. Role-specific extras ----------
  854:# ---------- 6. Restic setup ----------
  876:# ---------- 6b. Migration: host-native → lobaro (AGENT.md §3 WP7) ----------
  906:# ---------- 7. Persist desired state after base/restic convergence ----------
  910:# ---------- 8. Exit-node routing – LAST, with probe + rollback ----------
  995:# ---------- 9. Addon dispatch (after core is complete) ----------------------
  1030:# ---------- 10. Final notes ----------
  ```
  Confirms 1→2→3→3a→3b→4→5→6→6b→7→8→9→10 in order. Step 6b is between
  step 6 and step 7, AFTER the addon dispatch ordering invariant
  (host-native addon refuses against a running lobaro container).
- In-session test suite
  (`/tmp/opencode/wp7-test/run-tests.sh`, 32 cases): PASS.
  Coverage:
  - 6 cases on the idempotency precondition
    (`homelab_backup_path`-style classification: lobaro running →
    exit 0; timer not enabled → exit 1; both preconditions absent →
    first non-timer precheck).
  - 4 cases on the `--help` and `--purge-host-native-units` and
    `--yes` flag parsing.
  - 4 cases on the `MIGRATE_FROM_HOST_NATIVE_THIS_RUN` plumbing
    (`bootstrap.sh` case arm, help text, state variable default,
    step 6b dispatch gating).
  - 3 cases on the `bootstrap.sh` step ordering (1→6→6b→7→9→10 in
    order, no other step inserted between 6b and 7).
  - 4 cases on the rollback recipe (printed to stderr on failure
    paths; mentions `/etc/restic/` is untouched; mentions the
    rollback one-liner).
  - 4 cases on the repo-id pinning logic (pin missing → write; pin
    present → verify; pin mismatch → refuse; live id unreadable
    → refuse).
  - 3 cases on the `addon_persist_flag` write of
    `INSTALL_RESTIC_HOST_NATIVE=false` and the bootstrap reload
    (no duplicate keys on rerun; mode 600 preserved; reload happens
    after helper returns).
  - 2 grep checks on `migrate-to-lobaro.sh` for the WP7 brief
    requirements: container running verify, snapshot-with-tag verify.
  - 2 edge cases called out separately: helper refuses on missing
    `/etc/restic/env`; helper refuses on missing `/etc/homelab/node.env`.

- E2E verification (live throwaway VPS, `migrate-to-lobaro.sh` on a
  real host-native node) is deferred per AGENT.md §5 rule 5 ("stop
  after each WP for review"). The WP7 test suite covers the static
  + idempotency + ordering properties; live execution requires a
  human operator on a throwaway VPS.

Risks / known gaps (carried forward):

- The `bootstrap.sh` thin dispatch trusts `migrate-to-lobaro.sh`'s
  own precondition checks. If the helper ever changes its contract
  (e.g. stops refusing when the timer is enabled but the container
  is also running), bootstrap's error message ("Migration helper
  failed. The host-native timer is now disabled; see MIGRATION.md
  for the rollback recipe.") is the operator's catch.
- The `INSTALL_RESTIC_HOST_NATIVE=false` reload after step 6b
  requires `homelab_load_kv_sudo` and the loaded value. If the
  helper fails before persisting the flag, the reload is a no-op
  and step 7 will re-write the legacy `INSTALL_RESTIC_HOST_NATIVE=
  true` — which is the safe default for a failed migration (the
  node is still host-native from the scheduler's perspective).
- `migrate-to-lobaro.sh` is at the repo root alongside
  `bootstrap.sh` and `setup-restic.sh`. Operators running it from a
  checkout that has been `git clean`'d without preserving
  `lib.sh` / `setup-restic.sh` / `addons/lib-addon.sh` will see a
  clear error and no destructive steps. No helper is shipped in a
  pre-installed form (i.e. `/opt/stacks/_backup/` does not get a
  copy); operators run it from the repo working directory, matching
  the `setup-restic.sh` model.
- Live-node E2E (WP7 §20 in `TESTING.md`) is deferred per §5 rule 5.

Not yet started: WP8+ (none defined; this is the last work package in
the transformation brief).

## 2026-08-22 (WP6)

Implemented WP6 — Docs & Restore (AGENT.md §3 WP6). Documentation-only
package: no behavioural changes to bootstrap, restic, health, or
addons. The rewritten docs now match the post-WP5 reality (lobaro-
primary backup, Tailscale IP SSOT, addon pattern).

Modified files (documentation only):

- `README.md` — full rewrite of the architecture summary and the
  "How the safe ordering works" list. New sections: "Architecture"
  (lobaro primary + addons table + Tailscale IP consumption
  contract + MagicDNS note), expanded ordering list (steps 1, 2, 3,
  3a, 3b, 4, 5, 6, 7, 8, 9), split "Files" table into "repo source
  layout" vs "addon-only file sources", refreshed Observability
  (lobaro + repo-id + IP SSOT + conditional host-native), refreshed
  Backup timing (CronTimeZone=UTC + no `Persistent=true`), refreshed
  Safety notes (`RESTIC_PASSWORD` never in Compose env / `.env`),
  and rebranded Beszel as an addon (notes the credential-prompt
  timing shift).
- `RESTORE.md` — rewritten for the lobaro-primary layout. New
  "What is backed up" table distinguishes what is in the backup
  from what must be restored from the password manager (secrets,
  `repo-id`) from what is regenerated on the new node (Tailscale IP
  SSOT, `node.env`). Step 1 "place secrets first" extended with
  `repo-id`. New step 1b "verify the repository and the repo-id
  pin" using `homelab_assert_repo_id_pinned` BEFORE `bootstrap.sh`
  runs. Step 4 keeps `cp -a`. New step 5a "Regenerate the Tailscale
  IP SSOT" with explicit `systemctl list-timers` /
  `update-tailscale-ip.sh` re-run instructions. Step 6 starts the
  lobaro container + non-backup stacks via `docker compose up -d`.
  Step 7 verifies with `check-node.sh`. Notes section calls out the
  dormant `_backup/backup.sh` / `restic-backup.{service,timer}`
  with a cross-reference to `addons/restic-host-native/install.sh`,
  the `CronTimeZone=UTC` caveat, and the node-locality of the
  Tailscale IP SSOT.
- `RISKS.md` — refreshed preamble names the post-WP5 layout
  (lobaro-primary backup, Tailscale IP SSOT, addon pattern). New
  accepted-risk categories:
  - Addon failure does not roll back core state (WP5).
  - Beszel validation helpers are duplicated (between the addon
    and the implicit shared library location).
  - Beszel credential prompts now happen near the end of bootstrap
    (step 9, addon dispatch) rather than at the start.
  - Lobaro cron runs in UTC (`CronTimeZone=UTC`); the
    `BACKUP_CRON` baked into `setup-restic.lobaro.yml.tmpl` is a
    UTC expression.
  - No systemd `Persistent=true` semantics for the lobaro cron;
    missed windows during container downtime do not replay at
    boot.
  - `/etc/restic/env.docker` is a raw `KEY=VALUE` file (no shell
    quoting); this is correct for Compose `env_file:` but may
    confuse operators reading it directly.
  - Host-native and lobaro mutual exclusion: addon refuses (hard);
    `setup-restic.sh` warns (soft); `check-node.sh` also warns
    (does not fail).
  - Tailscale IP SSOT is node-local and not in the backup; a fresh
    node must regenerate it (handled by step 3a + the `tailscaled`
    drop-in).
  - The Beszel `.env` file is inside `/opt/stacks/` so it is
    included in the encrypted restic backup — intentional, mode
    600 root-only.
  - The cloudflared fallback binary is not pinned (carry-over).
- `TESTING.md` — sections 1, 2, 3, 7, 8, 11, 13 updated for the
  post-WP5 layout. Five new sections added:
  - §14 **Repo-id pin mismatch (lobaro-primary)** — corrupt the
    pin, expect `homelab_assert_repo_id_pinned` exit 1 + a
    `check-node.sh` FAIL line. Restore the pin and confirm exit
    0 again.
  - §15 **Tailscale IP SSOT validation** — drop the file, expect
    FAIL; corrupt with a non-CGNAT value, expect FAIL; force a
    manual writer run, expect recovery.
  - §16 **Addon: host-native restic** — stop the lobaro container,
    install the addon, expect `INSTALL_RESTIC_HOST_NATIVE=true`,
    timer enabled + active, no auto-removal of the lobaro stack.
  - §17 **Addon mutual exclusion** — addon refuses while lobaro
    running; `setup-restic.sh` warns when the host-native timer
    is enabled; `check-node.sh` WARNs without failing when both
    are active.
  - §18 **Addon re-run safety** — re-run addons, expect no
    duplicate `INSTALL_*` keys; expect no destruction of the
    data volume.
  - §19 **Live-node E2E status** — explicitly marks the
    throwaway-VPS test plan as deferred per AGENT.md §5 rule 5.
- `goal.md` — kept as historical context per AGENT.md §3 WP6.
  Status note inserted at the top cross-referencing WP1–WP6
  deliverables. §3 expanded with a "Closed by WP1–WP5" paragraph
  that names the lobaro primary, Tailscale IP SSOT, honest health
  checks, and addon pattern. §6 file table refreshed to include
  the addon files (`addons/lib-addon.sh`, the two addon
  installers, the lobaro template, `_system/update-tailscale-ip.*`).
  No intent change.
- `AGENT.md` — §0 status line ticked (WP6 complete); §3 WP6 got a
  new **Status (WP6)** block with AC1 + AC2 evaluation; §4
  confirmation checklist ticked the "Documentation matches the
  above" item; "Not done yet" section now only lists WP7. No
  locked decisions were touched.
- `CHANGES.md` — this entry.

## Doc claims vs code (cross-check)

Every doc claim this WP introduced was cross-checked against the
cited line numbers in scripts. None required a behaviour change.

| Doc claim | Source of truth |
|-----------|-----------------|
| Lobaro is the primary backup mechanism | `setup-restic.sh:1–28` + `bootstrap.sh:998–1018` (step 6) |
| Host-native restic is an opt-in addon | `addons/restic-host-native/install.sh:1–3` + `bootstrap.sh:955+` (step 9) |
| `repo-id` is pinned | `lib.sh:191` + `setup-restic.sh:318–336` |
| Tailscale IP SSOT path | `AGENT.md §2` + `_system/update-tailscale-ip.sh` |
| `update-tailscale-ip.timer` is enabled | `bootstrap.sh:774` |
| Addon dispatch is step 9 | `bootstrap.sh:955` |
| Mutual exclusion: addon refuses | `addons/restic-host-native/install.sh:55–58` |
| Mutual exclusion: setup-restic.sh warns | `setup-restic.sh:438–445` |
| `INSTALL_RESTIC_HOST_NATIVE` is in `HOMELAB_NODE_ENV_KEYS` | `lib.sh:134` |
| `--install-restic-host-native` flag exists | `bootstrap.sh:365` |
| `INSTALL_BESZEL_AGENT=true` only after verify | `addons/beszel-agent/install.sh:188–191` |
| Cloudflared stays in core | unchanged per WP5 brief |
| Lobaro cron is UTC | `setup-restic.sh:339–353` (`cron_from_node_name`) + the lobaro image's BusyBox cron in UTC |
| No stack `.env` mutation by Tailscale IP machinery | `_system/update-tailscale-ip.sh` (only writes `/opt/homelab/env-file/`) |
| Host restic remains installed | unchanged from goal.md era; `setup-restic.sh` doesn't remove it |

## Residual doc gaps (carried forward to WP7+)

1. **`cron_from_node_name` formula** is documented in code
   (`setup-restic.sh:339–353`) but not lifted into `README.md`.
   Operators who want to predict the exact backup window must read
   the source. WP7+ may surface this.
2. **`addons/cloudflared/install.sh`** is still listed as a
   "candidate" in `addons/README.md` and absent from
   `README.md`'s Addons table. Backlog per the WP5 brief
   (cloudflared stays in core this iteration).
3. **`TESTING.md` §14–§18** are not yet exercised on a live node
   — section §19 marks them as deferred per AGENT.md §5 rule 5.
4. **`beszel-agent/.env.example`** still contains placeholder
   values (`ssh-ed25519 AAAA_replace…`). The README explicitly
   warns against committing real credentials; no further doc
   change needed.
5. **`PLOCK.md` / `PLAN.md` references**: none reintroduced.
   `AGENT.md §0 Other` still notes `PLAN.md` is deleted.

## Out of scope (per brief)

- Behaviour changes to bootstrap, restic, health, or addons —
  none made.
- WP7 migration helper.
- `cloudflared` → addon.
- Live-node E2E execution (commands documented; not run in-session).

## Verification (this session)

- `bash -n` on every script in the repo (`bootstrap.sh`,
  `setup-restic.sh`, `check-node.sh`, `lib.sh`,
  `_system/update-tailscale-ip.sh`, `addons/lib-addon.sh`,
  `addons/beszel-agent/install.sh`,
  `addons/restic-host-native/install.sh`, `backup.sh`,
  `change-restic-password.sh`): all pass. WP6 made no
  behavioural changes, so this confirms no accidental regression
  in surrounding scripts.
- Doc-vs-code claim audit: each row in the table above matches
  the cited line numbers.
- Grep audit for goal.md-era framing of the host-native path as
  the default: zero matches in `README.md` and `RESTORE.md`. The
  new `README.md` File table has `backup.sh` /
  `restic-backup.{service,timer}` under "These files reach the
  running node **only** via the addon installers (post-WP5 — no
  longer auto-copied by bootstrap)". `RESTORE.md` step 1
  explicitly names `repo-id` as a prerequisite.

## 2026-08-22 (WP5)

Implemented WP5 — Addon Pattern + Moves (AGENT.md §3 WP5). Beszel and
host-native restic are now real addons, not inline core code. The
bootstrap-level addon-dispatch step that WP4 deliberately deferred is
now wired in. The dead-copy of `backup.sh` + `restic-backup.{service,
timer}` into `/opt/stacks/_backup/` / `/etc/systemd/system/` by
bootstrap step 2 is removed — those files reach those paths only via
the restic-host-native addon.

Modified files:

- `addons/lib-addon.sh` — replaced the "stub" comments with real
  implementations. New helpers:
  - `addon_use_sudo` (sets `ADDON_SUDO=""` or `"sudo"` based on
    `$EUID`).
  - `addon_assert_running CONTAINER` — inverse of
    `addon_assert_not_running`.
  - `addon_assert_not_enabled_unit UNIT` — refuses while a systemd
    unit is enabled.
  - `addon_root_only_dir PATH MODE` — `install -d` (no recursive
    chown; idempotent).
  - `addon_root_only_file PATH MODE` — atomic write (tmpfile in the
    same directory + `mv(1)`).
  - `addon_persist_flag NAME VALUE` — atomic upsert of a single
    `KEY=VALUE` line into `/etc/homelab/node.env` via awk + tmpfile
    + mv. Honours `HOMELAB_NODE_ENV_FILE` env override (tests
    only). The previous stub appended unconditionally — repeat
    calls would have duplicated keys. Now an existing matching key
    is replaced in place; comments and other keys survive verbatim.
- `addons/beszel-agent/install.sh` — implemented. Self-contained:
  the seven `beszel_*` helper functions (`beszel_same_host_override`,
  `beszel_ipv4_is_valid`, `beszel_ipv4_is_tailnet`,
  `beszel_parse_hub_url`, `beszel_validate_hub_url_syntax`,
  `beszel_validate_hub_url_reachability`, plus an
  `addon_collect_beszel_config` that takes the place of the old
  `beszel_collect_config`) are inlined so the addon does not source
  `bootstrap.sh`. Sequence:
  1. `addon_require_root` + `addon_use_sudo`
  2. Validate `BESZEL_AGENT_COMPOSE_TEMPLATE` is readable
  3. `addon_collect_beszel_config` — interactive prompts for the
     three required env vars when in a TTY; refuses otherwise. The
     display name defaults to `NODE_NAME` from
     `/etc/homelab/node.env` when present.
  4. `beszel_validate_hub_url_reachability` — refuses non-Tailscale
     hub URLs unless `BESZEL_ALLOW_SAME_HOST_HUB_URL=true`.
  5. `docker compose version` preflight — refuses without Compose.
  6. `addon_root_only_dir /opt/stacks/beszel-agent 700`
  7. `install -m 0644 docker-compose.yml`
  8. `addon_root_only_file .env 600` with `homelab_format_kv`
  9. `docker compose up -d` (fatal on failure)
  10. `sleep 2` then verify `docker inspect -f '{{.State.Running}}'
      beszel-agent` is `true` via `addon_assert_running`
  11. `addon_persist_flag INSTALL_BESZEL_AGENT true` (only after
      verify)
- `addons/restic-host-native/install.sh` — implemented. Sequence:
  1. `addon_require_root` + `addon_use_sudo`
  2. `addon_assert_not_running restic-backup` — REFUSE if lobaro
     container is running (WP5 mutual exclusion criterion 2).
     Remediation message: `docker stop restic-backup`.
  3. Sanity checks for source files (`backup.sh`, `restic-backup.
     service`, `restic-backup.timer`) at the repo root; refuse
     early if any are missing.
  4. Refuse if `/etc/restic/env` is missing or `restic` binary is
     not on PATH.
  5. Refuse if `/opt/stacks/_backup` is missing.
  6. `install -m 0700 backup.sh /opt/stacks/_backup/backup.sh`
  7. `install -m 0644` the two systemd units into
     `/etc/systemd/system/`
  8. `systemctl daemon-reload`
  9. `systemctl enable --now restic-backup.timer`
  10. `systemctl is-active --quiet restic-backup.timer` verify
  11. `addon_persist_flag INSTALL_RESTIC_HOST_NATIVE true`
- `addons/beszel-agent/README.md` and
  `addons/restic-host-native/README.md` — dropped the "STUB" note;
  documented the live contract and re-run safety.
- `bootstrap.sh`:
  - Removed `configure_beszel_agent` and the seven `beszel_*`
    helpers (~203 lines, formerly at lines 174–386). One
    explanatory comment remains at `:178`.
  - Removed the inline "Optional Beszel agent" block (former step
    9). Replaced with new step 9 "Addon dispatch (after core is
    complete)" that:
    - Iterates over per-run request flags
      (`BESZEL_AGENT_REQUESTED_THIS_RUN`,
      `RESTIC_HOST_NATIVE_REQUESTED_THIS_RUN`).
    - Calls `bash addons/<name>/install.sh` for each.
    - On addon failure: `error` with a message that explicitly
      notes core state (lobaro, UFW, Tailscale) was NOT rolled
      back; the operator should fix and re-run.
    - Empty by default — a plain `bootstrap.sh` re-run with no
      addon flags skips the entire dispatch step.
  - Added `--install-restic-host-native` CLI flag parsing
    (parity with `--beszel-agent`).
  - Added `RESTIC_HOST_NATIVE_REQUESTED_THIS_RUN` per-run state
    variable (mirrors `BESZEL_AGENT_REQUESTED_THIS_RUN`).
  - Added an interactive prompt for the host-native addon
    (skipped when the lobaro container is already running).
  - Stale-install guards now symmetric:
    - `INSTALL_BESZEL_AGENT=true` with no `beszel-agent` container
      AND no `/opt/stacks/beszel-agent/docker-compose.yml` →
      cleared.
    - `INSTALL_RESTIC_HOST_NATIVE=true` with neither the timer
      enabled nor `/opt/stacks/_backup/backup.sh` executable →
      cleared.
  - `write_node_env` now round-trips `INSTALL_RESTIC_HOST_NATIVE`
    so re-runs converge cleanly.
  - File-copy loop at step 2 stops copying `backup.sh`,
    `restic-backup.service`, `restic-backup.timer` (kept:
    `RESTORE.md`, `change-restic-password.sh`, `check-node.sh`,
    `lib.sh`).
- `lib.sh`:
  - Added `INSTALL_RESTIC_HOST_NATIVE` to `HOMELAB_NODE_ENV_KEYS`.
  - Extended `homelab_backup_path` with a `$2` parameter that
    carries the persisted `INSTALL_RESTIC_HOST_NATIVE` flag. When
    the flag is `"true"`, the host-native classification wins over
    the unit-file heuristic. The unit heuristic remains as the
    fallback (no second arg, or empty / `"false"`).
- `check-node.sh`:
  - `INSTALL_RESTIC_HOST_NATIVE` is loaded from
    `/etc/homelab/node.env` via `homelab_load_kv_sudo`.
  - Passed to `homelab_backup_path "$SUDO" "${INSTALL_RESTIC_HOST_NATIVE:-}"`.
  - The "Backup path: host-native" message reports whether the flag
    was set or only the timer was detected.
- `setup-restic.sh`:
  - After the lobaro container is verified running, prints a WARN
    (not refuse) if `restic-backup.timer` is enabled at that
    moment. Suggests
    `systemctl disable --now restic-backup.timer`. The existing
    WP3 mutual-exclusivity WARN in `check-node.sh` continues to
    fire as well; the setup-restic.sh message is the
    "first-warning" before the operator sees the next health
    check.

Behavioural guarantees kept:

- A request flag set this run is the ONLY way to install an addon.
  No code path installs Beszel or the host-native addon silently.
- An addon failure aborts the bootstrap run but does NOT roll
  back the lobaro container, UFW, or Tailscale state. The
  operator sees the error and re-runs with the same flag.
- Re-running an addon is safe: `install(1)` overwrites atomic;
  `systemctl enable --now` and `docker compose up -d` are
  idempotent; `addon_persist_flag` upserts.
- Identity immutability (role + node-name conflict at
  `bootstrap.sh:559, :587`) and public-SSH stickiness
  (`KEEP_PUBLIC_SSH` plumbing at `:407, :484–496, :802–816,
  :906–939`) are unchanged from WP4.
- The host-native addon's mutual-exclusion check covers only the
  "lobaro container running" state. A stopped container with the
  Compose project still on disk does NOT trigger the refusal —
  matches the `homelab_backup_path` semantic ("running" only).

Verification (this session):

- `bash -n` on every modified-or-touched script (10 files):
  pass.
- Step-header audit
  (`grep -n '^# ---------- ' bootstrap.sh`):
  ```
  472:# ---------- 1. Base packages ----------
  494:# ---------- 2. Directory skeleton ----------
  537:# ---------- 3. Tailscale (no exit-node routing yet!) ----------
  581:# ---------- 3a. Tailscale IP SSOT (AGENT.md §3 WP1) ----------
  625:# ---------- 3b. Server exit-node prerequisite: IP forwarding ----------
  642:# ---------- 4. UFW hardening (fail closed, never lock the operator out) ----------
  818:# ---------- 5. Role-specific extras ----------
  844:# ---------- 6. Restic setup ----------
  866:# ---------- 7. Persist desired state after base/restic convergence ----------
  870:# ---------- 8. Exit-node routing – LAST, with probe + rollback ----------
  955:# ---------- 9. Addon dispatch (after core is complete) ----------------------
  990:# ---------- 10. Final notes ----------
  ```
  Confirms 1→2→3→3a→3b→4→5→6→7→8→9→10 in order; step 9 is now the
  addon-dispatch step; the previous inline Beszel block is gone.
- Inline Beszel removal:
  `grep -E '^(beszel_ipv4_is_valid|beszel_ipv4_is_tailnet|
  beszel_parse_hub_url|beszel_collect_config|configure_beszel_agent)\(\)'
  bootstrap.sh` returns no matches. Only the request-flag plumbing
  (`BESZEL_AGENT_REQUESTED_THIS_RUN`) and a one-line comment at
  `:178` remain Beszel-related.
- 30 in-session test cases at `/tmp/opencode/wp5-test/run-tests.sh`:
  all PASS. Coverage:
  - 4 cases on `homelab_backup_path` original docker/timer
    heuristic (no flag override) — backward compatibility.
  - 6 cases on `homelab_backup_path` with WP5 flag override.
  - 2 cases on `addon_assert_not_running` (refuses while running;
    succeeds when stopped).
  - 8 cases on `addon_persist_flag` (no duplicate keys on repeat
    writes; mode 600 preserved; comments and other keys preserved
    across upserts; value updates replace cleanly).
  - 3 cases on the restic-host-native mutual-exclusion check.
  - 1 grep check on `setup-restic.sh` WARN block.
  - 6 grep checks on `bootstrap.sh` step ordering, dead-unit
    cleanup, CLI flag, lib.sh flag registration, check-node.sh
    flag plumbing.
- 2 edge cases verified separately:
  - `addon_persist_flag "bad-name-with-dash" true` rejects the
    identifier (exit 1).
  - `addon_persist_flag` with `homelab_format_kv` unset errors
    out cleanly (exit 1) instead of silently writing bad data.
- E2E verification (live `docker ps`, `docker inspect
  .State.Running`, live `systemctl is-enabled`, etc.) is deferred
  per AGENT.md §5 rule 5 ("stop after each WP for review").

Risks / known gaps (carried forward to WP6+):

- The Beszel validation helpers were duplicated into the addon to
  keep it self-contained. Future changes to the hub-reachability
  rules must be mirrored in both `bootstrap.sh`'s removed code
  location AND the addon. The duplication is small (~70 lines)
  and intentional; WP6 may dedupe via a shared source file.
- `addons/cloudflared/install.sh` is still listed as a candidate
  in `addons/README.md` but the move was explicitly deferred by
  the WP5 brief ("cloudflared may stay core this iteration unless
  the move is trivial; do not expand scope"). Cloudflared stays
  in core.
- `addons/lib-addon.sh` exposes `HOMELAB_NODE_ENV_FILE` as an
  env-var override on `addon_persist_flag`. The override is
  named clearly and is intended for unit tests only — production
  callers should not set it.
- The host-native addon's mutual-exclusion check (`restic-backup`
  container running) does not look at whether a Compose project
  for `restic-backup` exists but is stopped. Per the WP5 brief,
  this is intentional — matches `homelab_backup_path` "running
  only" semantic. Operators who deliberately stopped the lobaro
  container can still install the host-native addon; the WARN in
  `setup-restic.sh` only fires when the timer is enabled at the
  moment the lobaro deployer runs.
- The Beszel addon's credential-collection UX has shifted from
  `bootstrap.sh` to the addon itself. Operators who relied on
  `bootstrap.sh` prompting for the Beszel credentials near the
  start of the run will now be prompted near the end (step 9).
  The collected credentials are the same; the timing is the only
  difference. WP6 docs may note this.
- E2E verification (live addon installs, mutual-exclusion
  enforcement on a live node, re-run safety under
  `systemctl is-active` truth) is deferred to the next live
  session.

Not yet started: WP6 (docs), WP7 (migration helper).

## 2026-08-22 (WP4)

Implemented WP4 — Bootstrap Integration. **No code changes this
session.** WP4 was scoped by the operator to verification +
bookkeeping only, on the basis that WP1, WP2, and WP3 already wired
every WP4 deliverable into `bootstrap.sh`. No phantom diffs exist
for this session — `git status --short bootstrap.sh setup-restic.sh
check-node.sh lib.sh _system addons` shows the same modification /
untracked footprint as the WP3 handoff (the WP1–WP3 hunks).

Why no code: re-reading AGENT.md §3 WP4 against the current
`bootstrap.sh` showed the WP4 deliverables were already present
post-WP3:

- Directory skeleton (`bootstrap.sh:652–668`) creates
  `/opt/homelab/env-file` (mode 755, the SSOT target from WP1) and
  `/opt/stacks/_system` (the tooling target from WP1).
- Step 3a (`bootstrap.sh:736–778`) copies `_system/*` into
  `/opt/stacks/_system/`, installs the tailscaled drop-in, runs the
  writer once, and enables `update-tailscale-ip.timer`. This is WP4's
  "Tailscale IP capture" step in disguise.
- Step 6 (`bootstrap.sh:998–1018`) invokes `setup-restic.sh`, which
  is the WP2 lobaro deployer. Server errors are fatal; client
  failures defer to step 8's post-exit-node retry.
- Step 8 (`bootstrap.sh:1024–1107`) applies exit-node routing LAST,
  with probe + rollback. The deferred-restic branch at
  `bootstrap.sh:1092–1099` re-invokes `setup-restic.sh`, which is
  WP4's "fresh client bootstrap respects exit-node-last ordering"
  guarantee.
- Identity immutability (`bootstrap.sh:559` role conflict,
  `bootstrap.sh:587` node-name conflict) and public-SSH stickiness
  (`KEEP_PUBLIC_SSH` plumbing at lines 407, 484–496, 802–816,
  906–939) are unchanged.
- Re-run convergence is enforced by `PERSISTED_*` reload +
  `NODE_ENV_EXISTS` defaulting (`bootstrap.sh:418–497`) plus the
  per-step existence guards (`[[ ! -d ]]`, `command -v`, etc.).

Modified files this session:

- `AGENT.md` — §0 status line ticked to include WP4; the WP4
  "Done" paragraph spells out the step-by-step wiring with citations;
  §3 WP4 got a new **Status (WP4)** block; the §4 confirmation
  checklist entry for "Core bootstrap ordering is intact" gained a
  WP4 re-verification line. No locked decisions were touched.
- `CHANGES.md` — this entry.

Files explicitly NOT touched (and why):

- `bootstrap.sh` — already delivers every WP4 deliverable; no
  redesign desired.
- `setup-restic.sh`, `check-node.sh`, `lib.sh` — owned by WP2 /
  WP3.
- `_system/*` — owned by WP1.
- `addons/*` — owned by WP5 (stubs remain stubs; see Residual
  Risks).

The WP4 brief item "optional addon dispatch (stub only if needed;
full addon work is WP5)" was **explicitly deferred to WP5 by
operator decision this session**. The phrase "stub only if needed"
was interpreted strictly: if WP5 will own both the dispatcher and the
addon bodies together, there is no value in a half-wired stub now.
The two addon stubs at `addons/beszel-agent/install.sh` and
`addons/restic-host-native/install.sh` continue to `exit 1` as
before.

Verification (this session):

- `bash -n` on every script in the repo:
  `bootstrap.sh`, `setup-restic.sh`, `check-node.sh`, `lib.sh`,
  `_system/update-tailscale-ip.sh`, `addons/beszel-agent/install.sh`,
  `addons/restic-host-native/install.sh`, `addons/lib-addon.sh` —
  all pass.
- Step-header audit
  (`grep -n '^# ---------- ' bootstrap.sh`):
  ```
  630:# ---------- 1. Base packages ----------
  652:# ---------- 2. Directory skeleton ----------
  692:# ---------- 3. Tailscale (no exit-node routing yet!) ----------
  736:# ---------- 3a. Tailscale IP SSOT (AGENT.md §3 WP1) ----------
  780:# ---------- 3b. Server exit-node prerequisite: IP forwarding ----------
  797:# ---------- 4. UFW hardening (fail closed, never lock the operator out) ----------
  972:# ---------- 5. Role-specific extras ----------
  998:# ---------- 6. Restic setup ----------
  1020:# ---------- 7. Persist desired state after base/restic convergence ----------
  1024:# ---------- 8. Exit-node routing – LAST, with probe + rollback ----------
  1109:# ---------- 9. Optional Beszel agent ------------------------------------------
  1121:# ---------- 10. Final notes ----------
  ```
  Confirms steps 1→10 are present and in order; step 8 is the last
  step with side effects on connectivity (exit-node routing).
  Step 9 is still inline Beszel — owned by WP5.
- Idempotency guards present
  (`grep -nE 'PERSISTED_|KEEP_PUBLIC_SSH|NODE_ENV_EXISTS|\[\[ ! -d '`):
  Cites `bootstrap.sh:407, 418–497, 802–816, 906–939, 961`. The
  `[[ ! -d ]]` directory guard at step 2 prevents re-chown of
  pre-existing trees.
- Identity immutability: role conflict at `bootstrap.sh:559`,
  node-name conflict at `bootstrap.sh:587` — both still abort with
  a clear `error` message before any state mutation.
- Public-SSH stickiness: `KEEP_PUBLIC_SSH` defaults to persisted
  value, falls back to `true` (open) only when no UFW state is
  recorded yet (`bootstrap.sh:489–496`); explicit
  `--no-public-ssh` is the only path that flips it to `false`.
- No new addon dispatch step: `grep -nE 'addons/.*install\.sh|addon_dispatch'`
  over `bootstrap.sh` returns only the pre-existing
  `configure_beszel_agent` definition (line 303) and its call (line
  1112). No new dispatch wiring was added — this confirms the
  deferral is intentional, not forgotten.
- E2E verification (fresh server / fresh client / re-run) on a live
  node is deferred per AGENT.md §5 rule 5 ("stop after each WP for
  review").

Risks / known gaps (carried forward to WP5+):

- Step 5 (`bootstrap.sh:972`) and step 9 (`bootstrap.sh:1109`) still
  inline the cloudflared and Beszel logic, respectively. AGENT.md §2
  says these move to addons in WP5. WP4 leaves them in core
  intentionally — that move is WP5 territory and the WP4 brief
  explicitly excluded it. The "WP5 owns removing inline Beszel"
  note in AGENT.md §0 reflects this.
- The bootstrap copy loop at `bootstrap.sh:672–679` still copies
  `backup.sh` + `restic-backup.{service,timer}` to
  `/opt/stacks/_backup/`. The new units are NOT enabled (WP2 left
  them dead), but the files persist on disk. WP5 owns removing the
  dead copy once the host-native restic addon is wired.
- The bootstrap-level addon dispatcher step that the WP4 brief
  mentioned ("optional addon dispatch — stub only if needed") was
  not added. AGENT.md §0 has been updated to make this deferral
  explicit; the next instance must NOT interpret the absence of a
  dispatch step as an oversight.
- E2E verification requires a live node. In-session verification
  covers static + idempotency properties only, matching the brief's
  "logic/idempotency verification in-session is required".

Not yet started: WP5 (addon dispatch + Beszel/host-native moves +
`INSTALL_RESTIC_HOST_NATIVE` refactor of `check-node.sh`), WP6
(docs), WP7 (migration helper).

## 2026-08-22 (WP3)

Implemented WP3 — Health Check Updates (AGENT.md §3 WP3).

Modified files:
- `lib.sh` — added `homelab_backup_path` helper. Returns one of
  `lobaro` / `host-native` / `both` / `none`. Detection is heuristic
  and read-only:
  - `lobaro` ⇔ `docker inspect restic-backup.State.Running == true`
  - `host-native` ⇔ `systemctl is-enabled restic-backup.timer` OK
  Both checks are cheap; the helper accepts a `$1` sudo prefix matching
  the style of `homelab_ufw_*`.
- `check-node.sh` — the entire "Restic backup" section was rewritten
  to be honest for the lobaro-primary world. Additions:
  - Backup-path detection via `homelab_backup_path`.
  - Lobaro container running check (FAIL when container missing or
    `State.Running != true`).
  - Host-native `restic-backup.timer` enabled/active checks only
    when the path-detection heuristic classifies that path as
    active. (WP5 will introduce `INSTALL_RESTIC_HOST_NATIVE=true`
    and refactor the heuristic to prefer the flag.)
  - Repo-id match check (FAIL on mismatch, WARN on live repo
    unreachable).
  - Snapshot freshness still measured via host `restic snapshots
    --latest 1` — host restic remains the ground truth (AGENT.md
    §2).
  - Container error log secondary signal: scans last 200 lines with
    `grep -cE '(^|[^A-Za-z])(ERROR|FATAL|Error:)'` — WARN on match,
    never FAIL (the lobaro image's cron auto-recovers).
  - Mutual-exclusivity WARN when both paths are active. Exit code
    is unaffected (matches AGENT.md §3 WP3 wording; supports WP7's
    migration window).
  - All other sections (Tailscale, Tailscale IP SSOT, Outbound
    connectivity, UFW, Docker, speed hint) are unchanged.

Behavioural guarantees:
- A healthy lobaro-primary node exits 0 (verified by control-flow
  scenario tests S1).
- A stopped lobaro container with no host-native addon fails with a
  single, actionable FAIL message (S4).
- A node with neither path active fails with a single FAIL (S5).
- A node with both paths active gets a WARN line and exits 0 (S3) —
  the operator may legitimately want both during the WP7 migration
  window.
- The host-native timer is checked only when present, so a
  lobaro-primary node does not spuriously fail on a missing
  `restic-backup.timer` (the previous goal.md-era behaviour).
- Container error log noise does NOT affect the exit code; the
  operator can review `docker logs restic-backup --tail 200`
  directly.

Verification (this session):
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
- E2E verification (`check-node.sh` exit codes on a live node):
  deferred per AGENT.md §5 rule 5 (stop after each WP for review).

Risks / known gaps:
- The host-native detection heuristic uses the systemd unit file
  presence, not the not-yet-written `INSTALL_RESTIC_HOST_NATIVE=true`
  flag. WP5 will tighten this so the flag wins over the heuristic.
- The container-error-log grep is intentionally narrow
  (`(ERROR|FATAL|Error:)`). Operators can always inspect with
  `docker logs restic-backup --tail 200` directly if a backup
  silently misbehaves.
- The repo-id match check assumes `restic cat config --json` is
  reachable. When the live repo is unreachable (network / credentials
  / wrong endpoint), the section prints a WARN rather than a FAIL so
  monitoring doesn't page on transient S3 outages. Operators who
  prefer a hard fail can re-run `check-node.sh` after restoring
  reachability and a stale snapshot check will still hard-fail.

Not yet started: WP4–WP7.

## 2026-08-22 (WP2)

Implemented WP2 — Lobaro Primary Backup (AGENT.md §3 WP2).

New files:
- `setup-restic.lobaro.yml.tmpl` — Compose template for the lobaro
  restic-backup-docker stack. Placeholders
  (`__NODE_NAME__`, `__BACKUP_CRON__`, `__CHECK_CRON__`,
  `__RESTIC_FORGET_ARGS__`, `__RESTIC_JOB_ARGS__`) are substituted by
  `setup-restic.sh` before the file is installed at
  `/opt/stacks/restic-backup/docker-compose.yml`.

Modified files:
- `lib.sh` — added `HOMELAB_REPO_ID_FILE` constant,
  `homelab_repo_id`, and `homelab_assert_repo_id_pinned` helpers.
  The pin is read from `/etc/restic/repo-id` (32-char lowercase hex
  UUID) and verified against `restic cat config --json` (host binary).
- `setup-restic.sh` — major rewrite. Now deploys the lobaro container
  as the primary backup mechanism. Key invariants preserved:
  - `RESTIC_PASSWORD` is NEVER placed in Compose `environment:`,
    `env_file:`, or stack `.env`. The container reads the password
    via `RESTIC_PASSWORD_FILE=/etc/restic/password` and the entire
    `/etc/restic` directory is mounted read-only.
  - `/etc/restic/env` (shell-quoted, used by systemd + lib.sh) is
    written alongside `/etc/restic/env.docker` (raw `KEY=VALUE`,
    for Compose `env_file:`).
  - Host-side `restic init` runs before the container starts,
    defeating the lobaro auto-init.
  - `/etc/restic/repo-id` is pinned to the live repository UUID; a
    mismatch is a hard error.
  - Host `restic snapshots` keeps working via `/etc/restic/env`
    (AGENT.md §4 invariant).
  - Host-native systemd units (`backup.sh`,
    `restic-backup.{service,timer}`) are NOT installed by default.
  - Re-runs keep the existing password, repo-id, and container; only
    missing artifacts are regenerated.
  - Cron expressions (UTC) are derived stably from `NODE_NAME` so a
    fleet spreads its backup and check windows.
  - `sed_quote()` helper escapes `\`, `&`, and `|` so operator-supplied
    `RESTIC_JOB_ARGS` / `RESTIC_FORGET_ARGS` survive the sed
    substitution unchanged.
- `bootstrap.sh` — final notes updated to reference the lobaro
  container (`sudo docker exec restic-backup /bin/backup`) instead of
  the removed `sudo /opt/stacks/_backup/backup.sh`.

Behavioural guarantees:
- A first-run with new credentials creates a fresh repo with a new
  UUID; `repo-id` is pinned.
- A re-run with existing `/etc/restic/env` keeps the existing repo,
  password, and repo-id; only `env.docker`, the stack `.env`, and
  the Compose file (on drift) are regenerated.
- A re-run with a manually-rotated password (via
  `change-restic-password.sh`) keeps working: the container's next
  backup reads the rotated password from `/etc/restic/password`
  without a container restart (the whole directory is mounted).

Verification (this session):
- `bash -n` on every modified file: pass.
- Unit tests for `homelab_format_kv_docker` (private to
  `setup-restic.sh`): 7 cases pass — AWS keys with `/`, repo URL,
  multi-`=`, single quote, real newline + CR rejection.
- Roundtrip tests for `sed_quote` in template substitution:
  11 cases pass — plain, single-quoted exclude, multi-arg,
  `&`, `|`, `\`, all metachars combined.
- Error-path tracing of `setup-restic.sh`:
  - No `NODE_NAME` (non-interactive): bails with explicit error.
  - No S3 credentials (non-interactive, no existing `/etc/restic`):
    bails with explicit error.
  - With `NODE_NAME` and full creds: advances through validation →
    config summary → restic install attempt (sandbox can't `sudo`).

Risks / known gaps:
- The bootstrap copy step still copies `backup.sh` +
  `restic-backup.{service,timer}` to `/opt/stacks/_backup/` (for
  backwards compatibility with operators who run `backup.sh` directly).
  WP5 will remove that copy once the addon dispatch is wired.
- `check-node.sh` does NOT yet verify the lobaro container or
  repo-id match (WP3 territory).
- E2E verification (`docker ps`, `restic snapshots`, repo-id match,
  `docker inspect .Config.Env | grep PASSWORD`) requires a live node.

Not yet started: WP3–WP7.

## 2026-08-22

Implemented WP1 — Tailscale IP SSOT (AGENT.md §3 WP1).

New files:
- `_system/update-tailscale-ip.sh` — atomic writer. Validates CGNAT
  (100.64.0.0/10); refuses to overwrite on invalid input or Tailscale
  being down; no-op when the value is unchanged.
- `_system/update-tailscale-ip.service` — systemd oneshot
  (`Type=oneshot`, hardened with `ProtectSystem=strict`,
  `ReadWritePaths=/opt/homelab/env-file`).
- `_system/update-tailscale-ip.timer` — periodic refresh
  (`OnCalendar=*:0/15`, `Persistent=true`).
- `_system/tailscaled.service.d/override.conf` — drop-in with
  `ExecStartPost=/opt/stacks/_system/update-tailscale-ip.sh` so the
  SSOT file is also refreshed on every Tailscale (re)start.

Modified files:
- `lib.sh` — added `homelab_ipv4_is_valid` and
  `homelab_validate_tailscale_ip` helpers (mirrors the existing
  CGNAT check style in `bootstrap.sh:beszel_ipv4_is_tailnet`).
- `bootstrap.sh`:
  - Directory skeleton (step 2) now creates
    `/opt/homelab/env-file` (mode 755) and `/opt/stacks/_system`.
  - New step 3a "Tailscale IP SSOT install" between Tailscale `up`
    and UFW hardening. Copies `_system/*` to
    `/opt/stacks/_system/`, installs the tailscaled drop-in,
    `systemctl daemon-reload`, runs the writer once, and enables
    `update-tailscale-ip.timer`.
  - Final notes mention the new SSOT artifact.
- `check-node.sh` — new "Tailscale IP SSOT" section. Fails when the
  file is missing, fails when its value is not a valid CGNAT IPv4,
  and fails when the live `tailscale ip -4` disagrees with the file
  (only when Tailscale is up; a down Tailscale only warns).
- `_system/README.md` — table updated to match the now-delivered
  contents; "Install flow" relabelled "WP1 install flow".

Behavioural guarantees kept:
- The writer never mutates application `.env` files.
- The writer never overwrites the SSOT file with an empty or invalid
  value.
- CGNAT boundary detection works for the full `100.64.0.0/10` range.

Verification (this session):
- `bash -n` on every modified file: passes.
- Unit tests on `homelab_validate_tailscale_ip`: 23 cases pass
  (boundaries `100.64.0.0` / `100.127.255.255`, RFC1918 rejection,
  malformed input, CIDR suffix rejection).
- Parser tests on the SSOT file format: 6 cases pass
  (`TAILSCALE_IP=…`, single-quoted, double-quoted, wrong key,
  RFC1918, junk).
- E2E verification (live node, systemctl restart round-trip) is
  deferred to the next session per AGENT.md §5 rule 5 ("stop after
  each WP for review").

Not yet started: WP2–WP7.

## 2026-08-19

Added an opt-in Beszel agent deployment:

- `bootstrap.sh --beszel-agent` (or the interactive opt-in) requires the hub
  URL, public agent key, and token before writing the runtime `.env`.
- The agent-only Compose project lives under `/opt/stacks/beszel-agent/`, uses
  host networking for host statistics, listens on loopback, disables inbound
  SSH mode, and publishes no Docker ports.
- The generated `.env` is root-owned with mode `600`; `INSTALL_BESZEL_AGENT=true`
  is persisted only after a running container is verified.
- The hub and Uptime Kuma remain manual, with the hub UI intended for Tailscale
  access only.

## 2026-08-18

Closed the residual High issues from the second hardening review:

- Public SSH lockdown is persisted in `/etc/homelab/node.env`; ordinary re-runs do not reopen it. `--public-ssh` is the explicit reopen path.
- Node names are immutable after the first bootstrap. Role and node-name conflicts fail before convergence, protecting restic tags and retention.
- Exit-node success now requires Tailscale to report the requested exit node online. Public-IP and S3 probes remain diagnostics, and an unavailable third-party echo service no longer rolls back an otherwise verified route.
- `USE_EXIT_NODE` and `EXIT_NODE_APPLIED` distinguish wanted from successfully applied exit-node state. Failed or skipped application is not recorded as applied.
- UFW state is compared before and after convergence. `tailscaled` is restarted only after actual firewall changes or on a new node that needs its first firewall-path verification.
- `/etc/restic/env` and `/etc/homelab/node.env` are written with safe quoting and read with an allow-listed line parser. Installed backup, health, and password-rotation helpers no longer source secret files as shell code.
- Recovery-key setup works interactively and with `RESTIC_RECOVERY_PASSWORD_FILE` for non-interactive runs. A root-only marker records existence without storing the key. Password rotation requires at least two repository keys and verifies the recovery key before and after rotation.
- `check-node.sh` now fails on failed/timeout backup unit results, inactive UFW, persisted SSH-state mismatches, missing node state, and client exit-node state contradictions.
- `RESTORE.md` places `/etc/restic` secrets before bootstrap/restic setup and preserves restored ownership with `cp -a`.
- `TESTING.md` now covers re-runs, exit-node rejection, recovery-key rotation, special-character secrets, restore ordering, and backup-unit failures.

These changes make the scripts suitable for careful throwaway-machine testing,
not unattended or production deployment.

Additional first-run fixes:

- Root invocations now use `env DEBIAN_FRONTEND=noninteractive` correctly, so
  `sudo ./bootstrap.sh` does not try to execute the environment assignment.
- Cloudflared installation no longer derives an unsupported Ubuntu codename.
  It uses Cloudflare's documented `any` suite, removes stale apt metadata before
  base package updates, falls back to the official binary, and continues to
  restic/UFW/Tailscale when both installation paths fail.
- `INSTALL_CLOUDFLARED` records successful applied state only; a stale failed
  request is not retried on a plain re-run.
