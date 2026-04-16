# Home Network Step-by-Step Configuration Guide

**Device:** GL.iNet GL-BE6500  
**OS:** OpenWrt 23.05-SNAPSHOT  
**Last updated:** April 2026

---

## Target Architecture

| Zone | Purpose | Subnet | Internet Route | Key Devices |
|------|---------|--------|----------------|-------------|
| Main LAN | All wired devices + main Wi-Fi | 192.168.8.0/24 | mwan3 load balance (Digi primary) | Gaming PC, hypervisor, k8s cluster, Mac, printer |
| IoT VLAN | IoT devices (Wi-Fi only) | 192.168.50.0/24 | Vodafone primary | Smart plugs, cameras, Alexa, cat devices, Kindle |

**Server routing exception:**

- `hypervisor-01`, `k8s-master`, `k8s-worker-01`, and `k8s-worker-02` live on Main LAN but have per-host routing rules in `/etc/mwan3.user` that force all their outbound traffic through Vodafone.
- Cloudflare tunnels run on `hypervisor-01` — outbound connections only, no inbound port forwarding required.

---

## ⚠️ Safety Protocol — Read Before Touching Anything

**The rule of this guide:** never change more than one major area at a time. Always back up before each step group. Verify connectivity before continuing.

### GL.iNet GL-BE6500 Recovery Methods

#### Method 1 — U-Boot Web Recovery (hardware failsafe)

Use this when the router is completely unresponsive (web UI and SSH both unreachable).

1. Power off the router completely.
2. Hold the reset button.
3. While holding reset, power the router on. Keep holding for about 5 seconds until the LED blinks in a repeating pattern.
4. Connect your PC to any LAN port via Ethernet (disable Wi-Fi on your PC to avoid confusion).
5. Set your PC's IP to `192.168.1.2` manually (the router won't give out DHCP at this point).
6. Open a browser and go to `http://192.168.1.1`.
7. Upload a clean firmware image to restore the device to a known-good state.

**Why this works:** U-Boot is the bootloader and runs before OpenWrt. It is stored in protected flash and cannot be overwritten by a bad OpenWrt config. It is your last resort before hardware tools.

#### Method 2 — OpenWrt Failsafe Mode (software failsafe)

Use this when OpenWrt boots but is misconfigured (e.g., bad network settings locked you out of SSH).

1. Power on the router.
2. Watch the LED — when it starts flashing rapidly (within the first ~5 seconds), press the reset button once quickly.
3. The router boots in minimal mode with IP `192.168.1.1`.
4. From your PC: `ssh root@192.168.1.1` (no password required in failsafe).
5. Run `mount_root` to make the filesystem writable.
6. Edit or remove the broken config file, then reboot.
7. Alternatively, run `firstboot && reboot` to factory-reset all settings.

**Why this works:** Failsafe mode skips all custom configuration in `/etc/config/`. It is the software equivalent of safemode — useful when a bad UCI config breaks network access.

#### Method 3 — Restore from Tar Backup

Use this when you have a backup and want to roll back specific config files.

```bash
# On the router via SSH or failsafe:
sysupgrade -r /tmp/backup-YYYYMMDD-HHMMSS.tar.gz
reboot
```

---

## Step 1 — Full System Backup

**Why:** OpenWrt stores all persistent configuration under `/etc/config/`. A `sysupgrade` backup captures every config file in a single compressed archive. If anything goes wrong after this point, one command restores your entire configuration. Skip this and you may be reflashing firmware manually.

### 1.1 — Connect to the router via SSH

```bash
ssh root@192.168.1.1
```

If you have already changed the router IP, use that instead.

### 1.2 — Create a timestamped backup on the router

```bash
BACKUP_FILE="/tmp/backup-$(date +%Y%m%d-%H%M%S).tar.gz"
sysupgrade --create-backup "$BACKUP_FILE"
echo "Backup saved as: $BACKUP_FILE"
```

### 1.3 — Copy the backup to your PC (run this on your PC, not the router)

```bash
mkdir -p ~/router-backups
scp root@192.168.1.1:/tmp/backup-*.tar.gz ~/router-backups/
```

### 1.4 — Verify backup contents

```bash
tar -tzf ~/router-backups/backup-*.tar.gz | sort
```

Expected output includes: `etc/config/network`, `etc/config/firewall`, `etc/config/wireless`, `etc/config/dhcp`.

> **Repeat this backup procedure before every step group below.** The reminder is marked as `> BACKUP CHECKPOINT` at the start of each step.

---

## Step 2 — Verify and Document the Current State

**Why:** Before making any change, record the baseline. If something breaks later, comparing before/after output shows exactly what changed. This also confirms Digi (WAN1) is fully working before touching anything.

### 2.1 — Check which network interfaces exist

```bash
ip addr show
```

Command output

```text
root@GL-BE6500:/tmp# ip addr show
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
2: bond0: <BROADCAST,MULTICAST,MASTER> mtu 1500 qdisc noop state DOWN group default qlen 1000
    link/ether ea:10:6d:8f:94:8c brd ff:ff:ff:ff:ff:ff
3: miireg: <> mtu 0 qdisc noop state DOWN group default qlen 1000
    link/netrom 
4: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 00:03:7f:ba:db:ad brd ff:ff:ff:ff:ff:ff
5: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether c4:d0:05:d3:94:83 brd ff:ff:ff:ff:ff:ff
6: ip6tnl0@NONE: <NOARP> mtu 1452 qdisc noop state DOWN group default qlen 1000
    link/tunnel6 :: brd ::
7: sit0@NONE: <NOARP> mtu 1480 qdisc noop state DOWN group default qlen 1000
    link/sit 0.0.0.0 brd 0.0.0.0
8: gre0@NONE: <NOARP> mtu 1476 qdisc noop state DOWN group default qlen 1000
    link/gre 0.0.0.0 brd 0.0.0.0
9: gretap0@NONE: <BROADCAST,MULTICAST> mtu 1462 qdisc noop state DOWN group default qlen 1000
    link/ether 00:00:00:00:00:00 brd ff:ff:ff:ff:ff:ff
10: erspan0@NONE: <BROADCAST,MULTICAST> mtu 1450 qdisc noop state DOWN group default qlen 1000
    link/ether 00:00:00:00:00:00 brd ff:ff:ff:ff:ff:ff
11: ip6gre0@NONE: <NOARP> mtu 1448 qdisc noop state DOWN group default qlen 1000
    link/gre6 :: brd ::
12: teql0: <NOARP> mtu 1500 qdisc noop state DOWN group default qlen 100
    link/void 
13: br-lan: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 94:83:c4:d0:05:d2 brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan
       valid_lft forever preferred_lft forever
14: eth1.1@eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master br-lan state UP group default qlen 1000
    link/ether 94:83:c4:d0:05:d2 brd ff:ff:ff:ff:ff:ff
15: eth1.2@eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 94:83:c4:d0:05:d1 brd ff:ff:ff:ff:ff:ff
    inet 192.168.10.2/24 brd 192.168.10.255 scope global eth1.2
       valid_lft forever preferred_lft forever
16: eth0.20@eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether 94:83:c4:d0:05:d0 brd ff:ff:ff:ff:ff:ff
17: mld-wifi0: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN group default qlen 1000
    link/ether 00:00:00:00:00:00 brd ff:ff:ff:ff:ff:ff
18: wifi0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN group default qlen 2699
    link/ieee802.11 94:83:c4:d0:05:d3 brd ff:ff:ff:ff:ff:ff
19: soc0: <> mtu 0 qdisc noop state DOWN group default qlen 1000
    link/ieee802.11 
21: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master br-lan state UP group default 
    link/ether 12:af:b7:d7:48:94 brd ff:ff:ff:ff:ff:ff
22: wifi1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN group default qlen 2699
    link/ieee802.11 94:83:c4:d0:05:d4 brd ff:ff:ff:ff:ff:ff
23: soc1: <> mtu 0 qdisc noop state DOWN group default qlen 1000
    link/ieee802.11 
25: wlan1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master br-lan state UP group default 
    link/ether d6:60:84:11:2c:3f brd ff:ff:ff:ff:ff:ff
27: pppoe-wan: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1492 qdisc noqueue state UNKNOWN group default qlen 3
    link/ppp 
    inet 100.69.130.59 peer 10.0.23.139/32 scope global pppoe-wan
       valid_lft forever preferred_lft forever
28: mld0: <BROADCAST,MULTICAST,MASTER,UP,LOWER_UP> mtu 1500 qdisc noqueue master br-lan state UP group default qlen 1000
    link/ether ca:15:50:60:87:91 brd ff:ff:ff:ff:ff:ff
29: wlan02: <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP> mtu 1500 qdisc noqueue master mld0 state UP group default 
    link/ether e2:04:f7:d1:c7:c5 brd ff:ff:ff:ff:ff:ff
30: wlan12: <BROADCAST,MULTICAST,SLAVE,UP,LOWER_UP> mtu 1500 qdisc noqueue master mld0 state UP group default 
    link/ether a6:7b:73:49:86:72 brd ff:ff:ff:ff:ff:ff
```

Note the names of your WAN interface (usually `eth0` or `wan`) and LAN interfaces (`lan1`, `lan2`, etc.).

### 2.2 — Check active routes

```bash
ip route show table main
```

Command output:

```text
root@GL-BE6500:/tmp# ip route show table main
default via 10.0.23.139 dev pppoe-wan proto static metric 1 
default via 192.168.10.1 dev eth1.2 proto static src 192.168.10.2 metric 2 
10.0.23.139 dev pppoe-wan proto kernel scope link src 100.69.130.59 
192.168.1.0/24 dev br-lan proto kernel scope link src 192.168.1.1 
192.168.10.0/24 dev eth1.2 proto static scope link metric 2 
```

You should see a default route through Digi's gateway and local routes for the LAN subnet.

### 2.3 — Check current UCI network config

```bash
uci show network
```

Command output:

