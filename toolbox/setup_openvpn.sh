#!/bin/sh
# ============================================================================
# setup_openvpn.sh — OpenVPN server installer/configurator for GL.iNet
#                     GL-BE6500 (native OpenWrt firmware)
#
# Run it either way:
#   (a) directly on the router over SSH, or
#   (b) from your workstation (e.g. your Mac) — it detects it's not on
#       OpenWrt and auto-relays itself to the router over SSH using the
#       connection settings in router.env.
#
#   ./setup_openvpn.sh          # from your Mac — edit router.env first
#   ssh root@<router> '...'     # or run directly on the router, same file
#
# Safe to re-run: existing PKI, UCI sections and firewall rules are detected
# and left in place / updated in place instead of duplicated.
# ============================================================================

# --- remote relay: if this isn't OpenWrt, ship the scripts to the router --
# --- and run them there over SSH instead. ----------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/router.env" ] && . "$SCRIPT_DIR/router.env"
: "${ROUTER_HOST:=192.168.8.1}"
: "${ROUTER_PORT:=22}"
: "${ROUTER_USER:=root}"
: "${ROUTER_SSH_KEY:=}"

if [ "${OPENVPN_SETUP_ON_ROUTER:-}" != "1" ] && [ ! -f /etc/openwrt_release ]; then
    echo "==> Not running on OpenWrt — relaying to ${ROUTER_USER}@${ROUTER_HOST}:${ROUTER_PORT} over SSH..."
    SSH_OPTS="-p ${ROUTER_PORT} -o ConnectTimeout=10"
    SCP_OPTS="-O -P ${ROUTER_PORT} -o ConnectTimeout=10"   # scp's port flag is -P, ssh's is -p; -O = legacy SCP protocol (router has no sftp-server)
    if [ -n "$ROUTER_SSH_KEY" ]; then
        SSH_OPTS="$SSH_OPTS -i ${ROUTER_SSH_KEY}"
        SCP_OPTS="$SCP_OPTS -i ${ROUTER_SSH_KEY}"
    fi
    # shellcheck disable=SC2086
    scp $SCP_OPTS "$SCRIPT_DIR/setup_openvpn.sh" "$SCRIPT_DIR/new-client.sh" \
        "${ROUTER_USER}@${ROUTER_HOST}:/root/" || {
        echo "FATAL: scp to router failed. Check ROUTER_HOST/PORT/USER in router.env and that 'ssh ${SSH_OPTS} ${ROUTER_USER}@${ROUTER_HOST}' works." >&2
        exit 1
    }
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_HOST}" \
        "chmod +x /root/setup_openvpn.sh /root/new-client.sh && OPENVPN_SETUP_ON_ROUTER=1 /root/setup_openvpn.sh"
    rc=$?
    [ $rc -eq 0 ] && echo "==> Remote setup finished OK."
    exit $rc
fi

