# Home VPN — GL.iNet GL-BE6500

Remote access to the home LAN (`192.168.8.0/24`). Two layers:

| Layer | Role | Status |
|---|---|---|
| **Tailscale** (subnet router) | Primary remote access. | Live on the router |
| **OpenVPN server** (`myvpn`) | Secondary / on-LAN fallback. UDP 1194, split-tunnel. | Deployed, binds all interfaces |

Admin access to the router: **`ssh root@100.83.50.117`** (its Tailscale IP).
Prefer this over `192.168.8.1` — the macOS "Local Network" privacy block on
VS Code recurs and kills LAN SSH from this workstation
([[vscode-local-network-block]]), while the tailnet path keeps working.

---

## WAN / ISP topology

The router has two uplinks, managed by GL's `kmwan` (kernel multi-WAN).

| Uplink | Interface | Link | Address | State |
|---|---|---|---|---|
| **MEO** | `secondwan` → `eth1.2` (switch1 **port 7**, the 2.5 G LAN jack), DHCP | MEO CPE in **bridge mode** | **public**, e.g. `176.79.20.75/24` gw `176.79.20.1` (dynamic) | **working** — primary |
| **DIGI** | `wan` → `eth0.20`, PPPoE (`166961426@digi`) | — | **CGNAT** `100.69.x` (RFC 6598 `100.64.0.0/10`) | connects, but **outbound TCP 443 fails** — unusable |

- **DIGI**: ICMP and HTTP :80 pass (real fetches, not a captive portal), but
  outbound **TCP 443 never completes**. No HTTPS ⇒ no usable internet and no
  Tailscale over this link. This is DIGI-side (plan restriction / activation
  / 443 filter) — nothing to fix on the router. Call DIGI.
- **MEO bridge mode**: the CPE bridges, so the router holds the public IP
  directly on `eth1.2`. Stable after a cable swap (the 2.5 G port was
  flapping every ~1 min on the old cable — see history below).

### `kmwan` — must not load-balance into the broken DIGI link

`kmwan.global.mode='balance'` with both members enabled and **ICMP-only**
health checks (`tracks='ping,1.1.1.1' …`). DIGI passes ICMP, so kmwan keeps
it in rotation; every flow that hashes to the DIGI nexthop then fails HTTPS.

**Until DIGI actually passes 443, disable it:**

```
ssh root@100.83.50.117 'uci set kmwan.wan.disabled=1 && uci commit kmwan && /etc/init.d/kmwan restart'
```

Re-enable (`kmwan.wan.disabled=0`) once DIGI is fixed. Also note: after a
reboot the DIGI `wan` interface comes back up on its own (`auto=1`); to keep
it fully out until it works, `uci set network.wan.auto=0 && uci commit network`.

---

## Layer 1 — Tailscale (the remote-access path)

### What's configured on the router

- Package `tailscale` (OpenWrt), service enabled, node **`gl-be6500`** =
  **`100.83.50.117`**.
- Brought up with:
  `tailscale up --advertise-routes=192.168.8.0/24 --accept-dns=false --netfilter-mode=off --accept-routes`
  — prefs persist in `/etc/tailscale/tailscaled.state`.
- The `192.168.8.0/24` route is **approved** in the Tailscale admin console
  (Machines → gl-be6500 → Edit route settings).
- `uci set tailscale.settings.enabled='1'` — the OpenWrt init script needs
  this or the daemon never starts.
- With MEO's public IP, Tailscale now gets a real IPv4 endpoint
  (`176.79.20.75:*`) instead of a CGNAT one; still `MappingVariesByDestIP`,
  so peers often relay via DERP (Madrid). Good enough.

### CGNAT-collision fixes — keep while the DIGI `100.64.0.0/10` link exists

The DIGI WAN IP lives inside `100.64.0.0/10`, which is *also* Tailscale's own
internal range. That collision needs:

1. **`--netfilter-mode=off`** — otherwise `tailscaled` installs an anti-spoof
   rule `iif != tailscale0 ip saddr 100.64.0.0/10 drop` that drops the
   router's *own* WAN packets. With it off the firewall is managed by hand
   (below). Also patched in `/etc/init.d/tailscale`:
   `TS_DEBUG_FIREWALL_MODE=off` — **reverts on `opkg upgrade tailscale`,
   re-apply after any upgrade.**
