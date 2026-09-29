/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Test builds only: force-included into nct6775-platform.c (see run.sh), it
 * sends the driver's port I/O to fake-sio.ko instead of the hardware. The
 * driver's source is otherwise compiled exactly as shipped.
 */
/* The driver's own pr_fmt, set before io.h pulls in printk.h's default */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/io.h>

void fake_sio_outb(u8 v, u16 port);
u8 fake_sio_inb(u16 port);

#undef outb
#undef inb
#undef outb_p
#undef inb_p
#define outb(v, p)	fake_sio_outb(v, p)
#define inb(p)		fake_sio_inb(p)
#define outb_p(v, p)	fake_sio_outb(v, p)
#define inb_p(p)	fake_sio_inb(p)
