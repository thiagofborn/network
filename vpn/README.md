# Home VPN — GL.iNet GL-BE6500

Remote access to the home LAN (`192.168.8.0/24`). Two layers:

| Layer | Role | Status |
|---|---|---|
| **Tailscale** (subnet router) | Primary remote access. Works through the ISP's CGNAT. | Live on the router |
| **OpenVPN server** (`myvpn`) | Secondary / on-LAN. UDP 1194, split-tunnel. | Deployed, LAN-only |

The ISP (DIGI) puts the PPPoE link behind **CGNAT** — `pppoe-wan` gets a
`100.64.0.0/10` address (RFC 6598), not a public IP — so nothing on the
internet can open a connection *to* the router. Inbound port-forwarding for
OpenVPN cannot work. Tailscale sidesteps this: both ends dial out to the
Tailscale coordination/DERP servers and the tunnel is stitched in the middle.

---

## Layer 1 — Tailscale (the one you actually use remotely)

### What's configured on the router

- Package `tailscale` (OpenWrt), service enabled, node name **`gl-be6500`**.
- `tailscale up --advertise-routes=192.168.8.0/24 --accept-dns=false --netfilter-mode=off`
  — prefs persist in `/etc/tailscale/tailscaled.state`.
- The `192.168.8.0/24` route is **approved** in the Tailscale admin console
  (Machines → gl-be6500 → Edit route settings).

### CGNAT-specific fixes (all persisted)

The router's WAN IP lives inside `100.64.0.0/10`, which is *also* Tailscale's
own internal range. That collision breaks Tailscale unless:

1. **`--netfilter-mode=off`** — otherwise `tailscaled` installs an anti-spoof
   rule `iif != tailscale0 ip saddr 100.64.0.0/10 drop` that drops the
   router's *own* WAN packets. With it off we manage the firewall by hand
   (below). Also patched in `/etc/init.d/tailscale`:
   `TS_DEBUG_FIREWALL_MODE=off` (reverts on `opkg upgrade tailscale` — re-apply).
2. **WAN DNS** — pppoe was injecting the ISP's `100.90.1.1` / `100.100.1.1`
   resolvers into `/etc/resolv.conf`; the `100.64.0.0/10 dev tailscale0`
   route then black-holed all DNS. Fixed with
   `uci set network.wan.peerdns=0` + static `network.wan.dns='1.1.1.1' '8.8.8.8'`.

### Firewall (UCI, `/etc/config/firewall`)

```
config zone
	option name       'tailscale'
	option device     'tailscale0'
	option input      'ACCEPT'
	option output     'ACCEPT'
	option forward    'ACCEPT'
	option masq       '0'
	option mtu_fix    '1'

config forwarding   # tailscale <-> lan, both directions
	option src 'tailscale'
	option dest 'lan'
config forwarding
	option src 'lan'
	option dest 'tailscale'

config nat          # SNAT tailnet -> LAN (needed because netfilter-mode=off)
	option name    'ts-snat'
	option src     'lan'
	option src_ip  '100.64.0.0/10'
	option target  'MASQUERADE'
```

### Add another device

1. Install Tailscale on the device, sign in to the same tailnet
   (`thiagofborn@`).
2. To reach the home LAN through it: enable "Use subnet routes" /
   `tailscale set --accept-routes` (macOS: Tailscale menu → toggle;
   CLI: `tailscale up --accept-routes`).

### Verify — must be OFF the home Wi-Fi (use cellular / hotspot)

On the home LAN the client reaches `192.168.8.1` directly and the subnet
route is never exercised. From outside:

```
tailscale status | grep gl-be6500     # shows: 192.168.8.0/24
netstat -rn | grep 192.168.8          # routes to a utun* interface
ssh root@192.168.8.1 'uname -n'        # -> GL-BE6500
ping 192.168.8.<some-other-host>
```

### Other tailnet nodes

`mac` (`100.117.9.35`), `hypervisor-01` (`100.66.173.101`).

---

## Layer 2 — OpenVPN server (`myvpn`)

Deployed on the router (see `router/toolbox/OPENVPN_SETUP.md` for the full
build). Reachable only from the LAN today because of CGNAT; kept as a
fallback / for on-site use. If DIGI ever provides a public IP, it works from
the internet with no further changes.

- **Config:** instance `myvpn`, UDP/1194, TUN, split-tunnel
  (`FULL_TUNNEL=0`), subnet `10.8.0.0/24` (server `10.8.0.1`), EC
  `secp384r1` PKI, `tls-crypt`, `AES-256-GCM` / `SHA256`, TLS 1.2 floor,
  CRL checked. Public endpoint in profiles: `vpn.skyui.space`.
- **Scripts** (`router/toolbox/`, auto-relay to the router over SSH via
  `router.env`):
  - `setup_openvpn.sh` — idempotent installer / re-configurator.
  - `new-client.sh <name>` — issue a client, writes a self-contained
    `.ovpn` (inline ca/cert/key/tls-crypt) and copies it back to the
    workstation. `new-client.sh <name> --revoke` to revoke.
- **Issued clients:** `laptop` (`router/toolbox/laptop.ovpn`, gitignored —
  holds a private key; cert valid to Nov 2028).
- **Known drift:** `openvpn.myvpn.local='192.168.10.2'` exists in the live
  UCI (added via the GL.iNet web UI, not by `setup_openvpn.sh`) so the
  daemon binds only that address instead of `0.0.0.0`. Harmless while
  CGNAT blocks inbound; to bind all interfaces:
  `uci delete openvpn.myvpn.local && uci commit openvpn && /etc/init.d/openvpn restart`.

---

## Backup & recovery

`router/router-backup/backup-router.sh` — pulls a `sysupgrade` archive over
SSH, 30-day rotation, `scp -O` (router has no sftp-server). launchd job
`com.home.router-backup.plist`. Archives are gitignored. Run it before any
risky router change — this hardware is new and has been unstable.

Restore: `router/router-backup/restore-router.sh`.