```text
root@GL-BE6500:/tmp# uci show network
network.loopback=interface
network.loopback.device='lo'
network.loopback.proto='static'
network.loopback.ipaddr='127.0.0.1'
network.loopback.netmask='255.0.0.0'
network.globals=globals
network.globals.ula_prefix='fd23:7e72:770b::/48'
network.@device[0]=device
network.@device[0].name='br-lan'
network.@device[0].type='bridge'
network.@device[0].ports='eth1.1'
network.@device[0].macaddr='94:83:c4:d0:05:d2'
network.@device[1]=device
network.@device[1].name='eth1.1'
network.@device[1].macaddr='94:83:c4:d0:05:d2'
network.@device[1].isolate='0'
network.lan=interface
network.lan.device='br-lan'
network.lan.proto='static'
network.lan.ipaddr='192.168.1.1'
network.lan.netmask='255.255.255.0'
network.lan.ip6assign='60'
network.lan.isolate='0'
network.lan.multicast_querier='0'
network.lan.igmp_snooping='0'
network.@device[2]=device
network.@device[2].name='eth0.20'
network.@device[2].macaddr='94:83:c4:d0:05:d0'
network.wan=interface
network.wan.device='eth0.20'
network.wan.proto='pppoe'
network.wan.force_link='0'
network.wan.ipv6='0'
network.wan.classlessroute='0'
network.wan.metric='1'
network.wan.username='166961426@digi'
network.wan.password='XkOnKTjj'
network.wan6=interface
network.wan6.proto='dhcpv6'
network.wan6.device='@wan'
network.wan6.disabled='1'
network.@switch[0]=switch
network.@switch[0].name='switch0'
network.@switch[0].reset='1'
network.@switch[0].enable_vlan='0'
network.@switch[1]=switch
network.@switch[1].name='switch1'
network.@switch[1].reset='1'
network.@switch[1].enable_vlan='1'
network.vlan_lan=switch_vlan
network.vlan_lan.device='switch1'
network.vlan_lan.vlan='1'
network.vlan_lan.ports='4 5 6 3t'
network.guest=interface
network.guest.force_link='1'
network.guest.type='bridge'
network.guest.proto='static'
network.guest.ipaddr='192.168.9.1'
network.guest.netmask='255.255.255.0'
network.guest.ip6assign='60'
network.guest.multicast_querier='1'
network.guest.igmp_snooping='0'
network.guest.isolate='0'
network.guest.bridge_empty='1'
network.guest.disabled='1'
network.policy_relay_lo_rt_lan=rule
network.policy_relay_lo_rt_lan.lookup='16800'
network.policy_relay_lo_rt_lan.in='loopback'
network.policy_relay_lo_rt_lan.priority='1'
network.tethering6=interface
network.tethering6.device='@tethering'
network.tethering6.proto='dhcpv6'
network.tethering6.disabled='1'
network.wwan6=interface
network.wwan6.device='@wwan'
network.wwan6.proto='dhcpv6'
network.wwan6.disabled='1'
network.wwan=interface
network.wwan.proto='dhcp'
network.wwan.classlessroute='0'
network.wwan.metric='3'
network.secondwan=interface
network.secondwan.ipv6='0'
network.secondwan.proto='dhcp'
network.secondwan.metric='2'
network.secondwan.force_link='0'
network.secondwan.classlessroute='0'
network.secondwan.device='eth1.2'
network.secondwan6=interface
network.secondwan6.proto='dhcpv6'
network.secondwan6.device='@secondwan'
network.secondwan6.disabled='1'
network.novpn_to_main=rule
network.novpn_to_main.gl_vpn_rules='1'
network.novpn_to_main.mark='0x8000/0xf000'
network.novpn_to_main.priority='6000'
network.novpn_to_main.lookup='main'
network.novpn_to_main.disabled='0'
network.vpn_to_main=rule
network.vpn_to_main.gl_vpn_rules='1'
network.vpn_to_main.mark='0x0/0xf000'
network.vpn_to_main.priority='9000'
network.vpn_to_main.lookup='main'
network.vpn_to_main.invert='1'
network.vpn_to_main.disabled='0'
network.vpn_leak_block=rule
network.vpn_leak_block.gl_vpn_rules='1'
network.vpn_leak_block.mark='0x0/0xf000'
network.vpn_leak_block.priority='9910'
network.vpn_leak_block.action='blackhole'
network.vpn_leak_block.invert='1'
network.vpn_leak_block.disabled='0'
network.vpn_block_lan_leak=rule
network.vpn_block_lan_leak.gl_vpn_rules='1'
network.vpn_block_lan_leak.in='lan'
network.vpn_block_lan_leak.priority='9920'
root@GL-BE6500:/tmp# uci show network
network.loopback=interface
network.loopback.device='lo'
network.loopback.proto='static'
network.loopback.ipaddr='127.0.0.1'
network.loopback.netmask='255.0.0.0'
network.globals=globals
network.globals.ula_prefix='fd23:7e72:770b::/48'
network.@device[0]=device
network.@device[0].name='br-lan'
network.@device[0].type='bridge'
network.@device[0].ports='eth1.1'
network.@device[0].macaddr='94:83:c4:d0:05:d2'
network.@device[1]=device
network.@device[1].name='eth1.1'
network.@device[1].macaddr='94:83:c4:d0:05:d2'
network.@device[1].isolate='0'
network.lan=interface
network.lan.device='br-lan'
network.lan.proto='static'
network.lan.ipaddr='192.168.1.1'
network.lan.netmask='255.255.255.0'
network.lan.ip6assign='60'
network.lan.isolate='0'
network.lan.multicast_querier='0'
network.lan.igmp_snooping='0'
network.@device[2]=device
network.@device[2].name='eth0.20'
network.@device[2].macaddr='94:83:c4:d0:05:d0'
network.wan=interface
network.wan.device='eth0.20'
network.wan.proto='pppoe'
network.wan.force_link='0'
network.wan.ipv6='0'
network.wan.classlessroute='0'
network.wan.metric='1'
network.wan.username='166961426@digi'
network.wan.password='XkOnKTjj'
network.wan6=interface
network.wan6.proto='dhcpv6'
network.wan6.device='@wan'
network.wan6.disabled='1'
network.@switch[0]=switch
network.@switch[0].name='switch0'
network.@switch[0].reset='1'
network.@switch[0].enable_vlan='0'
network.@switch[1]=switch
network.@switch[1].name='switch1'
network.@switch[1].reset='1'
network.@switch[1].enable_vlan='1'
network.vlan_lan=switch_vlan
network.vlan_lan.device='switch1'
network.vlan_lan.vlan='1'
network.vlan_lan.ports='4 5 6 3t'
network.guest=interface
network.guest.force_link='1'
network.guest.type='bridge'
network.guest.proto='static'
network.guest.ipaddr='192.168.9.1'
network.guest.netmask='255.255.255.0'
network.guest.ip6assign='60'
network.guest.multicast_querier='1'
network.guest.igmp_snooping='0'
network.guest.isolate='0'
network.guest.bridge_empty='1'
network.guest.disabled='1'
network.policy_relay_lo_rt_lan=rule
network.policy_relay_lo_rt_lan.lookup='16800'
network.policy_relay_lo_rt_lan.in='loopback'
network.policy_relay_lo_rt_lan.priority='1'
network.tethering6=interface
network.tethering6.device='@tethering'
network.tethering6.proto='dhcpv6'
network.tethering6.disabled='1'
network.wwan6=interface
network.wwan6.device='@wwan'
network.wwan6.proto='dhcpv6'
network.wwan6.disabled='1'
network.wwan=interface
network.wwan.proto='dhcp'
network.wwan.classlessroute='0'
network.wwan.metric='3'
network.secondwan=interface
network.secondwan.ipv6='0'
network.secondwan.proto='dhcp'
network.secondwan.metric='2'
network.secondwan.force_link='0'
network.secondwan.classlessroute='0'
network.secondwan.device='eth1.2'
network.secondwan6=interface
network.secondwan6.proto='dhcpv6'
network.secondwan6.device='@secondwan'
network.secondwan6.disabled='1'
network.novpn_to_main=rule
network.novpn_to_main.gl_vpn_rules='1'
network.novpn_to_main.mark='0x8000/0xf000'
network.novpn_to_main.priority='6000'
network.novpn_to_main.lookup='main'
network.novpn_to_main.disabled='0'
network.vpn_to_main=rule
network.vpn_to_main.gl_vpn_rules='1'
network.vpn_to_main.mark='0x0/0xf000'
network.vpn_to_main.priority='9000'
network.vpn_to_main.lookup='main'
network.vpn_to_main.invert='1'
network.vpn_to_main.disabled='0'
network.vpn_leak_block=rule
network.vpn_leak_block.gl_vpn_rules='1'
network.vpn_leak_block.mark='0x0/0xf000'
network.vpn_leak_block.priority='9910'
network.vpn_leak_block.action='blackhole'
network.vpn_leak_block.invert='1'
network.vpn_leak_block.disabled='0'
network.vpn_block_lan_leak=rule
network.vpn_block_lan_leak.gl_vpn_rules='1'
network.vpn_block_lan_leak.in='lan'
network.vpn_block_lan_leak.priority='9920'
network.vpn_block_lan_leak.action='blackhole'
network.vpn_block_lan_leak.disabled='0'
network.vpn_block_guest_leak=rule
network.vpn_block_guest_leak.gl_vpn_rules='1'
network.vpn_block_guest_leak.in='guest'
network.vpn_block_guest_leak.priority='9920'
network.vpn_block_guest_leak.action='blackhole'
network.vpn_block_guest_leak.disabled='0'
network.vpn_block_wgserver_leak=rule
network.vpn_block_wgserver_leak.gl_vpn_rules='1'
network.vpn_block_wgserver_leak.in='wgserver'
network.vpn_block_wgserver_leak.priority='9920'
network.vpn_block_wgserver_leak.action='blackhole'
network.vpn_block_wgserver_leak.disabled='0'
network.vpn_block_ovpnserver_leak=rule
network.vpn_block_ovpnserver_leak.gl_vpn_rules='1'
network.vpn_block_ovpnserver_leak.in='ovpnserver'
network.vpn_block_ovpnserver_leak.priority='9920'
network.vpn_block_ovpnserver_leak.action='blackhole'
network.vpn_block_ovpnserver_leak.disabled='0'
network.vlan_secondwan=switch_vlan
network.vlan_secondwan.device='switch1'
network.vlan_secondwan.ports='7 3t'
network.vlan_secondwan.vlan='2'
network.secondwan_dev=device
network.secondwan_dev.name='eth1.2'
network.secondwan_dev.macaddr='94:83:c4:d0:05:d1'
network.main_static_net=rule
network.main_static_net.gl_vpn_rules='1'
network.main_static_net.suppress_prefixlength='0'
network.main_static_net.priority='800'
network.main_static_net.lookup='9910'
network.main_static_net.disabled='0'
```

Save this output somewhere (copy to a file on your PC) so you can diff it against later states.

### 2.4 — Confirm Digi (WAN1) works

```bash
ping -c 4 8.8.8.8
```

Command output:

```text
root@GL-BE6500:/tmp# ping -c 4 8.8.8.8
PING 8.8.8.8 (8.8.8.8): 56 data bytes
64 bytes from 8.8.8.8: seq=0 ttl=117 time=14.328 ms
64 bytes from 8.8.8.8: seq=1 ttl=117 time=14.133 ms
64 bytes from 8.8.8.8: seq=2 ttl=117 time=14.357 ms
^C
--- 8.8.8.8 ping statistics ---
4 packets transmitted, 3 packets received, 25% packet loss
round-trip min/avg/max = 14.133/14.272/14.357 ms
```

Do not continue until this succeeds. If it fails, fix WAN1 first — everything else depends on it.

### 2.5 — Check current firewall zones

```bash
uci show firewall | grep -E 'zone|network'
```

Command output:

```text
root@GL-BE6500:/tmp# uci show firewall | grep -E 'zone|network'
firewall.@zone[0]=zone
firewall.@zone[0].name='lan'
firewall.@zone[0].network='lan'
firewall.@zone[0].input='ACCEPT'
firewall.@zone[0].output='ACCEPT'
firewall.@zone[0].forward='ACCEPT'
firewall.@zone[1]=zone
firewall.@zone[1].name='wan'
firewall.@zone[1].network='wan' 'wan6' 'wwan' 'secondwan'
firewall.@zone[1].input='DROP'
firewall.@zone[1].output='ACCEPT'
firewall.@zone[1].forward='REJECT'
firewall.@zone[1].masq='1'
firewall.@zone[1].mtu_fix='1'
firewall.@zone[2]=zone
firewall.@zone[2].name='guest'
firewall.@zone[2].network='guest'
firewall.@zone[2].forward='REJECT'
firewall.@zone[2].output='ACCEPT'
firewall.@zone[2].input='REJECT'
```

Note the existing zone names (typically `lan` and `wan`). You will add to these later without breaking them.

---

## ✅ Analysis — What the Command Outputs Tell Us

Before proceeding, here is what was discovered from your system. Steps 3 and 5 have been updated below to reflect the actual hardware configuration.

### Network architecture (from `ip addr show` + `uci show network`)

The GL-BE6500 uses a **swconfig-based internal switch** (`switch1`), NOT DSA (Distributed Switch Architecture). This is important — it changes how VLANs are created.

| Component | Actual | Notes |
|-----------|--------|-------|
| WAN1 (Digi) | `pppoe-wan` over `eth0.20` | PPPoE, IP `100.69.130.59`, metric 1 ✓ |
| WAN2 (Vodafone) | `secondwan` over `eth1.2` | DHCP, IP `192.168.10.2`, gateway `192.168.10.1`, metric 2 ✓ |
| LAN bridge | `br-lan` | `eth1.1` (switch VLAN 1) + `wlan0` + `wlan1` + `mld0` |
| Internal switch | `switch1` (swconfig) | Port 3 = CPU (eth1), Ports 4/5/6 = LAN jacks, Port 7 = Vodafone jack |
| Wi-Fi | `wifi0` (radio0), `wifi1` (radio1) | `wlan02`/`wlan12` = MLO sub-interfaces |

**Switch port to physical jack mapping — to be confirmed in Step 3:**

- `switch1` VLAN 1: ports `4 5 6` (untagged LAN) + `3t` (CPU)
- `switch1` VLAN 2: port `7` (Vodafone/secondwan) + `3t` (CPU)
- Port 3 is the CPU port — this is how `eth1` connects to the switch.

### Routing (from `ip route show table main`)

Both default routes are already installed:

- `default via 10.0.23.139 dev pppoe-wan metric 1` — Digi wins as default ✓
- `default via 192.168.10.1 dev eth1.2 metric 2` — Vodafone standby ✓

### Firewall (from `uci show firewall`)

| Zone | Networks | Problem |
|------|----------|---------|
| `lan` | `lan` | OK |
| `wan` | `wan`, `wan6`, `wwan`, **`secondwan`** | ⚠️ Vodafone is lumped here — needs its own zone |
| `guest` | `guest` | Disabled, OK |

**Implication for Step 7:** must remove `secondwan` from the `wan` zone before creating the dedicated `wan2` zone.

### What is already done vs. what still needs doing

| Task | Status |
|------|--------|
| Digi PPPoE (WAN1) | ✅ Done — working |
| Vodafone DHCP (WAN2 / `secondwan`) | ✅ Done — connected, metric 2 |
| IoT VLAN (`br-iot`, 192.168.50.0/24) | ✅ Done — Step 5 |
| IoT SSID (`Tchocoloco-IoT`, 2.4 GHz, client isolated) | ✅ Done — Step 5 |
| IoT → Vodafone routing (mwan3.user) | ✅ Done — Step 5 |
| Server per-host Vodafone routing (mwan3.user) | ✅ Done — Step 6 |
| Cloudflare tunnels via Vodafone | ✅ Done — Step 7 |
| VLANs 10/20/30/40 (planned, not implemented) | ❌ Dropped — not needed |

> **⚠️ Security notice:** The `uci show network` output in section 2.3 contains your Digi PPPoE password in plaintext (`network.wan.password=...`). Redact this before sharing this document with anyone. You should also consider changing the password if this file has been stored anywhere public.

---

## Step 3 — Verify Vodafone (secondwan) — Already Configured

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why this step exists:** Vodafone (WAN2) is **already configured** by GL.iNet's firmware as the `secondwan` interface. The Vodafone cable is plugged into physical **switch port 7** (the last LAN jack), which is wired to switch VLAN 2 on `switch1`, presented to the OS as `eth1.2`. The `secondwan` interface runs DHCP on that port and currently has the IP `192.168.10.2` from Vodafone's modem/router at `192.168.10.1`.

**What we do NOT need to do:** create a new WAN interface, touch bridge members, or move any cables.

