// SPDX-License-Identifier: GPL-2.0
/*
 * One-shot, read-only helper: exposes the raw key and table parameters of
 * the dm-default-key target behind the userdata device as /proc/gw4_dmkey
 * (mode 0400), so that the same device can be recreated outside Android.
 *
 * The dm table helpers are not exported and kallsyms_lookup_name is not
 * either, so their addresses come in as module parameters (read from
 * /proc/kallsyms with kptr_restrict=0).
 */
#include <linux/module.h>
#include <linux/kdev_t.h>
#include <linux/mm.h>
#include <linux/string.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/device-mapper.h>
#include <linux/bio-crypt-ctx.h>

static unsigned long get_live_table;
static unsigned long put_live_table;
static unsigned long table_get_target;
static unsigned long table_num_targets;
module_param(get_live_table, ulong, 0);
module_param(put_live_table, ulong, 0);
module_param(table_get_target, ulong, 0);
module_param(table_num_targets, ulong, 0);

static unsigned int dm_major = 253, dm_minor = 35;
static unsigned int disk_major = 259, disk_minor = 28;
module_param(dm_major, uint, 0);
module_param(dm_minor, uint, 0);
module_param(disk_major, uint, 0);
module_param(disk_minor, uint, 0);

/* Same layout as in drivers/md/dm-default-key.c of the running kernel. */
struct default_key_c {
	struct dm_dev *dev;
	sector_t start;
	const char *cipher_string;
	u64 iv_offset;
	unsigned int sector_size;
	unsigned int sector_bits;
	struct blk_crypto_key key;
	bool is_hw_wrapped;
	u64 max_dun;
};

typedef struct dm_table *(*get_live_table_fn)(struct mapped_device *, int *);
typedef void (*put_live_table_fn)(struct mapped_device *, int);
typedef struct dm_target *(*table_get_target_fn)(struct dm_table *, unsigned int);
typedef unsigned int (*table_num_targets_fn)(struct dm_table *);

static int show(struct seq_file *m, void *v)
{
	get_live_table_fn get_live = (get_live_table_fn)get_live_table;
	put_live_table_fn put_live = (put_live_table_fn)put_live_table;
	table_get_target_fn get_target = (table_get_target_fn)table_get_target;
	table_num_targets_fn num_targets = (table_num_targets_fn)table_num_targets;
	const struct default_key_c *dkc;
	struct mapped_device *md;
	struct dm_target *ti;
	struct dm_table *t;
	int srcu_idx, ret = -EINVAL;

	md = dm_get_md(MKDEV(dm_major, dm_minor));
	if (!md)
		return -ENODEV;

	t = get_live(md, &srcu_idx);
	/* get_live_table takes the SRCU read lock even when it returns NULL */
	if (!t) {
		ret = -ENXIO;
		goto out;
	}
	if (num_targets(t) != 1) {
		seq_puts(m, "error: expected exactly one target\n");
		goto out;
	}
	ti = get_target(t, 0);
	if (!ti || !ti->type || !virt_addr_valid(ti->private) ||
	    strcmp(ti->type->name, "default-key")) {
		seq_puts(m, "error: target is not default-key\n");
		goto out;
	}
	dkc = ti->private;
	/* scalar fields first, pointers only after they look sane */
	if (dkc->sector_size != 4096 || dkc->is_hw_wrapped ||
	    dkc->key.is_hw_wrapped || dkc->key.size != 64 ||
	    !virt_addr_valid(dkc->dev) || !virt_addr_valid(dkc->cipher_string) ||
	    !virt_addr_valid(dkc->dev->bdev) ||
	    dkc->dev->bdev->bd_dev != MKDEV(disk_major, disk_minor) ||
	    strcmp(dkc->cipher_string, "aes-xts-plain64")) {
		seq_puts(m, "error: unexpected default-key parameters\n");
		goto out;
	}

	seq_printf(m, "len_sectors %llu\n", (unsigned long long)ti->len);
	seq_printf(m, "cipher %s\n", dkc->cipher_string);
	seq_printf(m, "key %*phN\n", (int)dkc->key.size, dkc->key.raw);
	seq_printf(m, "iv_offset %llu\n", (unsigned long long)dkc->iv_offset);
	seq_printf(m, "dev %u:%u\n", MAJOR(dkc->dev->bdev->bd_dev),
		   MINOR(dkc->dev->bdev->bd_dev));
	seq_printf(m, "start %llu\n", (unsigned long long)dkc->start);
	seq_printf(m, "sector_size %u\n", dkc->sector_size);
	seq_printf(m, "discards %u\n", ti->num_discard_bios);
	ret = 0;
out:
	put_live(md, srcu_idx);
	dm_put(md);
	return ret;
}

static int __init gw4dmkey_init(void)
{
	if (!get_live_table || !put_live_table || !table_get_target ||
	    !table_num_targets)
		return -EINVAL;
	if (!proc_create_single("gw4_dmkey", 0400, NULL, show))
		return -ENOMEM;
	return 0;
}

static void __exit gw4dmkey_exit(void)
{
	remove_proc_entry("gw4_dmkey", NULL);
}

module_init(gw4dmkey_init);
module_exit(gw4dmkey_exit);
MODULE_LICENSE("GPL");
