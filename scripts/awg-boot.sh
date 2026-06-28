#!/bin/sh
# Boot entrypoint for AmneziaWG-as-wireguard. Invoked from /etc/rc.local.
#
#   1. Ensure our module is the active "wireguard" (install-module.sh).
#   2. Bind-mount the thin wg-shim over /usr/bin/wg so udapi's setconf is
#      redirected to awg and its `wg show all dump` is normalized.
#   3. Populate iface_junk from Mongo so tunnels obfuscate.
#
# Order matters: module first (udapi-created interfaces are then ours), shim
# before udapi reconfigures tunnels, junk before/around the first handshake.
# The kernel's retroactive iface_junk apply and udapi's periodic syncconf cover
# any timing slack.
set -eu

BASE="${WG_BASE:-/data/amneziawg}"
LOG="${WG_BOOT_LOG:-${BASE}/awg-boot.log}"
SHIM_STATE="${WG_SHIM_STATE_DIR:-/data/wg-shim}"

install_shim() {
	wg_real="$(command -v wg)"
	[ -n "${wg_real}" ] || { echo "awg-boot: wg not found in PATH"; return 1; }
	mkdir -p "${SHIM_STATE}/orig"
	# Back up the genuine stock wg once (never the shim itself).
	if [ ! -f "${SHIM_STATE}/orig/wg" ] && ! head -3 "${wg_real}" 2>/dev/null | grep -q 'wg-shim'; then
		cp -a "${wg_real}" "${SHIM_STATE}/orig/wg"
	fi
	cp "${BASE}/wg-shim" "${SHIM_STATE}/wg"
	chmod 0755 "${SHIM_STATE}/wg"
	# Reinstall the bind-mount idempotently (it does not survive reboot/upgrade).
	umount "${wg_real}" 2>/dev/null || true
	mount --bind "${SHIM_STATE}/wg" "${wg_real}"
	echo "awg-boot: wg-shim bind-mounted over ${wg_real}"
}

{
	echo "=== awg-boot $(date) ==="
	"${BASE}/install-module.sh"
	install_shim
	if "${BASE}/populate-junk.sh"; then
		:
	else
		echo "awg-boot: populate-junk failed (tunnels fall back to plain WG)"
	fi
	echo "awg-boot: done"
} >> "${LOG}" 2>&1
