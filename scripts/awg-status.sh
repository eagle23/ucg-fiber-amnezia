#!/bin/sh
# Layered diagnostics for AmneziaWG-as-wireguard on UCG-Fiber.
# Read-only. Prints PASS/WARN/FAIL per layer so a single run localizes the fault.
#
#   awg-status.sh            full check (layers 1-9), skips the on-wire capture
#   awg-status.sh --wire     also tcpdump each wgclt* endpoint for junk (intrusive,
#                            ~15s per tunnel; needs a fresh/idle handshake to be useful)
#
# Note: junk values are invisible through any dump by design (dump-strip patch), so
# obfuscation itself is only confirmable via --wire (junk packets) or a working
# handshake through the blocking provider, not from `wg show`.
set -u

PARAM="/sys/module/wireguard/parameters/iface_junk"
MONGO="${WG_SHIM_MONGO:-/usr/bin/mongo}"
PORT="${WG_SHIM_MONGO_PORT:-27117}"
DB="${WG_SHIM_MONGO_DB:-ace}"
WIRE=0
[ "${1:-}" = "--wire" ] && WIRE=1
NOW="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
fails=0; warns=0

P() { printf '  [PASS] %s\n' "$*"; }
W() { printf '  [WARN] %s\n' "$*"; warns=$((warns+1)); }
F() { printf '  [FAIL] %s\n' "$*"; fails=$((fails+1)); }
H() { printf '\n== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
H "1. module identity"
if [ -e "${PARAM}" ]; then
	P "active wireguard module is OURS (iface_junk param present)"
	lsmod 2>/dev/null | grep -E '^wireguard[[:space:]]' | sed 's/^/        /'
else
	F "active module is STOCK or not loaded -> run /data/amneziawg/activate.sh"
fi

# ---------------------------------------------------------------------------
H "2. wg-shim (config -> awg, dump normalized)"
WGBIN="$(command -v wg 2>/dev/null)"
if [ -n "${WGBIN}" ] && mount 2>/dev/null | grep -q " ${WGBIN} "; then
	if head -3 "${WGBIN}" 2>/dev/null | grep -q 'wg-shim'; then
		P "shim bind-mounted over ${WGBIN}"
	else
		W "something is mounted over ${WGBIN} but it is not wg-shim"
	fi
else
	F "wg-shim NOT mounted over ${WGBIN:-wg} -> udapi configures stock wg (ABI clash); run activate.sh"
fi

# ---------------------------------------------------------------------------
H "3. iface_junk map (intent)"
if [ -e "${PARAM}" ]; then
	if [ -s "${PARAM}" ]; then
		# Truncate long values (the I1 ispec is a multi-KB hex blob).
		awk -F'\t' '{ out=""; for(i=1;i<=NF;i++){f=$i; if(length(f)>50) f=substr(f,1,47)"..."; out=out (i>1?"  |  ":"") f} print "        " out }' "${PARAM}"
		P "iface_junk populated"
	else
		W "iface_junk is EMPTY (no enabled tunnel carries junk, or populate-junk not run)"
	fi
else
	F "iface_junk param absent (module not OURS)"
fi

# ---------------------------------------------------------------------------
H "4. post-boot junk autopopulate (udev + systemd)"
[ -f /etc/udev/rules.d/99-amnezia-wgclt.rules ] && P "udev rule installed" \
	|| F "udev rule missing -> ./deploy.sh (new tunnels won't auto-get junk)"
[ -f /etc/systemd/system/awg-populate@.service ] && P "awg-populate@.service installed" \
	|| F "awg-populate@.service missing -> ./deploy.sh"
last_pop="$(journalctl -u 'awg-populate@*' --no-pager 2>/dev/null | grep 'wrote .* tunnel record' | tail -1)"
[ -n "${last_pop}" ] && printf '        last: %s\n' "${last_pop#* populate-junk.sh*: }"

# ---------------------------------------------------------------------------
H "5. interfaces: handshake, Established(10th col), routing"
IFACES="$(wg show interfaces 2>/dev/null)"
[ -n "${IFACES}" ] || W "no wireguard interfaces up"
for IF in ${IFACES}; do
	case "${IF}" in wgclt*) ;; *) continue ;; esac
	printf '  -- %s --\n' "${IF}"
	hs="$(wg show "${IF}" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
	if [ -n "${hs}" ] && [ "${hs}" -gt 0 ] 2>/dev/null; then
		age=$(( $(date +%s) - hs ))
		[ "${age}" -lt 200 ] && P "${IF} handshake fresh (${age}s ago)" || W "${IF} handshake stale (${age}s ago)"
	else
		W "${IF} no handshake yet (peer down or junk missing)"
	fi
	# 10th forced-handshake column the shim must synthesize for udapi
	nf="$(wg show all dump 2>/dev/null | awk -F'\t' -v i="${IF}" '$1==i && NF>=9 {print NF}' | sort -rn | head -1)"
	if [ -n "${nf}" ]; then
		[ "${nf}" -ge 10 ] && P "${IF} dump has 10th col (udapi can mark Established)" \
			|| F "${IF} dump only ${nf} cols -> shim dump-normalize broken -> no proto VPN route"
	fi
	# udapi installs `default dev wgcltN ... proto VPN` into the per-iface PBR
	# table once Established. Match proto-agnostically (a `table NNN` token sits
	# between `dev wgcltN` and `proto VPN` in `ip route show table all`).
	if ip route show table all 2>/dev/null | grep -qE "default dev ${IF}([[:space:]]|$)"; then
		P "${IF} has default route in its PBR table (udapi marked it Established)"
	else
		W "${IF} no default route in its PBR table (not Established yet, or no handshake)"
	fi
	ip -4 rule show 2>/dev/null | grep "${IF}" | sed 's/^/        PBR: /'
