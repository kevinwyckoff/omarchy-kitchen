#!/usr/bin/python3
# nvme-health: read each NVMe controller's SMART/Health log (Get Log Page 0x02)
# through the kernel's admin passthrough, the same command smartctl and
# nvme-cli send, so kitchen-sink needs neither package. Read-only. Needs root
# (CAP_SYS_ADMIN for the admin ioctl).
#
#   nvme-health.py           the SMART/Health log of every controller
#   nvme-health.py --probe   experiment X0 of the thermal events: can the drive
#                            raise a temperature event on the stock kernel?
#
# Prints one JSON object keyed by serial number, so the caller never depends on
# nvmeN numbering, which differs between the live ISO and the installed system.
# A controller that cannot be read gets an "error" entry; the exit status is
# then 1, but every other controller is still printed.
#
# --probe reads Identify Controller (OAES, AERL, WCTEMP, CCTEMP, VER, ONCS) and
# Get Features 0Bh (Asynchronous Event Configuration) and 04h (Temperature
# Threshold, over and under) with SEL current, default and, for 0Bh, supported
# capabilities. It gives each drive a verdict:
#
#   case A  OAES has bit 8, 9, 11 or 31. In Linux 7.2.5, nvme_start_ctrl ->
#           nvme_enable_aen (drivers/nvme/host/core.c:1774) then writes FID 0Bh
#           = OAES & 0x80000B00 (NVME_AEN_SUPPORTED, so the SMART bits 7:0 are
#           always cleared) and queues async_event_work, whose
#           nvme_async_event_work submits one Asynchronous Event Request while
#           the controller is LIVE (pci.c marks it LIVE just before
#           nvme_start_ctrl). Every successful AER completion re-queues that
#           work, which sends the NVME_AEN uevent and submits the next AER. So
#           an AER is always outstanding, and user space only has to set FID
#           0Bh bit 1 again after each controller start (the NVME_EVENT=
#           connected uevent). No kernel rebuild.
#   case B  none of those bits: nvme_enable_aen returns before queue_work, so
#           the stock kernel never submits an AER to this controller and no
#           event of any kind can arrive, whatever FID 0Bh holds. Sending an
#           AER from user space would hit admin_timeout and reset the
#           controller, so this needs the rebuilt nvme-core.
#
# The Set Features in nvme_enable_aen can fail ("Failed to configure AEN" in
# dmesg); the AER is queued either way, so only OAES decides the case.
#
# Every admin command goes through admin_cmd(), which refuses anything but the
# three read-only commands in ALLOWED_OPCODES (and, within them, the SMART log,
# Identify Controller and the two features above) before the device is even
# opened. It never sends Set Features: arming is the thermal daemon's job.
import ctypes
import fcntl
import glob
import json
import os
import struct
import sys

NVME_IOCTL_ADMIN_CMD = 0xC0484E41  # _IOWR('N', 0x41, struct nvme_admin_cmd), 72 bytes
# struct nvme_admin_cmd (include/uapi/linux/nvme_ioctl.h): opcode, flags, rsvd1,
# nsid, cdw2, cdw3, metadata, addr, metadata_len, data_len, cdw10-cdw15,
# timeout_ms, result. The kernel writes the completion's dword 0 into result.
ADMIN_CMD = struct.Struct('<BBHIIIQQIIIIIIIIII')
RESULT_OFFSET = 68
LOG_LEN = 512
IDENTIFY_LEN = 4096

OP_GET_LOG_PAGE = 0x02
OP_IDENTIFY = 0x06
OP_GET_FEATURES = 0x0A

# The hard allowlist. Each of these only moves data from the controller to the
# host (opcode bits 1:0 = 10b) and changes no setting. The one side effect is
# Get Log Page's: reading the SMART log with RAE=0 re-enables the SMART AEN it
# reported, exactly as udisks' 10-minute reads and the kernel's hwmon do.
ALLOWED_OPCODES = {OP_GET_LOG_PAGE: 'Get Log Page', OP_IDENTIFY: 'Identify', OP_GET_FEATURES: 'Get Features'}
LID_SMART = 0x02
CNS_CONTROLLER = 0x01
FID_TEMP_THRESH = 0x04
FID_ASYNC_EVENT = 0x0B
ALLOWED_FEATURES = {FID_TEMP_THRESH: 'Temperature Threshold', FID_ASYNC_EVENT: 'Asynchronous Event Configuration'}

