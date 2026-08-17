# Homelab Node Bootstrap

Opinionated bootstrap for personal homelab nodes that use:

- Docker Compose stacks under `/opt/stacks`
- Restic → S3-compatible storage (one repository per node, client-side encryption)
- Tailscale for the management / mesh network
- UFW default-deny with Tailscale interface allowed
- Optional Cloudflare Tunnel on server nodes
- Optional Tailscale exit-node routing for pure compute clients

## Roles

| Role     | Public exposure              | Typical use                          |
|----------|------------------------------|--------------------------------------|
| `server` | Yes (Cloudflare Tunnel preferred) | Entry point, reverse proxy, exit node |
| `client` | No                           | Pure compute, internet via exit node |

## Quick start

```bash
# On a fresh Ubuntu Server
git clone <your-private-repo> # or scp the files
cd homelab-bootstrap
chmod +x *.sh

# Server that will also be an exit node
sudo ./bootstrap.sh --role=server --node-name=edge-1 --advertise-exit-node --install-cloudflared

# Client that routes internet through the server
sudo ./bootstrap.sh --role=client --node-name=compute-1 --use-exit-node=edge-1
```

`--node-name` is **required**: it becomes the Tailscale hostname and the restic
backup tag. Generic names (`ubuntu`, `debian`, `localhost`, `server`, …) are
refused. Interactively you get a hostname-derived suggestion to confirm;
non-interactively the flag is mandatory.

You can also run interactively (the script will prompt for role and node name).

### Non-interactive mode

```bash
export TS_AUTHKEY="tskey-auth-..."
sudo ./bootstrap.sh --yes \
  --role=client --node-name=compute-1 \
  --use-exit-node=edge-1 --ts-authkey="$TS_AUTHKEY"
```