2. **WAN DNS** — pppoe injects DIGI's `100.90.1.1` / `100.100.1.1` resolvers
   into `/etc/resolv.conf`; the `100.64.0.0/10 dev tailscale0` route then
   black-holes DNS to them. Mitigation `uci set network.wan.peerdns=0` +
   static `network.wan.dns` **does not stick** — the GL web UI rewrites the
   whole `network.wan` section whenever WAN is touched there. Currently
   masked because MEO's DHCP hands out working public resolvers
   (`212.55.154.174` / `212.55.154.190`). If DNS breaks after a GL-UI change,
   re-apply `peerdns=0` (and don't edit WAN in the UI), or add static
   `/32` routes for `100.90.1.1` + `100.100.1.1` via the working gateway in
   a hotplug script.

If DIGI is permanently retired, both fixes become unnecessary (harmless to
leave; the manual firewall zone below still stands on its own).

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

### Tailnet nodes

`gl-be6500` (`100.83.50.117`), `mac` (`100.117.9.35`),
`hypervisor-01` (`100.66.173.101`), `iphone-14-pro` (`100.75.76.82`).

---

## Layer 2 — OpenVPN server (`myvpn`)

Deployed on the router (see `router/toolbox/OPENVPN_SETUP.md` for the full
build). Currently a LAN / on-site fallback; Tailscale is the remote path.

- **Config:** instance `myvpn`, UDP/1194, TUN, split-tunnel
  (`FULL_TUNNEL=0`), subnet `10.8.0.0/24` (server `10.8.0.1`), EC
  `secp384r1` PKI, `tls-crypt`, `AES-256-GCM` / `SHA256`, TLS 1.2 floor,
  CRL checked. Public endpoint in profiles: `vpn.skyui.space`.
- **Binding:** now listens on `0.0.0.0:1194` (all interfaces). The old drift
  `openvpn.myvpn.local='192.168.10.2'` (added via the GL web UI, pinned to
  the pre-MEO upstream subnet) was deleted and `uci commit`ed — it had left
  the daemon bound to a dead address after the ISP change.
- **Scripts** (`router/toolbox/`, auto-relay to the router over SSH via
  `router.env`):
  - `setup_openvpn.sh` — idempotent installer / re-configurator.
  - `new-client.sh <name>` — issue a client, writes a self-contained
    `.ovpn` (inline ca/cert/key/tls-crypt) and copies it back to the
    workstation. `new-client.sh <name> --revoke` to revoke.
- **Issued clients:** `laptop` (`router/toolbox/laptop.ovpn`, gitignored —
  holds a private key; cert valid to Nov 2028).
- **Internet reachability (not set up):** MEO bridge mode now puts a public
  IP on the router, so OpenVPN-over-internet is feasible via the existing
  `allow_myvpn` WAN rule (udp/1194) — but the MEO IP is dynamic and
  `vpn.skyui.space` isn't pointed at it. Tailscale covers remote access, so
  left alone.

---

## Backup & recovery

`router/router-backup/backup-router.sh` — pulls a `sysupgrade` archive over
SSH, 30-day rotation, `scp -O` (router has no sftp-server). launchd job
`com.home.router-backup.plist`. Archives are gitignored. Run it before any
risky router change — this hardware is new and has been unstable.

Restore: `router/router-backup/restore-router.sh`.

---

## Known issues / pending

- **DIGI outbound TCP 443 broken** — DIGI-side, call them. Keep
  `kmwan.wan.disabled=1` meanwhile.
- **`network.wan.peerdns=0` doesn't persist** — GL web UI rewrites
  `network.wan`. Masked by MEO's resolvers for now.
- **`TS_DEBUG_FIREWALL_MODE=off` init patch reverts on `opkg upgrade tailscale`.**
- **DIGI `wan` auto-returns after reboot** (`auto=1`); set `auto=0` to keep
  it out until fixed.
- End-to-end Tailscale subnet-route test from off-LAN still to be run by a
  human (steps above).

## History

- MEO replaced Vodafone on `secondwan`; Vodafone/MEO CPE moved to bridge
  mode (was double-NAT `192.168.10.x` before).
- The 2.5 G port (switch1 port 7) was flapping ~every minute at 2500baseT on
  the original cable — swapping the cable fixed it (12 min clean watch).
- `backup-router.sh` fixed to use `scp -O`; had been silently failing since
  ~June (router has no sftp-server).
