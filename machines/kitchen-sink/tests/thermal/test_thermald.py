#!/usr/bin/python3
# Tests for lib/kitchen-thermald.py: the settings parser, the level, hysteresis,
# dwell and rate-limit logic, and the whole daemon against a fake sysfs tree
# (the real nct6799 attribute set from tests/thermal/fixtures), fake uevents
# (a socketpair), simulated poll() wake-ups (pipes), a fake NVMe admin
# interface, a fake NVML backend (and, when a C compiler is present, a fake
# libnvidia-ml built from fake_nvml.c), and fake systemd-run and journalctl
# programs that record what they were asked to do.
import errno
import importlib.util
import io
import json
import os
import pwd
import queue
import select
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
DAEMON = os.path.join(ROOT, 'lib', 'kitchen-thermald.py')
FIXTURE = os.path.join(HERE, 'fixtures', 'nct6799.txt')

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('kitchen_thermald', DAEMON)
kt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kt)

ME = pwd.getpwuid(os.getuid()).pw_name
NCT_DEVPATH = '/devices/platform/nct6775.656/hwmon/hwmon7'


# ---- fakes ----------------------------------------------------------------------------


def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(f'{value}\n')


def load(path):
    with open(path) as fh:
        return json.load(fh)


def json_lines(path):
    with open(path) as fh:
        return [json.loads(line) for line in fh]


class FakeSysfs:
    """A /sys with the nct6799 (from the fixture), optional nct6775 notify
    parameters and NVMe controllers, laid out as the kernel does: class links
    pointing into /devices."""

    def __init__(self, root, notify=True, hwmon='hwmon7'):
        self.root = root
        self.hwmon = hwmon
        os.makedirs(f'{root}/class/hwmon')
        os.makedirs(f'{root}/class/nvme')
        with open(FIXTURE) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith('#'):
                    k, _, v = line.partition('=')
                    write(f'{self.dev}/{k}', v)
        self.link_hwmon(hwmon)
        if notify:
            self.params(notify_interval=1000, notify_pwm='Y', notify_pwm_delta=3, notify_temp_delta=1000)

    @property
    def devdir(self):
        return f'{self.root}/devices/platform/nct6775.656/hwmon'

    @property
    def dev(self):
        return f'{self.devdir}/{self.hwmon}'

    @property
    def devpath(self):
        return f'/devices/platform/nct6775.656/hwmon/{self.hwmon}'

    def link_hwmon(self, name):
        os.symlink(f'../../devices/platform/nct6775.656/hwmon/{name}', f'{self.root}/class/hwmon/{name}')

    def params(self, **kv):
        for k, v in kv.items():
            write(f'{self.root}/module/nct6775_core/parameters/{k}', v)

    def set(self, attr, value):
        write(f'{self.dev}/{attr}', value)

    def get(self, attr):
        with open(f'{self.dev}/{attr}') as fh:
            return fh.read().strip()

    def renumber(self, new):
        """Unload and reload nct6775: the device comes back as another hwmonN."""
        os.unlink(f'{self.root}/class/hwmon/{self.hwmon}')
        os.rename(self.dev, f'{self.devdir}/{new}')
        self.hwmon = new
        self.link_hwmon(new)

    def reload_same_number(self):
        """Unload and reload nct6775 at the same hwmonN: every file is new."""
        tmp = self.dev + '.new'
        shutil.copytree(self.dev, tmp)
        shutil.rmtree(self.dev)
        os.rename(tmp, self.dev)

    def add_nvme(self, ctrl, hwmon, serial, model, temp_c=35, over_k=358, under_k=0):
        pci = f'{self.root}/devices/pci0000:00/0000:00:02.2/0000:0e:0{ctrl[-1]}.0/nvme/{ctrl}'
        for k, v in (('serial', serial), ('model', model), ('firmware_rev', 'FW1'), ('state', 'live')):
            write(f'{pci}/{k}', v)
        hw = f'{pci}/{hwmon}'
        write(f'{hw}/name', 'nvme')
        write(f'{hw}/temp1_input', int(round(temp_c + 273.15)) * 1000 - 273150)
        write(f'{hw}/temp1_max', over_k * 1000 - 273150)
        write(f'{hw}/temp1_min', under_k * 1000 - 273150)
        write(f'{hw}/temp1_crit', 361 * 1000 - 273150)
        write(f'{hw}/temp1_alarm', 0)
        rel = os.path.relpath(pci, f'{self.root}/class/nvme')
        os.symlink(rel, f'{self.root}/class/nvme/{ctrl}')
        os.symlink(os.path.relpath(hw, f'{self.root}/class/hwmon'), f'{self.root}/class/hwmon/{hwmon}')
        return hw

    def snapshot(self):
        """Every file under the nct6799 with its content and mtime."""
        out = {}
        for dirpath, _, files in os.walk(self.dev):
            for f in files:
                p = os.path.join(dirpath, f)
                with open(p) as fh:
                    out[os.path.relpath(p, self.dev)] = (fh.read(), os.stat(p).st_mtime_ns)
        return out


class PipeWatch:
    """A stand-in for a sysfs attribute descriptor: poll() wakes when the test
    calls wake(), as sysfs_notify() would; reads return the file's content.
    Like a kernfs descriptor it belongs to the file it opened: alive() is
    false once the path holds another file (a driver reload)."""

    mask = select.POLLIN

    def __init__(self, path):
        if not os.path.exists(path):
            raise FileNotFoundError(path)
        self.path = path
        self.ino = os.stat(path).st_ino
        self.r, self.w = os.pipe()
        os.set_blocking(self.r, False)

    def alive(self):
        try:
            return os.stat(self.path).st_ino == self.ino
        except OSError:
            return False

    def fileno(self):
        return self.r

    def read(self):
        try:
            os.read(self.r, 4096)
        except (BlockingIOError, TypeError):
            pass
        with open(self.path) as fh:
            return fh.read().strip()

    def wake(self):
        os.write(self.w, b'!')

    def close(self):
        if self.r is not None:
            os.close(self.r)
            os.close(self.w)
            self.r = None


class KernfsWatch(PipeWatch):
    """Reads like a real sysfs descriptor after its file is gone or replaced:
    ENODEV, as kernfs answers."""

    def read(self):
        if not self.alive():
            try:
                os.read(self.r, 4096)
            except (BlockingIOError, TypeError):
                pass
            raise OSError(errno.ENODEV, 'No such device')
        return super().read()


class Watches:
    def __init__(self, cls=PipeWatch):
        self.by_path = {}
        self.cls = cls

    def __call__(self, path):
        w = self.cls(path)
        self.by_path[path] = w
        return w

    def wake(self, path):
        self.by_path[path].wake()

    def open_paths(self):
        return sorted(p for p, w in self.by_path.items() if w.r is not None)


class FakeUevents:
    def __init__(self):
        self.ours, self.theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.source = kt.UeventSocket(self.theirs, check_sender=False)
        self.seq = 0

    def send(self, action, devpath, subsystem, **env):
        self.seq += 1
        parts = [f'{action}@{devpath}', f'ACTION={action}', f'DEVPATH={devpath}', f'SUBSYSTEM={subsystem}']
        parts += [f'{k}={v}' for k, v in env.items()] + [f'SEQNUM={self.seq}']
        self.ours.send('\0'.join(parts).encode() + b'\0')


class OverflowOnce(kt.UeventSocket):
    def __init__(self, sock):
        super().__init__(sock, check_sender=False)
        self.overflow = False

    def read(self):
        if self.overflow:
            self.overflow = False
            super().read()  # the kernel dropped what was queued
            raise kt.UeventOverflow()
        return super().read()


class JournalSink:
    """A datagram socket standing in for /run/systemd/journal/socket.

    A thread drains it as journald would: a container's network namespace
    queues only 10 datagrams (net.unix.max_dgram_qlen).
    """

    def __init__(self, path):
        self.path = path
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.bind(path)
        self.sock.settimeout(0.05)
        self.entries = []
        self.lock = threading.Lock()
        self.running = True
        self.thread = threading.Thread(target=self.drain, daemon=True)
        self.thread.start()

    def drain(self):
        while self.running:
            try:
                data = self.sock.recv(1 << 20)
            except socket.timeout:
                continue
            except OSError:
                return
            with self.lock:
                self.entries.append(self.parse(data))

    def close(self):
        self.running = False
        self.thread.join()
        self.sock.close()

    @staticmethod
    def parse(data):
        fields, i = {}, 0
        while i < len(data):
            nl = data.index(b'\n', i)
            line = data[i:nl]
            if b'=' in line:
                k, v = line.split(b'=', 1)
                fields[k.decode()] = v.decode()
                i = nl + 1
            else:
                n = int.from_bytes(data[nl + 1:nl + 9], 'little')
                fields[line.decode()] = data[nl + 9:nl + 9 + n].decode()
                i = nl + 9 + n + 1
        return fields

    def read(self):
        time.sleep(0.06)  # let the drain thread catch up with what was just sent
        with self.lock:
            return list(self.entries)

    def events(self, name=None):
        return [e for e in self.read() if 'KITCHEN_EVENT' in e and (name is None or e['KITCHEN_EVENT'] == name)]


class FakeAdmin:
    """The NVMe admin interface: Identify, Get/Set Features, per controller."""

    def __init__(self):
        self.ctrls = {}
        self.calls = []

    def add(self, ctrl, oaes, aen=None, wctemp=358, oncs=0x5f, sel_defaults=(358, 0)):
        self.ctrls[ctrl] = {'oaes': oaes, 'aen': aen if aen is not None else oaes & kt.OAES_KERNEL_AER,
                            'wctemp': wctemp, 'oncs': oncs, 'defaults': sel_defaults}

    def identify(self, ctrl):
        self.calls.append(('identify', ctrl))
        c = self.ctrls[ctrl]
        b = bytearray(4096)
        b[80:84] = (0x10300).to_bytes(4, 'little')
        b[92:96] = c['oaes'].to_bytes(4, 'little')
        b[266:268] = c['wctemp'].to_bytes(2, 'little')
        b[268:270] = (361).to_bytes(2, 'little')
        b[520:522] = c['oncs'].to_bytes(2, 'little')
        return bytes(b)

    def get_feature(self, ctrl, fid, sel=0, cdw11=0):
        self.calls.append(('get', ctrl, fid, sel, cdw11))
        c = self.ctrls[ctrl]
        if fid == kt.FID_AEN:
            return c['aen']
        if fid == kt.FID_TEMP_THRESH and sel == 1:
            return c['defaults'][1 if cdw11 & kt.THSEL_UNDER else 0]
        raise kt.NvmeError('unexpected get')

    def set_aen_config(self, ctrl, value):
        self.calls.append(('set', ctrl, kt.FID_AEN, value))
        self.ctrls[ctrl]['aen'] = value
        return 0

    def sets(self):
        return [c for c in self.calls if c[0] == 'set']


class FakeNvml:
    """The NVML backend with a scripted event queue."""

    def __init__(self):
        self.q = queue.Queue()
        self.temp, self.pst = 35, 8
        self.ctr = {269: 0, 270: 0, 271: 0}
        self.reason_mask = 0x20
        self.calls = []
        self.registered = None
        self.init_rc = 0
        self.lost = False
        self.closed = False
        self.timeouts = []

    def error(self, rc):
        return f'fake error {rc}'

    def init(self):
        self.calls.append('init')
        return self.init_rc

    def shutdown(self):
        self.calls.append('shutdown')
        return 0

    def device(self, i):
        return 0, 'dev0'

    def supported_events(self, dev):
        return 0, 0xc19c

    def event_set(self):
        return 0, 'es'

    def register(self, dev, mask, es):
        self.registered = mask
        return 0

    def wait(self, es, timeout_ms):
        self.timeouts.append(timeout_ms)
        end = None if timeout_ms == kt.NVML_INFINITE else time.monotonic() + timeout_ms / 1000
        while True:
            try:
                return self.q.get(timeout=0.02)
            except queue.Empty:
                if self.closed or (end is not None and time.monotonic() >= end):
                    return (kt.NVML_TIMEOUT, 0, 0)

    def free(self, es):
        self.calls.append('free')

    def temperature(self, dev):
        return (kt.NVML_GPU_LOST, 0) if self.lost else (0, self.temp)

    def pstate(self, dev):
        return 0, self.pst

    def counters(self, dev):
        return 0, dict(self.ctr)

    def reasons(self, dev):
        self.calls.append('reasons')
        return 0, self.reason_mask

    def event(self, etype, data=0):
        self.q.put((0, etype, data))


