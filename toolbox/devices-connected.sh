#!/bin/bash

SSH="ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=error -T root@192.168.8.1"
STRIP_BANNER="grep -v -E '^\s*(M|\$|For those|OpenWrt|---|\-\-\-)'"

echo "
#----------------------------------------------------#
# Devices by VLAN                                    #
#----------------------------------------------------#
"
$SSH <<'ROUTER' | grep -vE '^\s*(M+|\$M+|For those|OpenWrt|-{3,}|$)' | sed '/^[[:space:]]*$/d'
awk 'BEGIN { printf "%-18s %-22s %-17s %s\n", "IP", "HOSTNAME", "MAC", "VLAN" }
{
  if ($3 ~ /^192\.168\.8\./)    vlan="Main LAN  (br-lan)"
  else if ($3 ~ /^192\.168\.50\./) vlan="IoT VLAN  (br-iot)"
  else if ($3 ~ /^192\.168\.11\./) vlan="VLAN 10   (home)"
  else if ($3 ~ /^192\.168\.20\./) vlan="VLAN 20   (servers)"
  else if ($3 ~ /^192\.168\.30\./) vlan="VLAN 30   (gaming)"
  else if ($3 ~ /^192\.168\.40\./) vlan="VLAN 40   (guest)"
  else vlan="unknown"
  hostname = ($4 == "*" ? "(unknown)" : $4)
  printf "%-18s %-22s %-17s %s\n", $3, hostname, $2, vlan
}' /tmp/dhcp.leases | sort -t. -k4 -n
ROUTER

echo "
#----------------------------------------------------#
# Wi-Fi Associations per SSID                        #
#----------------------------------------------------#
"
$SSH <<'ROUTER' | grep -vE '^\s*(M+|\$M+|For those|OpenWrt|-{3,}|={3,}|$)' | sed '/^[[:space:]]*$/d'
for entry in "wlan0:Tchocoloco-5d0 (2.4GHz)" "mld0:Tchocoloco-5d0-MLO (5/6GHz)" "ath02:Tchocoloco-IoT (2.4GHz)"; do
  iface="${entry%%:*}"
  label="${entry#*:}"
  # Only keep lines that start with a MAC address (xx:xx:xx:xx:xx:xx)
  clients=$(wlanconfig "$iface" list sta 2>/dev/null | grep -E '^[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}')
  count=$(printf '%s\n' "$clients" | grep -c '^[0-9a-f]' || true)
  echo "  $iface — \"$label\" ($count client(s))"
  echo "$clients" | while read -r line; do
    mac=$(echo "$line" | awk '{print $1}')
    [ -z "$mac" ] && continue
    rssi=$(echo "$line" | awk '{print $5}')
    rxrate=$(echo "$line" | awk '{print $4}')
    name=$(awk -v m="$mac" '$2==m {print ($4=="*"?"(unknown)":$4)}' /tmp/dhcp.leases)
    ip=$(awk   -v m="$mac" '$2==m {print $3}' /tmp/dhcp.leases)
    printf "    %-17s  %-15s  %-18s  RSSI:%-5s  RX:%s\n" \
      "$mac" "${ip:-no-IP}" "${name:-(unknown)}" "$rssi" "$rxrate"
  done
  echo ""
done
ROUTER

echo "
#----------------------------------------------------#
# Raw DHCP Leases                                    #
#----------------------------------------------------#
"
$SSH 'cat /tmp/dhcp.leases'