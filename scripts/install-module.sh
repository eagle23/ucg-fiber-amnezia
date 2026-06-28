#!/bin/sh
# Ensure the AmneziaWG-as-"wireguard" module is the one the kernel loads.
#
# Strategy: replace the stock wireguard.ko in /lib/modules with ours and run
# depmod, so any autoload of `type wireguard` (udapi, `wg`, modprobe) resolves
# to our module -- no rmmod/insmod race, no -EEXIST. Idempotent: safe to run on
# every boot from rc.local, which also re-asserts after a firmware update reverts
# /lib/modules to stock.
#
# Our module is recognised by the `iface_junk` param marker, absent on stock.
set -eu

KREL="$(uname -r)"
MODDIR="/lib/modules/${KREL}/kernel/net/wireguard"
STOCK="${MODDIR}/wireguard.ko"
BACKUP="${MODDIR}/wireguard.ko.stock"
OURS="${WG_MODULE_SRC:-/data/amneziawg/wireguard.ko}"
PARAM="/sys/module/wireguard/parameters/iface_junk"

log() { echo "install-module: $*"; }
is_ours_file() { modinfo "$1" 2>/dev/null | grep -q 'parm:[[:space:]]*iface_junk'; }

if [ ! -f "${OURS}" ]; then
	echo "install-module: our module not found: ${OURS}" >&2
	exit 1
fi

# 1. Put our module into /lib/modules (back up a genuine stock once), depmod.
if ! cmp -s "${OURS}" "${STOCK}" 2>/dev/null; then
	if [ -f "${STOCK}" ] && [ ! -f "${BACKUP}" ] && ! is_ours_file "${STOCK}"; then
		cp -a "${STOCK}" "${BACKUP}"
		log "backed up stock wireguard.ko -> ${BACKUP}"
	fi
	mkdir -p "${MODDIR}"
	cp "${OURS}" "${STOCK}"
	depmod -a "${KREL}"
	log "installed our wireguard.ko into ${MODDIR} + depmod"
fi

# 2. Make sure the LOADED module is ours. If stock is already loaded, only
#    unload it when no wireguard interfaces exist yet (early boot) to avoid
#    orphaning a live tunnel.
if [ ! -e "${PARAM}" ]; then
	if lsmod | grep -q '^wireguard[[:space:]]'; then
		if [ -z "$(wg show interfaces 2>/dev/null)" ]; then
			log "unloading stock wireguard (no live interfaces)"
			rmmod wireguard || true
		else
			log "WARNING: stock wireguard loaded with live interfaces; not unloading"
		fi
	fi
	modprobe wireguard 2>/dev/null || insmod "${OURS}" 2>/dev/null || true
fi

# 3. Verify our module is the active one.
if [ -e "${PARAM}" ]; then
	log "active module is ours (iface_junk param present)"
else
	echo "install-module: FAILED to activate our module (iface_junk missing)" >&2
	exit 1
fi
