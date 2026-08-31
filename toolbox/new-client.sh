#!/bin/sh
# ============================================================================
# new-client.sh — issue/revoke OpenVPN client certificates and .ovpn profiles
#
# Run either on the router, or from your workstation (e.g. your Mac) — it
# auto-relays to the router over SSH using router.env, same as
# setup_openvpn.sh. When run remotely, a freshly issued .ovpn is copied back
# to this machine and removed from the router afterward.
#
# Usage:
#   ./new-client.sh <client-name>            issue a new client + .ovpn file
#   ./new-client.sh <client-name> --revoke    revoke an existing client
#
# On the router, profiles land in /root/openvpn-clients/<client-name>.ovpn
# ============================================================================

# --- remote relay: if this isn't OpenWrt, run on the router over SSH ------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/router.env" ] && . "$SCRIPT_DIR/router.env"
: "${ROUTER_HOST:=192.168.8.1}"
: "${ROUTER_PORT:=22}"
: "${ROUTER_USER:=root}"
: "${ROUTER_SSH_KEY:=}"

if [ "${OPENVPN_SETUP_ON_ROUTER:-}" != "1" ] && [ ! -f /etc/openwrt_release ]; then
    CLIENT_ARG="${1:-}"
    ACTION_ARG="${2:-}"
    [ -n "$CLIENT_ARG" ] || { echo "FATAL: usage: $0 <client-name> [--revoke]" >&2; exit 1; }

    echo "==> Not running on OpenWrt — relaying to ${ROUTER_USER}@${ROUTER_HOST}:${ROUTER_PORT} over SSH..."
    SSH_OPTS="-p ${ROUTER_PORT} -o ConnectTimeout=10"
    SCP_OPTS="-O -P ${ROUTER_PORT} -o ConnectTimeout=10"   # scp's port flag is -P, ssh's is -p; -O = legacy SCP protocol (router has no sftp-server)
    if [ -n "$ROUTER_SSH_KEY" ]; then
        SSH_OPTS="$SSH_OPTS -i ${ROUTER_SSH_KEY}"
        SCP_OPTS="$SCP_OPTS -i ${ROUTER_SSH_KEY}"
    fi
    # shellcheck disable=SC2086
    scp $SCP_OPTS "$SCRIPT_DIR/new-client.sh" "${ROUTER_USER}@${ROUTER_HOST}:/root/" || {
        echo "FATAL: scp to router failed. Check ROUTER_HOST/PORT/USER in router.env and that 'ssh ${SSH_OPTS} ${ROUTER_USER}@${ROUTER_HOST}' works." >&2
        exit 1
    }
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_HOST}" \
        "chmod +x /root/new-client.sh && OPENVPN_SETUP_ON_ROUTER=1 /root/new-client.sh '${CLIENT_ARG}' '${ACTION_ARG}'"
    rc=$?
    [ $rc -ne 0 ] && exit $rc

    if [ "$ACTION_ARG" != "--revoke" ]; then
        echo "==> Fetching ${CLIENT_ARG}.ovpn..."
        # shellcheck disable=SC2086
        scp $SCP_OPTS "${ROUTER_USER}@${ROUTER_HOST}:/root/openvpn-clients/${CLIENT_ARG}.ovpn" "$SCRIPT_DIR/" && \
        ssh $SSH_OPTS "${ROUTER_USER}@${ROUTER_HOST}" "rm -f /root/openvpn-clients/${CLIENT_ARG}.ovpn" && \
        echo "==> Saved: ${SCRIPT_DIR}/${CLIENT_ARG}.ovpn (removed from router)."
    fi
    exit 0
fi

if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

set -euo pipefail

INSTANCE_NAME_DEFAULT="myvpn"
ENV_FILE="${ENV_FILE:-/etc/openvpn/${INSTANCE_NAME_DEFAULT}.env}"
OUT_DIR="/root/openvpn-clients"

log()  { echo "==> $*"; }
die()  { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root."
[ -f "$ENV_FILE" ] || die "settings file $ENV_FILE not found — run setup_openvpn.sh first (or set ENV_FILE=/path to point at it)."
# shellcheck disable=SC1090
. "$ENV_FILE"

CLIENT="${1:-}"
ACTION="${2:-issue}"
[ -n "$CLIENT" ] || die "usage: $0 <client-name> [--revoke]"
case "$CLIENT" in
    *[!a-zA-Z0-9_-]*) die "client name must be alphanumeric/underscore/hyphen only (got: '$CLIENT')" ;;
