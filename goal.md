# Homelab Bootstrap — Project Goal & Continuity Document

**Read this first** if you are a new AI instance, a future session with limited context, or a human returning to the project after a break.

This file is the source of truth for *intent*, *constraints*, *current status*, and *how to continue safely*.

---

## 1. What we are trying to achieve

Build a **personal, reviewable, low-footgun bootstrap system** for multi-node homelab machines that a careful operator can eventually fully understand and trust.

The system must:

- Bootstrap a node as either **server** or **client**
- Set up Docker Compose stacks under `/opt/stacks`
- Configure Tailscale (mesh + optional exit-node routing)
- Harden UFW (default deny, Tailscale interface allowed) without locking the operator out
- Set up restic → S3-compatible storage (one encrypted repo per node)
- Persist node identity and desired state
- Provide a truthful health check
- Remain understandable and auditable by a single human later

**Primary values (in order):**
1. Do not lock the operator out
2. Do not destroy existing data / ownership on re-run
3. Secrets handling that does not silently break
4. Honest observability (do not report green when things are wrong)
5. Minimal unnecessary complexity
6. Eventual full human understandability

This is **not** trying to be:
- A general-purpose fleet manager / Ansible replacement
- A zero-trust enterprise platform
- Something that can be deployed and forgotten with zero residual risk
- Compatible with every possible Linux distro or edge case

---

## 2. Architecture constraints (do not redesign)

These are deliberate and must be preserved unless there is a very strong reason:

| Decision | Rationale |
|----------|-----------|
| `/opt/stacks` for all Compose projects | Simple, portable, one tree to back up |
| One restic repository **per node** (S3 prefix = node name) | Clear blast radius, simple restore story |
| Client-side encryption only (restic password) | Operator controls the key; storage provider sees ciphertext |
| Tailscale for mesh + optional exit nodes | Low ops burden, good enough for personal use |
| UFW default-deny + allow `tailscale0` | Simple host firewall model |
| Thin `server` / `client` roles | Server may advertise exit node / run Cloudflare Tunnel; client typically uses an exit node |
| Document + detect for Docker published ports | Do **not** install ufw-docker / custom DOCKER-USER chains as default |
| Single orchestrator script (`bootstrap.sh`) | Safety lives in the **order** of operations; do not split into independently runnable phase scripts |
| Official Tailscale (not Headscale) for now | Lower friction; Headscale is a later optional migration |

---

## 3. Current status (as of last hardening rounds)

### Largely closed (first-run path)
- No recursive `chown -R` on a live `/opt/stacks`
- Exit-node applied last via `tailscale set` (not on initial `up`)
- UFW enable is fail-open / verified rather than “enable and hope”
- Secrets written with `printf` (no heredoc expansion at write time)
- Required `--node-name`, generic names refused
- State persisted in `/etc/homelab/node.env`
- Timer actually enabled and started
- `check-node.sh` uses correct Tailscale JSON fields and can fail

### Closed in the residual High pass
- Public SSH lockdown is sticky across re-runs, with an explicit `--public-ssh` reopen path
- Exit-node apply requires the requested node's `.ExitNodeStatus.Online` evidence and records wanted versus applied state
- `tailscaled` is not restarted when UFW is unchanged on an existing node
- Restic and node state files use safe parsing/quoting rather than shell evaluation
- Node-name changes are refused just like role changes
- `RESTORE.md` places secrets before setup and preserves restored ownership
- Recovery keys work interactively and through a non-interactive password-file path; rotation verifies a second key
- Backup unit failures are visible to `check-node.sh`

### Previously known High issues
These came from a second-pass review and are now addressed; residual non-High
risks are listed in `RISKS.md`:

1. **Lockdown is sticky** — fixed
2. **Exit-node probe requires routing evidence** — fixed
3. **`tailscaled` restart on every re-run** — fixed
4. **Unsafe restic/node env readers** — fixed
5. **`NODE_NAME` change is refused** — fixed
6. **`RESTORE.md` ordering and ownership** — fixed
7. **Recovery key path and rotation verification** — fixed
8. **Backup unit failure visibility** — fixed

