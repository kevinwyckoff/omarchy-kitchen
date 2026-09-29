# SPDX-License-Identifier: GPL-2.0
# Kbuild for the nct6775 hwmon driver family, the same module split as the
# kernel's drivers/hwmon/Makefile, so these three replace the in-tree
# nct6775-core, nct6775 and nct6775-i2c. They share struct nct6775_data, whose
# layout the patches change, so they are always built and installed together.
obj-m += nct6775-core.o
nct6775-objs := nct6775-platform.o
obj-m += nct6775.o
obj-m += nct6775-i2c.o
