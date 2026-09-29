#!/usr/bin/python3
# Tests for lib/nvme-health.py: the SMART/Health log decoding, the per-serial
# collection over a fake sysfs tree, the JSON the check-up reads, and the
# read-only probe for experiment X0: its hard allowlist of admin commands, the
# case A/B verdict, and every command it sends to a fake drive.
import ast
import ctypes
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, '..', 'lib', 'nvme-health.py')

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('nvme_health', HELPER)
nvme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nvme)


def smart_log(**f):
    """A 512-byte SMART/Health log page with the given fields set."""
    b = bytearray(512)
    b[0] = f.get('critical_warning', 0)
    b[1:3] = (f.get('temperature_c', 34) + 273).to_bytes(2, 'little')
    b[3] = f.get('available_spare', 100)
    b[4] = f.get('spare_threshold', 4)
    b[5] = f.get('percentage_used', 17)
    for offset, key in ((32, 'data_units_read'), (48, 'data_units_written'), (112, 'power_cycles'),
                        (128, 'power_on_hours'), (144, 'unsafe_shutdowns'), (160, 'media_errors'),
                        (176, 'error_log_entries')):
        b[offset:offset + 16] = f.get(key, 0).to_bytes(16, 'little')
    b[192:196] = f.get('warn_temp_minutes', 0).to_bytes(4, 'little')
    b[196:200] = f.get('crit_temp_minutes', 0).to_bytes(4, 'little')
    return bytes(b)


def fake_sysfs(root, controllers):
    for name, attrs in controllers.items():
        os.makedirs(os.path.join(root, name))
        for attr, value in attrs.items():
            with open(os.path.join(root, name, attr), 'w') as fh:
                fh.write(value + '\n')


WDC = {'serial': 'DATADRIVE0001', 'model': 'WDC WDS512G1X0C-00ENX0', 'firmware_rev': 'B35500WD', 'state': 'live'}
FIRECUDA = {'serial': 'SYSDRIVE0001', 'model': 'Seagate FireCuda 520 SSD ZP500GM30002', 'firmware_rev': 'STNSC014',
            'state': 'live'}


class ParseSmartLog(unittest.TestCase):
    def test_fields(self):
        # The WDC data drive's values from kitchen-sink on 2026-09-28
        e = nvme.parse_smart_log(smart_log(
            temperature_c=34, available_spare=100, spare_threshold=4, percentage_used=17,
            data_units_read=77519531, data_units_written=87832031, power_cycles=3792, power_on_hours=29508,
            unsafe_shutdowns=1718, media_errors=0, error_log_entries=1, warn_temp_minutes=210, crit_temp_minutes=2))
        self.assertEqual(e['temperature_c'], 34)
        self.assertEqual(e['percentage_used'], 17)
        self.assertEqual(e['available_spare'], 100)
        self.assertEqual(e['spare_threshold'], 4)
        self.assertEqual(e['power_on_hours'], 29508)
        self.assertEqual(e['unsafe_shutdowns'], 1718)
        self.assertEqual(e['error_log_entries'], 1)
        self.assertEqual(e['warn_temp_minutes'], 210)
        self.assertEqual(e['crit_temp_minutes'], 2)
        self.assertEqual(e['data_read_tb'], 39.69)  # data units are 1000 x 512 bytes
        self.assertEqual(e['data_written_tb'], 44.97)

    def test_warnings_and_big_counters(self):
        e = nvme.parse_smart_log(smart_log(critical_warning=0x04, media_errors=2 ** 70, available_spare=3))
        self.assertEqual(e['critical_warning'], 4)
        self.assertEqual(e['media_errors'], 2 ** 70)  # 128-bit little-endian counters
        self.assertEqual(e['available_spare'], 3)

    def test_short_log(self):
        with self.assertRaises(ValueError):
            nvme.parse_smart_log(b'\0' * 100)

    def test_ioctl_number(self):
        # _IOWR('N', 0x41, struct nvme_admin_cmd) with a 72-byte command
        size = nvme.ADMIN_CMD.size
        self.assertEqual(size, 72)
        self.assertEqual(struct.calcsize('<BBHIIIQQIIIIIIIIII'), size)
        self.assertEqual(nvme.NVME_IOCTL_ADMIN_CMD, (3 << 30) | (size << 16) | (ord('N') << 8) | 0x41)
        self.assertEqual(nvme.RESULT_OFFSET, size - 4)  # __u32 result is the last field


