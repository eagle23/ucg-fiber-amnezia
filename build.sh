#!/bin/bash
set -euo pipefail

KERNEL_VERSION="5.4.213"
EXTRAVERSION="-ui-ipq9574"
KERNEL_DIR="/build/linux-${KERNEL_VERSION}"
OUTPUT_DIR="/build/output"
AMNEZIAWG_MODULE_REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
AMNEZIAWG_MODULE_REF="${AMNEZIAWG_MODULE_REF:-v1.0.20260611}"
# amneziawg-tools (awg/awg-quick), rebuilt under genl family "wireguard" so they
# drive our renamed module natively. udapi's UniFi-patched `wg` cannot configure
# AmneziaWG (incompatible netlink ABI), so a thin wg-shim redirects setconf to
# `awg`, which speaks the module's ABI correctly.
AMNEZIAWG_TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"
AMNEZIAWG_TOOLS_REF="${AMNEZIAWG_TOOLS_REF:-v1.0.20260223}"

ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"

mkdir -p "${OUTPUT_DIR}"

checkout_repo_ref() {
    local repo_dir="$1"
    local repo_url="$2"
    local repo_ref="$3"

    if [ -e "${repo_dir}" ] && [ ! -d "${repo_dir}/.git" ]; then
        rm -rf "${repo_dir}"
    fi
    if [ ! -d "${repo_dir}/.git" ]; then
        git clone "${repo_url}" "${repo_dir}"
    fi
    git -C "${repo_dir}" fetch --tags --force origin
    git -C "${repo_dir}" checkout --force "${repo_ref}"
    git -C "${repo_dir}" reset --hard "${repo_ref}"
    git -C "${repo_dir}" clean -fdx
}

patch_vendor_netdevice_layout() {
    local netdevice_h="$1"

    # UCG Fiber's 5.4.213-ui-ipq9574 BSP inserts extra net_device members in
    # several places, not just before netdev_priv(). The offsets below were
    # derived from the exact on-device wireguard.ko:
    # netdev_ops  0x1e8 -> 0x1f8
    # header_ops  0x208 -> 0x228
    # flags       0x210 -> 0x230
    # priv_flags  0x214 -> 0x234
    # mtu         0x220 -> 0x244
    # max_mtu     0x228 -> 0x24c
    # type        0x22c -> 0x250
    # addr_len    0x257 -> 0x27b
    # dev.type    0x518 -> 0x568
    # netdev_priv 0x840 -> 0x8c0
    sed -i '/^[[:space:]]*const struct net_device_ops[[:space:]]*\*netdev_ops;$/i\	char			__ucg_fiber_pad_before_netdev_ops[16];' \
        "${netdevice_h}"
    sed -i '/^[[:space:]]*const struct header_ops[[:space:]]*\*header_ops;$/i\	char			__ucg_fiber_pad_before_header_ops[16];' \
        "${netdevice_h}"
    sed -i '/^[[:space:]]*unsigned int[[:space:]]*mtu;$/i\	char			__ucg_fiber_pad_before_mtu[4];' \
        "${netdevice_h}"
    sed -i '/^[[:space:]]*struct device[[:space:]]*dev;$/i\	char			__ucg_fiber_pad_before_dev[12];' \
        "${netdevice_h}"
    sed -i '/^[[:space:]]*unsigned[[:space:]]*wol_enabled:1;$/i\	char			__ucg_fiber_pad_tail[16];' \
        "${netdevice_h}"
}

patch_vendor_skbuff_layout() {
    local skbuff_h="$1"

    # UCG Fiber's BSP does not just move the tail/head cluster. It inserts:
    # _skb_refdst   0x58 -> 0x60
    # protocol      0xac -> 0xb8
    # network_hdr   0xb0 -> 0xbc
    # tail          0xb4 -> 0xc0
    # end           0xb8 -> 0xc4
    # head          0xbc -> 0xc8
    # data          0xc4 -> 0xd0
    #
    # The exact delta is:
    # - +8 bytes before the _skb_refdst/destructor union
    # - +4 bytes before protocol
    #
    # This keeps all later inline helpers consistent, including the TX path
    # (wg_xmit, skb_dst_drop, wg_reset_packet) and netlink skb helpers.
    perl -0pi -e 's@(\n[[:space:]]*char[[:space:]]+cb\[48\][[:space:]]+__aligned\(8\);\n)@$1\tchar\t\t\t__ucg_fiber_pad_before_skb_refdst[8];\n@s' \
        "${skbuff_h}"
    sed -i '/^[[:space:]]*__be16[[:space:]]*protocol;$/i\	char			__ucg_fiber_pad_before_skb_protocol[4];' \
        "${skbuff_h}"
}

