# unifi-amneziawg

AmneziaWG on a UniFi UCG-Fiber router (kernel `5.4.213-ui-ipq9574`), integrated
with the UniFi UI.

## Idea

Instead of intercepting `wg` with a bind-mount shim, the AmneziaWG kernel module
is rebuilt to **register under the name `wireguard`**, fully displacing the stock
`wireguard.ko`. UI-created `wgcltN` interfaces (`ip link add type wireguard`) are
then natively AmneziaWG-capable, and the stock `wg` that udapi uses for
`setconf`/`syncconf` talks straight to our module.

The obfuscation (junk) params never travel through udapi's config path, so they
are supplied out of band via a writable `iface_junk` module param, populated from
Mongo at boot and on udev interface-add, and applied **in the kernel before the
first packet** — so the very first handshake is already obfuscated.

This removes the shim's dump multiplexing, interface-type conversion and PBR
repair: the interface is never recreated, so its ifindex and the UCG policy
routing stay intact.

### Two layers

1. **Kernel** — `amneziawg` rebuilt as `wireguard` (see `build.sh`,
   `kmod/iface_junk.{c,h}`):
   - rtnl-link type + genl family renamed to `wireguard`;
   - `iface_junk` module param: `<ifname>\t<key>=<value>\t...\n...` (TAB-delimited);
   - applied in `wg_newlink` before `register_netdevice`, and re-applied to
     cold-started interfaces when the param is rewritten.
2. **Userspace** (`scripts/`, no daemons, no cron):
   - `install-module.sh` — make our module the active `wireguard` (replace in
     `/lib/modules` + `depmod`);
   - `populate-junk.sh` — build `iface_junk` from Mongo for all enabled tunnels;
   - `awg-boot.sh` + `awg.rc.local` — boot entrypoint;
   - `awg-populate@.service` + `99-amnezia-wgclt.rules` — udev hook for tunnels
     added after boot.

**Invariant:** an interface with no record in `iface_junk` gets `junk=0` and
behaves as plain WireGuard — so any non-Amnezia tunnel (Teleport, site-to-site,
wg-server) keeps working.

## Build

Needs Docker.

```bash
make build
```

Produces `output/wireguard.ko` (AmneziaWG registered as `wireguard`,
`v1.0.20260611`). No `awg`/`awg-quick` are built — the UCG ships stock
`wg`/`wg-quick`.

## Deploy

Non-disruptive (copies module + scripts, installs udev rule + systemd unit):

```bash
make deploy            # or: ./deploy.sh root@192.168.1.1
```

Activate the module (**disruptive** — swaps the wireguard module and briefly
drops wg tunnels; do it in a maintenance window):

```bash
ssh root@192.168.1.1 /data/amneziawg/awg-boot.sh
ssh root@192.168.1.1 /data/amneziawg/awg-status.sh
```

Persist across reboot:

```bash
INSTALL_RC_LOCAL=1 ./deploy.sh root@192.168.1.1
# or add /data/amneziawg/awg-boot.sh to /etc/rc.local before `exit 0`
```

## Verify

```bash
make verify
# or on the router:
/data/amneziawg/awg-status.sh
```

`awg-status.sh` reports module identity (the `iface_junk` param marks ours),
genl family, the `iface_junk` map, and per-interface `wg show` + PBR + ifindex.

Junk values are **invisible through any dump** by design (the dump-strip patch
keeps `wg show` stock-compatible). Confirm obfuscation actually engaged via a
working handshake through the blocking provider plus `tcpdump` on the WAN (junk
packets / non-standard sizes before the handshake), or the temporary
`pr_info` in `dmesg`.

## Roll back to stock WireGuard

```bash
ssh root@192.168.1.1 'cp /lib/modules/$(uname -r)/kernel/net/wireguard/wireguard.ko.stock \
    /lib/modules/$(uname -r)/kernel/net/wireguard/wireguard.ko && depmod -a'
ssh root@192.168.1.1 'rm -f /etc/udev/rules.d/99-amnezia-wgclt.rules; udevadm control --reload-rules'
# remove the awg-boot.sh hook from /etc/rc.local, then reboot
```

## Caveats

- **Not durable across firmware updates.** A UCG firmware update reverts
  `/lib/modules` to the stock `wireguard.ko`. `install-module.sh` re-asserts our
  module on the next boot, but if udapi autoloads stock and brings a tunnel up
  before `awg-boot.sh` runs, that one boot may run on stock (no obfuscation)
  until the following reboot.
- **Single point of obfuscation source:** Mongo schema (`ace.networkconf`,
  fields `wireguard_id` / `purpose` / `vpn_type` / `wireguard_client_configuration_file`).
  A UniFi update that renames these silently yields plain WireGuard.

## Files

- `build.sh` — patches + builds the renamed module (`patch_awg_*` functions).
- `kmod/iface_junk.{c,h}` — the per-interface junk store.
- `scripts/` — `install-module.sh`, `populate-junk.sh`, `awg-boot.sh`,
  `awg-status.sh`, `awg.rc.local`, `awg-populate@.service`,
  `99-amnezia-wgclt.rules`.
- `scripts/legacy/` — the old bind-mount `wg-shim` path (deprecated; not used by
  the amnezia-as-wireguard design).
- `docs/plans/20260628-amnezia-as-wireguard.md` — implementation plan.