FAKE_SYSTEMD_RUN = textwrap.dedent('''\
    #!/usr/bin/python3
    # Records what kitchen-thermald asked systemd-run to do.
    import json, os, sys, time
    start = time.time()
    time.sleep(float(os.environ.get('FAKE_RUN_SLEEP', '0')))
    with open(os.environ['FAKE_RUN_LOG'], 'a') as fh:
        fh.write(json.dumps({'argv': sys.argv[1:], 'start': start, 'end': time.time()}) + '\\n')
    sys.exit(int(os.environ.get('FAKE_RUN_RC', '0')))
''')

FAKE_SYSTEMCTL = textwrap.dedent('''\
    #!/usr/bin/python3
    # PID 1 as the daemon asks it: is the user's manager active (a file per
    # uid in FAKE_MANAGERS says so), and the service's main PID.
    import os, sys
    a = sys.argv[1:]
    if a[:2] == ['is-active', '--quiet'] and a[2].startswith('user@'):
        uid = a[2][5:].split('.')[0]
        sys.exit(0 if os.path.exists(os.path.join(os.environ['FAKE_MANAGERS'], uid)) else 3)
    if a[:3] == ['show', '-P', 'MainPID']:
        print(os.environ.get('FAKE_MAINPID', '0'))
        sys.exit(0)
    sys.exit(1)
''')

FAKE_JOURNALCTL = textwrap.dedent('''\
    #!/usr/bin/python3
    # Plays kernel log lines as `journalctl -k -f -o json` would, then follows.
    import json, os, sys, time
    with open(os.environ['FAKE_JCTL_LOG'], 'a') as fh:
        fh.write(json.dumps(sys.argv[1:]) + '\\n')
    if os.environ.get('FAKE_JCTL_NO_GREP') and '--grep' in sys.argv:
        sys.exit(1)  # "Compiled without pattern matching support"
    for line in open(os.environ['FAKE_JCTL_LINES']):
        print(json.dumps({'MESSAGE': line.rstrip('\\n')}), flush=True)
    time.sleep(3600)
''')


def run_until(d, pred, timeout=5.0, step=0.02):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        d.step(step)
        if pred():
            return True
    return pred()


def idle(d):
    """Nothing due but the once-a-minute parameter check (in event mode)."""
    return set(d.timers) <= {'superio-params'} and not d.delivery.deadlines()


def events(d, name=None, state=None):
    return [e for e in d.delivery.recent
            if (name is None or e['event'] == name) and (state is None or e['state'] == state)]


class Base(unittest.TestCase):
    """A temporary world: sysfs, /dev, /run/user, the journal and the fakes."""

    CONF = {}
    CHECKUP = ''
    NOTIFY = True

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='thermal-test-')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.sysfs = FakeSysfs(f'{self.tmp}/sys', notify=self.NOTIFY)
        os.makedirs(f'{self.tmp}/dev')
        os.makedirs(f'{self.tmp}/bin')
        for name, body in (('systemd-run', FAKE_SYSTEMD_RUN), ('journalctl', FAKE_JOURNALCTL),
                           ('systemctl', FAKE_SYSTEMCTL)):
            write(f'{self.tmp}/bin/{name}', body)
            os.chmod(f'{self.tmp}/bin/{name}', 0o755)
        self.run_log = f'{self.tmp}/systemd-run.log'
        self.jctl_log = f'{self.tmp}/journalctl.log'
        write(f'{self.tmp}/kmsg-lines', '')
        self.env = {'FAKE_RUN_LOG': self.run_log, 'FAKE_JCTL_LOG': self.jctl_log,
                    'FAKE_JCTL_LINES': f'{self.tmp}/kmsg-lines', 'FAKE_MANAGERS': f'{self.tmp}/managers'}
        for k in ('FAKE_RUN_SLEEP', 'FAKE_RUN_RC', 'FAKE_JCTL_NO_GREP', 'FAKE_MAINPID'):
            os.environ.pop(k, None)
        os.environ.update(self.env)
        self.manager(True)  # the user is logged in: their manager (user@UID.service) runs
        self.paths = {'sysfs': self.sysfs.root, 'dev': f'{self.tmp}/dev', 'journal': f'{self.tmp}/journal.sock'}
        self.journal = JournalSink(self.paths['journal'])
        self.addCleanup(self.journal.close)
        self.watches = Watches()
        self.uev = FakeUevents()
        self.addCleanup(self.uev.ours.close)
        self.addCleanup(self.uev.theirs.close)
        self.admin = FakeAdmin()
        self.nvml = FakeNvml()
        self.addCleanup(setattr, self.nvml, 'closed', True)
        self.conf = self.write_conf(self.CONF)
        self.checkup = f'{self.tmp}/checkup.conf'
        write(self.checkup, self.CHECKUP)
        self.daemons = []
        self.addCleanup(self.stop_daemons)

    def manager(self, up, name=ME):
        """Whether the fake PID 1 says user@UID.service is active."""
        path = f'{self.tmp}/managers/{pwd.getpwnam(name).pw_uid}'
        if up:
            write(path, 'active')
        elif os.path.exists(path):
            os.unlink(path)
        for d in getattr(self, 'daemons', []):
            d.delivery.manager_seen.clear()

    def write_conf(self, extra):
        base = {
            'CPU_DWELL_SECS': 0.3, 'CPU_CRIT_TOAST_SECS': 0.8, 'FAN_RAMP_MIN_SECS': 0.4, 'FAN_STALL_SECS': 0.3,
            'DEGRADED_POLL_SECS': 0.2, 'GPU_BUSY_TIMEOUT': 0.2, 'GPU_THROTTLE_TIMEOUT': 0.1,
            'GPU_THROTTLE_QUIET_SECS': 0.3, 'GPU_COALESCE_MS': 30, 'HOOK_USER': ME,
            'SYSTEMD_RUN': f'{self.tmp}/bin/systemd-run', 'JOURNALCTL': f'{self.tmp}/bin/journalctl',
            'SYSTEMCTL': f'{self.tmp}/bin/systemctl',
            'STATE_FILE': f'{self.tmp}/state.json', 'NVML': 1, 'KMSG_FOLLOW': 0, 'NVML_RETRY_SECS': 3600,
        }
        base.update(extra)
        path = f'{self.tmp}/thermal.conf'
        with open(path, 'w') as fh:
            for k, v in base.items():
                fh.write(f'{k}="{v}"\n')
        os.chmod(path, 0o644)
        return path

    def daemon(self, uevents=None, **kw):
        d = kt.Daemon(self.conf, self.checkup, paths=self.paths, uevents=uevents or self.uev.source,
                      watch_factory=self.watches, nvme_admin=self.admin, nvml_factory=lambda: self.nvml,
                      signals=False, **kw)
        self.daemons.append(d)
        return d

    def stop_daemons(self):
        self.nvml.closed = True
        for d in self.daemons:
            if d.nvml:
                d.nvml.stopping = True
            d.kmsg.stop()
            if d.kmsg.proc is not None:
                d.kmsg.proc.stdout.close()
            if d.journal.sock is not None:
                d.journal.sock.close()
            for w in d.superio.watches.values():
                w.close()
            for r in (d.delivery.hooks, d.delivery.toasts):
                if r.proc:
                    r.proc.kill()
                    r.proc.wait()
                    r.proc.stderr.close()

    def wake(self, attr, value):
        self.sysfs.set(attr, value)
        self.watches.wake(f'{self.sysfs.dev}/{attr}')

    def runs(self):
        try:
            return json_lines(self.run_log)
        except FileNotFoundError:
            return []


# ---- pure logic --------------------------------------------------------------------------