SEL_CURRENT, SEL_DEFAULT, SEL_SUPPORTED = 0, 1, 3
ONCS_SELECT = 1 << 4  # Save field in Set Features, Select field in Get Features
AEC_TEMPERATURE = 1 << 1  # FID 0Bh bit 1: SMART/Health critical warning "temperature"
THSEL_OVER, THSEL_UNDER = 0, 1

# NVME_AEN_SUPPORTED in drivers/nvme/host/core.c (identical in 7.2.5 and 7.2.7)
KERNEL_AEN_MASK = 0x80000B00
OAES_NOTICES = {8: 'namespace-attribute', 9: 'firmware-activation', 11: 'ana-change', 31: 'discovery-log-change'}

# The tests point this at a fake sysfs tree.
SYSFS = os.environ.get('NVME_HEALTH_SYSFS', '/sys/class/nvme')


class NotAllowed(Exception):
    """A command outside the read-only allowlist; nothing was sent."""


class NvmeStatus(Exception):
    """The controller completed the command with an error status."""

    NAMES = {0x01: 'Invalid Command Opcode', 0x02: 'Invalid Field in Command'}

    def __init__(self, opcode, status):
        self.opcode = opcode
        self.status = status
        name = self.NAMES.get(status & 0x7FF, 'status code type %d, code %#04x' % ((status >> 8) & 7, status & 0xFF))
        super().__init__('%s failed: NVMe status %#06x (%s)' % (ALLOWED_OPCODES.get(opcode, hex(opcode)), status, name))


def check_allowed(opcode, cdw10):
    """Raise NotAllowed unless this is one of the read-only commands this helper may send."""
    if opcode not in ALLOWED_OPCODES:
        raise NotAllowed('admin opcode %#04x is not on the read-only allowlist' % opcode)
    low = cdw10 & 0xFF
    if opcode == OP_GET_LOG_PAGE and low != LID_SMART:
        raise NotAllowed('Get Log Page %#04x: only the SMART/Health log (02h) is allowed' % low)
    if opcode == OP_IDENTIFY and low != CNS_CONTROLLER:
        raise NotAllowed('Identify CNS %#04x: only Identify Controller (01h) is allowed' % low)
    if opcode == OP_GET_FEATURES and low not in ALLOWED_FEATURES:
        raise NotAllowed('Get Features FID %#04x: only 04h and 0Bh are allowed' % low)


def ioctl_transport(dev, cmd):
    """Hand one packed struct nvme_admin_cmd to the kernel; return the ioctl's
    value: 0, or the NVMe status the controller completed it with."""
    fd = os.open(dev, os.O_RDONLY)
    try:
        return fcntl.ioctl(fd, NVME_IOCTL_ADMIN_CMD, cmd)
    finally:
        os.close(fd)


def admin_cmd(dev, opcode, cdw10=0, cdw11=0, nsid=0, data_len=0, transport=None):
    """Send one allowed admin command; return (completion dword 0, data)."""
    check_allowed(opcode, cdw10)
    buf = ctypes.create_string_buffer(data_len) if data_len else None
    addr = ctypes.addressof(buf) if buf is not None else 0
    cmd = bytearray(ADMIN_CMD.pack(opcode, 0, 0, nsid, 0, 0, 0, addr, 0, data_len, cdw10, cdw11, 0, 0, 0, 0, 0, 0))
    status = (transport or ioctl_transport)(dev, cmd)
    if status:
        raise NvmeStatus(opcode, status)
    return struct.unpack_from('<I', cmd, RESULT_OFFSET)[0], (buf.raw if buf is not None else b'')