These Highs are closed in the scripts, but the system is still **not** ready
for real nodes until the supervised throwaway-machine plan is executed and the
residual risks are understood.

---

## 4. Definition of “ready enough for careful personal use”

All of the following must be true:

- [x] Remaining High items above are either fixed or explicitly listed in `RISKS.md` with rationale
- [x] `TESTING.md` covers at least:
  - Re-run after `--no-public-ssh`
  - Re-run from a Tailscale-only session
  - Unapproved / non-routing exit node (probe must fail or roll back correctly)
  - Recovery-key add → rotate main password → open repo with recovery key only
  - `RESTORE.md` secrets-first path and no destructive `chown -R` on data
  - Special characters in AWS secret still work after write + backup
- [x] A short `RISKS.md` exists that states remaining accepted risks in plain language
- [x] `goal.md` (this file) is kept up to date
- [ ] The test plan has been executed at least once on throwaway machines (human or supervised)

**Still required of the human operator (non-negotiable):**
- Run the test plan on throwaway VPS before real nodes
- Understand at a high level: where secrets live, that Docker `0.0.0.0` publishes bypass UFW, and how exit-node routing is applied
- Keep the restic password (and any recovery key) in a password manager

Blind “deploy and forget” is **out of scope**.

---

## 5. How future AI instances should work

When continuing this project:

1. **Read this file first**, then `CHANGES.md`, `RISKS.md` (if present), `TESTING.md`, and the main scripts.
2. **Do not redesign** the architecture. Prefer small, reviewable fixes.
3. **Prefer evidence from the actual scripts** over generic advice.
4. Treat “claimed fixed in CHANGES.md but still incomplete” as higher priority than brand-new features.
5. Every change that touches networking, firewall, or secrets must err on the side of **operator can still get in** and **existing data is not damaged**.
6. After a round of fixes, update:
   - `CHANGES.md` (what changed and why)
   - `TESTING.md` (new cases)
   - `RISKS.md` (what is still accepted)
   - This `goal.md` if intent or definition of done moved
7. Never claim “production ready” or “fully trustworthy” while known High issues remain open and untested.

### Preferred next work style
- Close the High residual issues (sticky lockdown, probe quality, env sourcing, identity immutability, RESTORE path, recovery key, silent unit failure).
- Keep bootstrap as one orchestrator; helpers may be moved into a sourced `lib.sh` but must not become independent entry points.
- Optimize for a future human who will one day read everything and want to understand it without tribal knowledge.

---

## 6. Key files and their roles

| File | Role |
|------|------|
| `bootstrap.sh` | Main orchestrator (order is load-bearing) |
| `setup-restic.sh` | Restic + S3 wizard / configuration |
| `backup.sh` | Daily backup (installed verbatim, reads `node.env`) |
| `change-restic-password.sh` | Safe password rotation |
| `check-node.sh` | Truthful health / exit-node / exposure checker |
| `restic-backup.service` / `.timer` | Scheduling + sandbox |
| `RESTORE.md` | Break-glass recovery (must stay consistent with hardened bootstrap) |
| `CHANGES.md` | What was fixed and why |
| `TESTING.md` | Concrete throwaway-VPS test sequence |
| `RISKS.md` | Explicit remaining accepted risks (create if missing) |
| `goal.md` | This file — intent, constraints, continuity |

---

## 7. Explicit non-goals (for now)

- Full non-interactive zero-touch provisioning of many nodes
- Automatic Cloudflare Tunnel configuration beyond binary install
- Switching to Headscale
- Per-node scoped S3 credentials enforced by the scripts (document + recommend only)
- Installing ufw-docker or rewriting Docker’s iptables by default
- Making the system safe for completely unattended / unreviewed use

---

## 8. One-sentence summary

We are building a careful, understandable, personal homelab node bootstrap that optimizes against lockout and silent data loss, accepts that some residual risk remains, and is designed so that a future human (or AI with this document) can continue without starting from zero.