class Settings(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    def conf(self, text):
        p = f'{self.tmp}/c.conf'
        with open(p, 'w') as fh:
            fh.write(textwrap.dedent(text))
        os.chmod(p, 0o644)
        return p

    def test_values_quotes_comments(self):
        p = self.conf('''\
            # a comment
            CPU_WARN=88
            export CPU_CRIT="93"
            NOTIFY_EVENTS='fan-stall gpu-xid'  # trailing comment
            NVME_AEN_MASK=0x07
            CPU_DWELL_SECS=2.5
            NVME_scratch_WARN=72
            HOOK_USER=
            ''')
        cfg, roles, warnings = kt.load_config(p, '/nonexistent')
        self.assertEqual(warnings, [])
        self.assertEqual(cfg['CPU_WARN'], 88)
        self.assertEqual(cfg['CPU_CRIT'], 93)
        self.assertEqual(cfg['NOTIFY_EVENTS'], 'fan-stall gpu-xid')
        self.assertEqual(cfg['NVME_AEN_MASK'], 7)
        self.assertEqual(cfg['CPU_DWELL_SECS'], 2.5)
        self.assertEqual(cfg["NVME_scratch_WARN"], 72)
        self.assertEqual(cfg['HOOK_USER'], 'kevinwyckoff')  # empty: checkup's DESKTOP_USER, then the default
        self.assertEqual(cfg['GPU_HOT'], 85)

    def test_bad_lines_are_ignored_with_a_warning(self):
        p = self.conf('''\
            CPU_WARN=not-a-number
            FAN_WATCH=fan2 fan5
            BOGUS_KEY=1
            this is not a setting
            ''')
        cfg, _, warnings = kt.load_config(p, '/nonexistent')
        self.assertEqual(cfg['CPU_WARN'], 90)
        self.assertEqual(cfg['FAN_WATCH'], '')
        self.assertEqual(len(warnings), 4, warnings)

    def test_roles_and_desktop_user_from_checkup_conf(self):
        c = self.conf('NVME_SERIALS="S0123:system S4567:data"\nDESKTOP_USER=alice\n')
        cfg, roles, _ = kt.load_config('/nonexistent', c)
        self.assertEqual(roles, {'S0123': 'system', 'S4567': 'data'})
        self.assertEqual(cfg['HOOK_USER'], 'alice')

    def test_file_others_can_write_is_ignored(self):
        p = self.conf('CPU_WARN=70\n')
        os.chmod(p, 0o666)
        values, warnings = kt.parse_kv_file(p, check_owner=True)
        self.assertEqual(values, {})
        self.assertIn('owned by root and not writable by others', warnings[0])
        if os.geteuid() == 0:  # as root, load_config applies the rule itself
            cfg, _, warnings = kt.load_config(p, '/nonexistent')
            self.assertEqual(cfg['CPU_WARN'], 90)

    def test_shipped_conf_matches_the_defaults(self):
        """Every setting is documented in thermal.conf with its real default."""
        shipped = {}
        with open(os.path.join(ROOT, 'etc', 'kitchen-sink', 'thermal.conf')) as fh:
            for line in fh:
                if line.startswith('#') and '=' in line and line[1:2].isupper():
                    k, _, v = line[1:].strip().partition('=')
                    shipped[k] = v.strip('"')
        self.assertEqual(sorted(shipped), sorted(kt.DEFAULTS))
        for k, v in shipped.items():
            want = kt.DEFAULTS[k]
            self.assertEqual(kt.to_number(v) if not isinstance(want, str) else v, want, k)


class Uevents(unittest.TestCase):
    def test_parse(self):
        env = kt.parse_uevent(b'change@/devices/platform/nct6775.656/hwmon/hwmon7\0ACTION=change\0'
                              b'DEVPATH=/devices/platform/nct6775.656/hwmon/hwmon7\0SUBSYSTEM=hwmon\0NAME=temp1_alarm\0SEQNUM=9\0')
        self.assertEqual(env['ACTION'], 'change')
        self.assertEqual(env['SUBSYSTEM'], 'hwmon')
        self.assertEqual(env['NAME'], 'temp1_alarm')
        self.assertIsNone(kt.parse_uevent(b'libudev\0\xfe\xed'))

    def test_nvme_aen(self):
        env = kt.parse_uevent(b'change@/devices/pci0000:00/0000:00:02.2/0000:0e:00.0/nvme/nvme1\0ACTION=change\0'
                              b'SUBSYSTEM=nvme\0NVME_AEN=0x020101\0')
        self.assertEqual(env['DEVPATH'], '/devices/pci0000:00/0000:00:02.2/0000:0e:00.0/nvme/nvme1')
        self.assertEqual(int(env['NVME_AEN'], 16), kt.AEN_TEMPERATURE)


class Levels(unittest.TestCase):
    def tracker(self):
        return kt.LevelTracker(warn=90, crit=95, hyst=5, dwell=10, held_after=60)

    def test_dwell_then_levels_and_hysteresis(self):
        t = self.tracker()
        self.assertEqual(t.observe(91, 0), [])
        self.assertEqual(t.next_deadline(), 10)
        self.assertEqual(t.evaluate(9.9), [])
        self.assertEqual(t.evaluate(10), [('start', 'warn')])
        self.assertEqual(t.observe(96, 12), [])
        self.assertEqual(t.observe(97, 22), [('change', 'crit')])
        self.assertEqual(t.observe(91, 30), [])          # crit holds down to 90
        self.assertEqual(t.observe(90, 31), [('change', 'warn')])
        self.assertEqual(t.observe(86, 32), [])          # warn holds down to 85
        self.assertEqual(t.observe(85, 33), [('end', 'warn')])
        self.assertIsNone(t.next_deadline())

    def test_a_dip_restarts_the_dwell(self):
        t = self.tracker()
        t.observe(91, 0)
        t.observe(89, 5)
        self.assertIsNone(t.next_deadline())
        t.observe(92, 6)
        self.assertEqual(t.evaluate(15), [])
        self.assertEqual(t.evaluate(16), [('start', 'warn')])

    def test_straight_to_crit_and_held(self):
        t = self.tracker()
        t.observe(96, 0)
        self.assertEqual(t.evaluate(10), [('start', 'crit')])
        self.assertEqual(t.next_deadline(), 60)
        self.assertEqual(t.evaluate(59), [])
        self.assertEqual(t.evaluate(60), [('held', 'crit')])
        self.assertEqual(t.evaluate(120), [])            # once per episode
        self.assertEqual(t.observe(80, 121), [('end', 'crit')])

    def test_a_spike_is_not_an_event(self):
        t = self.tracker()
        t.observe(97, 0)
        self.assertEqual(t.observe(70, 3), [])
        self.assertEqual(t.evaluate(30), [])


class NvmeLevels(unittest.TestCase):
    def test_bands_in_kelvin(self):
        warn, crit, clear = kt.kelvin(70), kt.kelvin(80), kt.kelvin(65)
        self.assertEqual((warn, crit, clear), (343, 353, 338))
        L = lambda t, cur: kt.nvme_level(t, cur, warn, crit, clear, 5)
        self.assertEqual(L(342, 'normal'), 'normal')
        self.assertEqual(L(343, 'normal'), 'warm')
        self.assertEqual(L(339, 'warm'), 'warm')
        self.assertEqual(L(338, 'warm'), 'normal')      # the drive fires at <= under
        self.assertEqual(L(353, 'warm'), 'hot')
        self.assertEqual(L(349, 'hot'), 'hot')
        self.assertEqual(L(348, 'hot'), 'warm')
        self.assertEqual(L(330, 'hot'), 'normal')

    def test_identify_fields(self):
        a = FakeAdmin()
        a.add('nvme0', oaes=0x100, wctemp=363)
        f = kt.parse_identify(a.identify('nvme0'))
        self.assertEqual((f['oaes'], f['wctemp'], f['cctemp'], f['ver']), (0x100, 363, 361, 0x10300))
        with self.assertRaises(kt.NvmeError):
            kt.parse_identify(b'\0' * 100)


class Gpu(unittest.TestCase):
    CFG = dict(kt.DEFAULTS, GPU_THROTTLE_QUIET_SECS=30)

    def test_timeouts(self):
        g = kt.GpuLogic(self.CFG)
        g.prime((30, 8, {269: 0, 270: 0, 271: 0}), 0)
        self.assertEqual(g.timeout_ms(), kt.NVML_INFINITE)     # idle: never time out
        g.pstate = 2
        self.assertEqual(g.timeout_ms(), 15000)
        g.throttling = {'sw-thermal'}
        self.assertEqual(g.timeout_ms(), 5000)
        g2 = kt.GpuLogic(dict(self.CFG, GPU_IDLE_HEARTBEAT=300))
        g2.prime((30, 8, {}), 0)
        self.assertEqual(g2.timeout_ms(), 300000)

    def test_throttle_and_hot(self):
        g = kt.GpuLogic(self.CFG)
        calls = []

        def reasons():
            calls.append(1)
            return 0x20
        self.assertEqual(g.prime((80, 0, {269: 5, 270: 0, 271: 0}), 0), [])
        self.assertEqual(g.observe((82, 0, {269: 5, 270: 0, 271: 0}), 1, reasons), [])
        self.assertEqual(calls, [])                  # the 14 ms call only when a counter moved
        out = g.observe((86, 0, {269: 9, 270: 0, 271: 0}), 2, reasons)
        self.assertEqual([(e.name, e.state) for e in out], [('gpu-throttle', 'start'), ('gpu-hot', 'start')])
        self.assertEqual(out[0].get('reason'), 'sw-thermal')
        self.assertEqual(g.active, ['sw-thermal'])
        out = g.observe((86, 0, {269: 9, 270: 4, 271: 0}), 3, reasons)
        self.assertEqual([(e.name, e.state, e.get('reason')) for e in out],
                         [('gpu-throttle', 'change', 'hw-thermal,sw-thermal')])
        self.assertEqual(g.observe((81, 0, {269: 9, 270: 4, 271: 0}), 20, reasons), [])
        out = g.observe((80, 5, {269: 9, 270: 4, 271: 0}), 33, reasons)
        self.assertEqual([(e.name, e.state) for e in out], [('gpu-throttle', 'end'), ('gpu-hot', 'end')])

    def test_kmsg_spoofs_are_not_gpu_errors(self):
        """Names that devices and users choose end up in kernel lines; the
        patterns hold only at the start, where the kernel puts its own prefix."""
        C = kt.classify_kmsg
        for line in ('input: NVRM: Xid (PCI:0000:01:00): 79 as /devices/virtual/input/input42',
                     'usb 1-3: Product: NVRM: Xid (PCI:0000:01:00): 79',
                     'input: NVRM GPU has fallen off the bus as /devices/virtual/input/input43',
                     'input: NVRM: GPU 0000:01:00.0: GPU has fallen off the bus. as /devices/virtual/input/input44',
                     'input: GPU over temperature range(SW CTF) detected as /devices/virtual/input/input45',
                     'hid-generic 0005:046D:B023.0007: input,hidraw6: BLUETOOTH HID v0.01 Keyboard '
                     '[amdgpu 0000:0f:00.0: Critical Temperature Fault(aka CTF) detected] on 00:1a:7d:da:71:13'):
            self.assertIsNone(C(line), line)
        # amdgpu's own line, but not from its pci device
        self.assertIsNone(C('amdgpu 0000:0f:00.0: amdgpu: ERROR: GPU over temperature range(SW CTF) detected!', 'input'))
        self.assertEqual(C('amdgpu 0000:0f:00.0: amdgpu: ERROR: GPU over temperature range(SW CTF) detected!', 'pci'),
                         ('ctf', 0, 'amdgpu'))

    def test_kmsg_lines(self):
        C = kt.classify_kmsg
        self.assertEqual(C('NVRM: Xid (PCI:0000:01:00): 79, pid=1234, name=Xorg, GPU has fallen off the bus.'),
                         ('xid', 79, 'nvidia'))
        self.assertEqual(C('NVRM: GPU 0000:01:00.0: GPU has fallen off the bus.'), ('lost', 0, 'nvidia'))
        self.assertEqual(C('amdgpu 0000:0f:00.0: amdgpu: ERROR: GPU over temperature range(SW CTF) detected!'),
                         ('ctf', 0, 'amdgpu'))
        self.assertEqual(C('amdgpu 0000:0f:00.0: amdgpu: ERROR: GPU HW Critical Temperature Fault(aka CTF) detected!'),
                         ('ctf', 0, 'amdgpu'))
        self.assertIsNone(C('amdgpu 0000:0f:00.0: amdgpu: ERROR: System is going to shutdown due to GPU SW CTF!'))
        self.assertIsNone(C('usb 1-3: new full-speed USB device number 5'))


class JournalProtocol(unittest.TestCase):
    def test_fields_and_binary_form(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        sink = JournalSink(f'{tmp}/j.sock')
        self.addCleanup(sink.close)
        j = kt.Journal(f'{tmp}/j.sock')
        j.send('line one\nline two', kt.WARNING, KITCHEN_EVENT='cpu-hot', kitchen_level='warn')
        j.sock.close()
        e = sink.read()[0]
        self.assertEqual(e['MESSAGE'], 'line one\nline two')
        self.assertEqual(e['PRIORITY'], '4')
        self.assertEqual(e['SYSLOG_IDENTIFIER'], 'kitchen-thermal')
        self.assertEqual(e['KITCHEN_LEVEL'], 'warn')

    def test_a_full_journal_queue_never_blocks(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        stalled = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)  # a journald that reads nothing
        stalled.bind(f'{tmp}/j.sock')
        self.addCleanup(stalled.close)
        # Fill its queue: one sender runs out of its own buffer first, so keep
        # adding senders until a fresh one is refused too.
        fillers = []
        self.addCleanup(lambda: [f.close() for f in fillers])
        while len(fillers) < 200:
            f = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            fillers.append(f)
            sent = 0
            while True:
                try:
                    f.sendto(b'x', socket.MSG_DONTWAIT, f'{tmp}/j.sock')
                    sent += 1
                except BlockingIOError:
                    break
            if sent == 0:
                break
        stream = io.StringIO()
        j = kt.Journal(f'{tmp}/j.sock', stream=stream)
        t0 = time.monotonic()
        j.send('still here', kt.WARNING)
        j.sock.close()
        self.assertLess(time.monotonic() - t0, 0.5)
        self.assertEqual(stream.getvalue(), '<4>still here\n')


# ---- the daemon, Super I/O ------------------------------------------------------------------


class SuperIOEvents(Base):
    def test_starts_in_event_mode_and_sleeps(self):
        before = self.sysfs.snapshot()
        d = self.daemon()
        d.start()
        self.assertEqual(d.superio.mode, 'event')
        self.assertEqual(d.superio.hwmon, 'hwmon7')
        self.assertEqual(d.superio.cpu_attr, 'temp13_input')
        # pwm1 is manual (enable 1): not watched. Every fan input is.
        self.assertEqual(sorted(d.superio.watches), ['fan1_input', 'fan2_input', 'fan3_input', 'fan4_input',
                                                     'fan5_input', 'fan7_input', 'pwm2', 'pwm3', 'pwm4', 'pwm5',
                                                     'pwm7', 'temp13_input'])
        # The stuck voltage alarms and the latched intrusion alarm make no event.
        self.assertIn('in1_alarm', d.superio.stuck)
        self.assertIn('intrusion0_alarm', d.superio.stuck)
        self.assertEqual(list(d.delivery.recent), [])
        # Nothing is due but the driver-parameter check a minute away: the loop
        # blocks in poll() until the kernel wakes it.
        d.step(0.05)
        self.assertEqual(set(d.timers), {'superio-params'})
        self.assertGreater(d.next_timeout(), kt.SuperIO.PARAMS_CHECK_SECS - 5)
        self.assertEqual(self.sysfs.snapshot(), before)
        state = load(f'{self.tmp}/state.json')
        self.assertEqual(state['sources']['nct6775']['mode'], 'event')
        self.assertEqual(state['sources']['nct6775']['cpu']['sensor'], 'tsi0')

    def test_cpu_levels_by_poll_wake(self):
        d = self.daemon()
        d.start()
        self.wake('temp13_input', 91000)
        d.step(0.05)
        self.assertEqual(events(d, 'cpu-hot'), [])  # dwelling
        self.assertIsNotNone(d.next_timeout())
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot')))
        e = events(d, 'cpu-hot')[0]
        self.assertEqual((e['state'], e['level'], e['temp'], e['threshold'], e['sensor']), ('start', 'warn', 91, 90, 'tsi0'))
        self.assertEqual(e['via'], 'pollwake')
        self.assertEqual(e['toast'], 'no')
        self.wake('temp13_input', 95500)
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot', 'change')))
        e = events(d, 'cpu-hot', 'change')[0]
        self.assertEqual((e['level'], e['temp']), ('crit', 95.5))
        self.assertEqual(e['toast'], 'no')  # crit toasts only once held
        self.assertTrue(run_until(d, lambda: len(events(d, 'cpu-hot', 'change')) == 2))
        held = events(d, 'cpu-hot', 'change')[1]
        self.assertEqual((held['level'], held['held']), ('crit', 0.8))
        self.assertEqual(held['toast'], 'queued')
        j = [x for x in self.journal.events('cpu-hot') if x.get('KITCHEN_HELD')]
        self.assertEqual(j[0]['PRIORITY'], '3')
        self.wake('temp13_input', 89000)
        d.step(0.05)
        self.assertEqual(events(d, 'cpu-hot', 'change')[-1]['level'], 'warn')
        self.wake('temp13_input', 84000)
        d.step(0.05)
        end = events(d, 'cpu-hot', 'end')
        self.assertEqual((end[0]['level'], end[0]['temp']), ('warn', 84))
        self.assertIsNone(d.superio.cpu.next_deadline())
        self.assertTrue(run_until(d, lambda: idle(d)))  # once the hooks are done

    def test_fan_ramp_coalesced(self):
        d = self.daemon()
        d.start()
        self.wake('pwm2', 90)       # 85 -> 90: 2 %, below the 10 % step
        d.step(0.05)
        self.assertEqual(events(d, 'fan-ramp'), [])
        self.sysfs.set('fan2_input', 1200)
        self.wake('pwm2', 130)      # 51 %
        d.step(0.05)
        r = events(d, 'fan-ramp')
        self.assertEqual(len(r), 1)
        self.assertEqual((r[0]['pwm'], r[0]['pct'], r[0]['dir'], r[0]['rpm'], r[0]['src']),
                         ('pwm2', 51, 'up', 1200, 'temp7'))
        j = self.journal.events('fan-ramp')[0]
        self.assertEqual(j['PRIORITY'], '6')
        self.wake('pwm2', 180)      # 71 %, but within FAN_RAMP_MIN_SECS
        d.step(0.05)
        self.assertEqual(len(events(d, 'fan-ramp')), 1)
        self.wake('pwm2', 200)      # 78 %: reported when allowed, at the latest value
        self.assertTrue(run_until(d, lambda: len(events(d, 'fan-ramp')) == 2))
        self.assertEqual(events(d, 'fan-ramp')[1]['pct'], 78)

    def test_fan_stall_and_restart(self):
        d = self.daemon()
        d.start()
        self.wake('pwm2', 130)      # 51 %
        d.step(0.05)
        self.wake('fan2_input', 0)
        d.step(0.05)
        self.assertEqual(events(d, 'fan-stall'), [])  # spin-up grace
        self.assertTrue(run_until(d, lambda: events(d, 'fan-stall')))
        e = events(d, 'fan-stall')[0]
        self.assertEqual((e['state'], e['fan'], e['pwm'], e['pct'], e['rpm']), ('start', 'fan2', 'pwm2', 51, 0))
        self.assertEqual(e['toast'], 'queued')
        self.assertEqual(self.journal.events('fan-stall')[0]['PRIORITY'], '3')
        self.wake('fan2_input', 900)
        d.step(0.05)
        self.assertEqual(events(d, 'fan-stall', 'end')[0]['rpm'], 900)

    def test_fan_stopped_by_smartfan_is_not_a_stall(self):
        d = self.daemon()
        d.start()
        self.wake('pwm5', 20)        # 8 %: SmartFan may stop the fan
        self.wake('fan5_input', 0)
        run_until(d, lambda: False, timeout=0.6)
        self.assertEqual(events(d, 'fan-stall'), [])
        # A header that never spun (fan1) is not watched in auto mode, even
        # with its (manual, unwatched) pwm1 up.
        self.sysfs.set('pwm1', 200)
        self.wake('fan1_input', 0)
        run_until(d, lambda: False, timeout=0.5)
        self.assertEqual(events(d, 'fan-stall'), [])

    def test_board_alarms_by_uevent(self):
        d = self.daemon()
        d.start()
        self.sysfs.set('temp1_input', 81000)
        self.sysfs.set('temp1_alarm', 1)
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='temp1_alarm')
        d.step(0.05)
        e = events(d, 'board-hot')[0]
        self.assertEqual((e['state'], e['sensor'], e['label'], e['temp'], e['max'], e['hyst']),
                         ('start', 'temp1', 'SYSTIN', 81, 80, 75))
        self.assertEqual((e['via'], e['hook']), ('uevent', 'queued'))
        self.sysfs.set('temp1_alarm', 0)
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='temp1_alarm')
        d.step(0.05)
        self.assertEqual(events(d, 'board-hot', 'end')[0]['sensor'], 'temp1')
        # temp7 is the CPU proxy: journal only, at info.
        self.sysfs.set('temp7_alarm', 1)
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='temp7_alarm')
        d.step(0.05)
        e = events(d, 'board-hot', 'start')[-1]
        self.assertEqual((e['sensor'], e['hook'], e['toast']), ('temp7', 'journal-only', 'no'))
        self.assertEqual(self.journal.events('board-hot')[-1]['PRIORITY'], '6')
        # A stuck voltage alarm that clears is journalled, not an event.
        n = len(d.delivery.recent)
        self.sysfs.set('in3_alarm', 0)
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='in3_alarm')
        d.step(0.05)
        self.assertEqual(len(d.delivery.recent), n)
        self.assertTrue(any('in3_alarm cleared' in e.get('MESSAGE', '') for e in self.journal.read()))
        # A uevent from another device is ignored.
        self.uev.send('change', '/devices/pci0000:00/0000:00:18.3/hwmon/hwmon3', 'hwmon', NAME='temp1_alarm')
        d.step(0.05)
        self.assertEqual(len(d.delivery.recent), n)

    def test_enobufs_resyncs(self):
        src = OverflowOnce(self.uev.theirs)
        d = self.daemon(uevents=src)
        d.start()
        # The alarm changes, but its uevent is lost in an overflow.
        self.sysfs.set('temp4_alarm', 1)
        src.overflow = True
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='temp4_alarm')
        d.step(0.05)
        e = events(d, 'board-hot')
        self.assertEqual((e[0]['sensor'], e[0]['via']), ('temp4', 'resync'))
        self.assertTrue(any('ENOBUFS' in x.get('MESSAGE', '') for x in self.journal.read()))

    def test_renumbered_device_is_found_by_name(self):
        kt.SuperIO.ABSENT_GRACE_SECS = 0.3
        self.addCleanup(setattr, kt.SuperIO, 'ABSENT_GRACE_SECS', 15)
        d = self.daemon()
        d.start()
        old = NCT_DEVPATH
        self.uev.send('remove', old, 'hwmon')
        self.sysfs.renumber('hwmon9')
        d.step(0.05)
        self.assertIsNone(d.superio.dev)
        self.assertEqual(self.watches.open_paths(), [])
        self.uev.send('add', self.sysfs.devpath, 'hwmon')
        d.step(0.05)
        self.assertEqual(d.superio.hwmon, 'hwmon9')
        self.assertTrue(all('/hwmon9/' in p for p in self.watches.open_paths()))
        self.assertEqual(len(self.watches.open_paths()), 12)
        # A quick reload is not a thermal-monitor event.
        run_until(d, lambda: False, timeout=0.5)
        self.assertEqual(events(d, 'thermal-monitor'), [])
        # Wake-ups arrive on the new device.
        self.wake('temp13_input', 97000)
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot')))
        # Gone for good: off, announced once.
        self.uev.send('remove', self.sysfs.devpath, 'hwmon')
        shutil.rmtree(self.sysfs.dev)
        os.unlink(f'{self.sysfs.root}/class/hwmon/hwmon9')
        self.assertTrue(run_until(d, lambda: events(d, 'thermal-monitor')))
        e = events(d, 'thermal-monitor')[0]
        self.assertEqual((e['state'], e['source']), ('degraded', 'nct6775'))
        self.assertEqual(d.superio.mode, 'off')