# --- bootstrap: rest of this script uses bash-only syntax (set -o pipefail) -
if [ -z "$BASH_VERSION" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        echo "==> bash not found, installing..."
        opkg update >/dev/null 2>&1
        opkg install bash || { echo "FATAL: could not install 'bash' via opkg. Check internet/DNS on the router." >&2; exit 1; }
    fi
    exec bash "$0" "$@"
fi

set -euo pipefail

# ============================================================================
# CONFIGURATION — edit these, then run the script
# ============================================================================

# --- Instance / networking --------------------------------------------------
INSTANCE_NAME="myvpn"          # UCI section name; also used in file/log names
VPN_PROTO="udp"                # udp (recommended) or tcp
VPN_PORT="1194"                # WAN-facing port
TUN_DEV="tun_${INSTANCE_NAME}" # virtual interface name, e.g. tun_myvpn
VPN_SUBNET="10.8.0.0"          # dedicated VPN client subnet
VPN_NETMASK="255.255.255.0"

# --- Crypto ------------------------------------------------------------------
CIPHER="AES-256-GCM"
AUTH_DIGEST="SHA256"
TLS_MIN="1.2"                  # server accepts 1.2+, negotiates up to 1.3 when both peers support it
PKI_CURVE="secp384r1"          # EC keys: no slow `dh` generation needed on router CPU
CA_EXPIRE_DAYS="3650"
CERT_EXPIRE_DAYS="825"         # ~2.25 years, matches modern CA/B forum limits

# --- Client routing (pick ONE mode) ------------------------------------------
# 0 = split-tunnel: only LAN + VPN subnet routed through the tunnel
# 1 = full-tunnel:  ALL client internet traffic routed through the router
FULL_TUNNEL="0"

# DNS pushed to clients. Defaults to the router's own LAN IP (dnsmasq).
# Override with e.g. "1.1.1.1" if you don't want the router resolving for clients.
PUSH_DNS=""   # leave empty to auto-detect network.lan.ipaddr

# Allow VPN clients to see/reach each other (0/1)
ALLOW_CLIENT_TO_CLIENT="0"

# --- Public endpoint clients will dial -------------------------------------
# Your WAN IP or (preferred) a DDNS hostname, e.g. from GL.iNet's built-in DDNS.
# Required before generating client profiles with new-client.sh.
SERVER_PUBLIC_ADDR="vpn.skyui.space"

# --- Paths -------------------------------------------------------------------
PKI_DIR="/etc/openvpn/${INSTANCE_NAME}-pki"
ENV_FILE="/etc/openvpn/${INSTANCE_NAME}.env"   # consumed by new-client.sh

# ============================================================================
# Internals — no need to edit below this line
# ============================================================================

log()  { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "FATAL: $*" >&2; exit 1; }

trap 'echo "FATAL: setup failed at line $LINENO. Nothing was left half-committed to UCI (commit happens at the end of each section). Re-run after fixing the issue above." >&2' ERR

[ "$(id -u)" = "0" ] || die "must run as root (this is expected on the router over SSH)."

# ----------------------------------------------------------------------------
# 1. Packages
# ----------------------------------------------------------------------------
log "Checking/installing required packages..."

opkg update || die "'opkg update' failed — check the router's internet/DNS connectivity."

# Only one openvpn SSL backend can be installed at a time (they conflict on
# /usr/sbin/openvpn). Remove any other backend before installing openssl's.
for pkg in openvpn-mbedtls openvpn-wolfssl openvpn-nossl; do
    if opkg list-installed | grep -q "^${pkg} "; then
        log "Removing conflicting package ${pkg}..."
        opkg remove "${pkg}" || die "failed to remove conflicting package ${pkg}."
    fi
done

REQUIRED_PKGS="openvpn-openssl kmod-tun openssl-util"
for pkg in $REQUIRED_PKGS; do
    if opkg list-installed | grep -q "^${pkg} "; then
        log "  ${pkg}: already installed"
    else
        log "  ${pkg}: installing..."
        opkg install "${pkg}" || die "failed to install '${pkg}'. Is there enough free space (df -h /overlay)?"
    fi
done

command -v openvpn >/dev/null 2>&1 || die "openvpn binary not found after install — package layout may differ on this firmware build."
command -v openssl >/dev/null 2>&1 || die "openssl binary not found after installing 'openssl-util'."

# ----------------------------------------------------------------------------
# 2. PKI: CA, server cert, tls-crypt key, CRL — plain openssl, no easy-rsa
#    (GL.iNet's package feed doesn't carry an easy-rsa package). This builds
#    a minimal openssl `ca` database (index.txt/serial/crlnumber) so revoke
#    and CRL regeneration in new-client.sh work the same as they would with
#    easy-rsa.
# ----------------------------------------------------------------------------
if [ -f "${PKI_DIR}/private/server.key" ] && [ -f "${PKI_DIR}/ca.crt" ]; then
    log "PKI already exists at ${PKI_DIR} — skipping generation."
    log "(delete that directory and re-run to regenerate from scratch)"
else
    log "Generating PKI at ${PKI_DIR} (EC ${PKI_CURVE}, no slow DH-param step)..."
    mkdir -p "${PKI_DIR}/private" "${PKI_DIR}/issued" "${PKI_DIR}/newcerts" "${PKI_DIR}/csr"
    : > "${PKI_DIR}/index.txt"
    echo 1000 > "${PKI_DIR}/serial"
    echo 1000 > "${PKI_DIR}/crlnumber"

    cat > "${PKI_DIR}/openssl.cnf" <<CNF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir              = ${PKI_DIR}
certs            = \$dir/issued
new_certs_dir    = \$dir/newcerts
database         = \$dir/index.txt
serial           = \$dir/serial
crlnumber        = \$dir/crlnumber
private_key      = \$dir/private/ca.key
certificate      = \$dir/ca.crt
default_days     = ${CERT_EXPIRE_DAYS}
default_crl_days = 3650
default_md       = sha256
policy           = policy_anything
copy_extensions  = none
unique_subject   = no

[ policy_anything ]
commonName = supplied

[ server_ext ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyAgreement
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ client_ext ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
CNF

    log "Generating CA..."
    openssl ecparam -name "${PKI_CURVE}" -genkey -noout -out "${PKI_DIR}/private/ca.key" \
        || die "CA key generation failed."
    openssl req -new -x509 -key "${PKI_DIR}/private/ca.key" -sha256 \
        -days "${CA_EXPIRE_DAYS}" -subj "/CN=${INSTANCE_NAME}-CA" \
        -out "${PKI_DIR}/ca.crt" || die "CA cert generation failed."

    log "Generating server certificate..."
    openssl ecparam -name "${PKI_CURVE}" -genkey -noout -out "${PKI_DIR}/private/server.key" \
        || die "server key generation failed."
    openssl req -new -key "${PKI_DIR}/private/server.key" -subj "/CN=server" \
        -out "${PKI_DIR}/csr/server.csr" || die "server CSR generation failed."
    openssl ca -config "${PKI_DIR}/openssl.cnf" -batch -notext \
        -extensions server_ext -days "${CERT_EXPIRE_DAYS}" \
        -in "${PKI_DIR}/csr/server.csr" -out "${PKI_DIR}/issued/server.crt" \
        || die "server cert signing failed."

    log "Generating initial CRL..."
    openssl ca -config "${PKI_DIR}/openssl.cnf" -gencrl -out "${PKI_DIR}/crl.pem" \
        || die "CRL generation failed."

    log "Generating tls-crypt key..."
    openvpn --genkey secret "${PKI_DIR}/ta.key" || die "tls-crypt key generation failed."

    log "PKI generated."
fi

# CRL/CA must be world-readable; private keys stay root-only (read before privsep drop).
chmod 644 "${PKI_DIR}/crl.pem" "${PKI_DIR}/ca.crt" "${PKI_DIR}/issued/server.crt" "${PKI_DIR}/ta.key" 2>/dev/null || true
chmod 600 "${PKI_DIR}/private/server.key" "${PKI_DIR}/private/ca.key" 2>/dev/null || true
chmod 755 "${PKI_DIR}" "${PKI_DIR}/private" 2>/dev/null || true

# ----------------------------------------------------------------------------
# 3. Resolve LAN + DNS values for pushed routes
# ----------------------------------------------------------------------------
LAN_IP="$(uci get network.lan.ipaddr 2>/dev/null || true)"
LAN_MASK="$(uci get network.lan.netmask 2>/dev/null || echo 255.255.255.0)"
[ -n "$LAN_IP" ] || die "could not read network.lan.ipaddr from UCI — is 'lan' the correct interface name on this device?"

if [ -z "$PUSH_DNS" ]; then
    PUSH_DNS="$LAN_IP"
fi
log "LAN detected as ${LAN_IP}/${LAN_MASK}; clients will use DNS ${PUSH_DNS}."

# ----------------------------------------------------------------------------
# 4. UCI: openvpn server section
# ----------------------------------------------------------------------------
log "Writing UCI openvpn config (section '${INSTANCE_NAME}')..."

uci -q batch <<EOF
set openvpn.${INSTANCE_NAME}='openvpn'
set openvpn.${INSTANCE_NAME}.enabled='1'
set openvpn.${INSTANCE_NAME}.port='${VPN_PORT}'
set openvpn.${INSTANCE_NAME}.proto='${VPN_PROTO}'
set openvpn.${INSTANCE_NAME}.dev='${TUN_DEV}'
set openvpn.${INSTANCE_NAME}.dev_type='tun'
set openvpn.${INSTANCE_NAME}.topology='subnet'
set openvpn.${INSTANCE_NAME}.server='${VPN_SUBNET} ${VPN_NETMASK}'
set openvpn.${INSTANCE_NAME}.keepalive='10 120'
set openvpn.${INSTANCE_NAME}.persist_key='1'
set openvpn.${INSTANCE_NAME}.persist_tun='1'
set openvpn.${INSTANCE_NAME}.ca='${PKI_DIR}/ca.crt'
set openvpn.${INSTANCE_NAME}.cert='${PKI_DIR}/issued/server.crt'
set openvpn.${INSTANCE_NAME}.key='${PKI_DIR}/private/server.key'
set openvpn.${INSTANCE_NAME}.dh='none'
set openvpn.${INSTANCE_NAME}.tls_crypt='${PKI_DIR}/ta.key'
set openvpn.${INSTANCE_NAME}.crl_verify='${PKI_DIR}/crl.pem'
set openvpn.${INSTANCE_NAME}.cipher='${CIPHER}'
set openvpn.${INSTANCE_NAME}.data_ciphers='${CIPHER}'
set openvpn.${INSTANCE_NAME}.auth='${AUTH_DIGEST}'
set openvpn.${INSTANCE_NAME}.tls_version_min='${TLS_MIN}'
set openvpn.${INSTANCE_NAME}.remote_cert_tls='client'
set openvpn.${INSTANCE_NAME}.user='nobody'
set openvpn.${INSTANCE_NAME}.group='nogroup'
set openvpn.${INSTANCE_NAME}.status='/var/log/openvpn-${INSTANCE_NAME}-status.log'
set openvpn.${INSTANCE_NAME}.verb='3'
set openvpn.${INSTANCE_NAME}.log='/var/log/openvpn-${INSTANCE_NAME}.log'
set openvpn.${INSTANCE_NAME}.client_to_client='${ALLOW_CLIENT_TO_CLIENT}'
delete openvpn.${INSTANCE_NAME}.push
EOF

if [ "$FULL_TUNNEL" = "1" ]; then
    log "Mode: FULL-TUNNEL (all client internet traffic via router)"
    uci add_list openvpn.${INSTANCE_NAME}.push="redirect-gateway def1 bypass-dhcp"
    uci add_list openvpn.${INSTANCE_NAME}.push="dhcp-option DNS ${PUSH_DNS}"
else
    log "Mode: SPLIT-TUNNEL (only LAN ${LAN_IP}/${LAN_MASK} routed via VPN)"
    uci add_list openvpn.${INSTANCE_NAME}.push="route ${LAN_IP%.*}.0 ${LAN_MASK}"
    uci add_list openvpn.${INSTANCE_NAME}.push="dhcp-option DNS ${PUSH_DNS}"
fi

uci commit openvpn
log "UCI openvpn config committed."

# ----------------------------------------------------------------------------
# 5. Firewall: zone for the tun device, forwarding to lan/wan, WAN port open
# ----------------------------------------------------------------------------
log "Writing firewall rules..."

uci -q batch <<EOF
set firewall.${INSTANCE_NAME}_zone='zone'
set firewall.${INSTANCE_NAME}_zone.name='vpn_${INSTANCE_NAME}'
set firewall.${INSTANCE_NAME}_zone.input='ACCEPT'
set firewall.${INSTANCE_NAME}_zone.output='ACCEPT'
set firewall.${INSTANCE_NAME}_zone.forward='REJECT'
delete firewall.${INSTANCE_NAME}_zone.device
EOF
uci add_list firewall.${INSTANCE_NAME}_zone.device="${TUN_DEV}+"

uci -q batch <<EOF
set firewall.${INSTANCE_NAME}_to_lan='forwarding'
set firewall.${INSTANCE_NAME}_to_lan.src='vpn_${INSTANCE_NAME}'
set firewall.${INSTANCE_NAME}_to_lan.dest='lan'
set firewall.${INSTANCE_NAME}_to_wan='forwarding'
set firewall.${INSTANCE_NAME}_to_wan.src='vpn_${INSTANCE_NAME}'
set firewall.${INSTANCE_NAME}_to_wan.dest='wan'
set firewall.allow_${INSTANCE_NAME}='rule'
set firewall.allow_${INSTANCE_NAME}.name='Allow-OpenVPN-${INSTANCE_NAME}'
set firewall.allow_${INSTANCE_NAME}.src='wan'
set firewall.allow_${INSTANCE_NAME}.dest_port='${VPN_PORT}'
set firewall.allow_${INSTANCE_NAME}.proto='${VPN_PROTO}'
set firewall.allow_${INSTANCE_NAME}.target='ACCEPT'
EOF

uci commit firewall
log "Firewall rules committed."

# IPv4 forwarding: OpenWrt enables this by default, but confirm/persist anyway.
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

/etc/init.d/firewall reload || warn "firewall reload reported an error — check 'logread' output."

# ----------------------------------------------------------------------------
# 6. Save settings for new-client.sh, then (re)start the service
# ----------------------------------------------------------------------------
cat > "${ENV_FILE}" <<EOF
INSTANCE_NAME="${INSTANCE_NAME}"
PKI_DIR="${PKI_DIR}"
PKI_CURVE="${PKI_CURVE}"
CERT_EXPIRE_DAYS="${CERT_EXPIRE_DAYS}"
TUN_DEV="${TUN_DEV}"
VPN_PROTO="${VPN_PROTO}"
VPN_PORT="${VPN_PORT}"
CIPHER="${CIPHER}"
AUTH_DIGEST="${AUTH_DIGEST}"
TLS_MIN="${TLS_MIN}"
SERVER_PUBLIC_ADDR="${SERVER_PUBLIC_ADDR}"
EOF
log "Wrote ${ENV_FILE} (used by new-client.sh)."

/etc/init.d/openvpn enable
if /etc/init.d/openvpn running 2>/dev/null; then
    /etc/init.d/openvpn restart
else
    /etc/init.d/openvpn start
fi

sleep 2
if pgrep -f "openvpn.*${INSTANCE_NAME}" >/dev/null 2>&1 || ubus call service list '{"name":"openvpn"}' 2>/dev/null | grep -q running; then
    log "OpenVPN service is running."
else
    warn "Could not confirm the service is running. Check: logread | grep -i openvpn"
fi

echo
log "Done. Server: ${VPN_PROTO}/${VPN_PORT}, subnet ${VPN_SUBNET}/${VPN_NETMASK}, mode $([ "$FULL_TUNNEL" = "1" ] && echo full-tunnel || echo split-tunnel)."
log "Next: set SERVER_PUBLIC_ADDR at the top of this script if you haven't, then run ./new-client.sh <name> to issue a client profile."
