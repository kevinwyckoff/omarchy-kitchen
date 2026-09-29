# nct6775-notify-dkms

kitchen-sink's Super I/O (a Nuvoton NCT6799D at 0x2e, hardware monitor at 0x290) is driven by the kernel's nct6775 driver. The stock driver can only be polled. This package rebuilds it from the Linux 7.2.5 sources with two local patches, through DKMS, for every 7.2.x kernel:

- `0001-hwmon-nct6775-notify-userspace-of-changes.patch`: the driver samples the chip once a second, inside the kernel, and tells userspace what changed. Alarm transitions send `sysfs_notify` and a `KOBJ_CHANGE` uevent with `NAME=<attr>`. pwm ramps, fans stopping or starting, and temperature moves wake `poll()` readers only. What it compared also goes into the driver's sysfs cache before it notifies, so the reader it wakes reads the new value, not one cached up to 1.5 s earlier. It only reads the chip. kitchen-thermald waits on these; nothing in userspace polls the chip.
- `0002-hwmon-nct6775-read-only-register-dump-in-debugfs.patch`: a read-only dump of the Super I/O configuration and the hardware monitor's SMI/OVT registers, for experiments E1 and E1b (can the chip's interrupt be used on this board?). It is off unless asked for; see below.

The modules land in `/usr/lib/modules/<kernel>/updates/dkms`, where depmod prefers them over the in-tree copies. `/etc/modules-load.d/nct6775.conf` stays as it is. The modules are not in the UKI, so the signed boot chain does not change; they load unsigned with taint E, like nvidia's.

## Files

| File | What it is |
|---|---|
| `nct6775-core.c`, `nct6775-platform.c`, `nct6775-i2c.c`, `nct6775.h`, `lm75.h` | `drivers/hwmon/` from Linux 7.2.5, byte for byte |
| `upstream.sha256` | Where they came from (tarball URL, its sha256 and signature) and their sha256s; `sha256sum -c upstream.sha256` |
| `0001-*.patch`, `0002-*.patch` | The local patches, applied in order with no fuzz |
| `Makefile`, `dkms.conf` | The kbuild and DKMS files installed to `/usr/src/nct6775-notify-<version>` |
| `nct6775-notify.conf` | Defaults, installed as `/usr/lib/modprobe.d/nct6775-notify.conf` |
| `PKGBUILD` | Builds `nct6775-notify-dkms-<version>-any.pkg.tar.zst` |
| `refresh.sh` | Moves the sources to a new kernel release |
| `tests/` | Everything that checks the above; `tests/run.sh` |

The sources and patches sit next to the PKGBUILD, not in subdirectories, because makepkg only looks for local sources in the PKGBUILD's own directory.

All three modules are built and installed together: they share `struct nct6775_data`, whose layout 0001 changes.

## Build and install

```bash
makepkg                                   # in this directory
sudo pacman -U nct6775-notify-dkms-7.2.5.2-1-any.pkg.tar.zst
sudo modprobe -r nct6775 nct6775_core && sudo modprobe nct6775   # or reboot
```

The dkms pacman hook builds the modules for each installed 7.2.x kernel. Reloading leaves the fans under the chip's SmartFan control; hwmon disappears for a moment and may come back with another hwmonN number.

Removing the package (`sudo pacman -R nct6775-notify-dkms`) removes the modules, and the in-tree driver loads again after the same reload.

## Parameters

`nct6775-notify.conf` sets, for `nct6775_core`:

- `notify_interval=1000`: milliseconds between samples, 250 to 10000; a value outside that range is clamped, and the parameter reads back as the period in use. 0 turns notification off, and is the driver's own default: without this file (on another machine, or upstream) nothing is sampled. A change takes effect at once.
- `notify_pwm_delta=3`: the smallest pwm change (0-255) that wakes readers.
- `notify_temp_delta=1000`: the smallest temperature change, in millidegrees, that wakes readers. It is what lets the CPU reading (TSI0, `temp13_input`) drive kitchen-thermald's levels.