class Reload(Base):
    CHECKUP = 'NVME_SERIALS="SYS0001:system"\n'

    def test_sighup_rereads_the_settings(self):
        hw = self.sysfs.add_nvme('nvme1', 'hwmon0', 'SYS0001', 'FireCuda', temp_c=40, over_k=363)
        self.admin.add('nvme1', oaes=0x200)
        d = self.daemon()
        d.start()
        self.assertEqual(self.admin.calls, [])
        self.write_conf({'CPU_WARN': 80, 'NVME_ARM': 'system', 'NVME_system_WARN': 60, 'NVME_system_CLEAR': 55})
        d.reload()
        self.assertEqual(d.superio.cpu.warn, 80)
        self.assertTrue(d.nvme.drives['nvme1'].armed)
        with open(f'{hw}/temp1_max') as fh:
            self.assertEqual(int(fh.read()), 59850)
        self.wake('temp13_input', 81000)
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot')))


class Degraded(Base):
    NOTIFY = False  # the stock nct6775: no notify parameters at all

    def test_polls_and_says_so(self):
        d = self.daemon()
        d.start()
        self.assertEqual(d.superio.mode, 'degraded')
        e = events(d, 'thermal-monitor')[0]
        self.assertEqual((e['state'], e['source'], e['via'], e['toast']), ('degraded', 'nct6775', 'degraded-poll', 'queued'))
        self.assertIn('stock driver', e['reason'])
        self.assertAlmostEqual(d.next_timeout(), 0.2, delta=0.05)  # the labelled poll
        # No wake-up: the poll finds the change.
        self.sysfs.set('temp13_input', 92000)
        self.sysfs.set('temp5_alarm', 1)
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot') and events(d, 'board-hot')))
        self.assertEqual(events(d, 'cpu-hot')[0]['via'], 'degraded-poll')
        self.assertEqual(events(d, 'board-hot')[0]['via'], 'degraded-poll')
        # The patched driver arrives (modprobe): the add uevent brings events back.
        self.sysfs.params(notify_interval=1000, notify_temp_delta=1000)
        self.uev.send('remove', NCT_DEVPATH, 'hwmon')
        self.uev.send('add', NCT_DEVPATH, 'hwmon')
        self.assertTrue(run_until(d, lambda: events(d, 'thermal-monitor', 'restored')))
        self.assertEqual(d.superio.mode, 'event')
        # Once the hooks in flight are done nothing is due: no more polling.
        self.assertTrue(run_until(d, lambda: idle(d)))

    def test_zero_temp_delta_is_degraded(self):
        self.sysfs.params(notify_interval=1000, notify_temp_delta=0)
        d = self.daemon()
        d.start()
        self.assertEqual(d.superio.mode, 'degraded')
        self.assertIn('notify_temp_delta', d.superio.reason)

    def test_restart_does_not_announce_again(self):
        d = self.daemon()
        d.start()
        self.assertEqual(len(events(d, 'thermal-monitor')), 1)
        d2 = self.daemon()
        d2.start()
        self.assertEqual(events(d2, 'thermal-monitor'), [])
        self.assertEqual(d2.superio.mode, 'degraded')

    def test_no_device_at_all(self):
        os.unlink(f'{self.sysfs.root}/class/hwmon/hwmon7')
        d = self.daemon()
        d.start()
        self.assertEqual(d.superio.mode, 'off')
        self.assertIn('no nct6799', events(d, 'thermal-monitor')[0]['reason'])
        # Nothing to poll: the add uevent brings it back.
        self.assertTrue(run_until(d, lambda: d.next_timeout() is None))