esac

if [ "$SERVER_PUBLIC_ADDR" = "CHANGE-ME.example.com" ] || [ -z "$SERVER_PUBLIC_ADDR" ]; then
    die "SERVER_PUBLIC_ADDR is still unset. Edit it at the top of setup_openvpn.sh (or in $ENV_FILE) to your WAN IP / DDNS hostname, then re-run setup_openvpn.sh."
fi

# ----------------------------------------------------------------------------
# Revoke path
# ----------------------------------------------------------------------------
if [ "${2:-}" = "--revoke" ]; then
    [ -f "${PKI_DIR}/issued/${CLIENT}.crt" ] || die "no such client cert: ${PKI_DIR}/issued/${CLIENT}.crt"
    log "Revoking ${CLIENT}..."
    openssl ca -config "${PKI_DIR}/openssl.cnf" -revoke "${PKI_DIR}/issued/${CLIENT}.crt" || die "revoke failed."
    openssl ca -config "${PKI_DIR}/openssl.cnf" -gencrl -out "${PKI_DIR}/crl.pem" || die "CRL regeneration failed."
    chmod 644 "${PKI_DIR}/crl.pem"
    rm -f "${OUT_DIR}/${CLIENT}.ovpn"
    log "Revoked. CRL updated at ${PKI_DIR}/crl.pem — OpenVPN re-reads it on each new connection, no restart needed."
    log "(existing connections from this client will be dropped on their next TLS renegotiation; run '/etc/init.d/openvpn restart' to force it immediately)"
    exit 0
fi

# ----------------------------------------------------------------------------
# Issue path
# ----------------------------------------------------------------------------
mkdir -p "$OUT_DIR"

if [ -f "${PKI_DIR}/issued/${CLIENT}.crt" ]; then
    die "client '${CLIENT}' already exists (${PKI_DIR}/issued/${CLIENT}.crt). Use a different name, or --revoke first to reissue."
fi

log "Issuing certificate for '${CLIENT}'..."
openssl ecparam -name "${PKI_CURVE}" -genkey -noout -out "${PKI_DIR}/private/${CLIENT}.key" \
    || die "client key generation failed."
openssl req -new -key "${PKI_DIR}/private/${CLIENT}.key" -subj "/CN=${CLIENT}" \
    -out "${PKI_DIR}/csr/${CLIENT}.csr" || die "client CSR generation failed."
openssl ca -config "${PKI_DIR}/openssl.cnf" -batch -notext \
    -extensions client_ext -days "${CERT_EXPIRE_DAYS}" \
    -in "${PKI_DIR}/csr/${CLIENT}.csr" -out "${PKI_DIR}/issued/${CLIENT}.crt" \
    || die "client cert signing failed."

OUT_FILE="${OUT_DIR}/${CLIENT}.ovpn"
log "Building ${OUT_FILE}..."

{
    cat <<EOF
client
dev ${TUN_DEV}
proto ${VPN_PROTO}
remote ${SERVER_PUBLIC_ADDR} ${VPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher ${CIPHER}
data-ciphers ${CIPHER}
auth ${AUTH_DIGEST}
tls-version-min ${TLS_MIN}
verb 3

<ca>
EOF
    cat "${PKI_DIR}/ca.crt"
    echo "</ca>"

    echo "<cert>"
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "${PKI_DIR}/issued/${CLIENT}.crt"
    echo "</cert>"

    echo "<key>"
    cat "${PKI_DIR}/private/${CLIENT}.key"
    echo "</key>"

    echo "<tls-crypt>"
    cat "${PKI_DIR}/ta.key"
    echo "</tls-crypt>"
} > "$OUT_FILE"

chmod 600 "$OUT_FILE"
log "Done: ${OUT_FILE}"
log "Copy it off the router (scp) and delete the router-side copy once imported, since it contains the client's private key:"
log "  scp -P <ssh-port> root@<router-ip>:${OUT_FILE} ./"