patch_awg_socket_ipv6_fallback() {
    local socket_c="$1"

    perl -0pi -e 's@\Q		if (ret < 0) {
			udp_tunnel_sock_release(new4);
			if (ret == -EADDRINUSE && !port && retries++ < 100)
				goto retry;
			pr_err("%s: Could not create IPv6 socket\n",
			       wg->dev->name);
			goto out;
		}
		set_sock_opts(new6);
		setup_udp_tunnel_sock(net, new6, &cfg);\E@		if (ret < 0) {
			if (ret == -EADDRINUSE && !port && retries++ < 100) {
				udp_tunnel_sock_release(new4);
				goto retry;
			}
			pr_warn("%s: Could not create IPv6 socket, continuing with IPv4 only (%d)\\n",
				wg->dev->name, ret);
			new6 = NULL;
		} else {
			set_sock_opts(new6);
			setup_udp_tunnel_sock(net, new6, &cfg);
		}@s' "${socket_c}"
}

patch_awg_device_dump() {
    local netlink_c="$1"

    perl -0pi -e 's@\n\tchar buf\[32\];@@s' "${netlink_c}"
    perl -0pi -e 's@\Q		if (nla_put_u16(skb, WGDEVICE_A_LISTEN_PORT,
				wg->incoming_port) ||
		    nla_put_u32(skb, WGDEVICE_A_FWMARK, wg->fwmark) ||
		    nla_put_u32(skb, WGDEVICE_A_IFINDEX, wg->dev->ifindex) ||
		    nla_put_string(skb, WGDEVICE_A_IFNAME, wg->dev->name) ||
		    nla_put_u16(skb, WGDEVICE_A_JC, wg->jc) ||
		    nla_put_u16(skb, WGDEVICE_A_JMIN, wg->jmin) ||
		    nla_put_u16(skb, WGDEVICE_A_JMAX, wg->jmax) ||
		    nla_put_u16(skb, WGDEVICE_A_S1, wg->junk_size[MSGIDX_HANDSHAKE_INIT]) ||
		    nla_put_u16(skb, WGDEVICE_A_S2,wg->junk_size[MSGIDX_HANDSHAKE_RESPONSE]) ||
		    (mh_genspec(&wg->headers[MSGIDX_HANDSHAKE_INIT], buf, sizeof(buf)) &&
				nla_put_string(skb, WGDEVICE_A_H1, buf)) ||
			(mh_genspec(&wg->headers[MSGIDX_HANDSHAKE_RESPONSE], buf, sizeof(buf)) &&
				nla_put_string(skb, WGDEVICE_A_H2, buf)) ||
			(mh_genspec(&wg->headers[MSGIDX_HANDSHAKE_COOKIE], buf, sizeof(buf)) &&
				nla_put_string(skb, WGDEVICE_A_H3, buf)) ||
			(mh_genspec(&wg->headers[MSGIDX_TRANSPORT], buf, sizeof(buf)) &&
				nla_put_string(skb, WGDEVICE_A_H4, buf)) ||
			nla_put_u16(skb, WGDEVICE_A_S3, wg->junk_size[MSGIDX_HANDSHAKE_COOKIE]) ||
			nla_put_u16(skb, WGDEVICE_A_S4, wg->junk_size[MSGIDX_TRANSPORT]) ||
			(wg->ispecs[0].desc &&
				nla_put_string(skb, WGDEVICE_A_I1, wg->ispecs[0].desc)) ||
			(wg->ispecs[1].desc &&
				nla_put_string(skb, WGDEVICE_A_I2, wg->ispecs[1].desc)) ||
			(wg->ispecs[2].desc &&
				nla_put_string(skb, WGDEVICE_A_I3, wg->ispecs[2].desc)) ||
			(wg->ispecs[3].desc &&
				nla_put_string(skb, WGDEVICE_A_I4, wg->ispecs[3].desc)) ||
			(wg->ispecs[4].desc &&
				nla_put_string(skb, WGDEVICE_A_I5, wg->ispecs[4].desc)))\E@		if (nla_put_u16(skb, WGDEVICE_A_LISTEN_PORT,
				wg->incoming_port) ||
		    nla_put_u32(skb, WGDEVICE_A_FWMARK, wg->fwmark) ||
		    nla_put_u32(skb, WGDEVICE_A_IFINDEX, wg->dev->ifindex) ||
		    nla_put_string(skb, WGDEVICE_A_IFNAME, wg->dev->name))@s' "${netlink_c}"
}

