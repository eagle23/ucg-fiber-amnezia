/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Per-interface AmneziaWG junk-parameter store.
 *
 * UCG-Fiber integration: this module registers as "wireguard", so UI-created
 * `ip link add <ifname> type wireguard` interfaces are AmneziaWG-capable, but
 * udapi's `wg setconf` path never carries the junk obfuscation params. They are
 * supplied out of band through the writable `iface_junk` module param (populated
 * from Mongo at boot and on udev interface-add) and applied here, keyed by
 * interface name, at the moment the interface is created -- before the first
 * packet, so the handshake is obfuscated from the start.
 */
#ifndef _AWG_IFACE_JUNK_H
#define _AWG_IFACE_JUNK_H

struct wg_device;
struct list_head;

/*
 * Accessor for the module-private list of live wireguard devices (defined in
 * device.c, where the list head is static). Used by the iface_junk param
 * store-callback to re-apply junk to already-created interfaces. Callers must
 * hold RTNL while iterating.
 */
struct list_head *wg_device_list(void);

/*
 * Apply the junk params recorded for wg->dev->name onto the device.
 *
 * Mirrors the netlink setconf path (jc/jmin/jmax, S1-S4, H1-H4, I1-I5) and then
 * runs wg_device_handle_post_config() for validation + ispec setup.
 *
 * Returns 0 if junk was applied OR no record exists for this interface
 * (invariant: no record => plain WireGuard). Returns a negative errno on a
 * parse/validation error, in which case advanced_security is cleared and the
 * device falls back to plain WireGuard so interface creation still succeeds.
 *
 * Must run in sleepable context. Acquires wg->device_update_lock internally;
 * the caller is expected to hold RTNL (as both wg_newlink and the param
 * store-callback walk do).
 */
int wg_iface_junk_apply(struct wg_device *wg);

#endif /* _AWG_IFACE_JUNK_H */
