#!/bin/sh
set -eu

WG_REAL="$(command -v wg)"
STATE_DIR="${WG_SHIM_STATE_DIR:-/data/wg-shim}"
ASSOC_DIR="${WG_SHIM_ASSOC_DIR:-${STATE_DIR}/iface-extra.d}"

if [ -z "${WG_REAL}" ]; then
	echo "uninstall-wg-shim: wg not found in PATH" >&2
	exit 1
fi

if [ -d "${ASSOC_DIR}" ] && find "${ASSOC_DIR}" -type f -name '*.meta' -print -quit 2>/dev/null | grep -q .; then
	echo "uninstall-wg-shim: auto-associated ifaces still present in ${ASSOC_DIR}" >&2
	echo "uninstall-wg-shim: restore them first with restore-managed-iface.sh" >&2
	exit 1
fi

umount "${WG_REAL}" 2>/dev/null || true
echo "wg-shim unmounted from ${WG_REAL}"