done

# ---------------------------------------------------------------------------
H "6. obfuscation on the wire"
if [ "${WIRE}" -eq 1 ]; then
	for IF in ${IFACES}; do
		case "${IF}" in wgclt*) ;; *) continue ;; esac
		grep -q "^${IF}	" "${PARAM}" 2>/dev/null || { printf '  -- %s: no junk record, skipping\n' "${IF}"; continue; }
		EP="$(wg show "${IF}" endpoint 2>/dev/null | awk '{print $2}' | cut -d: -f1)"
		[ -n "${EP}" ] || { W "${IF} no endpoint"; continue; }
		printf '  -- %s: 15s tcpdump to %s (expect tiny junk pkts + ~1250B ispec, then ~92B reply) --\n' "${IF}" "${EP}"
		timeout 15 tcpdump -ni ppp0 "host ${EP}" 2>/dev/null | grep -oE 'length [0-9]+' | sort | uniq -c | sed 's/^/        /'
	done
else
	printf '  (skipped; run with --wire to capture. Junk is invisible via any dump.)\n'
fi

# ---------------------------------------------------------------------------
H "7. kernel health (recent vs historical)"
# dmesg timestamps are seconds since boot; compare against current uptime. Warns
# older than RECENT_S are historical (e.g. the pre-napi-fix WARNs). A genuinely
# new fault shows up within seconds/minutes.
RECENT_S=900
newest="$(dmesg 2>/dev/null | grep -E '__flush_work|cut here|invalid length|Unknown symbol|Internal error|Unable to handle' \
	| grep -oE '^\[[0-9]+' | tr -d '[' | sort -rn | head -1)"
if [ -z "${newest}" ]; then
	P "no WARN/oops in the dmesg buffer at all"
else
	age=$(( NOW - newest ))
	recent="$(dmesg 2>/dev/null | awk -v lo="$(( NOW - RECENT_S ))" '
		/__flush_work|cut here|invalid length|Unknown symbol|Internal error|Unable to handle/ {
			ts=$0; sub(/^\[/,"",ts); sub(/\..*/,"",ts); if (ts+0 > lo) c++ } END{print c+0}')"
	if [ "${recent}" -eq 0 ]; then
		P "only historical warnings (newest ${age}s ago, pre-dates this session)"
	else
		F "${recent} kernel warning(s) in the last ${RECENT_S}s (newest ${age}s ago) -> investigate:"
		dmesg 2>/dev/null | grep -E '__flush_work|cut here|invalid length|Unknown symbol|Internal error' | tail -3 | sed 's/^/        /'
	fi
fi

# ---------------------------------------------------------------------------
H "8. Mongo (source of truth)"
if [ -x "${MONGO}" ]; then
	"${MONGO}" --port "${PORT}" --quiet "${DB}" --eval '
		db.networkconf.find({purpose:"vpn-client",vpn_type:"wireguard-client"}).forEach(function(d){
			var cfg=d.wireguard_client_configuration_file||"";
			var junk=/(^|\n)\s*(Jc|H1|I1)\s*=/.test(cfg)?"junk":"plain";
			print("        wgclt"+d.wireguard_id+"  enabled="+d.enabled+"  "+junk);
		});' 2>/dev/null || W "mongo query failed"
else
	W "mongo client not at ${MONGO}"
fi

# ---------------------------------------------------------------------------
H "9. boot durability"
if grep -q 'awg-boot' /etc/rc.local 2>/dev/null; then
	P "rc.local boot hook present (survives reboot)"
else
	W "no rc.local hook -> INSTALL_RC_LOCAL=1 ./deploy.sh (won't survive reboot)"
fi
KREL="$(uname -r)"; ONDISK="/lib/modules/${KREL}/kernel/net/wireguard/wireguard.ko"
if [ -f "${ONDISK}.stock" ]; then
	P "stock backup present (${ONDISK}.stock) -> deactivate.sh can restore"
else
	W "no .ko.stock backup -> deactivate.sh has nothing to restore to"
fi
[ -f /data/amneziawg/awg-boot.log ] && printf '        last boot log: %s\n' "$(tail -1 /data/amneziawg/awg-boot.log 2>/dev/null)"

# ---------------------------------------------------------------------------
printf '\n== summary ==\n'
if [ "${fails}" -eq 0 ] && [ "${warns}" -eq 0 ]; then
	printf '  ALL GREEN\n'
else
	printf '  %s FAIL, %s WARN\n' "${fails}" "${warns}"
fi
[ "${fails}" -eq 0 ]
