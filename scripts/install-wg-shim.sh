#!/bin/sh
set -eu

WG_REAL="$(command -v wg)"
SHIM_SRC="${1:-/data/amneziawg/wg-shim}"
STATE_DIR="${WG_SHIM_STATE_DIR:-/data/wg-shim}"
ORIG_DIR="${STATE_DIR}/orig"
SHIM_DST="${STATE_DIR}/wg"
LOG_FILE="${WG_SHIM_LOG_FILE:-${STATE_DIR}/wg-shim.log}"

if [ -z "${WG_REAL}" ]; then
	echo "install-wg-shim: wg not found in PATH" >&2
	exit 1
fi

if [ ! -f "${SHIM_SRC}" ]; then
	echo "install-wg-shim: shim source not found: ${SHIM_SRC}" >&2
	exit 1
fi

mkdir -p \
	"${ORIG_DIR}" \
	"${STATE_DIR}/iface-extra.d" \
	"${STATE_DIR}/cache" \
	"${STATE_DIR}/locks"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}"

if [ ! -f "${ORIG_DIR}/wg" ]; then
	cp -a "${WG_REAL}" "${ORIG_DIR}/wg"
fi

cp "${SHIM_SRC}" "${SHIM_DST}"
chmod 0755 "${SHIM_DST}"

umount "${WG_REAL}" 2>/dev/null || true
mount --bind "${SHIM_DST}" "${WG_REAL}"

echo "wg-shim installed over ${WG_REAL}"
echo "iface association dir: ${STATE_DIR}/iface-extra.d"
echo "stock config cache dir: ${STATE_DIR}/cache"
echo "log file: ${LOG_FILE}"