patch_awg_unload_cleanup() {
    local device_c="$1"
    local peer_c="$2"

    perl -0pi -e 's@\Qvoid wg_device_uninit(void)
{
	rtnl_link_unregister(&link_ops);
	unregister_pernet_device(&pernet_ops);
	unregister_random_vmfork_notifier(&vm_notifier);
	unregister_pm_notifier(&pm_notifier);
	rcu_barrier();
}\E@void wg_device_uninit(void)
{
	struct wg_device *wg, *temp;
	LIST_HEAD(unregister_list);

	rtnl_lock();
	list_for_each_entry_safe(wg, temp, &device_list, device_list)
		unregister_netdevice_queue(wg->dev, &unregister_list);
	unregister_netdevice_many(&unregister_list);
	rtnl_unlock();

	rtnl_link_unregister(&link_ops);
	unregister_pernet_device(&pernet_ops);
	unregister_random_vmfork_notifier(&vm_notifier);
	unregister_pm_notifier(&pm_notifier);
	rcu_barrier();
}\E@s' "${device_c}"

    perl -0pi -e 's@\Qvoid wg_peer_uninit(void)
{
	kmem_cache_destroy(peer_cache);
}\E@void wg_peer_uninit(void)
{
	rcu_barrier();
	kmem_cache_destroy(peer_cache);
}\E@s' "${peer_c}"
}

patch_awg_unique_slab_names() {
    local main_c="$1"
    local allowedips_c="$2"
    local peer_c="$3"

    perl -0pi -e 's@static struct kmem_cache \*peer_cache;@static struct kmem_cache *peer_cache;\nstatic void wg_peer_slab_ctor(void *obj) { }\n@g' "${peer_c}"
    perl -0pi -e 's@peer_cache = KMEM_CACHE\(wg_peer, 0\);@peer_cache = kmem_cache_create("amneziawg_peer_ucgf", sizeof(struct wg_peer), __alignof__(struct wg_peer), 0, wg_peer_slab_ctor);@g' "${peer_c}"

    perl -0pi -e 's@static struct kmem_cache \*node_cache;@static struct kmem_cache *node_cache;\nstatic void wg_allowedips_node_slab_ctor(void *obj) { }\n@g' "${allowedips_c}"
    perl -0pi -e 's@node_cache = KMEM_CACHE\(allowedips_node, 0\);@node_cache = kmem_cache_create("amneziawg_allowedips_node_ucgf", sizeof(struct allowedips_node), __alignof__(struct allowedips_node), 0, wg_allowedips_node_slab_ctor);@g' "${allowedips_c}"

    perl -0pi -e 's#pr_info\("Copyright \(C\) 2024-2025 AmneziaVPN <admin\@amnezia.org>\. All Rights Reserved\\\\n"\);\n#pr_info("Copyright (C) 2024-2025 AmneziaVPN <admin\@amnezia.org>. All Rights Reserved\\n");\npr_info("UCGF build fingerprint: nomerge-slab-v2\\n");\n#' "${main_c}"
}

patch_awg_ctor_safe_slab_allocs() {
    local allowedips_c="$1"
    local peer_c="$2"

    perl -0pi -e 's@static void wg_peer_slab_ctor\(void \*obj\) \{ \}\n@static void wg_peer_slab_ctor(void *obj) { }\n\nstatic struct wg_peer *wg_peer_cache_alloc(void)\n{\n\tstruct wg_peer *peer;\n\n\tpeer = kmem_cache_alloc(peer_cache, GFP_KERNEL);\n\tif (peer)\n\t\tmemset(peer, 0, sizeof(*peer));\n\treturn peer;\n}\n@s' "${peer_c}"
    perl -0pi -e 's@peer = kmem_cache_zalloc\(peer_cache, GFP_KERNEL\);@peer = wg_peer_cache_alloc();@g' "${peer_c}"
    if ! grep -q '#include <linux/string.h>' "${peer_c}"; then
        sed -i '/#include <linux\/list.h>/a #include <linux/string.h>' "${peer_c}"
    fi

    perl -0pi -e 's@static void wg_allowedips_node_slab_ctor\(void \*obj\) \{ \}\n@static void wg_allowedips_node_slab_ctor(void *obj) { }\n\nstatic struct allowedips_node *wg_allowedips_node_alloc(void)\n{\n\tstruct allowedips_node *node;\n\n\tnode = kmem_cache_alloc(node_cache, GFP_KERNEL);\n\tif (node)\n\t\tmemset(node, 0, sizeof(*node));\n\treturn node;\n}\n\n@s' "${allowedips_c}"
    perl -0pi -e 's@kmem_cache_zalloc\(node_cache, GFP_KERNEL\)@wg_allowedips_node_alloc()@g' "${allowedips_c}"
}

