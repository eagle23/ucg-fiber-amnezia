#!/bin/sh
# Diagnostics for AmneziaWG-as-wireguard. Single on-router smoke check reused by
# the plan's verify steps. Note: junk values are intentionally invisible through
# any dump (the dump-strip patch), so this reports module identity, the
# iface_junk map (intent), interface/handshake state and PBR -- the actual
# obfuscation is confirmed via a working handshake + tcpdump, not here.
set -u

PARAM="/sys/module/wireguard/parameters/iface_junk"

echo "== module =="
if [ -e "${PARAM}" ]; then
	echo "active wireguard module: OURS (iface_junk param present)"
else
	echo "active wireguard module: STOCK or not loaded (no iface_junk param)"
fi
lsmod 2>/dev/null | grep -E '^wireguard[[:space:]]' || echo "wireguard not in lsmod"

echo "== genl family =="
genl ctrl list 2>/dev/null | grep -iA1 'name: wireguard' || echo "(genl tool unavailable)"

echo "== iface_junk map (intent) =="
if [ -e "${PARAM}" ]; then
	sed 's/\t/  |  /g' "${PARAM}" 2>/dev/null
	[ -s "${PARAM}" ] || echo "(empty)"
else
	echo "(n/a)"
fi

echo "== wireguard interfaces =="
wg show interfaces 2>/dev/null || echo "(wg show failed)"
for IF in $(wg show interfaces 2>/dev/null); do
	case "${IF}" in
	wgclt*)
		echo "-- ${IF} --"
		wg show "${IF}" 2>/dev/null | sed -n '1,7p'
		echo "ifindex: $(cat "/sys/class/net/${IF}/ifindex" 2>/dev/null)"
		echo "PBR (v4):"
		ip -4 rule show 2>/dev/null | grep "${IF}" || echo "  (none)"
		;;
	esac
done