def read_smart_log(dev, transport=None):
    """Send Get Log Page (LID 0x02, all namespaces) and return the 512-byte log."""
    cdw10 = ((LOG_LEN // 4 - 1) << 16) | LID_SMART  # NUMDL (dwords - 1), RAE 0, LID
    return admin_cmd(dev, OP_GET_LOG_PAGE, cdw10=cdw10, nsid=0xFFFFFFFF, data_len=LOG_LEN, transport=transport)[1]


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


def parse_identify(b):
    """The Identify Controller fields X0 needs (offsets as struct nvme_id_ctrl in include/linux/nvme.h)."""
    if len(b) < IDENTIFY_LEN:
        raise ValueError('short Identify Controller data: %d bytes' % len(b))

    def u16(o):
        return int.from_bytes(b[o:o + 2], 'little')

    def text(a, z):
        return b[a:z].decode('ascii', 'replace').strip(' \0')

    return {
        'serial': text(4, 24),
        'model': text(24, 64),
        'firmware': text(64, 72),
        'ver': int.from_bytes(b[80:84], 'little'),
        'oaes': int.from_bytes(b[92:96], 'little'),
        'aerl': b[259],
        'wctemp': u16(266),
        'cctemp': u16(268),
        'hctma': u16(322),
        'oncs': u16(520),
    }


def version_text(ver):
    """VER as major.minor.tertiary; 0 means a controller older than NVMe 1.2, which did not report it."""
    if not ver:
        return 'unreported (before 1.2)'
    return '%d.%d.%d' % (ver >> 16, (ver >> 8) & 0xFF, ver & 0xFF)


def celsius(kelvin):
    """Kelvin to whole degrees C the way the kernel's nvme hwmon shows them (K x 1000 - 273150 m°C)."""
    return None if kelvin is None else kelvin - 273


def verdict(oaes):
    """('case A' | 'case B', why): can the stock 7.2.5 kernel deliver this controller's SMART AENs?"""
    mask = oaes & KERNEL_AEN_MASK
    names = [OAES_NOTICES[bit] for bit in sorted(OAES_NOTICES) if mask & (1 << bit)]
    if mask:
        return 'case A', (
            'OAES %#010x has %s notices, so the stock 7.2.5 kernel writes FID 0Bh = %#x at every controller start '
            '(nvme_enable_aen) and keeps one Asynchronous Event Request outstanding while the controller is live. '
            'Setting FID 0Bh bit 1 again after each start (NVME_EVENT=connected) is enough for temperature events; '
            'no kernel rebuild' % (oaes, ', '.join(names), mask))
    return 'case B', (
        'OAES %#010x has none of bits 8, 9, 11 and 31 (the kernel\'s NVME_AEN_SUPPORTED), so the stock 7.2.5 '
        'nvme_enable_aen returns before queuing async_event_work: the kernel never submits an Asynchronous Event '
        'Request to this controller and no event can arrive, whatever FID 0Bh holds. Temperature events need the '
        'rebuilt nvme-core' % oaes)


def probe_controller(dev, transport=None):
    """Experiment X0 for one controller: Identify, FID 0Bh and 04h, and the verdict."""
    idc = parse_identify(admin_cmd(dev, OP_IDENTIFY, cdw10=CNS_CONTROLLER, data_len=IDENTIFY_LEN,
                                   transport=transport)[1])
    select = bool(idc['oncs'] & ONCS_SELECT)
    errors, notes = [], []

    def feature(fid, sel, cdw11=0):
        if sel != SEL_CURRENT and not select:
            return None
        try:
            return admin_cmd(dev, OP_GET_FEATURES, cdw10=(sel << 8) | fid, cdw11=cdw11, transport=transport)[0]
        except NvmeStatus as e:
            errors.append('FID %02xh SEL %d: %s' % (fid, sel, e))
            return None

    def threshold(thsel, sel):
        value = feature(FID_TEMP_THRESH, sel, cdw11=thsel << 20)  # TMPSEL 0: the composite temperature
        return None if value is None else value & 0xFFFF

    aec_cur = feature(FID_ASYNC_EVENT, SEL_CURRENT)
    aec_def = feature(FID_ASYNC_EVENT, SEL_DEFAULT)
    aec_cap = feature(FID_ASYNC_EVENT, SEL_SUPPORTED)
    temps = {}
    for name, thsel in (('temp_over', THSEL_OVER), ('temp_under', THSEL_UNDER)):
        cur, dflt = threshold(thsel, SEL_CURRENT), threshold(thsel, SEL_DEFAULT)
        temps[name] = {'current_k': cur, 'current_c': celsius(cur), 'default_k': dflt, 'default_c': celsius(dflt)}

    case, why = verdict(idc['oaes'])
    kernel_mask = idc['oaes'] & KERNEL_AEN_MASK
    if not select:
        notes.append('ONCS bit 4 is clear: the drive has no Select field in Get Features, so only current values were read')
    if case == 'case A' and aec_cur is not None and aec_cur & KERNEL_AEN_MASK != kernel_mask:
        notes.append('FID 0Bh reads %#x, not the %#x the kernel writes at each start: its Set Features may have failed '
                     '("Failed to configure AEN" in dmesg); the AER is queued either way' % (aec_cur, kernel_mask))
    return idc, {
        'version': version_text(idc['ver']),
        'oaes': idc['oaes'],
        'oaes_hex': '%#010x' % idc['oaes'],
        'oaes_notices': [OAES_NOTICES[bit] for bit in sorted(OAES_NOTICES) if idc['oaes'] & (1 << bit)],
        'kernel_aen_config': kernel_mask,
        'aerl': idc['aerl'],  # 0's based; the kernel keeps only one AER outstanding
        'oncs': idc['oncs'],
        'select_supported': select,
        'wctemp_k': idc['wctemp'] or None,
        'wctemp_c': celsius(idc['wctemp'] or None),
        'cctemp_k': idc['cctemp'] or None,
        'cctemp_c': celsius(idc['cctemp'] or None),
        'aen_config': {
            'current': aec_cur,
            'current_hex': None if aec_cur is None else '%#010x' % aec_cur,
            'default': aec_def,
            'capabilities': aec_cap,  # bit 0 saveable, 1 namespace specific, 2 changeable
            'changeable': None if aec_cap is None else bool(aec_cap & 4),
            'saveable': None if aec_cap is None else bool(aec_cap & 1),
        },
        **temps,
        'armed': None if aec_cur is None else bool(aec_cur & AEC_TEMPERATURE),
        'verdict': case,
        'why': why,
        'notes': notes,
        'errors': errors,
    }


def controllers(sysfs):
    """(nvmeN, its sysfs directory) for every NVMe controller, in name order."""
    for ctrl in sorted(glob.glob(os.path.join(sysfs, 'nvme*'))):
        yield os.path.basename(ctrl), ctrl


def describe(ctrl):
    """(serial, the identity fields) from a controller's sysfs directory."""
    def rd(f):
        with open(os.path.join(ctrl, f)) as fh:
            return fh.read().strip()
    return rd('serial'), {'ctrl': os.path.basename(ctrl), 'model': rd('model'), 'firmware': rd('firmware_rev'),
                          'state': rd('state')}


def collect(sysfs=SYSFS, read_log=read_smart_log):
    """Return ({serial: entry}, exit status) for every controller under sysfs."""
    out = {}
    rc = 0
    for name, ctrl in controllers(sysfs):
        try:
            serial, entry = describe(ctrl)
        except OSError as e:
            out['?' + name] = {'ctrl': name, 'error': str(e)}
            rc = 1
            continue
        try:
            entry.update(parse_smart_log(read_log('/dev/' + name)))
        except (OSError, ValueError, NvmeStatus) as e:
            entry['error'] = str(e)
            rc = 1
        out[serial] = entry
    return out, rc


def collect_probe(sysfs=SYSFS, transport=None):
    """Return ({serial: probe}, exit status): 1 when a controller could not be decided."""
    out = {}
    rc = 0
    for name, ctrl in controllers(sysfs):
        try:
            serial, entry = describe(ctrl)
        except OSError as e:
            out['?' + name] = {'ctrl': name, 'error': str(e)}
            rc = 1
            continue
        try:
            idc, probe = probe_controller('/dev/' + name, transport=transport)
            entry.update(probe)
            if idc['serial'] and idc['serial'] != serial:
                entry['notes'].append('Identify reports serial %s' % idc['serial'])
        except (OSError, ValueError, NvmeStatus, NotAllowed) as e:
            entry['error'] = str(e)
            entry['verdict'] = 'unknown'
            rc = 1
        out[serial] = entry
    return out, rc


def main(argv):
    if argv in ([], ['--probe']):
        out, rc = collect_probe() if argv else collect()
    else:
        print('usage: nvme-health.py [--probe]', file=sys.stderr)
        return 2
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
