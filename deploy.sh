#!/bin/bash
set -euo pipefail

ROUTER="${1:-root@192.168.1.1}"
REMOTE_DIR="/data/amneziawg"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SERVICE="${INSTALL_SERVICE:-0}"

echo "=== Deploying AmneziaWG to ${ROUTER} ==="

# Verify build artifacts exist
for f in amneziawg.ko awg awg-quick; do
    if [ ! -f "${SCRIPT_DIR}/output/${f}" ]; then
        echo "ERROR: ${SCRIPT_DIR}/output/${f} not found. Run 'make build' first."
        exit 1
    fi
done

# Create persistent directory
ssh "${ROUTER}" "mkdir -p ${REMOTE_DIR}"

# Copy artifacts
echo "Copying artifacts..."
scp -p \
    "${SCRIPT_DIR}/output/amneziawg.ko" \
    "${SCRIPT_DIR}/output/awg" \
    "${SCRIPT_DIR}/output/awg-quick" \
    "${ROUTER}:${REMOTE_DIR}/"

if [ "${INSTALL_SERVICE}" = "1" ]; then
    scp -p "${SCRIPT_DIR}/scripts/amneziawg.service" "${ROUTER}:${REMOTE_DIR}/"
fi

# Set permissions and save current kernel version for firmware update detection
ssh "${ROUTER}" "chmod +x ${REMOTE_DIR}/awg ${REMOTE_DIR}/awg-quick && uname -r > ${REMOTE_DIR}/.kernel-version"

# Create tunnel directory for optional service-managed startup
ssh "${ROUTER}" "mkdir -p ${REMOTE_DIR}/tunnels"

# Unload old module if loaded
ssh "${ROUTER}" "rmmod amneziawg 2>/dev/null || true"

# Ensure dependencies are loaded
ssh "${ROUTER}" "modprobe udp_tunnel 2>/dev/null || true; modprobe ip6_udp_tunnel 2>/dev/null || true"

# Load module
echo "Loading kernel module..."
ssh "${ROUTER}" "insmod ${REMOTE_DIR}/amneziawg.ko"

# Verify
echo "Verifying..."
ssh "${ROUTER}" "lsmod | grep amneziawg"
ssh "${ROUTER}" "dmesg | tail -3"

if [ "${INSTALL_SERVICE}" = "1" ]; then
    echo "Installing systemd service..."
    ssh "${ROUTER}" "cp ${REMOTE_DIR}/amneziawg.service /etc/systemd/system/amneziawg.service"
    ssh "${ROUTER}" "systemctl daemon-reload"
    ssh "${ROUTER}" "systemctl enable amneziawg.service"
fi

echo ""
echo "=== Deployment complete ==="
echo "Module loaded. To configure a tunnel manually:"
echo "  ssh ${ROUTER}"
echo "  cat > ${REMOTE_DIR}/awg0.conf << EOF"
echo "  [Interface]"
echo "  PrivateKey = <key>"
echo "  Address = 10.0.0.2/24"
echo "  Jc = 4"
echo "  Jmin = 40"
echo "  Jmax = 70"
echo "  S1 = 0"
echo "  S2 = 0"
echo "  H1 = 1"
echo "  H2 = 2"
echo "  H3 = 3"
echo "  H4 = 4"
echo "  [Peer]"
echo "  PublicKey = <key>"
echo "  Endpoint = <server>:51820"
echo "  AllowedIPs = 0.0.0.0/0"
echo "  EOF"
echo "  AWG=${REMOTE_DIR}/awg bash ${REMOTE_DIR}/awg-quick up ${REMOTE_DIR}/awg0.conf"
echo ""
echo "Optional: install boot service with INSTALL_SERVICE=1 ./deploy.sh ${ROUTER}"
echo "If you use the service, put tunnel configs into ${REMOTE_DIR}/tunnels/"
