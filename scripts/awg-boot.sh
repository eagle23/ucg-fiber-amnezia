#!/bin/sh
# Boot entrypoint for AmneziaWG-as-wireguard. Invoked from /etc/rc.local.
#
#   1. Ensure our module is the active "wireguard" (install-module.sh).
#   2. Populate iface_junk from Mongo for all enabled tunnels.
#
# Tunnels known at boot get their junk before/around udapi bringing them up; the
# kernel's retroactive apply covers any that come up before populate runs.
set -eu

BASE="${WG_BASE:-/data/amneziawg}"
LOG="${WG_BOOT_LOG:-${BASE}/awg-boot.log}"

{
	echo "=== awg-boot $(date) ==="
	"${BASE}/install-module.sh"
	if "${BASE}/populate-junk.sh"; then
		:
	else
		echo "awg-boot: populate-junk failed (interfaces will fall back to plain WG)"
	fi
	echo "awg-boot: done"
} >> "${LOG}" 2>&1