# ---- hooks and toasts ----------------------------------------------------------------------


class Hooks(Base):
    def test_command_line_and_payload(self):
        d = self.daemon()
        d.start()
        self.sysfs.set('temp1_alarm', 1)
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='temp1_alarm')
        self.assertTrue(run_until(d, lambda: self.runs()))
        argv = self.runs()[0]['argv']
        setenv = [a for a in argv if a.startswith('--setenv=')]
        self.assertEqual(argv[:6], ['--user', f'--machine={ME}@.host', '--collect', '--quiet', '--wait',
                                    '--expand-environment=no'])
        self.assertIn('-p', argv)
        self.assertEqual(argv[argv.index('-p') + 1], 'RuntimeMaxSec=60')
        cmd = argv[argv.index('/usr/bin/omarchy-hook'):]
        self.assertEqual(cmd, ['/usr/bin/omarchy-hook', 'thermal', 'board-hot', 'start', 'sensor=temp1', 'label=SYSTIN',
                               'temp=29', 'max=80', 'hyst=75'])
        payload = json.loads(setenv[0].split('=', 2)[2])
        self.assertEqual({k: payload[k] for k in ('event', 'state', 'sensor', 'label', 'temp', 'max', 'hyst', 'via')},
                         {'event': 'board-hot', 'state': 'start', 'sensor': 'temp1', 'label': 'SYSTIN', 'temp': 29,
                          'max': 80, 'hyst': 75, 'via': 'uevent'})
        j = self.journal.events('board-hot')[0]
        self.assertEqual((j['KITCHEN_STATE'], j['KITCHEN_SOURCE'], j['KITCHEN_SENSOR'], j['KITCHEN_HOOK']),
                         ('start', 'uevent', 'temp1', 'queued'))
        self.assertEqual(json.loads(j['KITCHEN_JSON'])['label'], 'SYSTIN')

    def test_one_at_a_time_and_never_blocking(self):
        os.environ['FAKE_RUN_SLEEP'] = '0.3'
        d = self.daemon()
        d.start()
        for n in (1, 3, 4):
            self.sysfs.set(f'temp{n}_alarm', 1)
            self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME=f'temp{n}_alarm')
        t0 = time.monotonic()
        d.step(0.05)
        self.assertLess(time.monotonic() - t0, 0.25)   # three hooks queued, the loop did not wait
        self.assertEqual(len(events(d, 'board-hot')), 3)
        self.assertTrue(run_until(d, lambda: len(self.runs()) == 3, timeout=5))
        runs = sorted(self.runs(), key=lambda r: r['start'])
        for a, b in zip(runs, runs[1:]):
            self.assertLessEqual(a['end'], b['start'] + 0.01)

    def test_rate_limits_and_pairing(self):
        self.conf = self.write_conf({'HOOK_RATE_PER_MIN': 2})
        d = self.daemon()
        d.start()
        for n in (1, 3, 4):
            self.sysfs.set(f'temp{n}_alarm', 1)
            self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME=f'temp{n}_alarm')
        d.step(0.05)
        self.assertEqual([e['hook'] for e in events(d, 'board-hot')], ['queued', 'queued', 'rate-limited'])
        # Every one is journalled anyway.
        self.assertEqual(len(self.journal.events('board-hot')), 3)
        # Ends: the delivered starts get theirs even over the cap; the limited one's end is suppressed.
        for n in (1, 3, 4):
            self.sysfs.set(f'temp{n}_alarm', 0)
            self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME=f'temp{n}_alarm')
        d.step(0.05)
        self.assertEqual([e['hook'] for e in events(d, 'board-hot', 'end')], ['queued', 'queued', 'suppressed'])

    def test_per_sensor_limit(self):
        self.conf = self.write_conf({'HOOK_KEY_RATE_PER_MIN': 2, 'FAN_RAMP_MIN_SECS': 0})
        d = self.daemon()
        d.start()
        for v in (130, 200, 60, 250):
            self.wake('pwm4', v)
            d.step(0.05)
        self.assertEqual([e['hook'] for e in events(d, 'fan-ramp')], ['queued', 'queued', 'rate-limited', 'rate-limited'])
        self.wake('pwm5', 200)
        d.step(0.05)
        self.assertEqual(events(d, 'fan-ramp')[-1]['hook'], 'queued')

    def test_no_user_manager(self):
        self.manager(False)  # nobody logged in
        d = self.daemon()
        d.start()
        self.wake('pwm2', 200)
        d.step(0.05)
        self.assertEqual(events(d, 'fan-ramp')[0]['hook'], 'no-user-manager')
        self.assertEqual(self.runs(), [])

    def test_user_manager_asked_of_pid1(self):
        """systemctl is-active user@UID.service decides, which answers inside
        the sandbox; /run/user/UID/bus, which the service cannot see, and
        logind's record, whose STATE= is not kept current, play no part."""
        d = self.daemon()
        self.assertIsNone(d.delivery.manager_down(os.getuid()))
        self.manager(False)
        why = d.delivery.manager_down(os.getuid())
        self.assertIn(f'user@{os.getuid()}.service is not active', why)
        # Asked once per event, not for the hook, the toast and both prechecks
        calls = []
        real = kt.subprocess.run
        self.addCleanup(setattr, kt.subprocess, 'run', real)
        kt.subprocess.run = lambda *a, **kw: calls.append(a) or real(*a, **kw)
        self.manager(True)
        for _ in range(4):
            self.assertIsNone(d.delivery.manager_down(os.getuid()))
        self.assertEqual(len(calls), 1)
        # A systemctl that cannot run means no manager, not a crash
        self.conf = self.write_conf({'SYSTEMCTL': f'{self.tmp}/no-such-systemctl'})
        d2 = self.daemon()
        self.assertIn('not active', d2.delivery.manager_down(os.getuid()))

    def test_failed_and_timed_out_hooks_are_journalled(self):
        os.environ['FAKE_RUN_RC'] = '3'
        d = self.daemon()
        d.start()
        self.wake('pwm2', 200)
        self.assertTrue(run_until(d, lambda: any(e.get('KITCHEN_HOOK_RESULT') == 'failed' for e in self.journal.read())))
        self.assertEqual(d.delivery.counts['hooks_failed'], 1)
        os.environ['FAKE_RUN_RC'] = '0'
        os.environ['FAKE_RUN_SLEEP'] = '5'
        d.delivery.hooks.timeout = 0.3
        self.wake('pwm4', 200)
        self.assertTrue(run_until(d, lambda: any(e.get('KITCHEN_HOOK_RESULT') == 'timeout' for e in self.journal.read())))

    def test_hooks_off_and_journal_only(self):
        self.conf = self.write_conf({'HOOKS': 0})
        d = self.daemon()
        d.start()
        self.wake('pwm2', 200)
        run_until(d, lambda: False, timeout=0.2)
        self.assertEqual(events(d, 'fan-ramp')[0]['hook'], 'off')
        self.assertEqual(self.runs(), [])

    def test_toast_rules(self):
        self.conf = self.write_conf({'NOTIFY_EVENTS': 'fan-stall board-hot:start', 'NOTIFY_MIN_SECS': 600})
        d = self.daemon()
        d.start()
        self.sysfs.set('temp1_alarm', 1)
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='temp1_alarm')
        d.step(0.05)
        self.sysfs.set('temp1_alarm', 0)
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='temp1_alarm')
        d.step(0.05)
        self.sysfs.set('temp1_alarm', 1)
        self.uev.send('change', NCT_DEVPATH, 'hwmon', NAME='temp1_alarm')
        d.step(0.05)
        self.assertEqual([(e['state'], e['toast']) for e in events(d, 'board-hot')],
                         [('start', 'queued'), ('end', 'no'), ('start', 'rate-limited')])
        self.assertTrue(run_until(d, lambda: len(self.runs()) >= 4))
        toast = [r['argv'] for r in self.runs() if '/usr/local/lib/kitchen-sink/notify' in r['argv']][0]
        i = toast.index('/usr/local/lib/kitchen-sink/notify')
        self.assertEqual(toast[i:i + 5], ['/usr/local/lib/kitchen-sink/notify', '--urgency', 'normal', '--title',
                                          'Board sensor over its limit'])
        self.assertIn(f'--machine={ME}@.host', toast)
        self.assertEqual(toast[toast.index('--user', i):], ['--user', ME])


# ---- NVMe --------------------------------------------------------------------------------------


