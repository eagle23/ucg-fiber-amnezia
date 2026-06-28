// SPDX-License-Identifier: GPL-2.0
/*
 * Per-interface AmneziaWG junk-parameter store. See iface_junk.h.
 *
 * Wire format of the `iface_junk` module param (one record per line):
 *
 *   <ifname>\t<key>=<value>\t<key>=<value>...\n<ifname2>\t...
 *
 * Records are separated by '\n', fields within a record by '\t', and the first
 * field of each record is the interface name. TAB is used as the field
 * separator because AmneziaWG descriptors (H1-H4 ranges, I1-I5 packet specs)
 * may contain spaces and angle brackets, but never tabs or newlines.
 *
 * Recognised keys: jc, jmin, jmax (u16); s1..s4 (u16 junk sizes); h1..h4
 * (magic-header ranges "start" or "start-end"); i1..i5 (ispec descriptors).
 */
#include "device.h"
#include "messages.h"
#include "magic_header.h"
#include "junk.h"
#include "iface_junk.h"

#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/list.h>
#include <linux/moduleparam.h>
#include <linux/netdevice.h>
#include <linux/rtnetlink.h>

/* Owned heap copy of the raw param string; guarded by iface_junk_lock. */
static char *iface_junk_str;
static DEFINE_MUTEX(iface_junk_lock);

/* Caller must hold iface_junk_lock. Returns a freshly allocated copy of the
 * record line whose first TAB-delimited field equals ifname, or NULL.
 */
static char *iface_junk_find_record(const char *ifname)
{
	const char *s = iface_junk_str;
	size_t namelen = strlen(ifname);

	while (s && *s) {
		const char *eol = strchrnul(s, '\n');
		size_t reclen = eol - s;

		if (reclen >= namelen && !strncmp(s, ifname, namelen) &&
		    (s[namelen] == '\t' || s + namelen == eol))
			return kstrndup(s, reclen, GFP_KERNEL);
		s = (*eol == '\n') ? eol + 1 : eol;
	}
	return NULL;
}

/* Parse a single record (mutated in place by strsep) into wg's junk fields.
 * Mirrors the WGDEVICE_A_* setconf handling in netlink.c. The leading ifname
 * field is skipped. wg->device_update_lock must be held by the caller.
 */
static int iface_junk_apply_fields(struct wg_device *wg, char *record)
{
	char *field;
	bool first = true;
	int ret = 0;

	while ((field = strsep(&record, "\t")) != NULL) {
		char *key, *val;

		if (first) {
			first = false;
			continue; /* ifname */
		}
		if (!*field)
			continue;
		val = field;
		key = strsep(&val, "=");
		if (!val)
			continue;
		wg->advanced_security = true;
		if (!strcmp(key, "jc"))
			ret = kstrtou16(val, 10, &wg->jc);
		else if (!strcmp(key, "jmin"))
			ret = kstrtou16(val, 10, &wg->jmin);
		else if (!strcmp(key, "jmax"))
			ret = kstrtou16(val, 10, &wg->jmax);
		else if (!strcmp(key, "s1"))
			ret = kstrtou16(val, 10, &wg->junk_size[MSGIDX_HANDSHAKE_INIT]);
		else if (!strcmp(key, "s2"))
			ret = kstrtou16(val, 10, &wg->junk_size[MSGIDX_HANDSHAKE_RESPONSE]);
		else if (!strcmp(key, "s3"))
			ret = kstrtou16(val, 10, &wg->junk_size[MSGIDX_HANDSHAKE_COOKIE]);
		else if (!strcmp(key, "s4"))
			ret = kstrtou16(val, 10, &wg->junk_size[MSGIDX_TRANSPORT]);
		else if (!strcmp(key, "h1"))
			ret = mh_parse(&wg->headers[MSGIDX_HANDSHAKE_INIT], val);
		else if (!strcmp(key, "h2"))
			ret = mh_parse(&wg->headers[MSGIDX_HANDSHAKE_RESPONSE], val);
		else if (!strcmp(key, "h3"))
			ret = mh_parse(&wg->headers[MSGIDX_HANDSHAKE_COOKIE], val);
		else if (!strcmp(key, "h4"))
			ret = mh_parse(&wg->headers[MSGIDX_TRANSPORT], val);
		else if (key[0] == 'i' && key[1] >= '1' && key[1] <= '5' && !key[2]) {
			int idx = key[1] - '1';
			char *desc = kstrdup(val, GFP_KERNEL);

			if (!desc) {
				ret = -ENOMEM;
			} else {
				kfree(wg->ispecs[idx].desc);
				wg->ispecs[idx].desc = desc;
			}
		}
		/* unknown keys are ignored on purpose */
		if (ret)
			break;
	}
	return ret;
}

