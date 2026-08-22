# _system/

Source for **node system scripts** that get installed to
`/opt/stacks/_system/` by `bootstrap.sh`. These are required node
infrastructure — they are NOT addons.

Distinction:

- `_system/` = required, installed by bootstrap, part of the base
  node. Examples: the Tailscale IP SSOT writer, its systemd unit,
  tailscaled drop-ins.
- `addons/` = optional, installed only when explicitly requested.
  Examples: Beszel agent, host-native restic fallback.

## Currently planned contents

| File | Purpose | WP |
|------|---------|----|
| `update-tailscale-ip.sh` | Writes `/opt/homelab/env-file/tailscale.env` atomically. Validates CGNAT address. Does not overwrite the existing file on failure. | WP1 |
| `update-tailscale-ip.service` | systemd oneshot that runs the script. | WP1 |
| `update-tailscale-ip.timer` | Periodic refresh every 15 min (`*:0/15`). | WP1 |
| `tailscaled.service.d/override.conf` | Drop-in so the IP writer also runs after Tailscale restarts. | WP1 |

## WP1 install flow

`bootstrap.sh` (at WP4) will:

1. `mkdir -p /opt/stacks/_system`
2. Copy all files in `_system/` (recursively, preserving `*.d/`
   drop-ins) to `/opt/stacks/_system/`.
3. Set ownership and perms appropriately (scripts mode 755 or 700,
   drop-ins mode 644).
4. `systemctl daemon-reload` if any unit or drop-in changed.
5. `systemctl enable --now update-tailscale-ip.timer`.

Until then this directory is empty and bootstrap.sh does not touch
`/opt/stacks/_system/`.

## Why not under `addons/`?

These scripts are required by the core bootstrap — every node needs
the Tailscale IP SSOT writer. Calling them "addons" would imply they
are optional. They are not.