`--yes` (or `HOMELAB_NONINTERACTIVE=1`) skips confirmations. Dangerous steps
still require their explicit flags: `--no-public-ssh` *is* the confirmation for
removing public SSH. For unattended restic setup export `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `S3_ENDPOINT`, `BUCKET` (and optionally
`RESTIC_PASSWORD`; otherwise one is generated and printed once. To add a
recovery key non-interactively, also provide `RESTIC_RECOVERY_PASSWORD_FILE`.

## How the safe ordering works

1. Packages, Docker, directory skeleton (existing `/opt/stacks` is **never**
   `chown -R`'d – only newly created directories get an owner).
2. Tailscale up with `--hostname="$NODE_NAME"` (no exit-node routing yet).
3. Servers with `--advertise-exit-node`: `net.ipv4.ip_forward=1` +
   `net.ipv6.conf.all.forwarding=1` via `/etc/sysctl.d/99-homelab-exitnode.conf`,
   applied and **verified**.
4. UFW: the persisted public-SSH choice and the `tailscale0` rule must verify
   **after** `ufw enable`, otherwise the firewall is disabled again and the
   script aborts. `tailscaled` is restarted only when UFW actually changed or
   a new node needs its first firewall-path verification. A peer ping must
   succeed before the script offers to remove public SSH.
5. Restic setup (deferred on clients if S3 is only reachable via the exit node).
6. Desired state persisted to `/etc/homelab/node.env`.
7. **Only now** a client gets its exit node, via
   `tailscale set --exit-node=... --exit-node-allow-lan-access=true` (LAN access
   stays on – homelab default). Success requires Tailscale's
   `.ExitNodeStatus.Online` evidence for the requested node. Public-IP and S3
   probes are useful diagnostics but a third-party echo failure does not roll
   back an otherwise verified exit-node session.

Re-running `bootstrap.sh` is safe: it parses `/etc/homelab/node.env` without
evaluating values, converges Tailscale prefs via `tailscale set`, re-verifies
UFW, and never touches existing data or ownership. Public SSH lockdown and
node identity are sticky. Use `--public-ssh` only for an explicit, intentional
reopen. Refusing `--role` and `--node-name` changes protects role and restic
retention identity.

## Docker and UFW (important!)

**Docker published ports bypass UFW.** Docker programs its own iptables chains
before UFW's, so `-p 8080:80` is reachable from the internet even with a
default-deny policy. This bootstrap deliberately does not rewrite Docker's
firewall rules. Instead:

- When using Cloudflare Tunnel on a server, bind services to `127.0.0.1`
  (e.g. `ports: ["127.0.0.1:8080:80"]`).
- When a service is only for the tailnet, bind it to the node's Tailscale IP.
- `check-node.sh` lists every container published on `0.0.0.0`/`::` so the
  exposure is at least visible.

## Files

| File                        | Purpose                                      |
|-----------------------------|----------------------------------------------|
| `bootstrap.sh`              | Main orchestrator                            |
| `setup-restic.sh`           | Interactive restic + S3 wizard               |
| `backup.sh`                 | Daily backup script (installed verbatim)     |
| `lib.sh`                    | Safe state/secret parsing helpers            |
| `restic-backup.service`     | Systemd unit                                 |
| `restic-backup.timer`       | Daily timer (03:00 + stable per-node offset) |
| `change-restic-password.sh` | Safe restic password rotation                |
| `check-node.sh`             | Health + exit-node + backup-freshness checker|
| `RESTORE.md`                | Self-describing recovery instructions        |
| `CHANGES.md`                | What was hardened and why                    |
| `TESTING.md`                | Throwaway-VPS verification plan              |
| `RISKS.md`                  | Explicit residual risks                     |

Node-local state that does not live in this repo:

| Path                        | Contents                                     |
|-----------------------------|----------------------------------------------|
| `/etc/homelab/node.env`     | ROLE, stable identity, wanted/applied exit-node state, lockdown metadata |
| `/etc/restic/env`           | S3 credentials, repository, cache dir (0600) |
| `/etc/restic/password`      | Repository password (0600)                   |
| `/etc/restic/recovery-key.present` | Recovery-key existence marker, never the secret |
| `/var/cache/restic`         | Restic cache (writable by the systemd unit)  |

## Observability

`sudo /opt/stacks/_backup/check-node.sh` exits non-zero when something is
actually broken, including: Tailscale down, exit-node state contradicting
`/etc/homelab/node.env`, missing `tailscale0` UFW rule, timer not running, or
the newest snapshot being older than `STALE_HOURS` (default 36). It also fails
when the last `restic-backup.service` result was failed or timed out. Wire it
into any monitoring that can run a command and watch the exit code.

## Backup timing

The timer fires at 03:00 plus a *stable per-machine* random offset of up to 2 h
(`FixedRandomDelay=true`), so many clients never stampede a single exit-node
uplink at the same minute – also not after a power event, when `Persistent=true`
makes all missed runs fire at boot.

## Safety notes

- Public SSH is left open by default. Use `--no-public-ssh` only after you have
  confirmed Tailscale access from another machine.
- The restic password is generated once, must be typed back during interactive
  setup (or supplied explicitly in non-interactive mode), and is stored only in
  `/etc/restic/password`. Save it in your password manager.
- Add a second recovery key that lives **only** in your password manager;
  `setup-restic.sh` offers this interactively and accepts
  `RESTIC_RECOVERY_PASSWORD_FILE` non-interactively. Password rotation refuses
  to proceed until a recovery key is recorded and successfully verified.
- Secrets never live inside `/opt/stacks` (so they are not part of the backup).

## Typical multi-node flow

1. Bootstrap the first **server** node with `--advertise-exit-node`.
2. Approve the exit node in the Tailscale admin console.
3. Bootstrap **client** nodes with `--use-exit-node=<server-name>`.
4. Verify from a client: `curl -4 ifconfig.me` (should show the server's public IP).
5. Run a manual backup on each node and confirm snapshots appear in the correct S3 prefix.

## Upgrading these scripts on an existing node

Pull the new files and re-run `sudo ./bootstrap.sh` once **with the same
`--node-name`** (the tag drives `restic forget --tag`, so the name must stay
stable). The re-run creates `/etc/homelab/node.env` and converges everything
else non-destructively.

## Changing the restic password later

```bash
sudo /opt/stacks/_backup/change-restic-password.sh
```

The script stops the timer, requires and verifies a recorded recovery key,
locks against concurrent backups, verifies the new password against the
repository, and only then atomically replaces the on-disk file. Remember to
update your password manager. Recovery keys added via `restic key add` keep
working across rotation. For supervised non-interactive rotation, provide
`RESTIC_RECOVERY_PASSWORD_FILE` and `RESTIC_NEW_PASSWORD_FILE`.

## License / ownership

Personal tooling. Adjust freely for your own nodes.