class Collect(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        fake_sysfs(self.root, {'nvme0': WDC, 'nvme1': FIRECUDA})

    def tearDown(self):
        self.tmp.cleanup()

    def test_keyed_by_serial(self):
        logs = {'/dev/nvme0': smart_log(percentage_used=17), '/dev/nvme1': smart_log(percentage_used=1)}
        out, rc = nvme.collect(self.root, read_log=logs.__getitem__)
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(out), ['DATADRIVE0001', 'SYSDRIVE0001'])
        self.assertEqual(out['SYSDRIVE0001']['ctrl'], 'nvme1')
        self.assertEqual(out['SYSDRIVE0001']['percentage_used'], 1)
        self.assertEqual(out['DATADRIVE0001']['model'], 'WDC WDS512G1X0C-00ENX0')

    def test_one_drive_fails(self):
        def read(dev):
            if dev == '/dev/nvme0':
                raise OSError(5, 'Input/output error')
            return smart_log()
        out, rc = nvme.collect(self.root, read_log=read)
        self.assertEqual(rc, 1)
        self.assertIn('Input/output error', out['DATADRIVE0001']['error'])
        self.assertNotIn('error', out['SYSDRIVE0001'])

    def test_missing_attribute(self):
        os.remove(os.path.join(self.root, 'nvme1', 'serial'))
        out, rc = nvme.collect(self.root, read_log=lambda dev: smart_log())
        self.assertEqual(rc, 1)
        self.assertIn('error', out['?nvme1'])
        self.assertIn('DATADRIVE0001', out)

    def test_script_output(self):
        # As a script, over the fake tree: /dev/nvme0 and nvme1 are not NVMe
        # devices here, so each gets an error entry, still valid JSON, exit 1.
        env = dict(os.environ, NVME_HEALTH_SYSFS=self.root, PYTHONDONTWRITEBYTECODE='1')
        p = subprocess.run([sys.executable, HELPER], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        out = json.loads(p.stdout)
        self.assertEqual(sorted(out), ['DATADRIVE0001', 'SYSDRIVE0001'])
        self.assertIn('error', out['SYSDRIVE0001'])


# ---- experiment X0: the read-only probe ------------------------------------------

def identify(serial='SYSDRIVE0001', ver=0x10300, oaes=0x200, aerl=3, wctemp=363, cctemp=368, oncs=0x5D):
    """A 4096-byte Identify Controller page with the fields the probe reads. The
    defaults are the FireCuda's, as X0 read them on kitchen-sink on 2026-09-29."""
    b = bytearray(4096)
    b[4:24] = serial.encode().ljust(20)
    b[24:64] = b'Seagate FireCuda 520 SSD ZP500GM30002'.ljust(40)
    b[64:72] = b'STNSC014'
    b[80:84] = ver.to_bytes(4, 'little')
    b[92:96] = oaes.to_bytes(4, 'little')
    b[259] = aerl
    b[266:268] = wctemp.to_bytes(2, 'little')
    b[268:270] = cctemp.to_bytes(2, 'little')
    b[520:522] = oncs.to_bytes(2, 'little')
    return bytes(b)


def features(aec=0x200, aec_default=0, aec_caps=4, over=363, over_default=363, under=213, under_default=213):
    """Get Features answers keyed by (FID, SEL, CDW11), as a controller would give
    them; the defaults are the FireCuda's on kitchen-sink."""
    return {(0x0B, 0, 0): aec, (0x0B, 1, 0): aec_default, (0x0B, 3, 0): aec_caps,
            (0x04, 0, 0): over, (0x04, 1, 0): over_default,
            (0x04, 0, 1 << 20): under, (0x04, 1, 1 << 20): under_default}


class FakeDrive:
    """Stands in for the kernel's admin passthrough: decodes each packed struct
    nvme_admin_cmd, records it, fills the data buffer and the result dword, and
    answers Invalid Field in Command for a feature it does not know."""

    def __init__(self, ident=None, feats=None, log=None):
        self.ident = identify() if ident is None else ident
        self.feats = features() if feats is None else feats
        self.log = log or smart_log()
        self.sent = []

    def __call__(self, dev, cmd):
        f = nvme.ADMIN_CMD.unpack(bytes(cmd))
        opcode, nsid, addr, data_len, cdw10, cdw11 = f[0], f[3], f[7], f[9], f[10], f[11]
        self.sent.append({'dev': dev, 'opcode': opcode, 'nsid': nsid, 'cdw10': cdw10, 'cdw11': cdw11})
        result = 0
        if opcode == 0x06:
            if isinstance(self.ident, int):
                return self.ident  # an Identify the controller refuses
            ctypes.memmove(addr, self.ident, data_len)
        elif opcode == 0x02:
            ctypes.memmove(addr, self.log, data_len)
        elif opcode == 0x0A:
            key = (cdw10 & 0xFF, (cdw10 >> 8) & 7, cdw11)
            if key not in self.feats:
                return 0x4002  # DNR, Invalid Field in Command
            result = self.feats[key]
        else:
            raise AssertionError('opcode %#04x reached the drive' % opcode)
        struct.pack_into('<I', cmd, nvme.RESULT_OFFSET, result)
        return 0


def must_not_send(dev, cmd):
    raise AssertionError('a refused command reached the transport')


class Allowlist(unittest.TestCase):
    def test_only_three_read_only_opcodes(self):
        self.assertEqual(set(nvme.ALLOWED_OPCODES), {0x02, 0x06, 0x0A})
        for opcode in nvme.ALLOWED_OPCODES:
            # bits 1:0 = 10b: data moves from the controller to the host only
            self.assertEqual(opcode & 3, 2, hex(opcode))
        self.assertEqual(set(nvme.ALLOWED_FEATURES), {0x04, 0x0B})

    def test_every_other_opcode_is_refused_before_the_device(self):
        for opcode in range(256):
            if opcode in nvme.ALLOWED_OPCODES:
                continue
            with self.assertRaises(nvme.NotAllowed, msg=hex(opcode)):
                nvme.admin_cmd('/dev/nvme0', opcode, cdw10=0x0B, transport=must_not_send)
        # Set Features, in particular, even for the very feature the probe reads
        with self.assertRaises(nvme.NotAllowed):
            nvme.admin_cmd('/dev/nvme0', 0x09, cdw10=0x0B, cdw11=0x202, transport=must_not_send)

    def test_only_the_allowed_page_cns_and_features(self):
        for low in range(256):
            if low != 0x02:
                self.assertRaises(nvme.NotAllowed, nvme.admin_cmd, '/dev/nvme0', 0x02, cdw10=low,
                                  transport=must_not_send)
            if low != 0x01:
                self.assertRaises(nvme.NotAllowed, nvme.admin_cmd, '/dev/nvme0', 0x06, cdw10=low,
                                  transport=must_not_send)
            if low not in (0x04, 0x0B):
                self.assertRaises(nvme.NotAllowed, nvme.admin_cmd, '/dev/nvme0', 0x0A, cdw10=low,
                                  transport=must_not_send)

    def test_one_way_to_the_kernel(self):
        # Nothing reaches the ioctl except through admin_cmd's check: the only
        # fcntl.ioctl call is in ioctl_transport, which only admin_cmd uses, and
        # the device is only ever opened read-only.
        with open(HELPER) as fh:
            tree = ast.parse(fh.read())
        where = {}
        for fn in ast.walk(tree):
            if isinstance(fn, ast.FunctionDef):
                for node in ast.walk(fn):
                    if isinstance(node, ast.Call) and ast.unparse(node.func) in ('fcntl.ioctl', 'ioctl'):
                        where.setdefault('ioctl', []).append(fn.name)
                    if isinstance(node, ast.Name) and node.id == 'ioctl_transport':
                        where.setdefault('transport', []).append(fn.name)
                    if isinstance(node, ast.Call) and ast.unparse(node.func) == 'os.open':
                        where.setdefault('open', []).append(ast.unparse(node.args[1]))
        self.assertEqual(where['ioctl'], ['ioctl_transport'])
        self.assertEqual(where['transport'], ['admin_cmd'])
        self.assertEqual(where['open'], ['os.O_RDONLY'])
        with open(HELPER) as fh:
            self.assertNotRegex(fh.read(), r'O_RDWR|O_WRONLY')

    def test_the_probe_sends_only_identify_and_get_features(self):
        drive = FakeDrive()
        nvme.probe_controller('/dev/nvme1', transport=drive)
        self.assertEqual({c['opcode'] for c in drive.sent}, {0x06, 0x0A})
        gets = [c for c in drive.sent if c['opcode'] == 0x0A]
        self.assertEqual({c['cdw10'] & 0xFF for c in gets}, {0x04, 0x0B})
        self.assertEqual({(c['cdw10'] >> 8) & 7 for c in gets}, {0, 1, 3})
        self.assertEqual([c['cdw10'] for c in drive.sent if c['opcode'] == 0x06], [0x01])

    def test_the_smart_read_sends_only_the_log_page(self):
        drive = FakeDrive(log=smart_log(percentage_used=9))
        self.assertEqual(nvme.parse_smart_log(nvme.read_smart_log('/dev/nvme0', transport=drive))['percentage_used'], 9)
        self.assertEqual([(c['opcode'], c['cdw10'] & 0xFF, c['nsid']) for c in drive.sent], [(0x02, 0x02, 0xFFFFFFFF)])


class Verdict(unittest.TestCase):
    def test_kernel_mask(self):
        # NVME_AEN_SUPPORTED in drivers/nvme/host/core.c, v7.2.5
        self.assertEqual(nvme.KERNEL_AEN_MASK, (1 << 8) | (1 << 9) | (1 << 11) | (1 << 31))

    def test_case_a_for_each_notice_bit(self):
        for bit in (8, 9, 11, 31):
            case, why = nvme.verdict(1 << bit)
            self.assertEqual(case, 'case A', bit)
            self.assertIn('no kernel rebuild', why)

    def test_case_b(self):
        # Telemetry (bit 10) and the other notices the kernel does not enable don't count
        for oaes in (0, 1 << 10, 1 << 12, 1 << 13, 1 << 14, 0x7FFF00FF & ~0x0B00):
            case, why = nvme.verdict(oaes)
            self.assertEqual(case, 'case B', hex(oaes))
            self.assertIn('never submits an Asynchronous Event Request', why)

    def test_mixed(self):
        case, why = nvme.verdict(0x1600)  # bits 9, 10, 12
        self.assertEqual(case, 'case A')
        self.assertIn('FID 0Bh = 0x200', why)


class Probe(unittest.TestCase):
    def test_firecuda_like_case_a(self):
        idc, p = nvme.probe_controller('/dev/nvme1', transport=FakeDrive())
        self.assertEqual(idc['serial'], 'SYSDRIVE0001')
        self.assertEqual(p['verdict'], 'case A')
        self.assertEqual(p['version'], '1.3.0')
        self.assertEqual(p['oaes_hex'], '0x00000200')
        self.assertEqual(p['oaes_notices'], ['firmware-activation'])
        self.assertEqual(p['kernel_aen_config'], 0x200)
        self.assertEqual(p['aerl'], 3)
        self.assertEqual((p['wctemp_c'], p['cctemp_c']), (90, 95))
        self.assertEqual(p['aen_config']['current'], 0x200)
        self.assertEqual(p['aen_config']['current_hex'], '0x00000200')
        self.assertEqual(p['aen_config']['default'], 0)
        self.assertTrue(p['aen_config']['changeable'])
        self.assertFalse(p['aen_config']['saveable'])
        # The kernel's hwmon on kitchen-sink: temp1_max 89850, temp1_min -60150
        self.assertEqual(p['temp_over'], {'current_k': 363, 'current_c': 90, 'default_k': 363, 'default_c': 90})
        self.assertEqual(p['temp_under']['current_c'], -60)
        self.assertIs(p['armed'], False)
        self.assertEqual((p['notes'], p['errors']), ([], []))

    def test_armed_and_lowered(self):
        _, p = nvme.probe_controller('/dev/nvme1', transport=FakeDrive(feats=features(aec=0x202, over=343)))
        self.assertIs(p['armed'], True)
        self.assertEqual(p['temp_over']['current_c'], 70)
        self.assertEqual(p['temp_over']['default_c'], 90)

    def test_case_b_drive(self):
        _, p = nvme.probe_controller('/dev/nvme0', transport=FakeDrive(identify(oaes=0), features(aec=0)))
        self.assertEqual(p['verdict'], 'case B')
        self.assertEqual(p['kernel_aen_config'], 0)
        self.assertIs(p['armed'], False)

    def test_kernel_setting_missing_is_noted(self):
        _, p = nvme.probe_controller('/dev/nvme1', transport=FakeDrive(feats=features(aec=0)))
        self.assertEqual(p['verdict'], 'case A')
        self.assertIn('Failed to configure AEN', p['notes'][0])

    def test_no_select_field(self):
        # An older controller without ONCS bit 4: current values only, no guessing
        drive = FakeDrive(identify(ver=0, oncs=0x0F))
        _, p = nvme.probe_controller('/dev/nvme0', transport=drive)
        self.assertEqual({(c['cdw10'] >> 8) & 7 for c in drive.sent if c['opcode'] == 0x0A}, {0})
        self.assertEqual(p['version'], 'unreported (before 1.2)')
        self.assertIsNone(p['aen_config']['default'])
        self.assertIsNone(p['temp_over']['default_c'])
        self.assertEqual(p['temp_over']['current_c'], 90)
        self.assertIn('ONCS bit 4 is clear', p['notes'][0])

    def test_a_refused_feature_is_an_error_not_a_crash(self):
        feats = features()
        del feats[(0x0B, 3, 0)]
        _, p = nvme.probe_controller('/dev/nvme1', transport=FakeDrive(feats=feats))
        self.assertEqual(p['verdict'], 'case A')
        self.assertIsNone(p['aen_config']['capabilities'])
        self.assertIn('Invalid Field in Command', p['errors'][0])

    def test_status_error(self):
        e = nvme.NvmeStatus(0x0A, 0x4002)
        self.assertIn('Get Features failed: NVMe status 0x4002 (Invalid Field in Command)', str(e))


class CollectProbe(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        fake_sysfs(self.root, {'nvme0': WDC, 'nvme1': FIRECUDA})
        # Both drives as experiment X0 read them on kitchen-sink on 2026-09-29
        self.drives = {'/dev/nvme0': FakeDrive(identify('DATADRIVE0001', ver=0x10200, oaes=0, aerl=7, wctemp=358,
                                                        cctemp=361, oncs=0x16),
                                               features(aec=0, over=358, over_default=358, under=0,
                                                        under_default=0)),
                       '/dev/nvme1': FakeDrive()}

    def tearDown(self):
        self.tmp.cleanup()

    def transport(self, dev, cmd):
        return self.drives[dev](dev, cmd)

    def test_keyed_by_serial(self):
        out, rc = nvme.collect_probe(self.root, transport=self.transport)
        self.assertEqual(rc, 0)
        self.assertEqual(sorted(out), ['DATADRIVE0001', 'SYSDRIVE0001'])
        self.assertEqual(out['DATADRIVE0001']['ctrl'], 'nvme0')
        # The WDC: no notices at all, so the kernel never wrote FID 0Bh (it reads 0)
        self.assertEqual(out['DATADRIVE0001']['oaes_notices'], [])
        self.assertEqual(out['DATADRIVE0001']['verdict'], 'case B')
        self.assertEqual(out['DATADRIVE0001']['version'], '1.2.0')
        self.assertEqual(out['DATADRIVE0001']['temp_under']['current_c'], -273)
        self.assertEqual(out['SYSDRIVE0001']['verdict'], 'case A')
        self.assertEqual(out['SYSDRIVE0001']['model'], FIRECUDA['model'])

    def test_identify_fails(self):
        self.drives['/dev/nvme0'].ident = 0x4002
        out, rc = nvme.collect_probe(self.root, transport=self.transport)
        self.assertEqual(rc, 1)
        self.assertEqual(out['DATADRIVE0001']['verdict'], 'unknown')
        self.assertIn('Identify failed: NVMe status 0x4002', out['DATADRIVE0001']['error'])
        self.assertEqual(out['SYSDRIVE0001']['verdict'], 'case A')

    def test_the_checkup_fixture_has_the_probe_shape(self):
        # tests/fixtures/nvme-probe.json feeds the check-up. It is kitchen-sink's real
        # X0 output (serials replaced), so these fakes must reproduce it exactly.
        out, _ = nvme.collect_probe(self.root, transport=self.transport)
        with open(os.path.join(HERE, 'fixtures', 'nvme-probe.json')) as fh:
            self.assertEqual(json.load(fh), out)

    def test_script(self):
        env = dict(os.environ, NVME_HEALTH_SYSFS=self.root, PYTHONDONTWRITEBYTECODE='1')
        p = subprocess.run([sys.executable, HELPER, '--probe'], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)  # the fake tree's /dev/nvme0 is no NVMe device
        out = json.loads(p.stdout)
        self.assertEqual(out['SYSDRIVE0001']['verdict'], 'unknown')
        p = subprocess.run([sys.executable, HELPER, '--bogus'], env=env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)
        self.assertIn('usage', p.stderr)


class SmartStatus(unittest.TestCase):
    def test_an_error_status_is_an_error_not_a_zeroed_log(self):
        # A log the controller refused used to decode as all zeros (-273C, no warnings)
        def refuse(dev, cmd):
            return 0x4002
        with self.assertRaises(nvme.NvmeStatus):
            nvme.read_smart_log('/dev/nvme0', transport=refuse)
        tmp = tempfile.TemporaryDirectory()
        fake_sysfs(tmp.name, {'nvme0': WDC})

        def read(dev):
            return nvme.read_smart_log(dev, transport=refuse)
        out, rc = nvme.collect(tmp.name, read_log=read)
        tmp.cleanup()
        self.assertEqual(rc, 1)
        self.assertIn('NVMe status 0x4002', out['DATADRIVE0001']['error'])


if __name__ == '__main__':
    unittest.main()