patch_awg_rename_to_wireguard() {
    local kbuild="$1"
    local uapi_h="$2"

    # Register the module under the name "wireguard" so it fully displaces the
    # stock wireguard.ko on the UCG: KBUILD_MODNAME drives the rtnl-link .kind,
    # device_type.name, MODULE_ALIAS_RTNL_LINK, the netlink consistency check and
    # pr_fmt. The composite-module name (<mod>-y / obj-... := <mod>.o) must match.
    #
    # CRITICAL: the composite variable amneziawg-y is also appended to from
    # crypto/Kbuild.include (zinc crypto: blake2s/chacha20poly1305/curve25519)
    # and compat/Kbuild.include (siphash/dst_cache/udp_tunnel/memneq). Renaming
    # only the main Kbuild orphans those objects -> the module builds WITHOUT its
    # own crypto and fails to load with "Unknown symbol zinc_*" once the stock
    # wireguard (which exported them) is unloaded. So rename the variable in all
    # kbuild fragments.
    sed -i 's/\bamneziawg-y\b/wireguard-y/g' "${kbuild}" crypto/Kbuild.include compat/Kbuild.include
    sed -i 's/:= amneziawg\.o$/:= wireguard.o/' "${kbuild}"
    if grep -rq '\bamneziawg-y\b' "${kbuild}" crypto/Kbuild.include compat/Kbuild.include; then
        echo "ERROR: stray amneziawg-y remains after rename (crypto/compat objects would be dropped)" >&2
        exit 1
    fi
    if ! grep -q '^wireguard-y :=' "${kbuild}" || ! grep -q ':= wireguard\.o$' "${kbuild}"; then
        echo "ERROR: Kbuild rename to wireguard did not apply" >&2
        exit 1
    fi
    # genl family name + MODULE_ALIAS_GENL_FAMILY resolve through WG_GENL_NAME.
    sed -i 's/#define WG_GENL_NAME "amneziawg"/#define WG_GENL_NAME "wireguard"/' "${uapi_h}"
    if ! grep -q '#define WG_GENL_NAME "wireguard"' "${uapi_h}"; then
        echo "ERROR: WG_GENL_NAME rename to wireguard did not apply" >&2
        exit 1
    fi
}

patch_awg_iface_junk() {
    local kmod_dir="$1"
    local kbuild="$2"
    local device_c="$3"

    # Drop in the per-interface junk store and add it to the composite module.
    cp "${kmod_dir}/iface_junk.c" "${kmod_dir}/iface_junk.h" .
    sed -i 's/^wireguard-y := \(.*\)$/wireguard-y := \1 iface_junk.o/' "${kbuild}"
    if ! grep -q 'iface_junk\.o' "${kbuild}"; then
        echo "ERROR: iface_junk.o not added to Kbuild" >&2
        exit 1
    fi
    # Inject junk into the device the moment it is created, before the first
    # packet, so boot-known tunnels obfuscate their very first handshake. Both
    # the new and the 5.4-compat newlink paths funnel through wg_newlink().
    if ! grep -q '#include "iface_junk.h"' "${device_c}"; then
        sed -i '/#include "messages.h"/a #include "iface_junk.h"' "${device_c}"
    fi
    perl -0pi -e 's@\tnetif_threaded_enable\(dev\);\n\tret = register_netdevice\(dev\);@\twg_iface_junk_apply(wg);\n\tnetif_threaded_enable(dev);\n\tret = register_netdevice(dev);@s' "${device_c}"
    if ! grep -q 'wg_iface_junk_apply(wg);' "${device_c}"; then
        echo "ERROR: iface_junk newlink hook not injected into wg_newlink" >&2
        exit 1
    fi
    # Expose the (static) device_list so the iface_junk param store-callback can
    # re-apply junk to already-live interfaces (cold-start of post-boot tunnels).
    if ! grep -q 'wg_device_list(void)' "${device_c}"; then
        cat >>"${device_c}" <<'AWG_EOF'

/* UCGF: accessor for the static device_list, used by iface_junk reapply. */
struct list_head *wg_device_list(void)
{
	return &device_list;
}
AWG_EOF
    fi
}

