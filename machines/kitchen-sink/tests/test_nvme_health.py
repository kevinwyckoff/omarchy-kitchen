#!/usr/bin/python3
# Tests for lib/nvme-health.py: the SMART/Health log decoding, the per-serial
# collection over a fake sysfs tree, and the JSON the check-up reads.
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
        size = struct.calcsize('<BBHIIIQQIIIIIIIIII')
        self.assertEqual(size, 72)
        self.assertEqual(nvme.NVME_IOCTL_ADMIN_CMD, (3 << 30) | (size << 16) | (ord('N') << 8) | 0x41)


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


if __name__ == '__main__':
    unittest.main()