class NvmeArming(Base):
    CHECKUP = 'NVME_SERIALS="SYS0001:system DATA0001:data"\n'

    def setUp(self):
        super().setUp()
        self.sys_hw = self.sysfs.add_nvme('nvme1', 'hwmon0', 'SYS0001', 'FireCuda', temp_c=40, over_k=363, under_k=213)
        self.data_hw = self.sysfs.add_nvme('nvme0', 'hwmon1', 'DATA0001', 'WDC', temp_c=35, over_k=358, under_k=0)
        self.admin.add('nvme1', oaes=0x100, wctemp=363, sel_defaults=(363, 213))   # Case A
        self.admin.add('nvme0', oaes=0x0, wctemp=358, oncs=0x0f)                 # Case B, no Select
        self.nvme_dev = '/devices/pci0000:00/0000:00:02.2/0000:0e:01.0/nvme/nvme1'

    def hw(self, hw, attr):
        with open(f'{hw}/{attr}') as fh:
            return int(fh.read())

    def set_temp(self, hw, c):
        write(f'{hw}/temp1_input', int(round(c + 273.15)) * 1000 - 273150)

    def test_nothing_armed_by_default(self):
        d = self.daemon()
        d.start()
        self.assertEqual(self.admin.calls, [])
        self.assertEqual(self.hw(self.sys_hw, 'temp1_max'), 363 * 1000 - 273150)
        self.assertEqual(d.nvme.mode(), ('off', 'NVME_ARM is empty'))
        state = load(f'{self.tmp}/state.json')
        self.assertNotIn('SYS0001', json.dumps(state))  # serials never leave the machine's config

    def test_case_a_armed_case_b_left_alone(self):
        self.conf = self.write_conf({'NVME_ARM': 'system data'})
        d = self.daemon()
        d.start()
        self.assertEqual(self.admin.sets(), [('set', 'nvme1', 0x0B, 0x102)])
        self.assertEqual(self.hw(self.sys_hw, 'temp1_max'), 69850)       # 70 °C = 343 K
        self.assertEqual(self.hw(self.sys_hw, 'temp1_min'), -273150)     # 0 K
        self.assertEqual(self.hw(self.data_hw, 'temp1_max'), 358 * 1000 - 273150)  # untouched
        self.assertFalse(d.nvme.drives['nvme0'].armed)
        self.assertIn('Case B', d.nvme.drives['nvme0'].reason)
        self.assertEqual(d.nvme.mode()[0], 'event')
        # Warm: an AEN, one event, thresholds moved so the reading sits between them.
        self.set_temp(self.sys_hw, 72)
        self.uev.send('change', self.nvme_dev, 'nvme', NVME_AEN='0x020101')
        d.step(0.05)
        e = events(d, 'nvme-hot')[0]
        self.assertEqual((e['state'], e['drive'], e['level'], e['temp'], e['via']), ('start', 'system', 'warn', 72, 'aen'))
        self.assertEqual(self.journal.events('nvme-hot')[0]['PRIORITY'], '4')
        self.assertEqual((self.hw(self.sys_hw, 'temp1_max'), self.hw(self.sys_hw, 'temp1_min')), (79850, 64850))
        # Hot.
        self.set_temp(self.sys_hw, 81)
        self.uev.send('change', self.nvme_dev, 'nvme', NVME_AEN='0x020101')
        d.step(0.05)
        e = events(d, 'nvme-hot', 'change')[0]
        self.assertEqual((e['level'], e['temp'], e['toast']), ('crit', 81, 'queued'))
        self.assertEqual(self.journal.events('nvme-hot')[-1]['PRIORITY'], '3')
        self.assertEqual((self.hw(self.sys_hw, 'temp1_max'), self.hw(self.sys_hw, 'temp1_min')), (89850, 74850))
        # Cooled right down: one end.
        self.set_temp(self.sys_hw, 55)
        self.uev.send('change', self.nvme_dev, 'nvme', NVME_AEN='0x020101')
        d.step(0.05)
        e = events(d, 'nvme-hot', 'end')[0]
        self.assertEqual((e['level'], e['temp']), ('crit', 55))
        self.assertEqual((self.hw(self.sys_hw, 'temp1_max'), self.hw(self.sys_hw, 'temp1_min')), (69850, -273150))

    def test_rearmed_after_a_controller_reset_and_restored_at_stop(self):
        self.conf = self.write_conf({'NVME_ARM': 'system'})
        d = self.daemon()
        d.start()
        # A reset (or resume) puts FID 0Bh and 04h back to their defaults.
        self.admin.ctrls['nvme1']['aen'] = 0x100
        write(f'{self.sys_hw}/temp1_max', 363 * 1000 - 273150)
        self.uev.send('change', self.nvme_dev, 'nvme', NVME_EVENT='connected')
        d.step(0.05)
        self.assertEqual(self.admin.sets(), [('set', 'nvme1', 0x0B, 0x102)] * 2)
        self.assertEqual(self.hw(self.sys_hw, 'temp1_max'), 69850)
        d.shutdown()
        self.assertEqual((self.hw(self.sys_hw, 'temp1_max'), self.hw(self.sys_hw, 'temp1_min')),
                         (363 * 1000 - 273150, 213 * 1000 - 273150))

    def test_patched_kernel_case_b_is_armed_without_set_features(self):
        self.admin.ctrls['nvme0']['aen'] = 0x02  # nvme-aen's smart_aen_mask already set it
        self.conf = self.write_conf({'NVME_ARM': 'data'})
        d = self.daemon()
        d.start()
        self.assertEqual(self.admin.sets(), [])
        self.assertTrue(d.nvme.drives['nvme0'].armed)
        self.assertEqual(self.hw(self.data_hw, 'temp1_max'), 64850)       # data warns at 65 °C

    def test_arm_by_serial(self):
        self.conf = self.write_conf({'NVME_ARM': 'SYS0001'})
        d = self.daemon()
        d.start()
        self.assertTrue(d.nvme.drives['nvme1'].armed)
        self.assertFalse(d.nvme.drives['nvme0'].managed)
        self.assertNotIn('SYS0001', json.dumps(d.state()))

    def test_health_aen(self):
        d = self.daemon()
        d.start()
        self.uev.send('change', self.nvme_dev, 'nvme', NVME_AEN='0x020201')
        d.step(0.05)
        e = events(d, 'nvme-health')[0]
        self.assertEqual((e['state'], e['drive'], e['kind']), ('info', 'system', 'spare'))

    def test_writes_only_nvme_thresholds(self):
        d = self.daemon()
        with self.assertRaises(kt.NvmeError):
            d.nvme.write_threshold(self.sysfs.dev, 'max', 300)
        with self.assertRaises(kt.NvmeError):
            d.nvme.write_threshold(self.sys_hw, 'crit', 300)


# ---- GPU -------------------------------------------------------------------------------------


class NvmlEvents(Base):
    def test_registers_waits_and_reports(self):
        d = self.daemon()
        d.start()
        self.assertTrue(run_until(d, lambda: d.nvml_state['mode'] == 'event'))
        self.assertEqual(self.nvml.registered, 0xc01c)
        self.assertEqual(self.nvml.timeouts[-1], kt.NVML_INFINITE)   # idle: no polling
        self.nvml.event(kt.EV_XID, 79)
        self.assertTrue(run_until(d, lambda: events(d, 'gpu-xid')))
        e = events(d, 'gpu-xid')[0]
        self.assertEqual((e['state'], e['code'], e['kind'], e['gpu'], e['via'], e['toast']),
                         ('info', 79, 'xid', 'nvidia', 'nvml', 'queued'))
        self.assertEqual(self.journal.events('gpu-xid')[0]['PRIORITY'], '3')
        # The kernel log reports the same Xid: one event, not two.
        d.gpu_xid('xid', 79, 'nvidia', 'kmsg')
        self.assertEqual(len(events(d, 'gpu-xid')), 1)
        # Busy and throttling.
        self.nvml.pst, self.nvml.temp = 0, 86
        self.nvml.ctr[269] = 500
        n = len(self.nvml.calls)
        self.nvml.event(kt.EV_CLOCK)
        self.assertTrue(run_until(d, lambda: events(d, 'gpu-throttle') and events(d, 'gpu-hot')))
        self.assertEqual(self.nvml.calls[n:].count('reasons'), 1)
        e = events(d, 'gpu-throttle')[0]
        self.assertEqual((e['reason'], e['temp'], e['pstate']), ('sw-thermal', 86, 0))
        self.assertTrue(run_until(d, lambda: events(d, 'gpu-throttle', 'end')))
        self.nvml.temp = 79
        self.nvml.event(kt.EV_PSTATE)
        self.assertTrue(run_until(d, lambda: events(d, 'gpu-hot', 'end')))

    def test_lost_gpu(self):
        d = self.daemon()
        d.start()
        self.assertTrue(run_until(d, lambda: d.nvml_state['mode'] == 'event'))
        self.nvml.lost = True
        self.nvml.event(kt.EV_CLOCK)
        self.assertTrue(run_until(d, lambda: events(d, 'thermal-monitor')))
        self.assertEqual(events(d, 'gpu-xid')[0]['kind'], 'lost')
        e = events(d, 'thermal-monitor')[0]
        self.assertEqual((e['state'], e['source']), ('degraded', 'nvml'))

    def test_library_mismatch_is_degraded(self):
        self.nvml.init_rc = kt.NVML_MISMATCH
        d = self.daemon()
        d.start()
        self.assertTrue(run_until(d, lambda: events(d, 'thermal-monitor')))
        self.assertIn('reboot', events(d, 'thermal-monitor')[0]['reason'])

    def test_a_crashing_thread_is_degraded_and_retried(self):
        self.conf = self.write_conf({'NVML_RETRY_SECS': 0.2})

        def boom(es, timeout_ms):
            raise RuntimeError('boom')
        self.nvml.wait = boom
        d = self.daemon()
        d.start()
        self.assertTrue(run_until(d, lambda: events(d, 'thermal-monitor')))
        self.assertIn('boom', events(d, 'thermal-monitor')[0]['reason'])
        self.assertTrue(run_until(d, lambda: self.nvml.calls.count('init') >= 2))  # it tries again

    def test_no_nvidia_is_simply_off(self):
        def missing():
            raise OSError('libnvidia-ml.so.1: cannot open shared object file')
        d = kt.Daemon(self.conf, self.checkup, paths=self.paths, uevents=self.uev.source, watch_factory=self.watches,
                      nvme_admin=self.admin, nvml_factory=missing, signals=False)
        self.daemons.append(d)
        d.start()
        self.assertTrue(run_until(d, lambda: d.nvml_state['mode'] == 'off' and 'library' in d.nvml_state['reason']))
        self.assertEqual(events(d, 'thermal-monitor'), [])


class KernelLog(Base):
    def test_follows_and_dedups(self):
        write(f'{self.tmp}/kmsg-lines', '\n'.join([
            'NVRM: Xid (PCI:0000:01:00): 13, pid=4242, name=python3, Graphics Exception',
            'NVRM: Xid (PCI:0000:01:00): 13, pid=4242, name=python3, Graphics Exception',
            'amdgpu 0000:0f:00.0: amdgpu: ERROR: GPU over temperature range(SW CTF) detected!',
            'usb 1-3: new full-speed USB device number 5',
        ]))
        self.conf = self.write_conf({'KMSG_FOLLOW': 1, 'NVML': 0})
        d = self.daemon()
        d.start()
        self.assertTrue(run_until(d, lambda: len(events(d, 'gpu-xid')) == 2))
        run_until(d, lambda: False, timeout=0.2)
        got = [(e['kind'], e['code'], e['gpu'], e['via']) for e in events(d, 'gpu-xid')]
        self.assertEqual(got, [('xid', 13, 'nvidia', 'kmsg'), ('ctf', 0, 'amdgpu', 'kmsg')])
        argv = json_lines(self.jctl_log)[0]
        self.assertEqual(argv[:8], ['-k', '-f', '-n', '0', '-o', 'json', '--output-fields=MESSAGE,_KERNEL_SUBSYSTEM',
                                    '--grep'])

    def test_without_grep_support(self):
        os.environ['FAKE_JCTL_NO_GREP'] = '1'
        write(f'{self.tmp}/kmsg-lines', 'NVRM: GPU 0000:01:00.0: GPU has fallen off the bus.\n')
        self.conf = self.write_conf({'KMSG_FOLLOW': 1, 'NVML': 0})
        d = self.daemon()
        d.start()
        self.assertTrue(run_until(d, lambda: events(d, 'gpu-xid')))
        self.assertEqual(events(d, 'gpu-xid')[0]['kind'], 'lost')
        calls = json_lines(self.jctl_log)
        self.assertIn('--grep', calls[0])
        self.assertNotIn('--grep', calls[1])


# ---- the command line --------------------------------------------------------------------------


class CommandLine(Base):
    def cli(self, *args):
        env = dict(os.environ, KITCHEN_THERMAL_SYSFS=self.paths['sysfs'], KITCHEN_THERMAL_DEV=self.paths['dev'],
                   KITCHEN_THERMAL_JOURNAL=self.paths['journal'], PYTHONDONTWRITEBYTECODE='1')
        return subprocess.run([sys.executable, DAEMON, '--config', self.conf, '--checkup-config', self.checkup, *args],
                              capture_output=True, text=True, env=env, timeout=60)

    def test_test_event_uses_the_real_delivery(self):
        r = self.cli('--local', '--test-event', 'fan-stall', 'start', 'fan=fan2', 'pwm=pwm2', 'pct=45', 'rpm=0')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('hook:    queued', r.stdout)
        self.assertIn('hook finished: ok', r.stdout)
        self.assertIn('toast finished: ok', r.stdout)
        runs = [x['argv'] for x in self.runs()]
        hook = [a for a in runs if '/usr/bin/omarchy-hook' in a][0]
        self.assertEqual(hook[hook.index('/usr/bin/omarchy-hook'):],
                         ['/usr/bin/omarchy-hook', 'thermal', 'fan-stall', 'start', 'fan=fan2', 'pwm=pwm2', 'pct=45', 'rpm=0'])
        payload = json.loads([a for a in hook if a.startswith('--setenv=')][0].split('=', 2)[2])
        self.assertTrue(payload['test'])
        toast = [a for a in runs if '/usr/local/lib/kitchen-sink/notify' in a][0]
        self.assertIn('[test] Fan stopped', toast)
        j = self.journal.events('fan-stall')[0]
        # fan-stall is err (3) for real; a test is capped at notice (5) for the check-up's journal row
        self.assertEqual((j['KITCHEN_TEST'], j['KITCHEN_SOURCE'], j['PRIORITY']), ('1', 'test', '5'))

    def test_test_event_rejects_unknown_names(self):
        r = self.cli('--test-event', 'cpu-melted', 'start')
        self.assertEqual(r.returncode, 2)
        self.assertIn('unknown event', r.stderr)
        self.assertEqual(self.runs(), [])

    def test_test_event_reports_a_missing_user_manager(self):
        self.manager(False)
        r = self.cli('--test-event', 'gpu-xid', 'info', 'code=79', 'kind=xid')
        self.assertEqual(r.returncode, 1)
        self.assertIn('no-user-manager', r.stdout)
        # No service here: it says the check did not go through the service
        self.assertIn('outside the service\'s sandbox', r.stderr)

    def test_once_changes_nothing(self):
        before = self.sysfs.snapshot()
        self.conf = self.write_conf({'NVML': 0})
        r = self.cli('--once')
        self.assertEqual(r.returncode, 0, r.stderr)
        state = json.loads(r.stdout)
        self.assertEqual(state['sources']['nct6775']['mode'], 'event')
        self.assertEqual(state['sources']['nct6775']['device'], 'hwmon7')
        self.assertEqual(state['sources']['nct6775']['cpu']['temp'], 37.4)
        self.assertEqual(self.runs(), [])
        self.assertEqual(self.journal.read(), [])
        self.assertFalse(os.path.exists(f'{self.tmp}/state.json'))
        self.assertEqual(self.sysfs.snapshot(), before)

    def test_dump_state(self):
        r = self.cli('--dump-state')
        self.assertEqual(r.returncode, 1)
        write(f'{self.tmp}/state.json', '{"version": 1}')
        r = self.cli('--dump-state')
        self.assertEqual((r.returncode, json.loads(r.stdout)), (0, {'version': 1}))

    def test_help(self):
        r = self.cli('--help')
        self.assertEqual(r.returncode, 0)
        self.assertIn('--test-event EVENT STATE', r.stdout)