# ============================================================
# Step 1: Prepare kernel headers
# ============================================================
echo "=== Preparing kernel ${KERNEL_VERSION}${EXTRAVERSION} ==="

cd "${KERNEL_DIR}"

# Apply device kernel config
cp /build/kernel.config .config

# Set EXTRAVERSION to match device vermagic
sed -i "s/^EXTRAVERSION =.*/EXTRAVERSION = ${EXTRAVERSION}/" Makefile

# Prepare kernel for out-of-tree module build
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} olddefconfig
make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} modules_prepare -j"$(nproc)"

# Verify kernel release string
RELEASE=$(make -s ARCH=${ARCH} kernelrelease)
echo "Kernel release: ${RELEASE}"
EXPECTED="${KERNEL_VERSION}${EXTRAVERSION}"
if [ "${RELEASE}" != "${EXPECTED}" ]; then
    echo "ERROR: kernel release '${RELEASE}' != expected '${EXPECTED}'"
    exit 1
fi

# ============================================================
# Step 2: Build AmneziaWG kernel module (registered as "wireguard")
# ============================================================
echo "=== Building wireguard.ko (AmneziaWG renamed) ==="

cd /build
checkout_repo_ref /build/amneziawg-linux-kernel-module "${AMNEZIAWG_MODULE_REPO}" "${AMNEZIAWG_MODULE_REF}"

cd /build/amneziawg-linux-kernel-module

cd src

# Patch 1: add missing #include for zinc crypto init functions (upstream bug,
# only manifests on kernel < 5.10 where COMPAT_INIT_CRYPTO is defined)
if ! grep -q 'crypto/zinc.h' main.c; then
    sed -i '/#include "uapi\/wireguard.h"/a #include "crypto/zinc.h"' main.c
fi

# Patch 2: fix blake2s conflict for kernel 5.4.200+ < 5.10.
# Kernel 5.4.200+ has a backported include/crypto/blake2s.h which conflicts
# with the zinc blake2s implementation. The Kbuild.include only adds the
# shadow include path when the kernel header is ABSENT. By removing the
# backported header, we force the compat shadow path, so all #include
# <crypto/blake2s.h> resolve to zinc/blake2s.h. This makes the original
# 6.19+ compat block in compat.h work correctly: it includes zinc's header
# (setting include guard), defines the inline blake2s(), THEN the arg-reorder
# macro is defined — proper ordering, no conflicts, no double-definition.
rm -f "${KERNEL_DIR}/include/crypto/blake2s.h"

# Patch 3: mirror UCG Fiber's vendor net_device layout instead of only fixing
# the tail size. A tail-only pad gives the right netdev_priv() offset, but the
# wrong offsets for netdev_ops/header_ops/flags/mtu/dev.type, which is exactly
# what blows up later in register_netdevice().
patch_vendor_netdevice_layout "${KERNEL_DIR}/include/linux/netdevice.h"

# Patch 3b: vendor sk_buff layout differs too. Without this, inline netlink
# nesting helpers compute bogus marks and awg show blows up in nlmsg_trim().
patch_vendor_skbuff_layout "${KERNEL_DIR}/include/linux/skbuff.h"

# Patch 4: UCG Fiber's kernel rejects the IPv6 UDP socket on bring-up, even
# after interface creation works. Falling back to IPv4 keeps client use-cases
# alive instead of aborting link-up in wg_open().
patch_awg_socket_ipv6_fallback socket.c

# Patch 5: AWG's extended dump path trips nlmsg_trim() on this BSP during
# "awg show". Keep the setconf path intact, but dump only the upstream-safe
# core attrs for now. SECURITY-CRITICAL: if this silently fails to apply (e.g.
# after an upstream bump rewrites the dump block), junk attrs would leak into
# `wg show` and break the stock-wg/UI compatibility, so assert it applied.
patch_awg_device_dump netlink.c
if grep -q 'nla_put_u16(skb, WGDEVICE_A_JC' netlink.c; then
    echo "ERROR: patch_awg_device_dump did not strip junk from the dump path (upstream source changed?)" >&2
    exit 1
