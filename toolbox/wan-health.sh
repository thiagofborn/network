#!/bin/bash

SSH="ssh -i ~/.ssh/id_ed25519 -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=error -T root@192.168.8.1"

echo "
#----------------------------------------------------#
# WAN Health Check — $(date '+%Y-%m-%d %H:%M:%S')
#----------------------------------------------------#
"

$SSH <<'ROUTER' | grep -vE '^\ *(M+|\$M+|For those|OpenWrt|-{3,}|={3,}|$)' | sed '/^[[:space:]]*$/d'

check_wan() {
  local label="$1"
  local uci_iface="$2"
  local ping_targets="8.8.8.8 1.1.1.1"
  local ping_count=4

  local status_json
  status_json=$(ifstatus "$uci_iface" 2>/dev/null)
  if [ -z "$status_json" ]; then
    echo "  $label — ERROR: interface '$uci_iface' not found"
    return
  fi

  local up uptime_sec assigned_ip gw proto ptp
  up=$(echo "$status_json"         | grep '"up"'         | head -1 | awk -F': ' '{print $2}' | tr -d ', ')
  uptime_sec=$(echo "$status_json" | grep '"uptime"'     | head -1 | awk -F': ' '{print $2}' | tr -d ',')
  assigned_ip=$(echo "$status_json"| grep '"address"'    | head -1 | awk -F'"' '{print $4}')
  gw=$(echo "$status_json"         | grep '"nexthop"'    | head -1 | awk -F'"' '{print $4}')
  proto=$(echo "$status_json"      | grep '"proto"'      | head -1 | awk -F'"' '{print $4}')
  ptp=$(echo "$status_json"        | grep '"ptpaddress"'           | awk -F'"' '{print $4}')

  local uptime_h=$(( uptime_sec / 3600 ))
  local uptime_m=$(( (uptime_sec % 3600) / 60 ))
  local uptime_s=$(( uptime_sec % 60 ))

  echo "  +-- $label"
  [ "$up" = "true" ] && echo "  |   Status   : UP" || echo "  |   Status   : DOWN *"
  echo "  |   Protocol : $proto"
  echo "  |   Assigned : $assigned_ip"
  [ -n "$ptp" ] && echo "  |   PtP peer : $ptp"
  [ -n "$gw"  ] && echo "  |   Gateway  : $gw"
  printf "  |   Uptime   : %dh %02dm %02ds\n" "$uptime_h" "$uptime_m" "$uptime_s"

  if [ "$up" != "true" ]; then
    echo "  +-> * Interface is down"
    return
  fi

  echo "  |"
  echo "  |   Ping (src $assigned_ip)"
  local all_ok=1
  for target in $ping_targets; do
    local result loss avg
    result=$(ping -I "$assigned_ip" -c "$ping_count" -W 2 "$target" 2>/dev/null)
    loss=$(echo "$result" | grep -oE '[0-9]+% packet loss' | grep -oE '[0-9]+')
    avg=$(echo  "$result" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | cut -d'/' -f2)
    if [ -z "$loss" ]; then
      printf "  |     %-14s  UNREACHABLE\n" "$target"
      all_ok=0
    elif [ "$loss" -eq 100 ]; then
      printf "  |     %-14s  100%% loss\n" "$target"
      all_ok=0
    elif [ "$loss" -gt 0 ]; then
      printf "  |     %-14s  %s%% loss  avg %sms\n" "$target" "$loss" "$avg"
      all_ok=0
    else
      printf "  |     %-14s  OK  avg %sms\n" "$target" "$avg"
    fi
  done

  echo "  |"
  if [ "$proto" = "pppoe" ]; then
    echo "  |   Public IP : $assigned_ip  (PPPoE — this IS your WAN IP)"
  else
    local exit_ip
    exit_ip=$(curl -s --interface "$assigned_ip" --max-time 5 https://ifconfig.me 2>/dev/null)
    [ -n "$exit_ip" ] \
      && echo "  |   Public IP : $exit_ip  (Vodafone modem NAT)" \
      || echo "  |   Public IP : (ifconfig.me unreachable)"
  fi

  [ "$all_ok" -eq 1 ] \
    && echo "  +--> OK Healthy" \
    || echo "  +--> * Degraded"
}

check_wan "Digi WAN1" wan
echo ""
check_wan "Vodafone WAN2" secondwan

echo ""
echo "  +-- Default routes"
ip route show table main | grep default | while read -r line; do
  echo "  |   $line"
done
echo "  +->"

echo ""
echo "  +-- mwan3 interface states"
if command -v mwan3 >/dev/null 2>&1; then
  mwan3 status 2>/dev/null | grep -E 'interface|online|offline|tracking' | while read -r line; do
    echo "  |   $line"
  done
else
  echo "  |   (mwan3 not available)"
fi
echo "  +->"

ROUTER
