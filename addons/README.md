# addons/

Optional features that ride on top of the core bootstrap. Each addon
follows the contract below.

## Contract

Every `addons/<name>/install.sh` MUST follow this exact sequence. If
any step fails, the addon MUST NOT persist `INSTALL_<NAME>=true` and
MUST NOT leave a half-configured runtime artifact behind.

1. **Validate** — confirm preconditions (mutual-exclusion checks,
   required tools, required env vars, hub reachability, etc.). On
   failure: return non-zero, no side effects.
2. **Atomic write** — write any generated files (`docker-compose.yml`,
   `.env`, systemd units) via tmpfile + `mv` so a partial write never
   becomes the active file. All secret-bearing files (`*.env`,
   password files, etc.) MUST be mode 600 or 700, root-owned.
3. **Start** — bring the unit up (`docker compose up -d`,
   `systemctl enable --now ...`, etc.).
4. **Verify running** — confirm the unit is actually running. Do NOT
   trust `up -d` exit code alone — re-inspect (e.g.
   `docker inspect -f '{{.State.Running}}'` or
   `systemctl is-active`).
5. **Persist flag** — only AFTER step 4 succeeds, write
   `INSTALL_<NAME>=true` to `/etc/homelab/node.env`. Use the safe
   `homelab_format_kv` helper from `lib.sh`.

## Re-run safety

Re-running an addon MUST be safe. Either:

- The addon detects existing configuration and skips steps that would
  be destructive (e.g. "compose project already running, leaving
  data volume untouched"), OR
- The addon explicitly asks for confirmation before overwriting.

Addons MUST NEVER silently rotate secrets, change passwords, or
recreate data volumes on a re-run.

## Permissions policy (F3)

Per the post-laptop-1 batch, stack directories follow a single,
predictable permission scheme:

| Path                                  | Mode  | Owner      |
|---------------------------------------|-------|------------|
| Stack dir (e.g. `/opt/stacks/<name>`)  | 755   | root:root  |
| `docker-compose.yml`                  | 644   | root:root  |
| `.env` (secret-bearing)               | 600   | root:root  |
| Data subdir (`beszel_data`, `config`) | 755   | root:root  |

Identity dirs (`/etc/homelab/`, `/etc/restic/`) stay 700 — they are
NOT stack dirs. `addon_root_only_dir` defaults to 755; callers that
need 700 for a secret-only dir MUST pass the mode explicitly
(see `addons/lib-addon.sh:addon_persist_flag`).

## Shared helpers

Source `addons/lib-addon.sh` from your `install.sh`. It provides:

- `addon_log` / `addon_warn` / `addon_error` — consistent logging.
- `addon_require_root` — exit if `$EUID != 0`.
- `addon_assert_not_running CONTAINER` — refuse if a container is
  running (used for mutual-exclusion).
- `addon_root_only_dir PATH MODE` — create a directory owned by root
  with the given mode.
- `addon_root_only_file PATH MODE` — atomic write + chmod.
- `addon_persist_flag NAME VALUE` — write `NAME=VALUE` to
  `/etc/homelab/node.env` via `homelab_format_kv`.

`lib-addon.sh` sources `lib.sh` from the repo root if available.

## Mutual exclusion

Addons that conflict with each other or with the core MUST check
before installing. Examples:

- `restic-host-native` and `lobaro` (core, primary backup) are
  mutually exclusive.
- Future addons that bind the same port are mutually exclusive.

Use `addon_assert_not_running` or equivalent logic. Document the
exclusion in the addon's `README.md`.

## Currently planned addons

| Addon | Status |
|-------|--------|
| `beszel-agent` | implemented (post-WP5) |
| `beszel-hub` | implemented (post-laptop-1 batch) |
| `restic-host-native` | implemented (post-WP5) |
| `cloudflared` | implemented (post-laptop-1 batch) — Docker container, not host binary |

See `AGENT.md` §3 WP5 for the original move from inline `bootstrap.sh`
code to these addon installers. The post-laptop-1 batch added the
hub/cloudflared addons and tightened the addon contract.