# ---- the device held must be the live one ---------------------------------------------------


class DeviceTracking(Base):
    def test_overflow_during_a_reload_to_another_number(self):
        """The remove and the add were both lost: the resync finds hwmon9."""
        src = OverflowOnce(self.uev.theirs)
        d = self.daemon(uevents=src)
        d.start()
        self.sysfs.renumber('hwmon9')
        src.overflow = True
        self.uev.send('remove', NCT_DEVPATH, 'hwmon')
        self.uev.send('add', self.sysfs.devpath, 'hwmon')
        d.step(0.05)
        self.assertEqual(d.superio.hwmon, 'hwmon9')
        self.assertEqual(len(self.watches.open_paths()), 12)
        self.assertTrue(all('/hwmon9/' in p for p in self.watches.open_paths()))
        self.wake('temp13_input', 97000)
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot')))

    def test_reloaded_at_the_same_number_with_its_remove_lost(self):
        """Every stale descriptor wakes (kernfs) and reads ENODEV; the add has
        the same devpath. The daemon attaches again instead of going deaf."""
        self.watches = Watches(KernfsWatch)
        src = OverflowOnce(self.uev.theirs)
        d = self.daemon(uevents=src)
        d.start()
        self.sysfs.reload_same_number()
        for w in list(self.watches.by_path.values()):
            w.wake()
        d.step(0.05)
        src.overflow = True
        self.uev.send('remove', NCT_DEVPATH, 'hwmon')
        d.step(0.05)
        self.uev.send('add', NCT_DEVPATH, 'hwmon')
        d.step(0.05)
        self.assertEqual(d.superio.hwmon, 'hwmon7')
        self.assertEqual(len(d.superio.watches), 12)
        self.assertTrue(d.superio.watches_alive())
        self.assertEqual(d.superio.mode, 'event')
        self.assertFalse(any('stopped watching' in x.get('MESSAGE', '') for x in self.journal.read()))
        self.wake('temp13_input', 97000)
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot')))
        run_until(d, lambda: False, timeout=0.3)
        self.assertEqual(events(d, 'thermal-monitor'), [])

    def test_same_number_add_without_any_wake(self):
        """Only the remove was lost, and no descriptor woke: the add alone
        (same devpath, dead descriptors) brings a fresh attach."""
        d = self.daemon()
        d.start()
        self.sysfs.reload_same_number()
        self.uev.send('add', NCT_DEVPATH, 'hwmon')
        d.step(0.05)
        self.assertTrue(d.superio.watches_alive())
        self.wake('temp13_input', 97000)
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot')))

    def test_uevents_read_before_an_overflow_are_kept(self):
        class Sock:
            def __init__(self, items):
                self.items = list(items)

            def setblocking(self, flag):
                pass

            def recvfrom(self, n):
                item = self.items.pop(0)
                if isinstance(item, Exception):
                    raise item
                return item, (0, 1)
        change = (f'change@{NCT_DEVPATH}\0ACTION=change\0DEVPATH={NCT_DEVPATH}\0SUBSYSTEM=hwmon\0'
                  'NAME=temp1_alarm\0').encode()
        src = kt.UeventSocket(Sock([change, OSError(errno.ENOBUFS, 'No buffer space available')]), check_sender=False)
        with self.assertRaises(kt.UeventOverflow) as cm:
            src.read()
        self.assertEqual([e['NAME'] for e in cm.exception.events], ['temp1_alarm'])


class Degraded2(Base):
    NOTIFY = False

    def test_a_reload_while_degraded_waits_out_the_grace(self):
        """The documented stock -> patched switch while degraded: a degraded
        poll between the remove and the add announces nothing."""
        kt.SuperIO.ABSENT_GRACE_SECS = 5
        self.addCleanup(setattr, kt.SuperIO, 'ABSENT_GRACE_SECS', 15)
        d = self.daemon()
        d.start()
        n = len(events(d, 'thermal-monitor'))
        self.uev.send('remove', NCT_DEVPATH, 'hwmon')
        os.unlink(f'{self.sysfs.root}/class/hwmon/hwmon7')
        run_until(d, lambda: False, timeout=0.6)  # three degraded poll periods
        self.assertEqual(events(d, 'thermal-monitor')[n:], [])
        self.sysfs.link_hwmon('hwmon7')
        self.sysfs.params(notify_interval=1000, notify_temp_delta=1000)
        self.uev.send('add', NCT_DEVPATH, 'hwmon')
        self.assertTrue(run_until(d, lambda: events(d, 'thermal-monitor')[n:]))
        self.assertEqual([e['state'] for e in events(d, 'thermal-monitor')[n:]], ['restored'])


class RuntimeParameters(Base):
    def test_notify_interval_zero_at_runtime_is_noticed(self):
        kt.SuperIO.PARAMS_CHECK_SECS = 0.3
        self.addCleanup(setattr, kt.SuperIO, 'PARAMS_CHECK_SECS', 60)
        d = self.daemon()
        d.start()
        self.assertEqual(d.superio.mode, 'event')
        self.sysfs.params(notify_interval=0)  # echo 0 > /sys/module/nct6775_core/parameters/notify_interval
        self.assertTrue(run_until(d, lambda: events(d, 'thermal-monitor')))
        self.assertEqual(d.superio.mode, 'degraded')
        self.assertIn('notify_interval is 0', events(d, 'thermal-monitor')[0]['reason'])
        # ... and the degraded poll now finds what no wake-up reports
        self.sysfs.set('temp13_input', 97000)
        self.assertTrue(run_until(d, lambda: events(d, 'cpu-hot')))
        self.assertEqual(events(d, 'cpu-hot')[0]['via'], 'degraded-poll')
        self.sysfs.params(notify_interval=1000)
        self.assertTrue(run_until(d, lambda: events(d, 'thermal-monitor', 'restored')))


# ---- --test-event through the running daemon -------------------------------------------------


class TestEventHandoff(Base):
    def hand(self, d, ev, pickup=5.0):
        got, sent = {}, threading.Event()

        def cli():
            got['r'] = kt.hand_to_daemon(ev, d.cfg, os.getpid(), kill=lambda pid, sig: sent.set(), pickup_secs=pickup)
        t = threading.Thread(target=cli)
        t.start()
        self.assertTrue(run_until(d, sent.is_set))
        return t, got

    def test_the_daemon_delivers_it(self):
        d = self.daemon()
        d.start()
        ev = kt.Event('fan-stall', 'start', [('fan', 'fan2'), ('pwm', 'pwm2'), ('pct', 45), ('rpm', 0)], 'test', test=True)
        t, got = self.hand(d, ev)
        d.take_test_requests()  # what SIGUSR1 does
        self.assertTrue(run_until(d, lambda: not t.is_alive(), timeout=10))
        rec, why = got['r']
        self.assertIsNone(why)
        self.assertEqual((rec['hook'], rec['toast'], rec['hook_result'], rec['toast_result'], rec['done']),
                         ('queued', 'queued', 'ok', 'ok', True))
        hook = [r['argv'] for r in self.runs() if '/usr/bin/omarchy-hook' in r['argv']][0]
        self.assertEqual(hook[hook.index('/usr/bin/omarchy-hook'):],
                         ['/usr/bin/omarchy-hook', 'thermal', 'fan-stall', 'start', 'fan=fan2', 'pwm=pwm2', 'pct=45', 'rpm=0'])
        self.assertTrue(json.loads([a for a in hook if a.startswith('--setenv=')][0].split('=', 2)[2])['test'])
        j = self.journal.events('fan-stall')[0]
        self.assertEqual((j['KITCHEN_TEST'], j['KITCHEN_SOURCE']), ('1', 'test'))
        self.assertEqual(glob_requests(self.tmp), [])

    def test_a_missing_user_manager_is_reported(self):
        self.manager(False)
        d = self.daemon()
        d.start()
        t, got = self.hand(d, kt.Event('gpu-xid', 'info', [('code', 79), ('kind', 'xid')], 'test', test=True))
        d.take_test_requests()
        self.assertTrue(run_until(d, lambda: not t.is_alive(), timeout=10))
        rec, why = got['r']
        self.assertEqual((rec['hook'], rec['toast'], rec['done']), ('no-user-manager', 'no-user-manager', True))

    def test_a_request_anyone_could_have_written_is_refused(self):
        d = self.daemon()
        d.start()
        write(f'{self.tmp}/test-00112233aabbccdd.json',
              json.dumps({'nonce': '00112233aabbccdd', 'event': 'gpu-xid', 'state': 'info', 'keys': []}))
        os.chmod(f'{self.tmp}/test-00112233aabbccdd.json', 0o666)
        d.take_test_requests()
        self.assertEqual(events(d), [])
        self.assertEqual(glob_requests(self.tmp), [])
        self.assertTrue(any('refused' in x.get('MESSAGE', '') for x in self.journal.read()))

    def test_an_older_daemon_is_not_signalled(self):
        write(f'{self.tmp}/state.json', json.dumps({'version': 1, 'pid': os.getpid()}))
        cfg = dict(kt.DEFAULTS, STATE_FILE=f'{self.tmp}/state.json')
        sent = []
        rec, why = kt.hand_to_daemon(kt.Event('gpu-xid', 'info', [], 'test', test=True), cfg, os.getpid(),
                                     kill=lambda pid, sig: sent.append(sig))
        self.assertIsNone(rec)
        self.assertIn('does not take test events', why)
        self.assertEqual(sent, [])

    def test_a_daemon_that_never_picks_it_up(self):
        d = self.daemon()
        d.start()
        t, got = self.hand(d, kt.Event('gpu-xid', 'info', [], 'test', test=True), pickup=0.3)
        t.join(5)
        rec, why = got['r']
        self.assertIsNone(rec)
        self.assertIn('did not take the event', why)
        self.assertEqual(glob_requests(self.tmp), [])  # its request is not left behind


def glob_requests(d):
    return sorted(f for f in os.listdir(d) if f.startswith('test-') or f.startswith('.test-'))


# ---- NVMe: --once, levels, release -----------------------------------------------------------