**What we DO need to do here:** verify the connection is healthy and identify which physical LAN jack on the router housing corresponds to switch port 7 (so you know which jack is Vodafone's).

### 3.1 — Confirm Vodafone (`secondwan`) is up

```bash
ifstatus secondwan
```

Command Output:

```text
root@GL-BE6500:/tmp# ifstatus secondwan
{
        "up": true,
        "pending": false,
        "available": true,
        "autostart": true,
        "dynamic": false,
        "uptime": 59050,
        "l3_device": "eth1.2",
        "proto": "dhcp",
        "device": "eth1.2",
        "metric": 2,
        "dns_metric": 0,
        "delegation": true,
        "ipv4-address": [
                {
                        "address": "192.168.10.2",
                        "mask": 24
                }
        ],
        "ipv6-address": [

        ],
        "ipv6-prefix": [

        ],
        "ipv6-prefix-assignment": [

        ],
        "route": [
                {
                        "target": "0.0.0.0",
                        "mask": 0,
                        "nexthop": "192.168.10.1",
                        "source": "192.168.10.2/32"
                }
        ],
        "dns-server": [
                "1.1.1.1",
                "1.1.1.2"
        ],
        "dns-search": [
                "lan"
        ],
        "neighbors": [

        ],
        "inactive": {
                "ipv4-address": [

                ],
                "ipv6-address": [

                ],
                "route": [

                ],
                "dns-server": [

                ],
                "dns-search": [

                ],
                "neighbors": [

                ]
        },
        "data": {
                "dhcpserver": "192.168.10.1",
                "leasetime": 60
        }
}
```

Command Output: (after 10 minutes uptime):

```text
root@GL-BE6500:/tmp# ifstatus secondwan
{
        "up": true,
        "pending": false,
        "available": true,
        "autostart": true,
        "dynamic": false,
        "uptime": 57932,
        "l3_device": "eth1.2",
        "proto": "dhcp",
        "device": "eth1.2",
        "metric": 2,
        "dns_metric": 0,
        "delegation": true,
        "ipv4-address": [
                {
                        "address": "192.168.10.2",
                        "mask": 24
                }
        ],
        "ipv6-address": [

        ],
        "ipv6-prefix": [

        ],
        "ipv6-prefix-assignment": [

        ],
        "route": [
                {
                        "target": "0.0.0.0",
                        "mask": 0,
                        "nexthop": "192.168.10.1",
                        "source": "192.168.10.2/32"
                }
        ],
        "dns-server": [
                "1.1.1.1",
                "1.1.1.2"
        ],
        "dns-search": [
                "lan"
        ],
        "neighbors": [

        ],
        "inactive": {
                "ipv4-address": [

                ],
                "ipv6-address": [

                ],
                "route": [

                ],
                "dns-server": [

                ],
                "dns-search": [

                ],
                "neighbors": [

                ]
        },
        "data": {
                "dhcpserver": "192.168.10.1",
                "leasetime": 60
        }
}
```

Look for `"up": true` in the output. The `ipaddr` field should show `192.168.10.2` (or whatever IP Vodafone's modem assigns).

**Output analysis:**

| Field | Value | Assessment |
|-------|-------|------------|
| `up` | `true` | ✅ Vodafone interface is live |
| `proto` | `dhcp` | ✅ Correct |
| `metric` | `2` | ✅ Lower priority than Digi (metric 1) |
| `ipv4-address` | `192.168.10.2/24` | ✅ Got a DHCP lease |
| `nexthop` | `192.168.10.1` | ✅ Vodafone modem is the gateway |
| `dns-server` | `1.1.1.1`, `1.1.1.2` | ✅ Cloudflare DNS pushed by modem |
| `leasetime` | `60` (seconds) | ⚠️ Very short — see note below | 

> **Note on 60-second lease:** Vodafone's modem is handing out 60-second DHCP leases. This is the modem's own LAN lease time (the router is behind the modem). It does **not** mean the WAN connection drops every minute — DHCP renewal is silent and automatic. This is a Vodafone modem quirk and poses no operational problem.

> **I have changed to 1 hour leases:** by logging into the Vodafone modem's admin interface and adjusting its DHCP settings. This is optional but reduces the frequency of DHCP renewals.

### 3.2 — Test Vodafone internet connectivity

```bash
ping -I eth1.2 -c 4 8.8.8.8
```

Command output:

```text
root@GL-BE6500:/tmp# ping -I eth1.2 -c 4 8.8.8.8
PING 8.8.8.8 (8.8.8.8): 56 data bytes
64 bytes from 8.8.8.8: seq=0 ttl=118 time=16.686 ms
64 bytes from 8.8.8.8: seq=1 ttl=118 time=16.489 ms
64 bytes from 8.8.8.8: seq=2 ttl=118 time=16.483 ms
^C
--- 8.8.8.8 ping statistics ---
3 packets transmitted, 3 packets received, 0% packet loss
round-trip min/avg/max = 16.483/16.552/16.686 ms
```

This forces pings to exit via the `eth1.2` interface (Vodafone). If it succeeds, Vodafone is routing traffic to the internet. If it fails, check the cable and the Vodafone modem.

**Expected output:** 4 replies from 8.8.8.8. Latency will be higher than Digi because `eth1.2` goes through Vodafone's modem/NAT.

**Output analysis:** 3/3 packets received, 0% packet loss, ~16ms RTT. ✅ Vodafone internet path is fully working. Latency is slightly higher than Digi (~16ms vs ~14ms), which is expected given the extra modem hop.

### 3.3 — Identify which physical LAN jack is Vodafone (switch port 7)

The switch reports that Vodafone is on switch port 7, but the physical label on the router housing (LAN1, LAN2, etc.) may not match the switch port number. Run the following:

```bash
swconfig dev switch1 show
```

Command output (abridged):

```text
root@GL-BE6500:/tmp# swconfig dev switch1 show
Global attributes:
Port 0:
        disable: ???
        pvid: 1
        link: ???
Port 1:
        disable: ???
        pvid: 1
        link: ???
Port 2:
        disable: ???
        pvid: 1
        link: ???
Port 3:
        disable: 0
        pvid: 1
        link: port:3 link:up speed:10000baseT full-duplex 
Port 4:
        disable: 0
        pvid: 1
        link: port:4 link:up speed:1000baseT full-duplex txflow rxflow 
Port 5:
        disable: 0
        pvid: 1
        link: port:5 link:up speed:100baseT full-duplex 
Port 6:
        disable: 0
        pvid: 1
        link: port:6 link:down
Port 7:
        disable: 0
        pvid: 2
        link: port:7 link:up speed:1000baseT full-duplex 
Port 8:
        disable: 0
        pvid: 1
        link: port:8 link:down
VLAN 1:
        ports: 3t 4 5 6 
VLAN 2:
        ports: 3t 7 
```

This prints link status for each port. With Vodafone's cable plugged in, port 7 should show `link: port:7 link:up`. Unplug the Vodafone cable momentarily and run the command again — the port that changes from `link:up` to `link:down` is the Vodafone jack. Note its physical label on the router housing.

**Output analysis — actual port state:**

| Switch port | Link state | Speed | PVID | Assignment |
|-------------|-----------|-------|------|------------|
| Port 3 | `link:up` | 10Gbps | 1 | CPU port (internal — `eth1`) |
| Port 4 | `link:up` | 1000Mbps | 1 | **Unmanaged switch → Laptop + Brother Printer** (VLAN 10) |
| Port 5 | `link:up` | 1000Mbps | 1 | **Home Lab Server — directly connected** ✅ |
| Port 6 | `link:up` | **2500Mbps** | 1 | **Gaming PC — directly connected** ✅ *(2.5GbE NIC confirmed)* |
| Port 7 | `link:up` | 1000Mbps | 2 | ✅ Vodafone — confirmed |
| Port 8 | `link:down` | — | 1 | Unused internal port |

**Important observations for Step 5:**

- **Port 4** — Unmanaged switch, 1000Mbps. Behind it: **Laptop + Brother Printer**, both of which belong on VLAN 10. No VLAN conflict — the unmanaged switch is no longer an architecture problem. ✅
- **Port 5** — Home Lab Server (`hypervisor-01`), 1000Mbps direct connection confirmed. Stays on Main LAN. Vodafone routing is handled by per-host `ip rule` entries in `/etc/mwan3.user` (Step 6). ✅
- **Port 6** — Gaming PC, **2500Mbps** — the router's port 6 is a multi-gig (2.5GbE) port, and the Gaming PC has a 2.5GbE NIC. Stays on Main LAN and uses the Digi default route. ✅
- **Port 8** — Unused; ignore.
- **CPU port 3** runs at 10Gbps internally — no bottleneck between switch and routing engine.

> **✅ Architecture fully resolved — no managed switch required, no workarounds needed.**
>
> Every device has its own router port or shares a VLAN with compatible devices only:

> - Port 4 → unmanaged switch carrying **Laptop + Printer**, both on VLAN 10 — no conflict
> - Port 5 → **Home Lab Server** (`hypervisor-01`) direct, stays on Main LAN, Vodafone routing via mwan3.user (Step 6)
> - Port 6 → **Gaming PC** direct, stays on Main LAN, uses Digi default route
>
> See Section 5.5a for a full summary.

- The CPU port (3) runs at **10Gbps** internally, which means there is no bottleneck between the switch and the routing engine.

**Port mapping reference:**

| Switch port | Physical jack label | Device | Notes |
|-------------|--------------------|----|-------|
| 4 | ________ | Unmanaged switch → Laptop + Brother Printer | Main LAN |
| 5 | ________ | Home Lab Server (`hypervisor-01`) — ✅ direct, 1Gbps | Main LAN, Vodafone routing via mwan3 |
| 6 | ________ | Gaming PC — ✅ direct, 2.5Gbps | Main LAN, Digi default |
| 7 | ________ (Vodafone — do not change) | Vodafone modem | `secondwan` |

> **Note the Vodafone jack label here:** ________________ (e.g., LAN4)

### 3.4 — Verify both default routes are present

```bash
ip route show table main | grep default
```

Expected:

```text
default via 10.0.23.139 dev pppoe-wan proto static metric 1    ← Digi (preferred)
default via 192.168.10.1 dev eth1.2 proto static metric 2      ← Vodafone (secondary)
```

The lower metric (1) means Digi wins for all traffic by default. Vodafone only carries traffic that policy routing explicitly sends to it — which we configure in Steps 7 and 8. Do not proceed until both lines appear.

---

## Step 4 — Install Required Packages

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** GL.iNet's firmware ships `mwan3` and `ip-full` pre-installed — these are the only tools needed for per-host policy routing. The one additional package needed is `openssh-sftp-server` to support SCP file transfers (used by the automated backup script in Step 1).

### 4.1 — Update package lists

```bash
opkg update
```

### 4.2 — Install openssh-sftp-server

```bash
opkg install openssh-sftp-server
```

**Why:** OpenDropbear (the SSH daemon on this router) does not include SFTP support by default. The `scp` command used in the backup script requires SFTP to work. Without this package, `scp` transfers fail silently.

| Package | Status | Purpose |
|---------|--------|---------|
| `ip-full` | ✅ Pre-installed | `ip rule` and `ip route table` commands for policy routing |
| `mwan3` | ✅ Pre-installed | Load balancer / multi-WAN manager — the actual routing engine used |
| `openssh-sftp-server` | Install this | Enables SCP for router backups |

> **Note:** `pbr` (Policy-Based Routing daemon) was explored early in this project but is not used. GL.iNet's `kmwan` daemon manages `mwan3` on this router and overwrites the `pbr` configuration. All custom routing is done via `/etc/mwan3.user` (see Step 6).

---

## Step 5 — IoT VLAN Setup

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** IoT devices (smart plugs, lamps, cameras, Alexa, cat feeders, Kindle) need their own isolated network segment for two reasons:
1. **Security** — IoT firmware is rarely updated and often has vulnerabilities. Isolation prevents a compromised device from reaching your server, PC, or router management.
2. **Routing** — IoT traffic routes via Vodafone, keeping Digi's low-latency PPPoE clean for the gaming PC.

**This VLAN is Wi-Fi only.** All IoT devices connect to the `Tchocoloco-IoT` 2.4 GHz SSID. No switch port changes are needed.

**Status: ✅ Completed.** The commands below are the record of what was applied.

---

### 5.1 — Create the IoT network interface

```bash
uci set network.iot=interface
uci set network.iot.proto='static'
uci set network.iot.type='bridge'
uci set network.iot.bridge_empty='1'
uci set network.iot.ipaddr='192.168.50.1'
uci set network.iot.netmask='255.255.255.0'
uci commit network
/etc/init.d/network restart
```

**Why `bridge_empty='1'`?** The bridge must exist before the Wi-Fi SSID attaches to it. Without this flag OpenWrt silently discards an empty bridge.

Verify:

```bash
ip addr show br-iot
```

Expected:
```text
br-iot: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    inet 192.168.50.1/24 ...
```

---

### 5.2 — Configure DHCP for the IoT subnet

```bash
uci set dhcp.iot=dhcp
uci set dhcp.iot.interface='iot'
uci set dhcp.iot.start='100'
uci set dhcp.iot.limit='150'
uci set dhcp.iot.leasetime='12h'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Devices receive IPs in `192.168.50.100 – 192.168.50.249`.

---

### 5.3 — Configure the IoT firewall zone

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='iot'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='iot'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='iot'
uci set firewall.@forwarding[-1].dest='wan'

# Allow DHCP so devices can get an IP
uci add firewall rule
uci set firewall.@rule[-1].name='IoT-DHCP'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='67-68'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow DNS so devices can resolve hostnames
uci add firewall rule
uci set firewall.@rule[-1].name='IoT-DNS'
uci set firewall.@rule[-1].src='iot'
uci set firewall.@rule[-1].dest_port='53'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
/etc/init.d/firewall restart
```

**Why `input='REJECT'`?** IoT devices cannot reach the router's admin interface or SSH. The two narrow exceptions (DHCP + DNS) are the minimum they need to get an address and resolve names.

**Why `forward='REJECT'`?** IoT devices cannot reach Main LAN devices (server, Gaming PC, Mac). A compromised camera cannot pivot to your server.

> **Troubleshooting — device gets no IP:** If a device associates with `Tchocoloco-IoT` but never gets an address, the firewall DHCP/DNS rules above were not applied. Verify with `uci show firewall | grep IoT-DHCP`.

---

### 5.4 — Create the IoT Wi-Fi SSID

```bash
uci set wireless.iot_ssid=wifi-iface
uci set wireless.iot_ssid.device='wifi0'
uci set wireless.iot_ssid.mode='ap'
uci set wireless.iot_ssid.network='iot'
uci set wireless.iot_ssid.ssid='Tchocoloco-IoT'
uci set wireless.iot_ssid.encryption='psk2+ccmp'
uci set wireless.iot_ssid.key='A4ET5F2KZP'
uci set wireless.iot_ssid.isolate='1'
uci commit wireless
wifi reload
```

**Why 2.4 GHz (`wifi0`) only?** Smart plugs, cameras, Alexa, cat feeders, and Kindle all require 2.4 GHz. Adding a 5 GHz SSID is unnecessary.

**Why `isolate='1'`?** Prevents a compromised IoT device from probing other IoT devices on the same SSID.

---

### 5.5 — Add mwan3 routing rule: IoT → Vodafone

Add the following inside the `apply_vlan_routing_rules()` function in `/etc/mwan3.user`:

```bash
ip rule add priority 112 from 192.168.50.0/24 lookup 7   # IoT → Vodafone (table 7)
ip rule add priority 212 from 192.168.50.0/24 lookup main # fallback
```

**What table 7 is:** Created by mwan3 for `secondwan` (Vodafone). Its default route is `via 192.168.10.1 dev eth1.2`. Any packet sent to table 7 exits via Vodafone.

Apply immediately (rules take effect without a restart):

```bash
ip rule add priority 112 from 192.168.50.0/24 lookup 7
ip rule add priority 212 from 192.168.50.0/24 lookup main
```

Verify:

```bash
ip rule show | grep 192.168.50
```

Expected:
```text
112: from 192.168.50.0/24 lookup 7
212: from 192.168.50.0/24 lookup main
```

---

### 5.6 — Connect IoT devices

| Device | Action |
|--------|--------|
| Smart Electric Plugs | Connect via app — select `Tchocoloco-IoT` |
| Smart Lamps | Connect via app — select `Tchocoloco-IoT` |
| Amazon Kindle | Wi-Fi settings → switch to `Tchocoloco-IoT` |
| Cat's Feeder | Connect via app — select `Tchocoloco-IoT` |
| Cat's Bathroom (Petkit_T4) | ✅ Already on IoT — MAC `b8:d6:1a:74:28:b0` |
| Cameras | Connect via app — select `Tchocoloco-IoT` |
| Amazon Alexa | Alexa app → Device Settings → Wi-Fi → switch |

---

## Step 6 — Server Vodafone Routing

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** `hypervisor-01`, `k8s-master`, `k8s-worker-01`, and `k8s-worker-02` are on Main LAN (`192.168.8.0/24`). They should always exit via Vodafone so Cloudflare tunnel connections have a stable, consistent outbound path. This is done with per-host `ip rule` entries in `/etc/mwan3.user`, which persist across reboots and `mwan3` restarts.

**No switch port or VLAN changes needed.** Devices stay on the same physical port and IP subnet.

---

### 6.1 — Assign static DHCP leases for all server devices

**Why:** The `ip rule` entries reference specific IPs. If DHCP assigns a different IP after lease expiry, the routing rule silently stops working. Static leases lock each device to a fixed IP permanently.

```bash
# hypervisor-01 — primary NIC
uci add dhcp host
uci set dhcp.@host[-1].name='hypervisor-01'
uci set dhcp.@host[-1].mac='86:fd:8b:b4:9b:88'
uci set dhcp.@host[-1].ip='192.168.8.229'

# hypervisor-01 — secondary NIC (VM bridge interface)
uci add dhcp host
uci set dhcp.@host[-1].name='hypervisor-01-vm-br'
uci set dhcp.@host[-1].mac='4c:cc:6a:bb:83:97'
uci set dhcp.@host[-1].ip='192.168.8.231'

# k8s-master
uci add dhcp host
uci set dhcp.@host[-1].name='k8s-master'
uci set dhcp.@host[-1].mac='52:54:00:22:a1:d5'
uci set dhcp.@host[-1].ip='192.168.8.206'

# k8s-worker-01
uci add dhcp host
uci set dhcp.@host[-1].name='k8s-worker-01'
uci set dhcp.@host[-1].mac='52:54:00:c1:53:09'
uci set dhcp.@host[-1].ip='192.168.8.125'

# k8s-worker-02
uci add dhcp host
uci set dhcp.@host[-1].name='k8s-worker-02'
uci set dhcp.@host[-1].mac='52:54:00:ff:8b:5c'
uci set dhcp.@host[-1].ip='192.168.8.162'

uci commit dhcp
/etc/init.d/dnsmasq restart
```

---

### 6.2 — Add per-host routing rules to /etc/mwan3.user

`/etc/mwan3.user` is the only file in the mwan3 stack that survives GL.iNet's `kmwan` daemon rewriting `/etc/config/mwan3`. The `apply_vlan_routing_rules()` function is called by the mwan3 hook every time an interface connects.

Add these entries inside `apply_vlan_routing_rules()` in `/etc/mwan3.user`:

```bash
# Server devices → Vodafone (table 7)
ip rule add priority 115 from 192.168.8.229 lookup 7   # hypervisor-01 primary NIC
ip rule add priority 116 from 192.168.8.231 lookup 7   # hypervisor-01 VM bridge NIC
ip rule add priority 117 from 192.168.8.206 lookup 7   # k8s-master
ip rule add priority 118 from 192.168.8.125 lookup 7   # k8s-worker-01
ip rule add priority 119 from 192.168.8.162 lookup 7   # k8s-worker-02

# Fallback to main table for each
ip rule add priority 215 from 192.168.8.229 lookup main
ip rule add priority 216 from 192.168.8.231 lookup main
ip rule add priority 217 from 192.168.8.206 lookup main
ip rule add priority 218 from 192.168.8.125 lookup main
ip rule add priority 219 from 192.168.8.162 lookup main
```

**Why priorities 115–119?** These must be higher priority (lower number) than the catch-all `lookup main` rules but distinct from the IoT/Guest rules at 112. Priorities 115–119 keep server rules grouped and easy to read.

Apply immediately — `ip rule add` takes effect instantly, no restart needed:

```bash
ip rule add priority 115 from 192.168.8.229 lookup 7
ip rule add priority 116 from 192.168.8.231 lookup 7
ip rule add priority 117 from 192.168.8.206 lookup 7
ip rule add priority 118 from 192.168.8.125 lookup 7
ip rule add priority 119 from 192.168.8.162 lookup 7
ip rule add priority 215 from 192.168.8.229 lookup main
ip rule add priority 216 from 192.168.8.231 lookup main
ip rule add priority 217 from 192.168.8.206 lookup main
ip rule add priority 218 from 192.168.8.125 lookup main
ip rule add priority 219 from 192.168.8.162 lookup main
```

---

### 6.3 — Verify routing rules are active

On the router:

```bash
ip rule show | grep '192\.168\.8\.\(229\|231\|206\|125\|162\)'
```

Expected:
```text
115: from 192.168.8.229 lookup 7
116: from 192.168.8.231 lookup 7
117: from 192.168.8.206 lookup 7
118: from 192.168.8.125 lookup 7
119: from 192.168.8.162 lookup 7
215: from 192.168.8.229 lookup main
...
```

---

### 6.4 — Confirm hypervisor-01 exits via Vodafone

SSH into `hypervisor-01`:

```bash
curl -s https://ifconfig.me
```

The returned IP must match the Vodafone WAN IP (`ifstatus secondwan | grep address` on the router). It must **not** be the Digi IP.

---

## Step 7 — Cloudflare Tunnel Configuration

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** Cloudflare tunnels are outbound connections — `cloudflared` dials out to Cloudflare's edge servers. Vodafone's CGNAT and your router firewall are irrelevant because there is no inbound connection to forward. No port forwarding is needed on the router. The only requirement is that `cloudflared` can reach the internet, which Step 6 guarantees.

**`cloudflared` runs on `hypervisor-01`.** From there it can reach:

- `http://localhost:3001` — the Node.js app running on `hypervisor-01` itself
- `http://192.168.8.206:30611` — the Kubernetes NodePort on `k8s-master` (same LAN, no firewall barrier)

All outbound traffic from `hypervisor-01` (including the `cloudflared` daemon) exits via Vodafone automatically via the mwan3 rule from Step 6.

---

### 7.1 — Verify cloudflared service status

On `hypervisor-01`:

```bash
systemctl status cloudflared
journalctl -u cloudflared -n 30
```

Look for: `Connection registered` or `Registered tunnel connection`. If it shows errors, check the tunnel config in Step 7.2.

---

### 7.2 — Verify the tunnel config points to correct local ports

```bash
cat /etc/cloudflared/config.yml
# or:
cat ~/.cloudflared/config.yml
```

The config should match this pattern:

```yaml
tunnel: <your-tunnel-id>
credentials-file: /etc/cloudflared/<your-tunnel-id>.json

ingress:
  - hostname: yoursite.com
    service: http://localhost:30611       # k8s NodePort — or use http://192.168.8.206:30611 if cloudflared is not a k8s node

  - hostname: api.yoursite.com
    service: http://localhost:3001        # Node.js app on hypervisor-01

  - service: http_status:404             # required catch-all
```

**Note on the k8s NodePort:** If `cloudflared` runs on `hypervisor-01` and the NodePort service is on `k8s-master` at `192.168.8.206:30611`, use that LAN IP directly. The static lease from Step 6.1 ensures this IP never changes.

---

### 7.3 — Confirm outbound routing via Vodafone

On `hypervisor-01`:

```bash
# Exit IP must be Vodafone's, not Digi's
curl -s https://ifconfig.me

# Confirm cloudflared can reach the Cloudflare tunnel endpoint
curl -sv https://region1.v2.argotunnel.com 2>&1 | grep -E 'Connected|TLS|SSL'
```

---

### 7.4 — Test the public URLs

From a device on cellular (not on your home network):

- Visit your site's public Cloudflare URL — should render normally.
- Hit the Node.js endpoint — should respond.

Both responses come through Cloudflare's network. Your router has no open inbound ports.

---

## Step 8 — End-to-End Tests

Run these after all steps above are complete.

### 8.1 — IoT network test

Connect a phone temporarily to `Tchocoloco-IoT`:

```bash
# Phone should get a 192.168.50.x address
cat /tmp/dhcp.leases | grep '192.168.50'

# From the phone: exit IP must be Vodafone's
curl https://ifconfig.me

# From the phone: router should be unreachable (REJECT)
ping 192.168.8.1
```

### 8.2 — Server routing test

SSH into `hypervisor-01`:

```bash
# Must return Vodafone's IP, not Digi's
curl -s https://ifconfig.me
```

Compare against the router: `ssh root@192.168.8.1 'ifstatus secondwan | grep address'`

### 8.3 — Routing rules check

On the router:

```bash
ip rule show | grep -E 'lookup [17]'
```

Expected rules present at minimum:
- Priority 112: `from 192.168.50.0/24 lookup 7` (IoT → Vodafone)
- Priority 115–119: `from 192.168.8.x lookup 7` (server hosts → Vodafone)

### 8.4 — DHCP static leases check

```bash
cat /tmp/dhcp.leases
```

Confirm `hypervisor-01` (`.229`/`.231`), `k8s-master` (`.206`), `k8s-worker-01` (`.125`), and `k8s-worker-02` (`.162`) all appear with their correct IPs. If any is missing, the device has not renewed its lease yet — reconnect it or wait for the lease to expire.

### 8.5 — Cloudflare tunnel check

```bash
systemctl status cloudflared     # on hypervisor-01
```

Confirm: `active (running)` and tunnel connection registered.

---

### 8.6 — Gaming PC routing verification

Confirm the Gaming PC (`games-01`, `192.168.8.196`) is using Digi exclusively and not being load-balanced:

```bash
# All dst= addresses should be 100.69.129.239 (Digi's public IP)
ssh -i ~/.ssh/id_ed25519 -o LogLevel=error root@192.168.8.1 \
  'conntrack -L -s 192.168.8.196 2>/dev/null | grep -oE "dst=100\.[0-9.]+" | sort -u | head -5'
```

**Expected output:** `dst=100.69.129.239`

If `dst=192.168.10.2` (Vodafone gateway) appears, the mwan3 rule hasn't taken effect for existing connections — flush conntrack to force re-routing:

```bash
ssh -i ~/.ssh/id_ed25519 -o LogLevel=error root@192.168.8.1 \
  'conntrack -D -s 192.168.8.196'
```

Then re-run the verification command above.

> **Note:** The mwan3 rule pinning `192.168.8.196` to `default_poli` was applied via `uci` and persisted with `uci commit mwan3`. It survives reboots automatically.

---

## Step 9 — Final System Backup

> Run this after confirming everything in Step 8 is working.

### 9.1 — Create backup on the router

```bash
ssh root@192.168.8.1

BACKUP_FILE="/tmp/backup-final-$(date +%Y%m%d-%H%M%S).tar.gz"
sysupgrade --create-backup "$BACKUP_FILE"
echo "Saved: $BACKUP_FILE"
```

### 9.2 — Download to Mac

```bash
scp -i ~/.ssh/id_ed25519 root@192.168.8.1:/tmp/backup-final-*.tar.gz \
    ~/Logs/router-backup/
```

### 9.3 — Export individual config files

```bash
scp -i ~/.ssh/id_ed25519 root@192.168.8.1:/etc/config/network   ~/Logs/router-backup/config-network.txt
scp -i ~/.ssh/id_ed25519 root@192.168.8.1:/etc/config/firewall  ~/Logs/router-backup/config-firewall.txt
scp -i ~/.ssh/id_ed25519 root@192.168.8.1:/etc/config/wireless  ~/Logs/router-backup/config-wireless.txt
scp -i ~/.ssh/id_ed25519 root@192.168.8.1:/etc/config/dhcp      ~/Logs/router-backup/config-dhcp.txt
scp -i ~/.ssh/id_ed25519 root@192.168.8.1:/etc/mwan3.user       ~/Logs/router-backup/mwan3.user.txt
```

Store a copy in a second location (external drive or cloud). This single archive restores the complete configuration after any factory reset or firmware flash.

---

## Quick Reference

### Network map

| Zone | Subnet | Gateway | WAN | Key Devices |
|------|--------|---------|-----|-------------|
| Main LAN | 192.168.8.0/24 | 192.168.8.1 | mwan3 (Digi primary) | Gaming PC, Mac, hypervisor, k8s |
| IoT VLAN | 192.168.50.0/24 | 192.168.50.1 | Vodafone | Smart plugs, cameras, Alexa, cat devices |

### Static IP assignments

| Device | MAC | IP | Routing |
|--------|-----|----|---------|
| hypervisor-01 (primary NIC) | `86:fd:8b:b4:9b:88` | `192.168.8.229` | Vodafone via mwan3 |
| hypervisor-01 (VM bridge) | `4c:cc:6a:bb:83:97` | `192.168.8.231` | Vodafone via mwan3 |
| k8s-master | `52:54:00:22:a1:d5` | `192.168.8.206` | Vodafone via mwan3 |
| k8s-worker-01 | `52:54:00:c1:53:09` | `192.168.8.125` | Vodafone via mwan3 |
| k8s-worker-02 | `52:54:00:ff:8b:5c` | `192.168.8.162` | Vodafone via mwan3 |
| games-01 | `a0:36:bc:bb:e4:0d` | `192.168.8.196` | Digi (default) |
| Petkit_T4 | `b8:d6:1a:74:28:b0` | `192.168.50.198` | Vodafone (IoT VLAN) |
| BRN94DDF (Brother Printer) | `94:dd:f8:20:43:ca` | `192.168.8.218` | Digi (default) |

### Key commands

```bash
# Check who is connected and to which network
~/Logs/toolbox/devices-connected.sh

# View active routing rules
ip rule show

# View Vodafone routing table
ip route show table 7

# Verify Vodafone is up
ifstatus secondwan | grep -E 'up|uptime|address'

# Test that a host routes via Vodafone
ip route get 8.8.8.8 from 192.168.8.229

# View DHCP leases
cat /tmp/dhcp.leases

# Reload Wi-Fi without full restart
wifi reload

# Quick backup (download to Mac afterwards)
sysupgrade --create-backup /tmp/backup-quick.tar.gz
```

### Routing tables

| Table | Interface | Via |
|-------|-----------|-----|
| 1 | Digi (`pppoe-wan`) | `10.0.23.139` (PPPoE peer) |
| 7 | Vodafone (`eth1.2`) | `192.168.10.1` (Vodafone modem) |

### Restore from backup

```bash
scp ~/Logs/router-backup/backup-YYYYMMDD.tar.gz root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'sysupgrade -r /tmp/backup-YYYYMMDD.tar.gz && reboot'
```

---


- Port `3` = CPU port (connects to `eth1`) — must always be tagged (`3t`)
- Port `4` = LAN jack — **unmanaged switch** (Laptop + Brother Printer, both VLAN 10)
- Port `5` = LAN jack — **Home Lab Server** (direct, confirmed 1000Mbps)
- Port `6` = LAN jack — **Gaming PC** (direct, confirmed **2500Mbps**, 2.5GbE)
- Port `7` = Vodafone jack (VLAN 2 / `secondwan`) — do not touch

**Confirmed port assignment plan — final topology, no workarounds needed:**

- Port `4` → VLAN 10 (Home — unmanaged switch carrying Laptop + Brother Printer; both are VLAN 10, no conflict)
- Port `5` → VLAN 20 (Home Lab Server — ✅ direct cable, 1Gbps, Vodafone routing)
- Port `6` → VLAN 30 (Gaming PC — ✅ direct cable, **2.5Gbps**, Digi routing)
- VLAN 40 (Guest) → Wi-Fi only, no physical port needed

> ⚠️ After this step, the existing `br-lan` will have no physical LAN ports (all 3 are moved to new VLANs). Management access will remain via the current Wi-Fi until you create new SSIDs in Step 9. Do not disconnect your PC from Wi-Fi during this step.

### 5.1 — Identify the physical jack numbers for ports 4, 5, 6

Before reassigning ports, verify which physical LAN jack label (LAN1, LAN2, LAN3) corresponds to which switch port. Plug a device into one LAN jack at a time and run:

```bash
swconfig dev switch1 show | grep -A3 'port:'
```

Match the jack that shows `link:up` to its switch port number. Record your mapping:

| Switch port | Physical jack label | Assigned to |
|-------------|--------------------|----|
| 4 | ________ | VLAN 10 (unmanaged switch → Laptop + Brother Printer) |
| 5 | ________ | VLAN 20 (Home Lab Server — ✅ confirmed) |
| 6 | ________ | VLAN 30 (Gaming PC — ✅ confirmed, 2.5Gbps) |
| 7 | ________ | Vodafone (do not change) |

### 5.2 — Remove ports 4, 5, 6 from LAN VLAN 1

**Why:** A switch port can only be untagged (PVID) in one VLAN. The LAN ports currently belong to VLAN 1. Moving them to new VLANs requires removing them from VLAN 1 first.

```bash
# Update VLAN 1 to only have the CPU port (no LAN jacks)
uci set network.vlan_lan.ports='3t'
uci commit network
```

> ⚠️ After this command, wired LAN ports will stop working (no DHCP, no connectivity) until you assign them to the new VLANs in the next sub-steps. Stay connected via Wi-Fi.

### 5.3 — Create switch VLAN 10 (Home wired port)

```bash
uci set network.vlan_home=switch_vlan
uci set network.vlan_home.device='switch1'
uci set network.vlan_home.vlan='10'
uci set network.vlan_home.ports='4 3t'    # port 4 = unmanaged switch (Laptop + Printer); CPU tagged
```

### 5.4 — Create switch VLAN 20 (Server wired port)

```bash
uci set network.vlan_servers=switch_vlan
uci set network.vlan_servers.device='switch1'
uci set network.vlan_servers.vlan='20'
uci set network.vlan_servers.ports='5 3t'    # port 5 = LAN jack for the server
```

### 5.5a — Final Topology Summary: How the Unmanaged Switch Problem Was Solved

The original concern was that a single cable from the router fed an unmanaged switch shared by devices that needed different VLANs. This is now fully resolved through physical recabling — no managed switch required, no Wi-Fi workaround.

**Final wired device layout:**

| Router port | swconfig port | Speed | Device | VLAN | WAN |
|-------------|--------------|-------|--------|------|-----|
| WAN | `eth0` | — | Digi PPPoE modem | — | — |
| LAN (Vodafone) | Port 7 | 1000Mbps | Vodafone router | `secondwan` | — |
| LAN (Server) | Port 5 | 1000Mbps | Home Lab Server | **20** | Vodafone |
| LAN (Gaming) | Port 6 | **2500Mbps** | Gaming PC | **30** | Digi |
| LAN (Switch) | Port 4 | 1000Mbps | Unmanaged switch | **10** | Digi |

**Unmanaged switch (port 4) — devices:**

| Device | VLAN via port 4 | Notes |
|--------|----------------|-------|
| Laptop | 10 | VLAN 10 only — no conflict |
| Brother Printer | 10 | VLAN 10 only — no conflict |

Because both devices behind the unmanaged switch belong to VLAN 10, the switch passes all traffic identically with no VLAN separation needed. The topological constraint that made an unmanaged switch problematic (devices needing *different* VLANs) no longer exists.

> ✅ **No managed switch required. No Wi-Fi workaround needed. All devices are wired and on the correct VLAN.**

---

### 5.5 — Create switch VLAN 30 (Gaming PC — direct port 6)

```bash
uci set network.vlan_gaming=switch_vlan
uci set network.vlan_gaming.device='switch1'
uci set network.vlan_gaming.vlan='30'
uci set network.vlan_gaming.ports='6 3t'    # port 6 = Gaming PC (2.5GbE direct); CPU tagged
```

### 5.6 — Create network interfaces for each VLAN

These tell OpenWrt the IP, subnet, and device for each VLAN. The `eth1.X` sub-interfaces are auto-created by the kernel when the switch VLAN entries above are applied.

For VLANs 10, 20, 30 (wired + Wi-Fi), the interface needs a bridge device so wired and wireless clients share the same VLAN. OpenWrt creates the bridge (`br-vlan10`, etc.) automatically when a Wi-Fi interface is attached to the network.

```bash
# VLAN 10 — Home
uci set network.vlan10=interface
uci set network.vlan10.proto='static'
uci set network.vlan10.device='eth1.10'
uci set network.vlan10.ipaddr='192.168.11.1'    # NOTE: NOT 192.168.10.x — that subnet belongs to Vodafone (eth1.2)
uci set network.vlan10.netmask='255.255.255.0'
uci set network.vlan10.type='bridge'

# VLAN 20 — Servers
uci set network.vlan20=interface
uci set network.vlan20.proto='static'
uci set network.vlan20.device='eth1.20'
uci set network.vlan20.ipaddr='192.168.20.1'
uci set network.vlan20.netmask='255.255.255.0'
uci set network.vlan20.type='bridge'

# VLAN 30 — Gaming
uci set network.vlan30=interface
uci set network.vlan30.proto='static'
uci set network.vlan30.device='eth1.30'
uci set network.vlan30.ipaddr='192.168.30.1'
uci set network.vlan30.netmask='255.255.255.0'
uci set network.vlan30.type='bridge'

# VLAN 40 — Guest (Wi-Fi only, no switch port)
uci set network.vlan40=interface
uci set network.vlan40.proto='static'
uci set network.vlan40.type='bridge'
uci set network.vlan40.bridge_empty='1'
uci set network.vlan40.ipaddr='192.168.40.1'
uci set network.vlan40.netmask='255.255.255.0'
```

**Why `bridge_empty='1'` for VLAN 40?** This allows the bridge to exist even with no physical member yet. When a Wi-Fi SSID is set to `network='vlan40'` in Step 9, the wireless interface will be added to this bridge automatically. Without `bridge_empty='1'`, the interface would fail to start with no members.

**Why `type='bridge'` for VLANs 10, 20, 30?** Each of these VLANs will have both a wired port (`eth1.X`) and a Wi-Fi interface. The bridge combines them into one L2 segment so wired and wireless devices on the same VLAN can communicate directly.

### 5.7 — Apply and restart networking

```bash
uci commit network
/etc/init.d/network restart
```

### 5.8 — Verify the interfaces came up

```bash
ip addr show | grep -E 'eth1\.|192\.168\.(10|11|20|30|40)'
```

Expected — you should see:
```text
eth1.10@eth1  ...
eth1.20@eth1  ...
eth1.30@eth1  ...
```

And the router IPs:
```text
192.168.11.1  (eth1.10 — VLAN 10 Home)
192.168.20.1  (eth1.20 — VLAN 20 Servers)
192.168.30.1  (eth1.30 — VLAN 30 Gaming)
192.168.40.1  (br-vlan40 — VLAN 40 Guest)
```

> ⚠️ **Subnet conflict to watch for:** Vodafone's modem uses `192.168.10.x`. Do NOT assign VLAN 10 the IP `192.168.10.1` — it will silently break Vodafone routing. Use `192.168.11.1` as shown above.

If an interface is missing, check:
```bash
logread | grep netifd | tail -30
swconfig dev switch1 show | grep -A2 'vlan:'
```

The `swconfig dev switch1 show` output should list VLAN 10, 20, 30 alongside the existing VLANs 1 and 2.

**Command output — actual result:**

```text
    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan
66: eth1.1@eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master br-lan state UP group default qlen 1000
    inet 192.168.40.1/24 brd 192.168.40.255 scope global br-vlan40
68: eth1.2@eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    inet 192.168.10.2/24 brd 192.168.10.255 scope global eth1.2
69: eth1.10@eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    inet 192.168.11.1/24 brd 192.168.11.255 scope global eth1.10
70: eth1.20@eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    inet 192.168.20.1/24 brd 192.168.20.255 scope global eth1.20
71: eth1.30@eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    inet 192.168.30.1/24 brd 192.168.30.255 scope global eth1.30
```

```text
default via 10.0.24.25 dev pppoe-wan proto static metric 1
default via 192.168.10.1 dev eth1.2 proto static src 192.168.10.2 metric 2
```

**Output analysis:**

| Interface | IP | Status |
|-----------|-----|--------|
| `br-lan` (`eth1.1`) | `192.168.1.1` | Old VLAN 1 bridge — still exists, harmless, cleaned up later |
| `eth1.2` (`secondwan`) | `192.168.10.2` | ✅ Vodafone WAN2 — unaffected |
| `eth1.10` (VLAN 10) | `192.168.11.1` | ✅ Home VLAN — subnet conflict resolved |
| `eth1.20` (VLAN 20) | `192.168.20.1` | ✅ Servers |
| `eth1.30` (VLAN 30) | `192.168.30.1` | ✅ Gaming PC |
| `br-vlan40` (VLAN 40) | `192.168.40.1` | ✅ Guest |
| Default route metric 1 | `10.0.24.25` via `pppoe-wan` | ✅ Digi preferred |
| Default route metric 2 | `192.168.10.1` via `eth1.2` | ✅ Vodafone standby |

---

## Step 6 — Configure DHCP Servers for Each VLAN

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** Each VLAN is its own subnet. Without a DHCP server on each, every device would need a manually configured static IP — impractical for phones, tablets, and IoT devices. DHCP also lets you control address ranges and lease times per segment (shorter for guests, longer for servers).

### 6.1 — VLAN 10 DHCP (Home)

Assigns IPs in the range `192.168.11.100 – 192.168.11.249`. The lower range (`192.168.11.2 – .99`) is reserved for static assignments (Smart TV, etc.).

```bash
uci set dhcp.vlan10=dhcp
uci set dhcp.vlan10.interface='vlan10'
uci set dhcp.vlan10.start='100'
uci set dhcp.vlan10.limit='150'
uci set dhcp.vlan10.leasetime='12h'
```

### 6.2 — VLAN 20 DHCP (Servers)

Small dynamic pool. Servers should use static IPs or static DHCP leases so their addresses never change (Plex configuration, Cloudflare tunnel configs, and Kubernetes node IPs depend on stability).

```bash
uci set dhcp.vlan20=dhcp
uci set dhcp.vlan20.interface='vlan20'
uci set dhcp.vlan20.start='50'
uci set dhcp.vlan20.limit='20'
uci set dhcp.vlan20.leasetime='24h'
```

### 6.3 — VLAN 30 DHCP (Gaming)

```bash
uci set dhcp.vlan30=dhcp
uci set dhcp.vlan30.interface='vlan30'
uci set dhcp.vlan30.start='100'
uci set dhcp.vlan30.limit='50'
uci set dhcp.vlan30.leasetime='12h'
```

### 6.4 — VLAN 40 DHCP (Guest)

Short lease time ensures addresses are recycled quickly for temporary users.

```bash
uci set dhcp.vlan40=dhcp
uci set dhcp.vlan40.interface='vlan40'
uci set dhcp.vlan40.start='100'
uci set dhcp.vlan40.limit='100'
uci set dhcp.vlan40.leasetime='4h'
```

### 6.5 — Reserve a static IP for the Smart TV

Find the Smart TV's MAC address (from its network settings or the current DHCP leases in LuCI → Network → DHCP and DNS → Active Leases). Then:

```bash
uci add dhcp host
uci set dhcp.@host[-1].name='SmartTV'
uci set dhcp.@host[-1].mac='AA:BB:CC:DD:EE:FF'   # replace with real MAC
uci set dhcp.@host[-1].ip='192.168.11.50'
uci set dhcp.@host[-1].interface='vlan10'
```

**Why:** The Smart TV needs a fixed IP so that policy routing and firewall rules can reference it by IP reliably. If the IP changes, the rules break silently.

### 6.6 — Apply DHCP changes

```bash
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### 6.7 — Verify DHCP is listening on all interfaces

```bash
netstat -ulnp | grep dnsmasq
```

You should see dnsmasq listening on ports 53 and 67 for each VLAN IP (`192.168.11.1`, `192.168.20.1`, etc.).

---

## Step 7 — Configure Firewall Zones

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** OpenWrt's firewall operates on zones. Every interface must belong to a zone, and traffic between zones is controlled by forwarding rules. Without zones, no VLAN-to-VLAN or VLAN-to-WAN policies can be applied. The default `lan` and `wan` zones are not enough once you have multiple VLANs and two WANs.

### 7.1 — Extract `secondwan` from the existing `wan` zone and create a dedicated `wan2` zone

**Why this is needed:** From the firewall output in Step 2.5, `secondwan` (Vodafone) is currently inside the `wan` zone alongside Digi. This means both ISPs share the same masquerade policy and you cannot apply different forwarding rules per ISP. Splitting Vodafone into its own zone (`wan2`) gives independent control.

**Step A — Remove `secondwan` from the `wan` zone first:**

```bash
uci del_list firewall.@zone[1].network='secondwan'
uci commit firewall
/etc/init.d/firewall restart
```

Verify it was removed:
```bash
uci show firewall | grep "zone\[1\]"
```

The `secondwan` entry should no longer appear under `zone[1]`.

**Step B — Create the dedicated `wan2` zone for Vodafone:**

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='wan2'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add_list firewall.@zone[-1].network='secondwan'
```

**Why `masq='1'`?** Vodafone places you behind their NAT (CGNAT). Masquerading (NAT) rewrites outgoing source IPs to the router's Vodafone IP, which is the only IP Vodafone routes for you. Without masquerade, packets from 192.168.20.x would be dropped at Vodafone's network boundary.

**Why `mtu_fix='1'`?** Vodafone may have a different MTU than Digi (common with PPPoE/CGNAT setups). MTU fix (TCP MSS clamping) prevents large packets from being silently dropped, which causes slow or broken connections.

### 7.2 — Create zone for VLAN 10 (Home)

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='vlan10'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci add_list firewall.@zone[-1].network='vlan10'
```

### 7.3 — Create zone for VLAN 20 (Servers)

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='vlan20'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci add_list firewall.@zone[-1].network='vlan20'
```

### 7.4 — Create zone for VLAN 30 (Gaming)

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='vlan30'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci add_list firewall.@zone[-1].network='vlan30'
```

### 7.5 — Create zone for VLAN 40 (Guest)

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='vlan40'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci add_list firewall.@zone[-1].network='vlan40'
```

**Why `input='REJECT'` for guests?** This blocks guest devices from reaching the router itself (admin interface, SSH). Guests should only be able to get to the internet, not to the router's management plane.

### 7.6 — Create zone-to-WAN forwarding rules

Each VLAN needs an explicit forwarding rule to exit to the internet. By default, forward is REJECT between zones.

```bash
# VLAN 10 → WAN1 (Digi)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='vlan10'
uci set firewall.@forwarding[-1].dest='wan'

# VLAN 20 → WAN2 (Vodafone) — server zone
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='vlan20'
uci set firewall.@forwarding[-1].dest='wan2'

# VLAN 30 → WAN1 (Digi) — gaming
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='vlan30'
uci set firewall.@forwarding[-1].dest='wan'

# VLAN 40 → WAN2 (Vodafone) — guests
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='vlan40'
uci set firewall.@forwarding[-1].dest='wan2'
```

### 7.7 — Apply firewall changes

```bash
uci commit firewall
/etc/init.d/firewall restart
```

### 7.8 — Verify zones and forwarding rules

```bash
uci show firewall | grep -E 'zone\[|forwarding'
```

**Command output — actual result:**

```text
firewall.@zone[0]=zone
firewall.@zone[0].name='lan'
firewall.@zone[0].network='lan'
firewall.@zone[0].input='ACCEPT'
firewall.@zone[0].output='ACCEPT'
firewall.@zone[0].forward='ACCEPT'
firewall.@zone[1]=zone
firewall.@zone[1].name='wan'
firewall.@zone[1].network='wan' 'wan6' 'wwan'
firewall.@zone[1].input='DROP'
firewall.@zone[1].output='ACCEPT'
firewall.@zone[1].forward='REJECT'
firewall.@zone[1].masq='1'
firewall.@zone[1].mtu_fix='1'
firewall.@forwarding[0]=forwarding
firewall.@forwarding[0].src='lan'
firewall.@forwarding[0].dest='wan'
firewall.@forwarding[0].enabled='1'
firewall.@zone[2]=zone
firewall.@zone[2].name='guest'
firewall.@zone[2].network='guest'
firewall.@zone[2].forward='REJECT'
firewall.@zone[2].output='ACCEPT'
firewall.@zone[2].input='REJECT'
firewall.@forwarding[1]=forwarding
firewall.@forwarding[1].src='guest'
firewall.@forwarding[1].dest='wan'
firewall.@forwarding[1].enabled='1'
firewall.@zone[3]=zone
firewall.@zone[3].name='wan2'
firewall.@zone[3].input='DROP'
firewall.@zone[3].forward='REJECT'
firewall.@zone[3].output='ACCEPT'
firewall.@zone[3].masq='1'
firewall.@zone[3].mtu_fix='1'
firewall.@zone[3].network='secondwan'
firewall.@zone[4]=zone
firewall.@zone[4].name='vlan10'
firewall.@zone[4].input='ACCEPT'
firewall.@zone[4].forward='REJECT'
firewall.@zone[4].output='ACCEPT'
firewall.@zone[4].network='vlan10'
firewall.@zone[5]=zone
firewall.@zone[5].name='vlan20'
firewall.@zone[5].input='ACCEPT'
firewall.@zone[5].forward='REJECT'
firewall.@zone[5].output='ACCEPT'
firewall.@zone[5].network='vlan20'
firewall.@zone[6]=zone
firewall.@zone[6].name='vlan30'
firewall.@zone[6].input='ACCEPT'
firewall.@zone[6].forward='REJECT'
firewall.@zone[6].output='ACCEPT'
firewall.@zone[6].network='vlan30'
firewall.@zone[7]=zone
firewall.@zone[7].name='vlan40'
firewall.@zone[7].input='DROP'
firewall.@zone[7].forward='REJECT'
firewall.@zone[7].output='ACCEPT'
firewall.@zone[7].network='vlan40'
firewall.@forwarding[2]=forwarding
firewall.@forwarding[2].src='vlan10'
firewall.@forwarding[2].dest='wan'
firewall.@forwarding[3]=forwarding
firewall.@forwarding[3].src='vlan20'
firewall.@forwarding[3].dest='wan2'
firewall.@forwarding[4]=forwarding
firewall.@forwarding[4].src='vlan30'
firewall.@forwarding[4].dest='wan'
firewall.@forwarding[5]=forwarding
firewall.@forwarding[5].src='vlan40'
firewall.@forwarding[5].dest='wan2'
```

**Output analysis:**

| Zone | Networks | Policy | Status |
|------|----------|--------|--------|
| `lan` | `lan` | All ACCEPT | ✅ GL.iNet default — harmless |
| `wan` | `wan` `wan6` `wwan` | DROP in, masq | ✅ Digi — `secondwan` removed |
| `guest` | `guest` | REJECT in | ✅ GL.iNet pre-existing guest — unrelated to `vlan40`, harmless |
| `wan2` | `secondwan` | DROP in, masq, mtu_fix | ✅ Vodafone zone |
| `vlan10` | `vlan10` | ACCEPT in | ✅ Home |
| `vlan20` | `vlan20` | ACCEPT in | ✅ Servers |
| `vlan30` | `vlan30` | ACCEPT in | ✅ Gaming |
| `vlan40` | `vlan40` | DROP in | ✅ Guest |

| Forwarding | Direction | Status |
|-----------|-----------|--------|
| `lan` → `wan` | GL.iNet default | ✅ Pre-existing, harmless |
| `guest` → `wan` | GL.iNet default | ✅ Pre-existing, harmless |
| `vlan10` → `wan` | Home → Digi | ✅ |
| `vlan20` → `wan2` | Servers → Vodafone | ✅ |
| `vlan30` → `wan` | Gaming → Digi | ✅ |
| `vlan40` → `wan2` | Guest → Vodafone | ✅ |

> **ℹ️ Internet access at this point:**
> - VLAN 10 (Home) and VLAN 30 (Gaming PC) → internet via Digi works **immediately** — firewall + default route both point to Digi.
> - VLAN 20 (Servers) and VLAN 40 (Guest) → **no internet yet** — firewall allows only `wan2`, but the kernel still routes them via the Digi default route. PBR (Step 8) fixes this by adding a routing rule that sends these subnets via Vodafone.

---

## Step 8 — Configure Policy-Based Routing (PBR)

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** Zone forwarding rules (Step 7) tell the firewall which traffic is *allowed* to exit via which WAN. But routing — where packets actually go — is separate. Without PBR, the kernel's default route always wins (Digi). PBR adds rules that say "if the source IP is in VLAN 20 or VLAN 40, look up a routing table that points to Vodafone."

### 8.1 — Configure PBR via UCI

The `pbr` daemon reads its rules from `/etc/config/pbr` and manages the routing tables automatically, including handling WAN2 reconnects.

> ⚠️ **GL.iNet QSDK note:** This build of pbr 1.1.1-7 uses `policy` sections, **not** `rule` sections. Using `uci add pbr rule` stores entries that are silently ignored — the `pbr_prerouting` nftables chain will remain empty. Always use `uci add pbr policy`.

```bash
uci set pbr.config=pbr
uci set pbr.config.enabled='1'
uci set pbr.config.verbosity='2'           # logging level (0=off, 2=info)
uci set pbr.config.ipv6_enabled='0'        # disable if you don't need IPv6 PBR
uci commit pbr
```

### 8.2 — Add PBR policy: VLAN 20 (Servers) → Vodafone

```bash
uci add pbr policy
uci set pbr.@policy[-1].name='Servers-via-Vodafone'
uci set pbr.@policy[-1].src_addr='192.168.20.0/24'
uci set pbr.@policy[-1].interface='secondwan'
uci set pbr.@policy[-1].enabled='1'
```

**Why:** All traffic originating from the server subnet (`192.168.20.0/24`) must exit via Vodafone. This covers Plex streams, Kubernetes outbound traffic, and Cloudflare tunnel keepalives.

### 8.3 — Add PBR policy: VLAN 40 (Guest) → Vodafone

```bash
uci add pbr policy
uci set pbr.@policy[-1].name='Guest-via-Vodafone'
uci set pbr.@policy[-1].src_addr='192.168.40.0/24'
uci set pbr.@policy[-1].interface='secondwan'
uci set pbr.@policy[-1].enabled='1'
```

### 8.4 — Add PBR policy: Smart TV → Vodafone (by static IP)

```bash
uci add pbr policy
uci set pbr.@policy[-1].name='SmartTV-via-Vodafone'
uci set pbr.@policy[-1].src_addr='192.168.11.50'   # the static IP from Step 6.5
uci set pbr.@policy[-1].interface='secondwan'
uci set pbr.@policy[-1].enabled='1'
```

**Why:** The Smart TV lives in VLAN 10 (whose default route is Digi), but you want its internet traffic on Vodafone. A source-IP-based PBR policy overrides the default, catching the Smart TV's traffic before it reaches the normal routing table.

### 8.5 — Apply and start PBR

```bash
uci commit pbr
/etc/init.d/pbr restart
```

> **Expected warnings during restart** — these are harmless GL.iNet pre-configuration artifacts:
> - `WARNING: Variable 'tor' does not exist or is not an array/object` — GL.iNet ships PBR with TOR redirect config that requires TOR to be installed. Safe to ignore.
> - `ERROR: Failed to set up 'tor/53->9053/80,443->9040'!` — same cause, same conclusion.

### 8.6 — Verify PBR rules are active

```bash
/etc/init.d/pbr status | grep -A10 'pbr_prerouting'
```

**Command output — actual result:**

```text
        chain pbr_prerouting { # handle 77
                ip saddr @pbr_secondwan_4_src_ip_cfg066ff5 goto pbr_mark_0x030000 comment "Servers-via-Vodafone" # handle 319
                ip saddr @pbr_secondwan_4_src_ip_cfg076ff5 goto pbr_mark_0x030000 comment "Guest-via-Vodafone" # handle 321
                ip saddr @pbr_secondwan_4_src_ip_cfg086ff5 goto pbr_mark_0x030000 comment "SmartTV-via-Vodafone" # handle 323
        }
```

**Output analysis:**

All three policies are active in the nftables `pbr_prerouting` chain. Packets from the matching source IPs are marked `0x030000`, which routes them to table `pbr_secondwan` (table 258: `default via 192.168.10.1 dev eth1.2`). This is Vodafone. ✅

| Policy | Source | Mark | Routing table | WAN |
|--------|--------|------|--------------|-----|
| Servers-via-Vodafone | `192.168.20.0/24` | `0x030000` | `pbr_secondwan` (258) | Vodafone ✅ |
| Guest-via-Vodafone | `192.168.40.0/24` | `0x030000` | `pbr_secondwan` (258) | Vodafone ✅ |
| SmartTV-via-Vodafone | `192.168.11.50` | `0x030000` | `pbr_secondwan` (258) | Vodafone ✅ |

VLANs 10 and 30 are **not** in the prerouting chain — they use the kernel default route (Digi, metric 1) without any marking. This is correct.

### 8.7 — Test routing from the server VLAN

Connect a device to VLAN 20 (or SSH into your home server) and confirm:

```bash
# The exit IP should be your Vodafone IP, not Digi
curl -s https://ifconfig.me
```

Compare this to the Vodafone WAN IP shown in `ifstatus secondwan`. They should match.

---

## Step 9 — Configure Wi-Fi SSIDs per VLAN

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** Each VLAN needs at least one Wi-Fi network (SSID) through which wireless devices connect. The key is setting `network` in the Wi-Fi interface config to the correct VLAN interface. This is what places a wireless device into the right VLAN — the SSID is the entry point, the VLAN interface is the network it lands on.

### 9.1 — List current radio devices

```bash
uci show wireless | grep 'wifi-device'
```

Run this to see the exact radio names configured in UCI (they will be names like `radio0`, `radio1`). Note: the kernel interface names (`wifi0`, `wifi1` shown in `ip addr show`) are different from the UCI device names. The `uci show wireless` output is what you use in the commands below.

From the `ip addr show` output in Step 2.1, we know the GL-BE6500 has at least two radios active (`wifi0`, `wifi1`) plus MLO sub-interfaces (`wlan02`, `wlan12` under `mld0`). The GL-BE6500 is a Wi-Fi 7 tri-band router — after running the command above, confirm you see entries for all three bands and note their UCI names.

**Record your radio names:**

- 2.4 GHz radio → ________ (commonly `radio0`)
- 5 GHz radio → ________ (commonly `radio1`)
- 6 GHz radio → ________ (commonly `radio2`)

> ⚠️ The existing SSIDs (`wlan0`, `wlan1`) are currently bridged to `br-lan`. Keep the existing SSIDs running while you create new ones — do not delete or disable `wlan0`/`wlan1` until you have confirmed the new VLAN SSIDs are working and you can still SSH in.

### 9.2 — Create SSID for VLAN 10 (Home)

```bash
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio1'      # 5 GHz — replace with your actual radio name
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Home'
uci set wireless.@wifi-iface[-1].encryption='psk2+ccmp'
uci set wireless.@wifi-iface[-1].key='YourStrongHomePassword'
uci set wireless.@wifi-iface[-1].network='vlan10'
```

### 9.3 — Create SSID for VLAN 20 (Servers — optional, for wireless server access)

If your server has Wi-Fi capability, or you want wireless access to the server VLAN:

```bash
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio1'      # adjust radio name if needed
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Home-Servers'
uci set wireless.@wifi-iface[-1].encryption='psk2+ccmp'
uci set wireless.@wifi-iface[-1].key='YourStrongServerPassword'
uci set wireless.@wifi-iface[-1].network='vlan20'
```

### 9.4 — Create SSID for VLAN 30 (Gaming)

```bash
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio2'      # 6 GHz for lowest latency — adjust if needed
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Gaming'
uci set wireless.@wifi-iface[-1].encryption='psk2+ccmp'
uci set wireless.@wifi-iface[-1].key='YourStrongGamingPassword'
uci set wireless.@wifi-iface[-1].network='vlan30'
```

**Note:** If the gaming PC is connected by Ethernet to `lan3`, no SSID is needed for VLAN 30 — the port assignment from Step 5 already handles it.

### 9.5 — Create SSID for VLAN 40 (Guest)

```bash
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio0'      # 2.4 GHz — wide coverage for guests
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='Guest'
uci set wireless.@wifi-iface[-1].encryption='psk2+ccmp'
uci set wireless.@wifi-iface[-1].key='YourGuestPassword'
uci set wireless.@wifi-iface[-1].network='vlan40'
uci set wireless.@wifi-iface[-1].isolate='1'          # prevents guest-to-guest traffic
```

**Why `isolate='1'`?** This prevents guests from talking directly to each other on the same SSID. Combined with the VLAN isolation, guests are limited to internet-only and cannot reach each other or any other VLAN.

### 9.6 — Apply wireless config

```bash
uci commit wireless
wifi reload
```

### 9.7 — Verify SSIDs are broadcasting

```bash
iwinfo | grep -E 'ESSID|Mode'
```

---

## Step 9.5 — VLAN-3: IoT Devices (Wi-Fi Only, Vodafone Primary)

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** IoT devices (smart plugs, lamps, cameras, Alexa, cat feeders, Kindle) need their own isolated VLAN for two reasons:
1. **Security** — IoT firmware is rarely updated and often has vulnerabilities. Isolating them prevents a compromised device from reaching your servers, PC, or router management.
2. **Routing** — IoT devices generate steady background traffic (telemetry, cloud pings). Routing this through Vodafone reserves Digi's low-latency PPPoE for the Gaming PC.

**All devices in this VLAN are Wi-Fi only.** No switch port is needed — only a 2.4 GHz SSID. Most IoT devices (smart plugs, cameras, Alexa, feeders) do not support 5 GHz.

**Subnet:** `192.168.50.0/24` — Router IP `192.168.50.1`
**Primary WAN:** Vodafone (`secondwan`) — via PBR policy, same pattern as VLAN 20 and VLAN 40.
**Fallback WAN:** Digi — automatic when Vodafone is unreachable.

---

### 9.5.1 — Create the IoT network interface (Wi-Fi bridge only)

```bash
uci set network.iot=interface
uci set network.iot.proto='static'
uci set network.iot.type='bridge'
uci set network.iot.bridge_empty='1'     # bridge exists before the Wi-Fi SSID attaches to it
uci set network.iot.ipaddr='192.168.50.1'
uci set network.iot.netmask='255.255.255.0'
uci commit network
/etc/init.d/network restart
```

**Why `bridge_empty='1'`?** The bridge must exist before the Wi-Fi reload in Step 9.5.4. Without this flag, OpenWrt silently discards a bridge with no members.

Verify the interface came up:

```bash
ip addr show br-iot
```

Expected output:
```text
br-iot: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    inet 192.168.50.1/24 ...
```

---

### 9.5.2 — Configure DHCP for the IoT subnet

```bash
uci set dhcp.iot=dhcp
uci set dhcp.iot.interface='iot'
uci set dhcp.iot.start='100'
uci set dhcp.iot.limit='150'
uci set dhcp.iot.leasetime='12h'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Devices will receive IPs in the range `192.168.50.100 – 192.168.50.249`.

---

### 9.5.3 — Configure the firewall zone for IoT

```bash
# Create the IoT firewall zone
uci add firewall zone
uci set firewall.@zone[-1].name='iot'
uci set firewall.@zone[-1].input='REJECT'      # devices cannot reach the router (SSH, LuCI)
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'    # no cross-VLAN traffic by default
uci add_list firewall.@zone[-1].network='iot'

# Allow IoT zone to reach WAN (internet only)
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='iot'
uci set firewall.@forwarding[-1].dest='wan'

uci commit firewall
/etc/init.d/firewall restart
```

**Why `input='REJECT'`?** IoT devices have no business accessing the router's admin interface. If a device is compromised, it cannot be used to change your firewall rules or SSH config.

**Why `forward='REJECT'`?** IoT devices must not be able to reach your server VLAN (Plex, Kubernetes) or your Gaming PC, even if a device is hacked.

---

### 9.5.4 — Create the IoT Wi-Fi SSID (2.4 GHz only)

```bash
uci set wireless.iot_ssid=wifi-iface
uci set wireless.iot_ssid.device='wifi0'          # 2.4 GHz radio — maximum device compatibility
uci set wireless.iot_ssid.mode='ap'
uci set wireless.iot_ssid.network='iot'           # attaches to the bridge created in 9.5.1
uci set wireless.iot_ssid.ssid='Tchocoloco-IoT'
uci set wireless.iot_ssid.encryption='psk2+ccmp'
uci set wireless.iot_ssid.key='YourIoTPassword'   # change this
uci set wireless.iot_ssid.isolate='1'             # IoT devices cannot talk to each other
uci commit wireless
wifi reload
```

**Why 2.4 GHz (`wifi0`) only?** Smart plugs, cameras, Alexa, cat feeders, and Kindle all require 2.4 GHz. Adding a 5 GHz SSID is pointless and wastes a radio slot.

**Why `isolate='1'`?** Client isolation prevents a compromised camera from probing other cameras or plugs on the same SSID. Each IoT device can only talk to the router (for internet), not to each other.

Verify the SSID is broadcasting:

```bash
iwinfo | grep -E 'ESSID|Mode'
```

You should see `Tchocoloco-IoT` listed.

---

### 9.5.5 — Add PBR policy: IoT → Vodafone

```bash
uci add pbr policy
uci set pbr.@policy[-1].name='IoT-via-Vodafone'
uci set pbr.@policy[-1].src_addr='192.168.50.0/24'
uci set pbr.@policy[-1].interface='secondwan'
uci set pbr.@policy[-1].enabled='1'
uci commit pbr
/etc/init.d/pbr restart
```

Verify the policy is active:

```bash
/etc/init.d/pbr status | grep -A15 'pbr_prerouting'
```

Expected — you should see a new line alongside the existing policies:
```text
ip saddr @pbr_secondwan_4_src_ip_... goto pbr_mark_0x030000 comment "IoT-via-Vodafone"
```

---

### 9.5.6 — End-to-end test

1. Connect any IoT device (or your phone temporarily) to `Tchocoloco-IoT`.
2. It should receive an IP in the `192.168.50.x` range.
3. Confirm it exits via Vodafone:
   ```bash
   # From the IoT device's browser or a phone connected to Tchocoloco-IoT:
   curl https://ifconfig.me
   # The returned IP must match your Vodafone WAN IP, not Digi
   ```
4. Confirm it cannot reach your main LAN:
   ```bash
   ping 192.168.8.1      # router — should be REJECTED (no reply)
   ping 192.168.20.1     # server VLAN — should be REJECTED
   ```

**IoT Devices to connect to `Tchocoloco-IoT`:**

| Device | Notes |
|--------|-------|
| Smart Electric Plugs | Connect in app — use new SSID |
| Smart Lamps | Connect in app — use new SSID |
| Amazon Kindle | Wi-Fi settings → switch to `Tchocoloco-IoT` |
| Cat's Feeder | Connect in app — use new SSID |
| Cat's Bathroom | Connect in app — use new SSID |
| Cameras | Connect in app — use new SSID |
| Amazon Alexa | Alexa app → Device Settings → Wi-Fi → switch |

---

### Troubleshooting — Devices connect to `Tchocoloco-IoT` but never get an IP

**Symptom:** Phone or IoT device associates with the SSID, shows "Obtaining IP address…" indefinitely, then fails.

**Root cause:** The firewall zone was configured with `input='REJECT'`, which correctly blocks admin access from IoT devices but also silently drops DHCP and DNS traffic — two things every device needs just to get an address.

**Diagnosis:**

```bash
# Check if any leases exist on the IoT subnet
cat /tmp/dhcp.leases | grep "192.168.50"

# Confirm SSID is broadcasting and interface is UP
iwinfo | grep -A3 "Tchocoloco-IoT"
ip addr show br-iot

# Check the firewall zone input policy
uci get firewall.@zone[X].input   # where X is the IoT zone index
```

**Fix — add two narrow exceptions to allow DHCP and DNS into the router:**

```bash
# Allow DHCP (UDP 67-68) from IoT clients so they can get an IP
uci add firewall rule
uci set firewall.@rule[-1].name="IoT-DHCP"
uci set firewall.@rule[-1].src="iot"
uci set firewall.@rule[-1].dest_port="67-68"
uci set firewall.@rule[-1].proto="udp"
uci set firewall.@rule[-1].target="ACCEPT"

# Allow DNS (TCP/UDP 53) from IoT clients so they can resolve hostnames
uci add firewall rule
uci set firewall.@rule[-1].name="IoT-DNS"
uci set firewall.@rule[-1].src="iot"
uci set firewall.@rule[-1].dest_port="53"
uci set firewall.@rule[-1].proto="tcp udp"
uci set firewall.@rule[-1].target="ACCEPT"

uci commit firewall
/etc/init.d/firewall restart
```

**Why `input='REJECT'` still makes sense:** These two rules are surgical — they allow only DHCP and DNS to the router itself. SSH (port 22), the web UI (port 80/443), and all other admin ports remain `REJECT`ed. A compromised IoT device still cannot reconfigure the router.

**Verify fix:**

```bash
# After a device connects, a lease should appear here
cat /tmp/dhcp.leases | grep "192.168.50"
```

Expected output format:
```
1744999999 aa:bb:cc:dd:ee:ff 192.168.50.100 android-phone *
```

---

## Step 10 — Smart TV Special Rules: Plex Access and Forced Vodafone Routing

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** The Smart TV has two special requirements that go against the defaults of its zone (VLAN 10):

1. It must reach the Plex Server on VLAN 20 (cross-VLAN communication, normally blocked).
2. Its internet traffic must exit via Vodafone (PBR rule already added in Step 8.4).

This step handles the cross-VLAN firewall rule for Plex. The PBR routing is already configured.

### 10.1 — Identify the Plex Server's IP

Your Plex Server is in VLAN 20. Assign it a static DHCP lease (similar to Step 6.5):

```bash
uci add dhcp host
uci set dhcp.@host[-1].name='PlexServer'
uci set dhcp.@host[-1].mac='XX:XX:XX:XX:XX:XX'   # replace with real MAC
uci set dhcp.@host[-1].ip='192.168.20.10'
uci set dhcp.@host[-1].interface='vlan20'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

### 10.2 — Allow Smart TV → Plex firewall rule

This rule opens VLAN 10 → VLAN 20 forwarding **only** for the Smart TV's IP to the Plex port (32400 TCP by default, plus UDP for media streaming):

```bash
# Allow Smart TV to reach Plex on TCP 32400
uci add firewall rule
uci set firewall.@rule[-1].name='SmartTV-to-Plex-TCP'
uci set firewall.@rule[-1].src='vlan10'
uci set firewall.@rule[-1].src_ip='192.168.11.50'     # Smart TV static IP
uci set firewall.@rule[-1].dest='vlan20'
uci set firewall.@rule[-1].dest_ip='192.168.20.10'    # Plex Server static IP
uci set firewall.@rule[-1].dest_port='32400'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'

# Allow return traffic (for stateful connections this is handled by conntrack, but
# adding explicit forwarding for vlan20 → vlan10 for the Plex connection response)
uci add firewall rule
uci set firewall.@rule[-1].name='Plex-to-SmartTV-reply'
uci set firewall.@rule[-1].src='vlan20'
uci set firewall.@rule[-1].src_ip='192.168.20.10'
uci set firewall.@rule[-1].dest='vlan10'
uci set firewall.@rule[-1].dest_ip='192.168.11.50'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].target='ACCEPT'
```

**Why so specific?** Allowing full VLAN 10 → VLAN 20 forwarding would let every IoT device, smart lamp, and camera reach your server network. Scoping the rule to the Smart TV's IP and the Plex port limits the blast radius if any other device in VLAN 10 is compromised.

### 10.3 — Add a forwarding rule between the two zones

OpenWrt requires both a firewall rule *and* a zone forwarding entry for the traffic to flow:

```bash
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='vlan10'
uci set firewall.@forwarding[-1].dest='vlan20'
```

**Note:** The zone-level forwarding is set to pass, but the specific firewall rule from Step 10.2 scopes which traffic is actually allowed. Packets that don't match the rule will still be rejected by the zone's default forward policy.

### 10.4 — Apply firewall changes

```bash
uci commit firewall
/etc/init.d/firewall restart
```

### 10.5 — Test from the Smart TV

Open Plex on your Smart TV. It should discover and connect to the Plex Server. If it does not:

```bash
# Check if the Smart TV's traffic is being allowed
logread | grep -i 'smarts\|plex\|32400'
```

You can also enable firewall logging temporarily:

```bash
uci set firewall.@defaults[0].log_invalid='1'
uci commit firewall
/etc/init.d/firewall restart
logread -f | grep -i 'DROP\|REJECT'
```

Remember to disable logging after debugging — it generates high log volume.

---

## Step 11 — Verify Cloudflare Tunnels on VLAN 20

> **BACKUP CHECKPOINT** — Run Step 1 before continuing.

**Why:** The Cloudflare tunnels (`cloudflared`) run as daemons on your home server in VLAN 20. They make outbound HTTPS connections to Cloudflare's edge — no inbound port forwarding is needed on the router. However, since VLAN 20 now routes via Vodafone (WAN2), you must confirm the tunnels are reaching Cloudflare through that path.

### 11.1 — Confirm outbound connectivity from VLAN 20

SSH into your home server (or a device in VLAN 20) and verify:

```bash
# Source IP should be Vodafone's IP
curl -s https://ifconfig.me

# DNS resolution should work
nslookup cloudflare.com

# Cloudflare tunnel endpoint reachable
curl -v https://region1.v2.argotunnel.com 2>&1 | grep -E 'Connected|SSL|TLS'
```

### 11.2 — Check tunnel status on the server

On the server running `cloudflared`:

```bash
# Check the tunnel daemon status
systemctl status cloudflared

# View tunnel logs for connection errors
journalctl -u cloudflared -n 50

# Or if running in Docker/Kubernetes:
kubectl logs -n <namespace> <cloudflared-pod-name> --tail=50
```

### 11.3 — Verify the Node.js capture service port via Cloudflare

Your Node.js service uses a specific port via Cloudflare tunnel. Check that `cloudflared` is configured to forward traffic to the correct local port:

```bash
cat ~/.cloudflared/config.yml
# or
cat /etc/cloudflared/config.yml
```

The `service` URL in the tunnel config should point to `http://localhost:<port>`. The actual port does not need to be open in the router firewall because the connection is outbound from the server.

### 11.4 — Test the public URLs

From any device on the internet (use your phone on cellular, not on your own network):

- Visit the React app's public Cloudflare URL.
- Test the Node.js endpoint via its public URL.

Both should respond through Cloudflare's network, routed outbound via Vodafone.

---

## Step 12 — End-to-End Connectivity Tests

Before declaring the setup complete, run through each scenario methodically.

### 12.1 — VLAN isolation test

From a device on VLAN 10, try to reach a device on VLAN 20:

```bash
ping 192.168.20.10
```

Expected: **timeout** (blocked by firewall, except for the Smart TV's specific Plex rule).

### 12.2 — ISP routing test per VLAN

| Test | Expected exit IP |
|------|-----------------|
| Device on VLAN 10 → `https://ifconfig.me` | Digi IP |
| Device on VLAN 20 → `https://ifconfig.me` | Vodafone IP |
| Device on VLAN 30 → `https://ifconfig.me` | Digi IP |
| Device on VLAN 40 → `https://ifconfig.me` | Vodafone IP |
| Smart TV → `https://ifconfig.me` | Vodafone IP |

### 12.3 — Smart TV → Plex test

Open Plex on the Smart TV. It should connect to Plex on `192.168.20.10:32400`.

### 12.4 — Guest isolation test

From a guest device on VLAN 40:

- `ping 192.168.11.1` → **timeout** (cannot reach home devices)
- `ping 192.168.1.1` → **timeout** (cannot reach router admin)
- `ping 8.8.8.8` → **responds** (internet works via Vodafone)

### 12.5 — Gaming PC test (VLAN 30)

Verify low-latency routing via Digi:

```bash
traceroute 8.8.8.8
```

The first hop should be `192.168.30.1` (router), then Digi's gateway.

---

## Step 13 — Final System Backup and Documentation

> This is the most important backup — it captures your entire working configuration.

### 13.1 — Create final backup

```bash
ssh root@192.168.1.1

BACKUP_FILE="/tmp/backup-final-$(date +%Y%m%d-%H%M%S).tar.gz"
sysupgrade --create-backup "$BACKUP_FILE"
echo "Final backup: $BACKUP_FILE"
```

### 13.2 — Copy to PC and store safely

```bash
scp root@192.168.1.1:/tmp/backup-final-*.tar.gz ~/router-backups/
```

Store a copy in a second location (external drive, cloud storage). This backup is the key to recovering your full configuration without repeating all the steps above.

### 13.3 — Export individual config files for readability

```bash
scp root@192.168.1.1:/etc/config/network ~/router-backups/config-network.txt
scp root@192.168.1.1:/etc/config/firewall ~/router-backups/config-firewall.txt
scp root@192.168.1.1:/etc/config/wireless ~/router-backups/config-wireless.txt
scp root@192.168.1.1:/etc/config/dhcp ~/router-backups/config-dhcp.txt
scp root@192.168.1.1:/etc/config/pbr ~/router-backups/config-pbr.txt
```

### 13.4 — Document static IP assignments

Keep a local record of all static DHCP reservations:

| Device | MAC Address | IP | VLAN |
|--------|-------------|-----|------|
| Smart TV | AA:BB:CC:DD:EE:FF | 192.168.11.50 | VLAN 10 |
| Plex Server | XX:XX:XX:XX:XX:XX | 192.168.20.10 | VLAN 20 |
| Gaming PC | YY:YY:YY:YY:YY:YY | 192.168.30.x | VLAN 30 |

---

## Quick Reference

### IP Address Map

| Network | Gateway | DHCP Range | Router |
|---------|---------|------------|--------|
| VLAN 10 Home | 192.168.11.1 | .100–.249 | Digi |
| VLAN 20 Servers | 192.168.20.1 | .50–.69 | Vodafone |
| VLAN 30 Gaming | 192.168.30.1 | .100–.149 | Digi |
| VLAN 40 Guest | 192.168.40.1 | .100–.199 | Vodafone |

### Key Commands

```bash
# Restart all services after config changes
/etc/init.d/network restart && /etc/init.d/firewall restart && /etc/init.d/dnsmasq restart

# View PBR routing rules
ip rule show

# View routing tables
ip route show table 200     # Vodafone routing table
ip route show table main    # Default routing table

# Check which WAN a source IP uses
ip route get 8.8.8.8 from 192.168.20.1

# View DHCP leases
cat /tmp/dhcp.leases

# Reload Wi-Fi without full restart
wifi reload

# Create a quick backup (save to PC afterwards)
sysupgrade --create-backup /tmp/backup-quick.tar.gz
```

### Restore from Backup

```bash
# On the router:
sysupgrade -r /tmp/backup-YYYYMMDD.tar.gz
reboot
```

### Commands and References

Adding your SSH public key to the router for passwordless access:

```bash
cat ~/.ssh/id_ed25519.pub | ssh root@192.168.8.1 'mkdir -p /etc/dropbear && cat >> /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys'
```

---

## Automatic Router Backup (macOS)

**Why:** Manual backups are easy to forget. This setup runs a backup every night at 3 AM using macOS `launchd`. Each backup is a full `sysupgrade` archive — enough to restore the entire OpenWrt config after a factory reset or firmware flash. Backups older than 30 days are deleted automatically to avoid filling up disk space.

**Files created:**

| File | Purpose |
|------|---------|
| `~/Logs/router-backup/backup-router.sh` | The backup script |
| `~/Logs/router-backup/com.home.router-backup.plist` | The launchd schedule |
| `~/Logs/router-backup/backup.log` | Combined log (created on first run) |
| `~/Logs/router-backup/backup-YYYYMMDD-HHMMSS.tar.gz` | Each nightly backup |

### Step 1 — Make the script executable

```bash
chmod +x ~/Logs/router-backup/backup-router.sh
```

### Step 2 — Test it manually first

```bash
~/Logs/router-backup/backup-router.sh
```

Expected output in `backup.log`:
```
[2026-04-14 03:00:00] =========================================
[2026-04-14 03:00:00] Starting router backup — 20260414-030000
[2026-04-14 03:00:00] Creating sysupgrade backup on router...
[2026-04-14 03:00:05] Downloading backup to .../backup-20260414-030000.tar.gz ...
[2026-04-14 03:00:07] Cleaning up temp file on router...
[2026-04-14 03:00:07] Backup verified OK — size: 48K
[2026-04-14 03:00:07] Rotating backups older than 30 days...
[2026-04-14 03:00:07] Backup complete. Total backups on disk: 1
[2026-04-14 03:00:07] =========================================
```

### Step 3 — Install the launchd agent

```bash
cp ~/Logs/router-backup/com.home.router-backup.plist \
   ~/Library/LaunchAgents/com.home.router-backup.plist

launchctl load ~/Library/LaunchAgents/com.home.router-backup.plist
```

### Step 4 — Verify it is loaded

```bash
launchctl list | grep router-backup
```

You should see a line like:
```
-  0  com.home.router-backup
```

The `-` in the first column means it ran 0 times (not yet triggered). After the first scheduled run it becomes the PID of the last execution.

### How to restore from a backup

```bash
# 1. Copy the backup to the router
scp ~/Logs/router-backup/backup-YYYYMMDD-HHMMSS.tar.gz root@192.168.8.1:/tmp/

# 2. SSH in and restore
ssh root@192.168.8.1
sysupgrade -r /tmp/backup-YYYYMMDD-HHMMSS.tar.gz
reboot
```

### How to uninstall the automatic backup

```bash
launchctl unload ~/Library/LaunchAgents/com.home.router-backup.plist
rm ~/Library/LaunchAgents/com.home.router-backup.plist
```
```