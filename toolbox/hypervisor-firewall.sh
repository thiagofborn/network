#!/bin/bash

SSH="ssh -i ~/.ssh/id_rsa -p 2235 -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=error born@192.168.8.229"

echo "
#----------------------------------------------------#
# hypervisor-01 Firewall Rules — $(date '+%Y-%m-%d %H:%M:%S')
#----------------------------------------------------#
"

$SSH 'sudo ufw status verbose' 2>/dev/null
