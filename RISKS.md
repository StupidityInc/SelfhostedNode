# Accepted Risks

The High issues listed in `agent.md` are implemented, but these residual risks
remain accepted for this personal tooling:

- The test plan has not been executed by this session on throwaway VPSes. A human must run `TESTING.md` before using real nodes.
- UFW does not control Docker-published ports. A Compose port bound to `0.0.0.0` or `::` can remain internet-reachable; `check-node.sh` only reports that exposure.
- Tailscale's online exit-node status is strong routing evidence, but it does not independently verify every destination or the public IP. The optional echo and S3 probes can be unavailable or filtered.
- Choosing `--no-public-ssh` before confirming a working Tailscale path can still lock out the operator. The script keeps any existing public SSH rule when verification fails, but a first-run explicit lockdown has no public fallback by design.
- The recovery marker proves that setup recorded a second repository key and rotation verifies a supplied recovery password; it cannot prove that the human will retain the offline secret afterward.
- S3 credentials are stored root-only but are not automatically scoped to one node's prefix. Operators must create appropriately limited credentials where their provider supports it.
- The scripts assume the expected Ubuntu/Debian command set and behavior of `ufw`, `systemd`, Docker, restic, and Tailscale. Other distributions require supervised testing and may need manual adjustments.
- `RESTIC_PASSWORD` and recovery-password environment variables can be exposed by an operator's process environment or command invocation if used carelessly. Prefer password-manager files and the documented root-only paths.
- If the Cloudflared apt package is unavailable, the fallback downloads the
  latest official architecture-specific binary over HTTPS without pinning a
  release; operators wanting pinned upgrades should manage that separately.

The project is therefore “ready for careful testing on throwaway machines,” not
fully trustworthy or production-ready.
