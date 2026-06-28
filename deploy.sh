#!/bin/bash
# Deploy AmneziaWG-as-wireguard to a UCG-Fiber router.
#
# By default this is NON-DISRUPTIVE: it copies the module + scripts and installs
# the udev rule / systemd unit, but does NOT swap the live wireguard module.
# Activating the module (install-module.sh, run via awg-boot.sh) is disruptive
# -- it replaces the wireguard module and briefly drops wg tunnels -- so it is a
# separate, explicit step you run in a maintenance window.
set -euo pipefail

ROUTER="${1:-root@192.168.1.1}"
REMOTE_DIR="/data/amneziawg"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying AmneziaWG-as-wireguard to ${ROUTER} ==="

if [ ! -f "${SCRIPT_DIR}/output/wireguard.ko" ]; then
	echo "ERROR: ${SCRIPT_DIR}/output/wireguard.ko not found. Run 'make build' first." >&2
	exit 1
fi

ssh "${ROUTER}" "mkdir -p ${REMOTE_DIR}"

if [ ! -f "${SCRIPT_DIR}/output/awg" ]; then
	echo "ERROR: ${SCRIPT_DIR}/output/awg not found. Run 'make build' first." >&2
	exit 1
fi

echo "Copying module + awg + scripts..."
scp -p \
	"${SCRIPT_DIR}/output/wireguard.ko" \
	"${SCRIPT_DIR}/output/awg" \
	"${SCRIPT_DIR}/scripts/wg-shim" \
	"${SCRIPT_DIR}/scripts/install-module.sh" \
	"${SCRIPT_DIR}/scripts/populate-junk.sh" \
	"${SCRIPT_DIR}/scripts/awg-boot.sh" \
	"${SCRIPT_DIR}/scripts/awg-status.sh" \
	"${SCRIPT_DIR}/scripts/awg.rc.local" \
	"${SCRIPT_DIR}/scripts/awg-populate@.service" \
	"${SCRIPT_DIR}/scripts/99-amnezia-wgclt.rules" \
	"${ROUTER}:${REMOTE_DIR}/"

ssh "${ROUTER}" "
	chmod +x ${REMOTE_DIR}/awg ${REMOTE_DIR}/wg-shim ${REMOTE_DIR}/install-module.sh \
	         ${REMOTE_DIR}/populate-junk.sh ${REMOTE_DIR}/awg-boot.sh ${REMOTE_DIR}/awg-status.sh
	uname -r > ${REMOTE_DIR}/.kernel-version
"

echo "Installing udev rule + systemd unit..."
ssh "${ROUTER}" "
	cp ${REMOTE_DIR}/awg-populate@.service /etc/systemd/system/awg-populate@.service
	cp ${REMOTE_DIR}/99-amnezia-wgclt.rules /etc/udev/rules.d/99-amnezia-wgclt.rules
	systemctl daemon-reload
	udevadm control --reload-rules
"

if [ "${INSTALL_RC_LOCAL:-0}" = "1" ]; then
	echo "Installing /etc/rc.local boot hook (overwrites existing rc.local)..."
	ssh "${ROUTER}" "cp ${REMOTE_DIR}/awg.rc.local /etc/rc.local && chmod +x /etc/rc.local && systemctl restart rc-local.service || true"
fi

cat <<EOF

=== Files deployed (non-disruptive). ===

Activate the module NOW (DISRUPTIVE -- swaps the wireguard module and briefly
drops wg tunnels; do it in a maintenance window):

  ssh ${ROUTER} ${REMOTE_DIR}/awg-boot.sh
  ssh ${ROUTER} ${REMOTE_DIR}/awg-status.sh

Persist across reboot:
  INSTALL_RC_LOCAL=1 ./deploy.sh ${ROUTER}
  (or add '${REMOTE_DIR}/awg-boot.sh' to /etc/rc.local before 'exit 0')

Roll back to stock WireGuard:
  ssh ${ROUTER} 'umount \$(command -v wg) 2>/dev/null
      KREL=\$(uname -r); MODDIR=/lib/modules/\$KREL/kernel/net/wireguard
      cp \$MODDIR/wireguard.ko.stock \$MODDIR/wireguard.ko && depmod -a
      rmmod wireguard 2>/dev/null; modprobe wireguard
      rm -f /etc/udev/rules.d/99-amnezia-wgclt.rules; udevadm control --reload-rules
      systemctl restart udapi-server.service'
EOF
