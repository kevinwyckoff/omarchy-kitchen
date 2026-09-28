#!/usr/bin/python3
# nvme-health: read each NVMe controller's SMART/Health log (Get Log Page 0x02)
# through the kernel's admin passthrough, the same command smartctl and
# nvme-cli send, so kitchen-sink needs neither package. Read-only. Needs root
# (CAP_SYS_ADMIN for the admin ioctl).
#
# Prints one JSON object keyed by serial number, so the caller never depends on
# nvmeN numbering, which differs between the live ISO and the installed system.
# A controller that cannot be read gets an "error" entry; the exit status is
# then 1, but every other controller is still printed.
import ctypes
import fcntl
import glob
import json
import os
import struct
import sys

NVME_IOCTL_ADMIN_CMD = 0xC0484E41  # _IOWR('N', 0x41, struct nvme_admin_cmd), 72 bytes
LOG_LEN = 512

# The tests point this at a fake sysfs tree.
SYSFS = os.environ.get('NVME_HEALTH_SYSFS', '/sys/class/nvme')


def read_smart_log(dev):
    """Send Get Log Page (LID 0x02, all namespaces) and return the 512-byte log."""
    buf = ctypes.create_string_buffer(LOG_LEN)
    cdw10 = ((LOG_LEN // 4 - 1) << 16) | 0x02  # NUMDL (dwords - 1), LID
    cmd = struct.pack('<BBHIIIQQIIIIIIIIII', 0x02, 0, 0, 0xFFFFFFFF, 0, 0, 0,
                      ctypes.addressof(buf), 0, LOG_LEN, cdw10, 0, 0, 0, 0, 0, 0, 0)
    fd = os.open(dev, os.O_RDONLY)
    try:
        fcntl.ioctl(fd, NVME_IOCTL_ADMIN_CMD, bytearray(cmd))
    finally:
        os.close(fd)
    return buf.raw


def parse_smart_log(b):
    """Decode the fields the check-up uses from a SMART/Health log page (NVMe base spec, figure 'SMART / Health Information')."""
    if len(b) < LOG_LEN:
        raise ValueError('short SMART log: %d bytes' % len(b))

    def u128(o):
        return int.from_bytes(b[o:o + 16], 'little')

    def u32(o):
        return int.from_bytes(b[o:o + 4], 'little')

    return {
        'critical_warning': b[0],
        'temperature_c': int.from_bytes(b[1:3], 'little') - 273,  # composite, in kelvin
        'available_spare': b[3],
        'spare_threshold': b[4],
        'percentage_used': b[5],
        'data_read_tb': round(u128(32) * 512000 / 1e12, 2),  # units of 1000 x 512 bytes
        'data_written_tb': round(u128(48) * 512000 / 1e12, 2),
        'power_cycles': u128(112),
        'power_on_hours': u128(128),
        'unsafe_shutdowns': u128(144),
        'media_errors': u128(160),
        'error_log_entries': u128(176),
        'warn_temp_minutes': u32(192),
        'crit_temp_minutes': u32(196),
    }


def collect(sysfs=SYSFS, read_log=read_smart_log):
    """Return ({serial: entry}, exit status) for every controller under sysfs."""
    out = {}
    rc = 0
    for ctrl in sorted(glob.glob(os.path.join(sysfs, 'nvme*'))):
        name = os.path.basename(ctrl)

        def rd(f):
            with open(os.path.join(ctrl, f)) as fh:
                return fh.read().strip()

        try:
            serial = rd('serial')
            entry = {'ctrl': name, 'model': rd('model'), 'firmware': rd('firmware_rev'), 'state': rd('state')}
        except OSError as e:
            out['?' + name] = {'ctrl': name, 'error': str(e)}
            rc = 1
            continue
        try:
            entry.update(parse_smart_log(read_log('/dev/' + name)))
        except (OSError, ValueError) as e:
            entry['error'] = str(e)
            rc = 1
        out[serial] = entry
    return out, rc


def main():
    out, rc = collect()
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()
    return rc


if __name__ == '__main__':
    sys.exit(main())
