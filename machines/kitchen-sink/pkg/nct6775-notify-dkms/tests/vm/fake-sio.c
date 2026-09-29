// SPDX-License-Identifier: GPL-2.0
/*
 * fake-sio: an NCT6799D-like Super-I/O chip in software, for the
 * nct6775-notify-dkms VM tests only.
 *
 * A test build of nct6775-platform.c is compiled with fake-sio-io.h, which
 * sends its outb()/inb() here instead of to the I/O ports. That lets the
 * platform driver (the path the real machine uses) probe, notify and take
 * its register dump in QEMU, which has no such chip.
 *
 * The chip model: configuration space at 0x2e/0x2f (enter 0x87 0x87, exit
 * 0xaa, CR07 selects the logical device), and the hardware monitor at 0x290
 * with its index and data ports at 0x295/0x296 and the bank select at index
 * 0x4e. Reading one of the read-to-clear registers (the hardware monitor's
 * interrupt status, or configuration space's GPIO and wake-up event status)
 * counts as a violation and clears it, as the chip would. Every register
 * starts with a value derived from its address, so a read that lands in the
 * wrong bank or logical device shows up as a wrong value.
 *
 * /sys/kernel/debug/fake_sio/
 *   stats       counters, one key=value per line
 *   reset       write anything: zero the counters (rc_reads_total stays)
 *   poke        "hm <addr> <val>" or "cfg <ldn|ff> <index> <val>"
 *   expect_sio  what the driver's sio_regs should say for experiment E1
 *   expect_hm   what the driver's hm_regs should say for experiment E1b
 *
 * The E1/E1b lists and the read-to-clear lists below are this file's own copy,
 * written from the design and datasheet rather than from the driver, so the
 * test checks the driver against an independent oracle.
 */
#include <linux/debugfs.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/spinlock.h>
#include <linux/uaccess.h>

#define SIO_INDEX	0x2e
#define SIO_DATA	0x2f
#define SIO2_INDEX	0x4e	/* the second address the driver probes: no chip */
#define SIO2_DATA	0x4f
#define HM_INDEX	0x295
#define HM_DATA		0x296
#define HM_BANK_REG	0x4e

static const u16 read_to_clear[] = { 0x041, 0x042, 0x045, 0x450, 0x567, 0xc02, 0xc03 };

/* Configuration space (NCT6796D v0.6 section 24): logical device, register */
static const struct { u8 ld, reg; } cfg_read_to_clear[] = {
	{ 0x07, 0xe3 }, { 0x07, 0xe7 }, { 0x07, 0xf7 }, { 0x08, 0xe3 }, { 0x08, 0xf3 },
	{ 0x09, 0xe3 }, { 0x09, 0xe7 }, { 0x09, 0xe8 }, { 0x09, 0xf7 }, { 0x0a, 0xe3 },
};

static const u16 e1b[] = {
	0x018, 0x039, 0x03a, 0x040, 0x043, 0x044, 0x046, 0x04c,
	0x152, 0x153, 0x154, 0x155, 0x156, 0x451, 0x566, 0x621, 0x622,
	0xc04, 0xc05, 0xc06, 0xc07, 0xc08, 0xc0c, 0xc0d,
	0xc1a, 0xc1b, 0xc1c, 0xc1d, 0xc1e, 0xc1f, 0xc20, 0xc21, 0xc22,
	0xc23, 0xc24, 0xc25, 0xc26, 0xc27, 0xc28, 0xc29, 0xc2a, 0xc2b,
};

static const struct { int ld, first, last; } e1[] = {
	{ -1, 0x1a, 0x2f }, { 0x0b, 0x30, 0x30 }, { 0x0b, 0x60, 0x65 },
	{ 0x0b, 0x70, 0x70 }, { 0x0b, 0xe0, 0xff }, { 0x0a, 0xe7, 0xe7 },
	{ 0x0a, 0xf2, 0xf7 }, { 0x0d, 0xe2, 0xe2 },
};

void fake_sio_outb(u8 v, u16 port);
u8 fake_sio_inb(u16 port);

static DEFINE_SPINLOCK(lock);

static u8 cfg_global[0x30];
static u8 cfg_ldn[0x20][0x100];
static u8 hm[0x10][0x100];

static bool cfg_mode;
static int keys;
static u8 cfg_index, ldn, hm_index, bank;

static unsigned long cfg_enters, cfg_exits, cfg_reads, cfg_ldn_writes, cfg_other_writes;
static unsigned long hm_reads, hm_writes, hm_bank_writes, rc_reads, rc_reads_total;
static unsigned long cfg_rc_reads;
static unsigned long idle_writes, stray;
static u16 rc_last = 0xffff;

static bool is_read_to_clear(u16 addr)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(read_to_clear); i++)
		if (addr == read_to_clear[i])
			return true;
	return false;
}

static bool cfg_is_read_to_clear(u8 l, u8 reg)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(cfg_read_to_clear); i++)
		if (l == cfg_read_to_clear[i].ld && reg == cfg_read_to_clear[i].reg)
			return true;
	return false;
}

