#!/bin/sh
# Populate the kernel `iface_junk` param from Mongo for ALL enabled AmneziaWG
# vpn-client tunnels. Authoritative full rewrite -- used both at boot and from
# the udev interface-add hook (rebuilding the whole set is idempotent and avoids
# read-modify-write merge logic). The kernel re-applies junk to cold-started
# interfaces on write (see iface_junk store-callback).
#
# Wire format written to the param (see kmod/iface_junk.c):
#   <ifname>\t<key>=<value>\t...\n<ifname2>\t...
set -eu

MONGO="${WG_SHIM_MONGO:-/usr/bin/mongo}"
PORT="${WG_SHIM_MONGO_PORT:-27117}"
DB="${WG_SHIM_MONGO_DB:-ace}"
PARAM="/sys/module/wireguard/parameters/iface_junk"

if [ ! -e "${PARAM}" ]; then
	echo "populate-junk: ${PARAM} missing (our module not loaded?)" >&2
	exit 1
fi

# Map AmneziaWG config keys -> iface_junk keys; emit one TAB-record per enabled
# tunnel that actually carries junk fields.
records="$(
	"${MONGO}" --port "${PORT}" --quiet "${DB}" --eval '
db.networkconf.find({purpose:"vpn-client", vpn_type:"wireguard-client", enabled:true}).forEach(function(d){
  if(!d.wireguard_id || !d.wireguard_client_configuration_file) return;
  var map={Jc:"jc",Jmin:"jmin",Jmax:"jmax",S1:"s1",S2:"s2",S3:"s3",S4:"s4",H1:"h1",H2:"h2",H3:"h3",H4:"h4",I1:"i1",I2:"i2",I3:"i3",I4:"i4",I5:"i5"};
  var rec="wgclt"+d.wireguard_id, any=false;
  d.wireguard_client_configuration_file.split("\n").forEach(function(line){
    var m=line.match(/^\s*([A-Za-z0-9]+)\s*=\s*(.+?)\s*$/);
    if(!m) return;
    var k=map[m[1]];
    if(!k) return;
    rec+="\t"+k+"="+m[2];
    any=true;
  });
  if(any) print(rec);
});
' 2>/dev/null | grep '^wgclt[0-9]' || true
)"

# Single write (sysfs param store is one write, <PAGE_SIZE for one-to-few
# tunnels). No trailing newline: records are newline-separated, and the kernel
# strips one trailing newline anyway.
printf '%s' "${records}" > "${PARAM}"
n="$(printf '%s\n' "${records}" | grep -c '^wgclt[0-9]' || true)"
echo "populate-junk: wrote ${n} tunnel record(s) to iface_junk"