fi

# Patch 6: make module unload deterministic by unregistering any lingering
# interfaces during module exit and waiting for deferred peer RCU frees before
# destroying the peer slab cache.
patch_awg_unload_cleanup device.c peer.c

# Patch 7: avoid reusing stale slab caches left behind by earlier broken builds.
# This gives us a clean signal when validating unload on the current module.
patch_awg_unique_slab_names main.c allowedips.c peer.c

# Patch 8: ctor-backed private slab caches must not be allocated with
# kmem_cache_zalloc(), or SLUB warns in ___slab_alloc() on this BSP. Keep the
# non-mergeable caches, but zero objects explicitly after kmem_cache_alloc().
patch_awg_ctor_safe_slab_allocs allowedips.c peer.c

# Patch 9: register the module as "wireguard" (rtnl-link type + genl family) so
# it natively backs UI-created `ip link add type wireguard` interfaces and the
# stock `wg` (which udapi uses for setconf/syncconf) talks straight to it.
patch_awg_rename_to_wireguard Kbuild uapi/wireguard.h

# Patch 10: add the per-interface junk store (iface_junk module param) and hook
# it into wg_newlink so junk is applied before the first packet. Must run after
# the rename patch (it edits the renamed wireguard-y line).
patch_awg_iface_junk /build/kmod Kbuild device.c

make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} KERNELDIR="${KERNEL_DIR}" -j"$(nproc)"

# Verify vermagic
VERMAGIC=$(modinfo wireguard.ko 2>/dev/null | grep vermagic | awk '{print $2, $3, $4, $5, $6}' || true)
echo "Module vermagic: ${VERMAGIC}"

# Self-contained check: the module must bundle its own zinc crypto, otherwise it
# fails to load standalone with "Unknown symbol zinc_*" once stock wireguard is
# unloaded. Assert there are no undefined zinc/crypto symbols.
NM="${CROSS_COMPILE}nm"
UNDEF_CRYPTO=$("${NM}" wireguard.ko 2>/dev/null | awk '$1 == "U" && $2 ~ /(zinc_|chacha20|poly1305|curve25519|blake2s)/ { print $2 }' || true)
if [ -n "${UNDEF_CRYPTO}" ]; then
    echo "ERROR: wireguard.ko has undefined crypto symbols (zinc not bundled):" >&2
    echo "${UNDEF_CRYPTO}" >&2
    exit 1
fi
echo "Crypto self-contained: no undefined zinc symbols"

cp wireguard.ko "${OUTPUT_DIR}/"
echo "Built: ${OUTPUT_DIR}/wireguard.ko"

# ============================================================
# Step 3: Build awg userspace tool, renamed to genl family "wireguard"
# ============================================================
echo "=== Building awg (amneziawg-tools, genl family wireguard) ==="

cd /build
checkout_repo_ref /build/amneziawg-tools "${AMNEZIAWG_TOOLS_REPO}" "${AMNEZIAWG_TOOLS_REF}"

cd /build/amneziawg-tools/src
# Rename the genl family the tools talk to (also used to match the rtnl-link
# kind in ipc-linux.h), matching the renamed kernel module.
TOOLS_UAPI="uapi/linux/linux/wireguard.h"
sed -i 's/#define WG_GENL_NAME "amneziawg"/#define WG_GENL_NAME "wireguard"/' "${TOOLS_UAPI}"
if ! grep -q '#define WG_GENL_NAME "wireguard"' "${TOOLS_UAPI}"; then
    echo "ERROR: awg-tools WG_GENL_NAME rename did not apply" >&2
    exit 1
fi
make CC="${CROSS_COMPILE}gcc" -j"$(nproc)"

cp wg "${OUTPUT_DIR}/awg"
cp wg-quick/linux.bash "${OUTPUT_DIR}/awg-quick"
echo "Built: ${OUTPUT_DIR}/awg, ${OUTPUT_DIR}/awg-quick (genl family wireguard)"

# ============================================================
# Done
# ============================================================
echo ""
echo "=== Build complete ==="
ls -lh "${OUTPUT_DIR}/"