void fake_sio_outb(u8 v, u16 port)
{
	spin_lock(&lock);
	switch (port) {
	case SIO_INDEX:
		if (!cfg_mode) {
			if (v == 0x87 && ++keys == 2) {
				cfg_mode = true;
				keys = 0;
				cfg_enters++;
			} else if (v != 0x87) {
				keys = 0;
				idle_writes++;
			}
		} else if (v == 0xaa) {
			cfg_mode = false;
			cfg_exits++;
		} else {
			cfg_index = v;
		}
		break;
	case SIO_DATA:
		if (!cfg_mode) {
			idle_writes++;	/* the driver's exit writes 0x02 here */
		} else if (cfg_index == 0x07) {
			ldn = v;
			cfg_ldn_writes++;
		} else {
			cfg_other_writes++;
			if (cfg_index < 0x30)
				cfg_global[cfg_index] = v;
			else
				cfg_ldn[ldn & 0x1f][cfg_index] = v;
		}
		break;
	case HM_INDEX:
		hm_index = v;
		break;
	case HM_DATA:
		if (hm_index == HM_BANK_REG) {
			bank = v & 0x0f;
			hm_bank_writes++;
		} else {
			hm[bank][hm_index] = v;
			hm_writes++;
		}
		break;
	case SIO2_INDEX:
	case SIO2_DATA:
		break;
	default:
		stray++;
	}
	spin_unlock(&lock);
}
EXPORT_SYMBOL_GPL(fake_sio_outb);

u8 fake_sio_inb(u16 port)
{
	u8 v = 0xff;
	u16 addr;

	spin_lock(&lock);
	switch (port) {
	case SIO_DATA:
		if (!cfg_mode)
			break;
		cfg_reads++;
		if (cfg_index == 0x07)
			v = ldn;
		else if (cfg_index < 0x30)
			v = cfg_global[cfg_index];
		else
			v = cfg_ldn[ldn & 0x1f][cfg_index];
		if (cfg_index >= 0x30 && cfg_is_read_to_clear(ldn, cfg_index)) {
			cfg_rc_reads++;
			rc_reads_total++;
			cfg_ldn[ldn & 0x1f][cfg_index] = 0;
		}
		break;
	case HM_INDEX:
		v = hm_index;
		break;
	case HM_DATA:
		hm_reads++;
		if (hm_index == HM_BANK_REG) {
			v = bank;
			break;
		}
		addr = bank << 8 | hm_index;
		v = hm[bank][hm_index];
		if (is_read_to_clear(addr)) {
			rc_reads++;
			rc_reads_total++;
			rc_last = addr;
			hm[bank][hm_index] = 0;
		}
		break;
	case SIO_INDEX:
	case SIO2_INDEX:
	case SIO2_DATA:
		break;
	default:
		stray++;
	}
	spin_unlock(&lock);
	return v;
}
EXPORT_SYMBOL_GPL(fake_sio_inb);

static int stats_show(struct seq_file *s, void *unused)
{
	spin_lock(&lock);
	seq_printf(s, "cfg_mode=%d\nldn=0x%02x\ncfg_enters=%lu\ncfg_exits=%lu\ncfg_reads=%lu\n"
		   "cfg_ldn_writes=%lu\ncfg_other_writes=%lu\nhm_reads=%lu\nhm_writes=%lu\n"
		   "hm_bank_writes=%lu\nrc_reads=%lu\ncfg_rc_reads=%lu\nrc_reads_total=%lu\n"
		   "rc_last=0x%03x\nidle_writes=%lu\nstray=%lu\n",
		   cfg_mode, ldn, cfg_enters, cfg_exits, cfg_reads, cfg_ldn_writes,
		   cfg_other_writes, hm_reads, hm_writes, hm_bank_writes, rc_reads,
		   cfg_rc_reads, rc_reads_total, rc_last, idle_writes, stray);
	spin_unlock(&lock);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(stats);

static ssize_t reset_write(struct file *f, const char __user *buf, size_t len, loff_t *pos)
{
	spin_lock(&lock);
	cfg_enters = cfg_exits = cfg_reads = cfg_ldn_writes = cfg_other_writes = 0;
	hm_reads = hm_writes = hm_bank_writes = rc_reads = idle_writes = stray = 0;
	cfg_rc_reads = 0;
	rc_last = 0xffff;
	spin_unlock(&lock);
	return len;
}

static const struct file_operations reset_fops = {
	.write = reset_write,
};

static ssize_t poke_write(struct file *f, const char __user *ubuf, size_t len, loff_t *pos)
{
	char buf[64];
	ssize_t ret = len;
	u16 addr;
	u8 l, idx, val;

	if (len >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ubuf, len))
		return -EFAULT;
	buf[len] = 0;

	spin_lock(&lock);
	if (sscanf(buf, "hm %hx %hhx", &addr, &val) == 2 && addr < 0x1000) {
		hm[addr >> 8][addr & 0xff] = val;
	} else if (sscanf(buf, "cfg %hhx %hhx %hhx", &l, &idx, &val) == 3) {
		if (l == 0xff && idx < 0x30)
			cfg_global[idx] = val;
		else if (l < 0x20 && idx >= 0x30)
			cfg_ldn[l][idx] = val;
		else
			ret = -EINVAL;
	} else {
		ret = -EINVAL;
	}
	spin_unlock(&lock);
	return ret;
}

