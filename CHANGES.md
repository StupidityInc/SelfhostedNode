# Changes

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