All three can be changed at runtime under `/sys/module/nct6775_core/parameters/`. kitchen-thermald re-reads them once a minute (or at `systemctl reload kitchen-thermal`) and falls back to polling when notification is off. To change the defaults, copy the file to `/etc/modprobe.d/nct6775-notify.conf`, which then replaces this one.

On a kernel the package does not cover, the in-tree driver loads and logs `unknown parameter ... ignored` for these. It works as before, without notification.

## The register dump

`/sys/kernel/debug/nct6775/nct6775.656/` (656 is 0x290) holds two root-only files:

- `sio_regs`: global CR1A-CR2F; logical device 0B CR30, CR60-65, CR70, CRE0-FF; logical device 0A CRE7, CRF2-F7; logical device 0D CRE2.
- `hm_regs`: bank 0 0x18, 0x39, 0x3A, 0x40, 0x43, 0x44, 0x46, 0x4C; bank 1 0x52-0x56; bank 4 0x51; bank 5 0x66; bank 6 0x21, 0x22; bank C 0x04-0x08, 0x0C, 0x0D, 0x1A-0x2B.

To take a dump on the machine:

```bash
sudo sh -c 'echo 1 > /sys/module/nct6775/parameters/dump
  cat /sys/kernel/debug/nct6775/nct6775.*/sio_regs /sys/kernel/debug/nct6775/nct6775.*/hm_regs
  echo 0 > /sys/module/nct6775/parameters/dump'
```

What it does and does not do:

- It never reads a register that clears when read, which could steal an event from firmware. Both lists are hard-coded, from the NCT6796D datasheet, and a listed register that is on one prints as `denied`:
  - in the hardware monitor, the interrupt status registers (bank 0 0x41, 0x42, 0x45; 0x450; 0x567; 0xC02, 0xC03). Every hardware-monitor read goes through one helper that checks the list, including the second byte of a word-sized register;
  - in configuration space, the GPIO event status registers (logical device 7 CRE3, CRE7, CRF7; 8 CRE3, CRF3; 9 CRE3, CRE7, CRE8, CRF7) and logical device A CRE3, the thermal-shutdown, PSIN and wake-up status that this board's firmware reads at `_PTS` and `_WAK`. The loop over configuration registers checks the list before each read.

  None of them is in the dump's register lists; the checks are there so that a longer list cannot clear them.
- It writes nothing but the selects every read needs: the logical-device select (put back as found) and the hardware-monitor bank select (through the driver's own regmap, under its lock, so the driver's cached bank stays right).
- Configuration space is entered and left with the driver's own sequence, holding the muxed Super-I/O region, exactly as the driver does at probe and resume. CR26 bit 4, which would expose CR10-CR14, is left alone.
- It exists only for the platform driver with direct I/O on nct6796 and nct6799 (the lists come from the NCT6796D datasheet), not for the i2c driver or ASUS WMI boards.

Why it is off by default: reading `sio_regs` enters the Super I/O's configuration mode, which firmware (SMM) may use at the same moment. Off by default means nothing reads it by accident, such as a bug-report tool that collects all of debugfs; while off, reads fail with EPERM before touching the chip. The switch is a runtime parameter (`/sys/module/nct6775/parameters/dump`, or `options nct6775 dump=1`) so that taking a dump needs no driver reload, which would drop kitchen-thermald's open files and may renumber hwmon.

## Kernel updates

`BUILD_EXCLUSIVE_KERNEL="^7\.2\."` in `dkms.conf`: every 7.2.x kernel gets the modules built by the dkms hook before the UKI is made. Any other series is skipped without an error, and the in-tree driver loads; kitchen-thermald then falls back to polling and says so.

Every 7.2.x kernel gets these 7.2.5 sources, which would hide a stable fix to the driver in a later 7.2 release. `upstream.sha256` records, as `checked-through`, the newest release whose driver files `refresh.sh` found identical. The package installs it in `/usr/share/doc/nct6775-notify-dkms/`, and kitchen-sink's updater (preflight) and check-up (`nct6775`) say so, at info level, when a pending or running kernel is newer: run `refresh.sh` for that release.