static const struct file_operations poke_fops = {
	.write = poke_write,
};

static int expect_sio_show(struct seq_file *s, void *unused)
{
	int i, reg;

	spin_lock(&lock);
	for (i = 0; i < ARRAY_SIZE(e1); i++)
		for (reg = e1[i].first; reg <= e1[i].last; reg++)
			if (e1[i].ld < 0)
				seq_printf(s, "CR%02X = 0x%02x\n", reg, cfg_global[reg]);
			else
				seq_printf(s, "LDN%02X CR%02X = 0x%02x\n", e1[i].ld, reg,
					   cfg_ldn[e1[i].ld][reg]);
	spin_unlock(&lock);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(expect_sio);

static int expect_hm_show(struct seq_file *s, void *unused)
{
	int i;

	spin_lock(&lock);
	for (i = 0; i < ARRAY_SIZE(e1b); i++)
		seq_printf(s, "0x%03x = 0x%02x\n", e1b[i], hm[e1b[i] >> 8][e1b[i] & 0xff]);
	spin_unlock(&lock);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(expect_hm);

static struct dentry *dir;

static void fake_sio_setup(void)
{
	int l, i, b;

	/* Values from the address, distinct across banks and logical devices */
	for (i = 0; i < 0x30; i++)
		cfg_global[i] = (i * 0x0b + 0x21) & 0xff;
	for (l = 0; l < 0x20; l++)
		for (i = 0x30; i < 0x100; i++)
			cfg_ldn[l][i] = (l * 0x35 + i * 0x07 + 0x5b) & 0xff;
	for (b = 0; b < 0x10; b++)
		for (i = 0; i < 0x100; i++)
			hm[b][i] = (b * 0x1d + i * 0x07 + 0x11) & 0xff;

	/* What the driver needs to find and accept an NCT6799D at 0x290 */
	cfg_global[0x20] = 0xd8;		/* device ID 0xd802 */
	cfg_global[0x21] = 0x02;
	cfg_global[0x28] &= ~0x10;		/* HM I/O space unlocked: no write */
	cfg_ldn[0x0b][0x30] = 0x01;		/* hardware monitor enabled */
	cfg_ldn[0x0b][0x60] = 0x02;		/* at 0x290 */
	cfg_ldn[0x0b][0x61] = 0x90;
	ldn = 0x05;

	/* No alarms; the read-to-clear registers hold a marker */
	hm[0x4][0x59] = hm[0x4][0x5a] = hm[0x4][0x5b] = hm[0x4][0x5d] = 0;
	hm[0x5][0x68] = hm[0xc][0x01] = 0;
	for (i = 0; i < ARRAY_SIZE(read_to_clear); i++)
		hm[read_to_clear[i] >> 8][read_to_clear[i] & 0xff] = 0xa5;
	for (i = 0; i < ARRAY_SIZE(cfg_read_to_clear); i++)
		cfg_ldn[cfg_read_to_clear[i].ld][cfg_read_to_clear[i].reg] = 0xa5;

	/* SMIOVT sources like the real board: SYSTIN, CPUTIN, AUXTIN0-3, SMBUSMASTER 0, AUXTIN4 */
	hm[0x6][0x21] = 0x01;
	hm[0x6][0x22] = 0x02;
	hm[0xc][0x26] = 0x03;
	hm[0xc][0x27] = 0x04;
	hm[0xc][0x28] = 0x05;
	hm[0xc][0x29] = 0x06;
	hm[0xc][0x2a] = 0x08;
	hm[0xc][0x2b] = 0x07;

	hm[0x1][0x00] = 0x01;			/* pwm1 follows SYSTIN */
	hm[0x1][0x02] = 0x40;			/* pwm1 in SmartFan IV */
	hm[0x0][0x01] = 0x80;			/* pwm1 live output */
	hm[0x4][0x09] = 0x28;			/* TSI0 40.000 C */
	hm[0x4][0x0a] = 0x00;
	hm[0x4][0x0b] = hm[0x4][0x0c] = 0;	/* TSI1 absent */
}

static int __init fake_sio_init(void)
{
	fake_sio_setup();
	dir = debugfs_create_dir("fake_sio", NULL);
	debugfs_create_file("stats", 0400, dir, NULL, &stats_fops);
	debugfs_create_file("reset", 0200, dir, NULL, &reset_fops);
	debugfs_create_file("poke", 0200, dir, NULL, &poke_fops);
	debugfs_create_file("expect_sio", 0400, dir, NULL, &expect_sio_fops);
	debugfs_create_file("expect_hm", 0400, dir, NULL, &expect_hm_fops);
	return 0;
}

static void __exit fake_sio_exit(void)
{
	debugfs_remove_recursive(dir);
}

module_init(fake_sio_init);
module_exit(fake_sio_exit);
MODULE_DESCRIPTION("Fake NCT6799D Super-I/O for the nct6775-notify-dkms VM tests");
MODULE_LICENSE("GPL");