class NvmeSafety(Base):
    CHECKUP = 'NVME_SERIALS="SYS0001:system DATA0001:data"\n'

    def setUp(self):
        super().setUp()
        self.sys_hw = self.sysfs.add_nvme('nvme1', 'hwmon0', 'SYS0001', 'FireCuda', temp_c=40, over_k=363, under_k=213)
        self.admin.add('nvme1', oaes=0x200, wctemp=363, sel_defaults=(363, 213))
        self.nvme_dev = '/devices/pci0000:00/0000:00:02.2/0000:0e:01.0/nvme/nvme1'

    def thresholds(self):
        with open(f'{self.sys_hw}/temp1_max') as a, open(f'{self.sys_hw}/temp1_min') as b:
            return int(a.read()), int(b.read())

    def test_once_changes_nothing_on_a_drive_it_would_arm(self):
        self.conf = self.write_conf({'NVME_ARM': 'system', 'NVML': 0})
        before = self.thresholds()
        d = kt.Daemon(self.conf, self.checkup, paths=self.paths, uevents=self.uev.source, watch_factory=self.watches,
                      nvme_admin=self.admin, dry=True, signals=False)
        self.daemons.append(d)
        state = kt.once_state(d)
        self.assertEqual(self.admin.sets(), [])                  # no Set Features 0Bh
        self.assertEqual(self.thresholds(), before)               # no Set Features 04h
        drive = state['sources']['nvme']['drives']['system']
        self.assertEqual((drive['reason'], drive['armed'], drive['case']), ('would arm (Case A)', False, 'A'))
        # Belt and braces: in a dry run the writer refuses on its own
        with self.assertRaises(kt.NvmeError):
            d.nvme.write_threshold(self.sys_hw, 'max', 343)
        with self.assertRaises(kt.NvmeError):
            d.nvme_admin.set_aen_config('nvme1', 0x202)

    def test_levels_out_of_order_are_not_programmed(self):
        for extra, why in (({'NVME_system_CLEAR': 70}, 'CLEAR < WARN < CRIT'),
                           ({'NVME_system_WARN': 85}, 'CLEAR < WARN < CRIT'),
                           ({'NVME_system_CRIT': 150}, 'within 0 to 120')):
            conf = self.write_conf(dict({'NVME_ARM': 'system'}, **extra))
            cfg, _, warnings = kt.load_config(conf, self.checkup)
            self.assertTrue(any(why in w and 'role system is not armed' in w for w in warnings), (extra, warnings))
        self.conf = self.write_conf({'NVME_ARM': 'system', 'NVME_system_CLEAR': 70})
        d = self.daemon()
        d.start()
        self.assertEqual(self.admin.calls, [])
        self.assertEqual(self.thresholds(), (363 * 1000 - 273150, 213 * 1000 - 273150))
        self.assertFalse(d.nvme.drives['nvme1'].armed)
        self.assertIn('CLEAR < WARN < CRIT', d.nvme.drives['nvme1'].reason)

    def test_hot_hysteresis_below_one_is_refused(self):
        for bad in (0, -3, 0.5, 45):
            conf = self.write_conf({'NVME_HOT_HYST': bad})
            cfg, _, warnings = kt.load_config(conf, self.checkup)
            self.assertEqual(cfg['NVME_HOT_HYST'], 5, bad)
            self.assertTrue(any('NVME_HOT_HYST' in w for w in warnings), bad)

    def test_taken_out_of_nvme_arm_gets_its_own_thresholds_back(self):
        self.conf = self.write_conf({'NVME_ARM': 'system'})
        d = self.daemon()
        d.start()
        self.assertEqual(self.thresholds()[0], 69850)
        self.write_conf({'NVME_ARM': ''})
        d.reload()
        self.assertEqual(self.thresholds(), (363 * 1000 - 273150, 213 * 1000 - 273150))
        drive = d.nvme.drives['nvme1']
        self.assertEqual((drive.managed, drive.armed, drive.thresholds), (False, False, None))
        self.assertEqual(d.nvme.mode(), ('off', 'NVME_ARM is empty'))

    def test_restored_at_stop_even_after_a_failed_rearm(self):
        self.conf = self.write_conf({'NVME_ARM': 'system'})
        d = self.daemon()
        d.start()
        self.assertEqual(self.thresholds()[0], 69850)
        # A controller reset, and the re-arm fails half-way (Identify refused)
        self.admin.identify = lambda ctrl: (_ for _ in ()).throw(kt.NvmeError('Identify failed'))
        self.uev.send('change', self.nvme_dev, 'nvme', NVME_EVENT='connected')
        d.step(0.05)
        self.assertFalse(d.nvme.drives['nvme1'].armed)
        d.shutdown()
        self.assertEqual(self.thresholds(), (363 * 1000 - 273150, 213 * 1000 - 273150))


# ---- the GPU cooling at idle ------------------------------------------------------------------


class GpuHotAtIdle(Base):
    def test_hot_then_p8_then_cooling_ends(self):
        g = kt.GpuLogic(dict(kt.DEFAULTS))
        g.prime((86, 0, {}), 0)
        self.assertTrue(g.hot)
        self.assertEqual(g.observe((84, 8, {}), 1, lambda: 0), [])
        self.assertEqual(g.timeout_ms(), 15000)     # still hot at P8: keep looking
        out = g.observe((40, 8, {}), 16, lambda: 0)
        self.assertEqual([(e.name, e.state) for e in out], [('gpu-hot', 'end')])
        self.assertEqual(g.timeout_ms(), kt.NVML_INFINITE)

    def test_through_the_thread(self):
        d = self.daemon()
        d.start()
        self.assertTrue(run_until(d, lambda: d.nvml_state['mode'] == 'event'))
        self.nvml.pst, self.nvml.temp = 0, 86
        self.nvml.event(kt.EV_PSTATE)
        self.assertTrue(run_until(d, lambda: events(d, 'gpu-hot')))
        self.nvml.pst, self.nvml.temp = 8, 84       # the game ends: P8, still hot
        self.nvml.event(kt.EV_PSTATE)
        run_until(d, lambda: False, timeout=0.3)
        self.assertEqual(events(d, 'gpu-hot', 'end'), [])
        self.nvml.temp = 40                          # cools with no NVML event at all
        self.assertTrue(run_until(d, lambda: events(d, 'gpu-hot', 'end')))
        self.assertFalse(d.nvml_state['gpu']['hot'])


# ---- the fake libnvidia-ml (ctypes against real C) -------------------------------------------


class CtypesAgainstC(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc = shutil.which('cc') or shutil.which('gcc')
        if not cc:
            raise unittest.SkipTest('no C compiler: the fake libnvidia-ml is not built')
        cls.tmp = tempfile.mkdtemp()
        cls.lib = f'{cls.tmp}/libfake-nvml.so'
        subprocess.run([cc, '-shared', '-fPIC', '-Wall', '-Werror', '-o', cls.lib, os.path.join(HERE, 'fake_nvml.c')],
                       check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.log = f'{self.tmp}/calls.log'
        self.events = f'{self.tmp}/events-{self._testMethodName}'
        for p in (self.log, self.events):
            if os.path.exists(p):
                os.unlink(p)
        os.environ['FAKE_NVML_LOG'] = self.log
        os.environ['FAKE_NVML_EVENTS'] = self.events

    def calls(self):
        with open(self.log) as fh:
            return fh.read().splitlines()

    def test_bindings(self):
        write(self.events, f'{kt.EV_XID} 79\n{kt.EV_RECOVERY} {1 << 36}\n')
        be = kt.CtypesNvml(self.lib)
        self.assertEqual(be.init(), 0)
        rc, dev = be.device(0)
        rc, sup = be.supported_events(dev)
        self.assertEqual(sup, 0xc19c | 1 << 40)                     # all 64 bits came back
        rc, es = be.event_set()
        self.assertEqual(be.register(dev, kt.NVML_WANT & sup, es), 0)
        self.assertIn('register 0x1650 0xc01c 0xe5e7', self.calls())
        self.assertEqual(be.wait(es, kt.NVML_INFINITE), (0, kt.EV_XID, 79))
        self.assertIn('wait 4294967295', self.calls())               # "infinite" reached C unsigned
        self.assertEqual(be.wait(es, 250), (0, kt.EV_RECOVERY, 1 << 36))
        self.assertEqual(be.wait(es, 5)[0], kt.NVML_TIMEOUT)
        self.assertEqual(be.temperature(dev), (0, 47))
        self.assertEqual(be.pstate(dev), (0, 2))
        rc, c = be.counters(dev)
        self.assertEqual(sorted(c), [269, 270, 271])
        self.assertEqual(c[270], 270 * 10000000000)                 # past 2^32 intact
        self.assertIn('fields 3 269 270 271', self.calls())
        self.assertEqual(be.reasons(dev), (0, 0x20 | 1 << 33))
        self.assertEqual(be.error(18), 'fake error 18 (18)')
        self.assertFalse([c for c in self.calls() if 'bad device' in c])

    def test_thread_against_the_library(self):
        write(self.events, f'{kt.EV_XID} 31\n')
        got = queue.Queue()
        cfg = dict(kt.DEFAULTS, GPU_BUSY_TIMEOUT=0.05, GPU_COALESCE_MS=10)
        t = kt.NvmlThread(cfg, got.put, lambda: kt.CtypesNvml(self.lib))
        t.start()
        msgs = []
        end = time.monotonic() + 5
        while time.monotonic() < end and not any(m[0] == 'event' and m[1].name == 'gpu-throttle' for m in msgs):
            try:
                msgs.append(got.get(timeout=0.1))
            except queue.Empty:
                pass
        t.stopping = True
        self.assertIn(('mode', 'event', 'events 0xc01c'), msgs)
        self.assertIn(('xid', 'xid', 31), msgs)
        # The fake's sw-thermal counter moves on every read: a throttle start.
        thr = [m[1] for m in msgs if m[0] == 'event' and m[1].name == 'gpu-throttle']
        self.assertEqual((thr[0].state, thr[0].get('reason'), thr[0].get('temp'), thr[0].get('pstate')),
                         ('start', 'sw-thermal', 47, 2))

    def test_probe(self):
        r = kt.NvmlThread(dict(kt.DEFAULTS), lambda m: None, lambda: kt.CtypesNvml(self.lib)).probe()
        self.assertEqual((r['mode'], r['reason'], r['gpu']['temp']), ('event', 'events 0xc01c', 47))
        self.assertIn('shutdown', self.calls())
        os.environ['FAKE_NVML_INIT_RC'] = '18'
        try:
            r = kt.NvmlThread(dict(kt.DEFAULTS), lambda m: None, lambda: kt.CtypesNvml(self.lib)).probe()
        finally:
            del os.environ['FAKE_NVML_INIT_RC']
        self.assertEqual(r['mode'], 'degraded')
        self.assertIn('waiting for a reboot', r['reason'])


# ---- the unit ----------------------------------------------------------------------------------


class Unit(unittest.TestCase):
    def test_hardening_and_paths(self):
        with open(os.path.join(ROOT, 'systemd', 'kitchen-thermal.service')) as fh:
            lines = [l.strip() for l in fh if l.strip() and not l.startswith('#')]
        s = set(lines)
        for want in ('Restart=always', 'Nice=10', 'IOSchedulingClass=idle', 'MemoryMax=96M', 'Type=notify',
                     'CapabilityBoundingSet=CAP_SYS_ADMIN', 'NoNewPrivileges=yes', 'ProtectHome=yes',
                     'ExecStart=/usr/local/lib/kitchen-sink/kitchen-thermald.py', 'RuntimeDirectory=kitchen-thermal',
                     'SyslogIdentifier=kitchen-thermal', 'ProtectProc=invisible',
                     # CAP_SYS_ADMIN could remount what ProtectSystem made read-only
                     'SystemCallFilter=@system-service', 'SystemCallFilter=~@mount', 'SystemCallErrorNumber=EPERM'):
            self.assertIn(want, s)
        # The user-manager check asks PID 1, which answers inside the sandbox
        self.assertEqual(kt.DEFAULTS['SYSTEMCTL'], '/usr/bin/systemctl')
        # These would break the NVMe threshold writes or the device nodes.
        for bad in ('ProtectKernelTunables=yes', 'PrivateDevices=yes'):
            self.assertNotIn(bad, s)
        self.assertTrue(os.access(DAEMON, os.X_OK) or os.stat(DAEMON).st_mode & stat.S_IXUSR)


if __name__ == '__main__':
    unittest.main(verbosity=1)