`refresh.sh` moves the package to a new release. Run it in an Arch container with base-devel, sparse and the target's linux-omarchy-headers:

```bash
./refresh.sh 7.2.8              # download, diff against the vendored files, patch, build (W=1 + sparse); change nothing
./refresh.sh 7.2.8 --update     # ... then rewrite the sources, upstream.sha256, PKGBUILD and dkms.conf
./refresh.sh 7.2.9 --record     # ... or, if 7.2.9 left the driver files alone, record it as checked-through
./refresh.sh 7.2.8 --tarball linux-7.2.8.tar.xz   # use a tarball already here
./refresh.sh --sums             # after editing a patch: recompute the PKGBUILD's sha256sums
```

It checks the tarball against kernel.org's `sha256sums.asc` and its signature against the release keys from kernel.org's WKD, prints any upstream change to the driver files (a stable fix our copy would hide), and fails if a patch needs fuzz or the build warns. `--update` sets `pkgver` to `<release>.1`; bump the last number by hand when only the patches change. `--record` refuses when the files changed.

Up to 7.2.8, the driver files are unchanged from 7.2.5 (checked on 2026-09-29, `checked-through: 7.2.8`).

## Tests

`tests/run.sh` runs everything in containers from any Docker host, with KVM when `/dev/kvm` exists. It needs the linux-omarchy and linux-omarchy-headers packages the package is built for; it fetches them into `~/.cache/omarchy-kitchen/kernel` (or `$NCT6775_KPKG_DIR`) and checks their pinned sha256.

| Part | What it proves |
|---|---|
| `denylist` | The two denylists are exactly the chip's read-to-clear registers (seven in the hardware monitor, ten in configuration space), written again here from the datasheet; the dump lists are E1 and E1b and never touch them, word reads included; the code has one guarded path to the hardware monitor, reads configuration space only behind its list, writes nothing else, checks `dump` before any I/O, and makes 0400 files for the platform driver only. The checks are shown to catch a bad list. |
| `build` | Both patches apply without fuzz; the three modules build against linux-omarchy-headers with W=1 and sparse and no warnings; vermagic and parameters are right. |
| `vm` | The real linux-omarchy kernel in QEMU. Notification on the i2c path (i2c-stub as the chip) and on the platform path, against a fake NCT6799D (`tests/vm/fake-sio.c`) that the platform driver's port I/O is redirected to in a test build. Off by default; `notify_interval` clamped to 250-10000, applied at once when changed, and no sampling at all at 0. A reader woken by a notification reads the new value while another reader keeps the cache warm (12 alarm uevents and 12 fan wakes, none stale). The dump against the fake chip: off by default with no chip access, E1 and E1b read from the right logical devices and banks, configuration mode left and the logical device restored, no read-to-clear read in either space even while racing the sampler, safe unbind. Two test mutations: read-to-clear registers put in either list are all denied; with the guards switched off the fake chip does see them, which shows the test can tell. |
| `package` | makepkg; the package's files; pacman -U runs the dkms hook and modprobe then resolves to `updates/dkms` with the defaults applied; pacman -R removes it all and the in-tree driver is back. |
| `refresh` | refresh.sh against the vendored release: no upstream change, clean patches and build. |
| `lint` | shellcheck. |

On kitchen-sink itself (2026-09-29, 7.2.5-4-omarchy):
- **The real chip.** Swapped in live, with the fans, the pwm settings and the 78 configuration attributes unchanged. Under 120 s of all-core load (Tctl 37 to 85 °C), `poll()` woke on pwm2 24 times (up to 255), pwm4 37 times and temp13 22 times, and `temp7_alarm` sent its two uevents, set at 80 °C and cleared at 75 °C.
- **The cost.** One sample every second takes 0.95 ms, almost all of it about 39 LPC register reads at 24 µs each: about 0.1 % of one core. Measured with the ftrace function profiler over 30 quiet seconds.
- **The dump.** It read the chip without changing a setting; what it showed is in `docs/decisions.md` (2026-09-29).

Not yet tried there: the first boot through modules-load.d with these modules.
