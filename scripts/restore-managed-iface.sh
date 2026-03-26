#!/bin/sh
set -eu

if [ $# -ne 1 ]; then
	echo "usage: $0 <iface>" >&2
	exit 1
fi

IFACE="$1"
REAL_WG="${WG_SHIM_REAL:-/data/wg-shim/orig/wg}"
IP_BIN="${WG_SHIM_IP:-$(command -v ip 2>/dev/null || true)}"
STATE_DIR="${WG_SHIM_STATE_DIR:-/data/wg-shim}"
MANAGED_FILE="${WG_SHIM_MANAGED_FILE:-${STATE_DIR}/managed-ifaces.txt}"
CACHE_DIR="${WG_SHIM_CACHE_DIR:-${STATE_DIR}/cache}"
ASSOC_DIR="${WG_SHIM_ASSOC_DIR:-${STATE_DIR}/iface-extra.d}"
STOCK_CONFIG="${CACHE_DIR}/${IFACE}.stock.conf"

require_ip() {
	if [ -n "${IP_BIN}" ] && [ -x "${IP_BIN}" ]; then
		return 0
	fi
	echo "restore-managed-iface: ip binary not found" >&2
	return 127
}

iface_exists() {
	require_ip >/dev/null
	"${IP_BIN}" link show dev "${IFACE}" >/dev/null 2>&1
}

capture_iface_state() {
	state_dir="$1"

	mkdir -p "${state_dir}"
	: >"${state_dir}/mtu"
	printf '0\n' >"${state_dir}/is_up"
	: >"${state_dir}/addr4"
	: >"${state_dir}/addr6"
	: >"${state_dir}/route4"
	: >"${state_dir}/route6"

	if ! iface_exists; then
		return 1
	fi

	"${IP_BIN}" -o link show dev "${IFACE}" | awk '
		{
			for (i = 1; i <= NF; ++i) {
				if ($i == "mtu") {
					print $(i + 1)
					exit
				}
			}
		}
	' >"${state_dir}/mtu"
	if "${IP_BIN}" link show dev "${IFACE}" | grep -Eq '<[^>]*UP[^>]*>'; then
		printf '1\n' >"${state_dir}/is_up"
	fi
	"${IP_BIN}" -o -4 addr show dev "${IFACE}" scope global | awk '{ print $4 }' >"${state_dir}/addr4" || true
	"${IP_BIN}" -o -6 addr show dev "${IFACE}" scope global | awk '{ print $4 }' >"${state_dir}/addr6" || true
	"${IP_BIN}" -o -4 route show dev "${IFACE}" >"${state_dir}/route4" || true
	"${IP_BIN}" -o -6 route show dev "${IFACE}" >"${state_dir}/route6" || true
	return 0
}

restore_addresses() {
	family="$1"
	address_file="$2"
	batch_file="$(mktemp)"

	while IFS= read -r address; do
		[ -n "${address}" ] || continue
		printf 'addr add %s dev %s\n' "${address}" "${IFACE}" >>"${batch_file}"
	done <"${address_file}"
	if [ -s "${batch_file}" ]; then
		"${IP_BIN}" "-${family}" -batch "${batch_file}" >/dev/null 2>&1 || true
	fi
	rm -f "${batch_file}"
}

restore_routes() {
	family="$1"
	route_file="$2"
	batch_file="$(mktemp)"

	while IFS= read -r route; do
		[ -n "${route}" ] || continue
		printf 'route replace %s\n' "${route}" >>"${batch_file}"
	done <"${route_file}"
	if [ -s "${batch_file}" ]; then
		"${IP_BIN}" "-${family}" -batch "${batch_file}" >/dev/null 2>&1 || true
	fi
	rm -f "${batch_file}"
}

restore_iface_state() {
	state_dir="$1"
	mtu=''
	is_up='0'

	if [ -s "${state_dir}/mtu" ]; then
		mtu="$(cat "${state_dir}/mtu")"
	fi
	if [ -s "${state_dir}/is_up" ]; then
		is_up="$(cat "${state_dir}/is_up")"
	fi
	if [ -n "${mtu}" ]; then
		"${IP_BIN}" link set mtu "${mtu}" dev "${IFACE}" >/dev/null 2>&1 || true
	fi
	restore_addresses 4 "${state_dir}/addr4"
	restore_addresses 6 "${state_dir}/addr6"
	if [ "${is_up}" = '1' ]; then
		"${IP_BIN}" link set up dev "${IFACE}" >/dev/null 2>&1 || true
	fi
	restore_routes 4 "${state_dir}/route4"
	restore_routes 6 "${state_dir}/route6"
}

remove_from_managed_file() {
	if [ ! -f "${MANAGED_FILE}" ]; then
		return 0
	fi
	tmp_file="$(mktemp)"
	awk -v iface="${IFACE}" '
		/^[[:space:]]*#/ || !NF { print; next }
		$1 != iface { print }
	' "${MANAGED_FILE}" >"${tmp_file}"
	mv "${tmp_file}" "${MANAGED_FILE}"
}

remove_assoc_file() {
	rm -f "${ASSOC_DIR}/${IFACE}.meta"
}

if [ ! -x "${REAL_WG}" ]; then
	echo "restore-managed-iface: real wg binary not found at ${REAL_WG}" >&2
	exit 1
fi

if [ ! -f "${STOCK_CONFIG}" ]; then
	echo "restore-managed-iface: cached stock config not found: ${STOCK_CONFIG}" >&2
	exit 1
fi

require_ip >/dev/null
state_dir="$(mktemp -d)"
capture_iface_state "${state_dir}" || true
if iface_exists; then
	"${IP_BIN}" link del dev "${IFACE}" >/dev/null 2>&1 || true
fi
if ! "${IP_BIN}" link add "${IFACE}" type wireguard >/dev/null 2>&1; then
	rm -rf "${state_dir}"
	echo "restore-managed-iface: failed to create stock wireguard iface ${IFACE}" >&2
	exit 1
fi
if ! "${REAL_WG}" setconf "${IFACE}" "${STOCK_CONFIG}"; then
	rm -rf "${state_dir}"
	echo "restore-managed-iface: failed to restore stock config for ${IFACE}" >&2
	exit 1
fi
restore_iface_state "${state_dir}"
remove_from_managed_file
remove_assoc_file

rm -rf "${state_dir}"
echo "restored stock wireguard iface: ${IFACE}"
echo "cached stock config kept: ${STOCK_CONFIG}"
echo "assoc removed: ${ASSOC_DIR}/${IFACE}.meta"
