# unifi-amneziawg

AmneziaWG on a UniFi UCG-Fiber router (kernel `5.4.213-ui-ipq9574`), integrated
with the UniFi UI.

## Idea

The AmneziaWG kernel module is rebuilt to **register under the name `wireguard`**,
displacing the stock `wireguard.ko`. So UI-created `wgcltN` interfaces
(`ip link add type wireguard`) ARE our AmneziaWG module — the interface is never
recreated, so its ifindex and the UCG policy routing stay intact (no
dump-multiplex / type-conversion / PBR-repair the old shim needed).

But udapi's UniFi-patched `wg` cannot configure our module (its custom netlink
attributes collide with AmneziaWG's), and udapi decides a tunnel is "Established"
(and only then routes it) from an extra 10th column in `wg show all dump`. So a
**thin `wg-shim`** (bind-mounted over `/usr/bin/wg`) bridges exactly two gaps:

- `setconf`/`syncconf wgclt*` → redirect to **`awg`** (amneziawg-tools rebuilt
  under the same `wireguard` genl family), which speaks the module's ABI;
- `wg show all dump` → synthesize the 10th "forced-handshake" field for wgclt*
  peer rows so udapi marks the tunnel Established and adds its own
  `default dev wgcltN proto VPN` route.

Obfuscation (junk: `Jc/S1/H1/I1`...) is stripped by udapi from the config it
generates, so it is supplied out of band via a writable **`iface_junk`** module
param, populated from Mongo and applied kernel-side (device-level), independent
of the awg config. Verified end-to-end: a UI WireGuard client with Amnezia junk
obfuscates its handshake (Jc junk packets + I1 ispec on the wire), the Amnezia
server responds, and the UI shows Established.

### Pieces

1. **Kernel** — `amneziawg` rebuilt as `wireguard` (`build.sh`,
   `kmod/iface_junk.{c,h}`): renamed rtnl-link/genl family; `iface_junk` module
   param (`<ifname>\t<key>=<value>\t...`) applied in `wg_newlink` and re-applied
   when the param is rewritten. Because it builds against **stock** kernel.org
   5.4.213 headers but runs on the UCG vendor kernel, `build.sh` mirrors the
   vendor struct layouts for `net_device`, `sk_buff` and `napi_struct` (the last
   appends the trailing `work_struct` of the vendor's `CONFIG_THREADED_NAPI`, or
   `netif_napi_del` warns on every peer teardown).
2. **`scripts/wg-shim`** — the thin shim (config→awg + dump-normalize).
3. **Userspace boot** (`scripts/`): `install-module.sh` (make our module the
   active `wireguard`), `awg-boot.sh` (+`awg.rc.local`) installs the shim and
   runs `populate-junk.sh` (Mongo → `iface_junk`); `awg-populate@.service` +
   `99-amnezia-wgclt.rules` re-populate on post-boot tunnel adds.

**Invariant:** an interface with no `iface_junk` record gets `junk=0` and behaves
as plain WireGuard, so non-junk tunnels keep working.

## Build

Needs Docker.

```bash
make build
```

Produces `output/wireguard.ko` (AmneziaWG registered as `wireguard`,
`v1.0.20260611`) and `output/awg` (amneziawg-tools rebuilt under the `wireguard`
genl family — the shim drives our module through it).

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
/data/amneziawg/awg-status.sh            # 9-layer check, PASS/WARN/FAIL, exits non-zero on FAIL
/data/amneziawg/awg-status.sh --wire     # also tcpdumps each endpoint for junk
```

`awg-status.sh` localizes faults across the whole stack: (1) module identity,
(2) wg-shim mount, (3) `iface_junk` map, (4) udev+systemd autopopulate,
(5) per-interface handshake / 10th dump column / PBR routing, (6) on-wire junk
(`--wire`), (7) kernel health (recent vs historical dmesg warnings by age),
(8) Mongo source-of-truth (enabled + junk/plain), (9) boot durability.

Junk values are **invisible through any dump** by design (the dump-strip patch
keeps `wg show` stock-compatible), so obfuscation itself is only confirmable via
`--wire` (junk packets / non-standard sizes before the handshake) or a working
handshake through the blocking provider — not from `wg show`.

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
- **Built against stock headers, run on the vendor kernel.** The module compiles
  against kernel.org 5.4.213 and hand-patches the vendor `net_device` / `sk_buff`
  / `napi_struct` layouts to match (`build.sh` `patch_vendor_*`). A kernel bump
  that changes any of those structs (or the offsets in the netdevice/skbuff
  pads) needs the layout patches re-derived, or the module corrupts memory at
  those offsets. Layer 7 of `awg-status.sh` catches the napi case at runtime.

## Files

- `build.sh` — patches + builds the renamed module (`patch_awg_*` functions).
- `kmod/iface_junk.{c,h}` — the per-interface junk store.
- `scripts/` — `install-module.sh`, `populate-junk.sh`, `awg-boot.sh`,
  `awg-status.sh`, `awg.rc.local`, `awg-populate@.service`,
  `99-amnezia-wgclt.rules`.
- `scripts/legacy/` — the old bind-mount `wg-shim` path (deprecated; not used by
  the amnezia-as-wireguard design).
- `docs/plans/20260628-amnezia-as-wireguard.md` — implementation plan.