int wg_iface_junk_apply(struct wg_device *wg)
{
	char *record;
	int ret;

	mutex_lock(&iface_junk_lock);
	record = iface_junk_find_record(wg->dev->name);
	mutex_unlock(&iface_junk_lock);
	if (!record)
		return 0; /* invariant: no record => plain WireGuard */

	mutex_lock(&wg->device_update_lock);
	ret = iface_junk_apply_fields(wg, record);
	if (!ret)
		ret = wg_device_handle_post_config(wg);
	if (ret) {
		/* Invalid junk: fall back to plain WireGuard so the interface
		 * still comes up. Leftover ispec descs are freed at destruct.
		 */
		wg->advanced_security = false;
		net_warn_ratelimited("%s: iface_junk invalid (%d), falling back to plain WireGuard\n",
				     wg->dev->name, ret);
	} else {
		pr_info("%s: iface_junk applied (jc=%u jmin=%u jmax=%u s1=%u s2=%u)\n",
			wg->dev->name, wg->jc, wg->jmin, wg->jmax,
			wg->junk_size[MSGIDX_HANDSHAKE_INIT],
			wg->junk_size[MSGIDX_HANDSHAKE_RESPONSE]);
	}
	mutex_unlock(&wg->device_update_lock);
	kfree(record);
	return ret;
}

static int iface_junk_set(const char *val, const struct kernel_param *kp)
{
	struct wg_device *wg;
	char *new_str, *old;
	size_t len;

	new_str = kstrdup(val ? val : "", GFP_KERNEL);
	if (!new_str)
		return -ENOMEM;
	/* sysfs echo appends a trailing newline; drop one so it is not parsed
	 * as an empty trailing record.
	 */
	len = strlen(new_str);
	if (len && new_str[len - 1] == '\n')
		new_str[len - 1] = '\0';

	mutex_lock(&iface_junk_lock);
	old = iface_junk_str;
	iface_junk_str = new_str;
	mutex_unlock(&iface_junk_lock);
	kfree(old);

	/* Re-apply to already-live interfaces that came up plain so tunnels
	 * created after boot (udev path) pick up junk without a restart. We only
	 * touch interfaces without advanced_security set: cold-started ones that
	 * still need junk. Already-configured tunnels are left undisturbed
	 * (changing their params requires a reconnect anyway). Run outside
	 * iface_junk_lock -- wg_iface_junk_apply re-takes it via find_record --
	 * and under RTNL so the device list is stable, matching the lock order
	 * (rtnl -> device_update_lock) of the setconf path.
	 */
	rtnl_lock();
	list_for_each_entry(wg, wg_device_list(), device_list)
		if (!wg->advanced_security)
			wg_iface_junk_apply(wg);
	rtnl_unlock();
	return 0;
}

static int iface_junk_get(char *buffer, const struct kernel_param *kp)
{
	int len;

	mutex_lock(&iface_junk_lock);
	len = scnprintf(buffer, PAGE_SIZE, "%s\n", iface_junk_str ? iface_junk_str : "");
	mutex_unlock(&iface_junk_lock);
	return len;
}

static const struct kernel_param_ops iface_junk_ops = {
	.set = iface_junk_set,
	.get = iface_junk_get,
};

module_param_cb(iface_junk, &iface_junk_ops, NULL, 0644);
MODULE_PARM_DESC(iface_junk,
		 "Per-interface AmneziaWG junk params: '<ifname>\\t<key>=<value>...\\n...'");
