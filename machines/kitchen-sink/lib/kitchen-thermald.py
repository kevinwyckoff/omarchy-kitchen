#!/usr/bin/python3
"""kitchen-thermald: kitchen-sink's thermal event daemon.

One root process that turns what the hardware and the kernel already signal
into thermal events, and otherwise sleeps. It waits in a single poll() over:

  - a NETLINK_KOBJECT_UEVENT socket: hwmon add/remove (the Super I/O is found
    again by name, never by hwmonN), hwmon change NAME=<attr>_alarm (the
    patched nct6775 reports alarm transitions this way), nvme add and
    NVME_EVENT=connected (a controller reset forgets the NVMe settings, so they
    are applied again) and NVME_AEN (the drive's own temperature comparator);
  - poll(POLLPRI) on the nct6799's pwmN, fanN_input and the CPU temperature
    (TSI0), which the patched driver wakes when they move;
  - a self-pipe fed by an NVML thread, which blocks in nvmlEventSetWait for
    Xid, P-state and clock events from the GTX 1650;
  - `journalctl -k -f`, a backstop for NVRM Xids, "fallen off the bus" and
    amdgpu critical-temperature lines when NVML cannot say;
  - its own signals and children (hooks and toasts are never waited for).

Events go to the journal (native protocol, SYSLOG_IDENTIFIER=kitchen-thermal
and KITCHEN_* fields), to Omarchy hooks in the desktop user's own manager
(`omarchy-hook thermal <event> <state> key=value...`, the full event as JSON in
KITCHEN_THERMAL_EVENT) and, for a short list, to a toast. The state is in
/run/kitchen-thermal/state.json.

What it never does: write any Super I/O limit, pwm or SmartFan setting
(tempN_max, max_hyst, crit, in*_max, pwm*, pwm*_enable, fanN_min). Its only
writes are the NVMe temperature thresholds (hwmon temp1_max/temp1_min, which
is Set Features 04h) and the SMART bits of the NVMe AEN configuration (Set
Features 0Bh), and those only on drives named in NVME_ARM whose controller can
deliver the events without a rebuilt kernel ("Case A").

Where it has to poll, it says so: with the stock nct6775 (no notify_interval)
it reads the same attributes every DEGRADED_POLL_SECS and reports
`thermal-monitor degraded`; the NVML wait times out only while the GPU is busy
or hot (GPU_BUSY_TIMEOUT) or throttling (GPU_THROTTLE_TIMEOUT), and never at
idle unless GPU_IDLE_HEARTBEAT is set. Once a minute it re-reads the nct6775
driver's four parameters, since a change to them at runtime signals nothing.

usage: kitchen-thermald.py                     run (the systemd unit does this)
       kitchen-thermald.py --once              detect everything once, print the state, change nothing
       kitchen-thermald.py --dump-state        print the running daemon's state.json
       kitchen-thermald.py [--local] --test-event EVENT STATE [KEY=VALUE...]
                                               send a synthetic event through the real delivery
                                               (journal, hook, toast), for checking a deploy. As
                                               root, with kitchen-thermal.service running, the
                                               service delivers it, from inside its sandbox;
                                               otherwise (or with --local) this process does
"""

import collections
import ctypes
import errno
import fcntl
import glob
import json
import math
import os
import pwd
import queue
import re
import select
import shlex
import signal
import socket
import struct
import subprocess
import stat
import sys
import threading
import time
from datetime import datetime

IDENT = 'kitchen-thermal'
CONF_PATH = '/etc/kitchen-sink/thermal.conf'
CHECKUP_CONF_PATH = '/etc/kitchen-sink/checkup.conf'

# syslog priorities
ERR, WARNING, NOTICE, INFO, DEBUG = 3, 4, 5, 6, 7

# Every setting and its default. /etc/kitchen-sink/thermal.conf shows the same
# list commented out; anything missing there falls back to this.
DEFAULTS = {
    # CPU: the Super I/O's TSI0 channel (the CPU's own temperature over SB-TSI)
    'CPU_SENSOR_LABEL': 'TSI0_TEMP',
    'CPU_WARN': 90,
    'CPU_CRIT': 95,
    'CPU_HYST': 5,
    'CPU_DWELL_SECS': 10,
    'CPU_CRIT_TOAST_SECS': 60,
    # the Super I/O chip, and its alarms that go to the journal only
    'SUPERIO_NAME': 'nct6799',
    'JOURNAL_ONLY_ALARMS': 'temp7_alarm',
    'DEGRADED_POLL_SECS': 10,
    # fans
    'FAN_RAMP_STEP_PCT': 10,
    'FAN_RAMP_MIN_SECS': 5,
    'FAN_STALL_PWM_MIN': 20,
    'FAN_STALL_SECS': 5,
    'FAN_WATCH': '',
    # NVMe: roles come from checkup.conf NVME_SERIALS
    'NVME_ARM': '',
    'NVME_AEN_MASK': 0x02,
    'NVME_HOT_HYST': 5,
    'NVME_system_WARN': 70,
    'NVME_system_CRIT': 80,
    'NVME_system_CLEAR': 65,
    'NVME_data_WARN': 65,
    'NVME_data_CRIT': 75,
    'NVME_data_CLEAR': 60,
    # GPU (NVML)
    'NVML': 1,
    'NVML_LIBRARY': 'libnvidia-ml.so.1',
    'NVML_RETRY_SECS': 600,
    'GPU_HOT': 85,
    'GPU_HYST': 5,
    'GPU_BUSY_TIMEOUT': 15,
    'GPU_THROTTLE_TIMEOUT': 5,
    'GPU_IDLE_HEARTBEAT': 0,
    'GPU_THROTTLE_QUIET_SECS': 30,
    'GPU_COALESCE_MS': 250,
    # kernel-log backstop
    'KMSG_FOLLOW': 1,
    'JOURNALCTL': '/usr/bin/journalctl',
    'XID_DEDUP_SECS': 2,
    # delivery
    'HOOKS': 1,
    'HOOK_USER': '',
    'HOOK_CMD': '/usr/bin/omarchy-hook',
    'HOOK_TIMEOUT': 60,
    'HOOK_RATE_PER_MIN': 30,
    'HOOK_KEY_RATE_PER_MIN': 12,
    'HOOK_QUEUE_MAX': 32,
    'SYSTEMD_RUN': '/usr/bin/systemd-run',
    'SYSTEMCTL': '/usr/bin/systemctl',
    'NOTIFY_EVENTS': 'fan-stall nvme-hot:crit cpu-hot:crit gpu-xid thermal-monitor:degraded',
    'NOTIFY_CMD': '/usr/local/lib/kitchen-sink/notify',
    'NOTIFY_MIN_SECS': 600,
    'STATE_FILE': '/run/kitchen-thermal/state.json',
}
NVME_ROLE_KEY = re.compile(r'NVME_([A-Za-z0-9]+)_(WARN|CRIT|CLEAR)$')

EVENTS = ('cpu-hot', 'board-hot', 'fan-ramp', 'fan-stall', 'nvme-hot', 'nvme-health',
          'gpu-throttle', 'gpu-hot', 'gpu-xid', 'thermal-monitor')
STATES = ('start', 'end', 'change', 'info', 'degraded', 'restored')
# Events that open and close. A hook that saw the start always sees the end,
# and one that did not see the start never sees the end (see Delivery).
PAIRED = {'cpu-hot', 'board-hot', 'fan-stall', 'nvme-hot', 'gpu-throttle', 'gpu-hot', 'thermal-monitor'}
OPENING, CLOSING = ('start', 'degraded'), ('end', 'restored')
# The key that names what an event is about, for rate limits and pairing.
IDENT_KEYS = ('sensor', 'fan', 'pwm', 'drive', 'source', 'gpu')
# Names the JSON payload uses itself; event keys must not reuse them.
RESERVED_KEYS = {'event', 'state', 'via', 'time', 'id', 'test'}


def paths_from_environ():
    """Where the daemon finds sysfs, device nodes and the journal.

    Only the tests change these (a fake sysfs tree, a socket they read), so they
    are environment variables and not settings.
    """
    e = os.environ
    return {
        'sysfs': e.get('KITCHEN_THERMAL_SYSFS', '/sys'),
        'dev': e.get('KITCHEN_THERMAL_DEV', '/dev'),
        'journal': e.get('KITCHEN_THERMAL_JOURNAL', '/run/systemd/journal/socket'),
    }


# ---- settings -----------------------------------------------------------------------


def parse_kv_file(path, check_owner=None):
    """Read a bash KEY=VALUE file without running it: ({key: value}, [warnings]).

    The files are the same kind kitchen-checkup sources, so the rules match:
    as root, one that is not owned by root or that others can write is ignored.
    A line bash would run as a command (more than one word) is ignored too.
    """
    values, warnings = {}, []
    if check_owner is None:
        check_owner = os.geteuid() == 0
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return values, warnings
    except OSError as e:
        return values, [f'cannot read {path}: {e}']
    if check_owner and (st.st_uid != 0 or st.st_mode & 0o022):
        return values, [f'ignored {path}: it must be owned by root and not writable by others '
                        f'(mode {st.st_mode & 0o7777:o}, uid {st.st_uid})']
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        return values, [f'cannot read {path}: {e}']
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        if s.startswith('export '):
            s = s[7:].lstrip()
        m = re.match(r'([A-Za-z_][A-Za-z0-9_]*)=(.*)$', s)
        if not m:
            warnings.append(f'{path}:{n}: not a KEY=VALUE line; ignored')
            continue
        try:
            words = shlex.split(m.group(2), comments=True, posix=True)
        except ValueError as e:
            warnings.append(f'{path}:{n}: {e}; ignored')
            continue
        if len(words) > 1:
            warnings.append(f'{path}:{n}: {m.group(1)} has more than one word (quote it); ignored')
            continue
        values[m.group(1)] = words[0] if words else ''
    return values, warnings


def to_number(text):
    """'10' -> 10, '0.5' -> 0.5, '0x02' -> 2; ValueError otherwise."""
    text = text.strip()
    if re.fullmatch(r'[+-]?0[xX][0-9a-fA-F]+', text):
        return int(text, 16)
    f = float(text)
    if not math.isfinite(f):
        raise ValueError(text)
    return int(f) if f == int(f) and re.fullmatch(r'[+-]?\d+', text) else f


def load_config(conf_path=CONF_PATH, checkup_path=CHECKUP_CONF_PATH):
    """The settings, the NVMe serial->role map and any warnings about the files."""
    cfg = dict(DEFAULTS)
    raw, warnings = parse_kv_file(conf_path)
    for key, value in raw.items():
        default = DEFAULTS.get(key)
        if default is None and not NVME_ROLE_KEY.match(key):
            warnings.append(f'{conf_path}: unknown setting {key}; ignored')
            continue
        if isinstance(default, str):
            cfg[key] = value
            continue
        try:
            cfg[key] = to_number(value)
        except ValueError:
            warnings.append(f'{conf_path}: {key}={value!r} is not a number; using {default}')
    checkup, cw = parse_kv_file(checkup_path)
    warnings += cw
    roles = {}
    for item in checkup.get('NVME_SERIALS', '').split():
        serial, _, role = item.partition(':')
        if serial and role:
            roles[serial] = role
    if not cfg['HOOK_USER']:
        cfg['HOOK_USER'] = checkup.get('DESKTOP_USER') or 'kevinwyckoff'
    # The NVMe levels become thresholds on the drive. Levels out of order
    # would program one whose condition already holds, and every AEN would
    # then bring the next one at once: such a role is not armed at all.
    hyst = cfg['NVME_HOT_HYST']
    if not (isinstance(hyst, (int, float)) and 1 <= int(hyst) <= 30):
        warnings.append(f'{conf_path}: NVME_HOT_HYST={hyst!r} must be 1 to 30 (°C); using {DEFAULTS["NVME_HOT_HYST"]}')
        cfg['NVME_HOT_HYST'] = DEFAULTS['NVME_HOT_HYST']
    named = {m.group(1) for m in (NVME_ROLE_KEY.match(k) for k in cfg) if m}
    for role in sorted(named | set(roles.values()) | {'system', 'data'}):
        why = nvme_levels_problem(cfg, role)
        if why:
            warnings.append(f'{conf_path}: {why}; a drive with role {role} is not armed')
    return cfg, roles, warnings


NVME_LEVEL_RANGE = (0, 120)  # °C


def nvme_levels(cfg, role):
    """(warn, crit, clear) in °C for a role; a role without its own takes the system drive's."""
    return tuple(cfg.get(f'NVME_{role}_{k}', cfg[f'NVME_system_{k}']) for k in ('WARN', 'CRIT', 'CLEAR'))


def nvme_levels_problem(cfg, role):
    """Why a role's NVMe levels cannot be programmed, or None."""
    warn, crit, clear = levels = nvme_levels(cfg, role)
    lo, hi = NVME_LEVEL_RANGE
    shown = f'WARN {fmt_num(warn)}, CRIT {fmt_num(crit)}, CLEAR {fmt_num(clear)} °C'
    if not all(isinstance(x, (int, float)) and lo <= x <= hi for x in levels):
        return f'the NVMe levels of role {role} ({shown}) must be within {lo} to {hi} °C'
    if not clear < warn < crit:
        return f'the NVMe levels of role {role} ({shown}) must be CLEAR < WARN < CRIT'
    return None


# ---- small helpers ------------------------------------------------------------------


def read_text(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        return fh.read().strip()


def read_int(path):
    """An integer sysfs attribute, or None when it cannot be read."""
    try:
        return int(read_text(path))
    except (OSError, ValueError):
        return None


def fmt_num(v):
    """Numbers as a person writes them: 37.375 -> 37.4, 95.0 -> 95."""
    if v is None:
        return '?'
    if isinstance(v, float):
        v = round(v, 1)
        return str(int(v)) if v == int(v) else str(v)
    return str(v)


def json_num(v):
    if isinstance(v, float):
        v = round(v, 1)
        return int(v) if v == int(v) else v
    return v


def pct_of(pwm):
    return None if pwm is None else round(pwm * 100 / 255)


def iso(ts):
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec='seconds')


def sd_notify(message):
    """Tell systemd (Type=notify) where we are; a no-op outside systemd."""
    path = os.environ.get('NOTIFY_SOCKET')
    if not path:
        return
    if path.startswith('@'):
        path = '\0' + path[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC) as s:
            s.sendto(message.encode(), path)
    except OSError:
        pass


# ---- events -------------------------------------------------------------------------


class Event:
    """One thermal event: a name, a state and ordered key=value pairs.

    via is the input that produced it (uevent, pollwake, aen, nvml, kmsg,
    degraded-poll, resync, timer, test); it goes to the journal as KITCHEN_SOURCE.
    """

    def __init__(self, name, state, keys, via, message=None, priority=None, test=False):
        if name not in EVENTS:
            raise ValueError(f'unknown event {name}')
        if state not in STATES:
            raise ValueError(f'unknown state {state}')
        self.name, self.state, self.via, self.test = name, state, via, test
        self.keys = [(k, v) for k, v in keys if v is not None]
        for k, _ in self.keys:
            if k in RESERVED_KEYS or not re.fullmatch(r'[a-z][a-z0-9_]*', k):
                raise ValueError(f'bad key name {k!r}')
        self.time = time.time()
        self.id = None
        self.journal_only = False
        self.priority = priority if priority is not None else default_priority(self)
        self.message = message or describe(self)

    def get(self, key, default=None):
        for k, v in self.keys:
            if k == key:
                return v
        return default

    @property
    def ident(self):
        for k in IDENT_KEYS:
            v = self.get(k)
            if v is not None:
                return str(v)
        return ''

    @property
    def limit_key(self):
        return f'{self.name}:{self.ident}'

    def args(self):
        return [f'{k}={fmt_num(v)}'.replace('\n', ' ') for k, v in self.keys]

    def payload(self):
        p = {'event': self.name, 'state': self.state}
        for k, v in self.keys:
            p[k] = json_num(v)
        p.update({'via': self.via, 'time': iso(self.time), 'id': self.id})
        if self.test:
            p['test'] = True
        return p


def default_priority(ev):
    """Journal priority. err only for what needs a person: a stalled fan, NVMe
    crit, a GPU Xid or loss, and a CPU held at crit; the 09:00 check-up scans at
    err, so this keeps its count meaningful."""
    n, s = ev.name, ev.state
    if n == 'gpu-xid':
        return ERR
    if s in CLOSING:
        return NOTICE
    if n == 'fan-stall':
        return ERR
    if n == 'nvme-hot':
        return ERR if ev.get('level') == 'crit' else WARNING
    if n == 'cpu-hot':
        return ERR if ev.get('held') is not None else WARNING
    if n == 'fan-ramp':
        return INFO
    return WARNING


def describe(ev):
    """The human line for the journal and the toast body."""
    g = ev.get
    n, s = ev.name, ev.state
    t = fmt_num(g('temp')) if g('temp') is not None else '?'
    if n == 'cpu-hot':
        if s == 'end':
            return f'CPU ({g("sensor")}) back to {t} °C, below {g("level")}'
        if g('held') is not None:
            return f'CPU ({g("sensor")}) {t} °C: held at crit (>= {fmt_num(g("threshold"))} °C) for {g("held")} s'
        return f'CPU ({g("sensor")}) {t} °C: {g("level")} (>= {fmt_num(g("threshold"))} °C)'
    if n == 'board-hot':
        if s == 'end':
            return f'{g("label")} ({g("sensor")}) back to {t} °C (clears at {fmt_num(g("hyst"))} °C)'
        return f'{g("label")} ({g("sensor")}) {t} °C, over its limit {fmt_num(g("max"))} °C'
    if n == 'fan-ramp':
        rpm = f', {g("rpm")} rpm' if g('rpm') is not None else ''
        src = f', following {g("src")}' if g('src') else ''
        return f'{g("pwm")} ramped {g("dir")} to {g("pct")}%{rpm}{src}'
    if n == 'fan-stall':
        if s == 'end':
            return f'{g("fan")} is spinning again ({g("rpm")} rpm)'
        why = ' (its alarm)' if g('alarm') else ''
        return f'{g("fan")} stopped{why}: 0 rpm while {g("pwm")} drives it at {g("pct")}%'
    if n == 'nvme-hot':
        if s == 'end':
            return f'NVMe {g("drive")} back to {t} °C, below {g("level")}'
        return f'NVMe {g("drive")} {t} °C: {g("level")}'
    if n == 'nvme-health':
        return f'NVMe {g("drive")} reports a {g("kind")} warning (SMART critical warning)'
    if n == 'gpu-throttle':
        if s == 'end':
            return f'GPU throttling ({g("reason")}) ended, {t} °C'
        return f'GPU throttling ({g("reason")}) at {t} °C, P{g("pstate")}'
    if n == 'gpu-hot':
        if s == 'end':
            return f'GPU back to {t} °C'
        return f'GPU {t} °C'
    if n == 'gpu-xid':
        kind = g('kind')
        if kind == 'xid':
            return f'GPU error: NVRM Xid {g("code")}'
        if kind == 'lost':
            return 'GPU lost: it has fallen off the bus'
        if kind == 'unavailable':
            return 'GPU unavailable (NVML GpuUnavailableError)'
        if kind == 'recovery':
            return f'GPU recovery action {g("code")} requested'
        if kind == 'ctf':
            return 'amdgpu critical temperature fault (CTF): the system shuts down'
        return f'GPU error ({kind})'
    if n == 'thermal-monitor':
        return f'thermal events from {g("source")} {s}: {g("reason")}'
    return f'{n} {s}'


TOAST_TITLES = {
    'cpu-hot': 'CPU at its temperature limit',
    'board-hot': 'Board sensor over its limit',
    'fan-ramp': 'Fan speed changed',
    'fan-stall': 'Fan stopped',
    'nvme-hot': 'NVMe drive hot',
    'nvme-health': 'NVMe drive health warning',
    'gpu-throttle': 'GPU throttling',
    'gpu-hot': 'GPU hot',
    'gpu-xid': 'GPU error',
    'thermal-monitor': 'Thermal monitoring degraded',
}


# ---- the journal --------------------------------------------------------------------


class Journal:
    """systemd's native journal protocol: one datagram of KEY=VALUE fields.

    Never blocks the loop: the datagram is sent with MSG_DONTWAIT, and when the
    socket is missing or its queue is full (a stalled journald), the line goes
    to stderr instead, which systemd also sends to the journal.
    """

    def __init__(self, socket_path='/run/systemd/journal/socket', stream=None):
        self.path = socket_path
        self.stream = stream
        self.sock = None
        self.lock = threading.Lock()

    @staticmethod
    def encode(fields):
        out = bytearray()
        for key, value in fields:
            k = re.sub(r'[^A-Z0-9_]', '_', key.upper()).lstrip('_') or 'X'
            v = str(value).encode('utf-8', 'replace')
            if b'\n' in v:
                out += k.encode() + b'\n' + struct.pack('<Q', len(v)) + v + b'\n'
            else:
                out += k.encode() + b'=' + v + b'\n'
        return bytes(out)

    def send(self, message, priority=INFO, **fields):
        items = [('MESSAGE', message), ('PRIORITY', priority), ('SYSLOG_IDENTIFIER', IDENT)]
        items += [(k, v) for k, v in fields.items() if v is not None]
        data = self.encode(items)
        with self.lock:
            if self.path:
                try:
                    if self.sock is None:
                        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC)
                    self.sock.sendto(data, socket.MSG_DONTWAIT, self.path)
                    return
                except OSError:
                    pass
            stream = self.stream or sys.stderr
            try:
                # systemd reads a <N> prefix as the priority; a terminal gets plain text.
                line = f'{IDENT}: {message}' if stream.isatty() else f'<{priority}>{message}'
                print(line, file=stream, flush=True)
            except (OSError, ValueError):
                pass


# ---- delivery: journal, hooks, toasts ----------------------------------------------


class Job:
    def __init__(self, argv, label, done, precheck=None):
        self.argv, self.label, self.done, self.precheck = argv, label, done, precheck


class Runner:
    """Runs one child at a time from a bounded FIFO and never waits for it.

    The loop reaps it (SIGCHLD wakes the loop) and kills it past its deadline.
    One at a time keeps a burst of events from starting a crowd of hooks.
    """

    def __init__(self, name, max_queue, timeout, clock):
        self.name, self.max_queue, self.timeout, self.clock = name, max_queue, timeout, clock
        self.queue = collections.deque()
        self.proc = self.job = None
        self.deadline = None
        self.killed = False

    def submit(self, job, force=False):
        if len(self.queue) >= self.max_queue and not force:
            return False
        self.queue.append(job)
        self.pump()
        return True

    def pump(self):
        while self.proc is None and self.queue:
            job = self.queue.popleft()
            if job.precheck:
                why = job.precheck()
                if why:
                    job.done('skipped', None, why)
                    continue
            try:
                self.proc = subprocess.Popen(job.argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                             stderr=subprocess.PIPE, close_fds=True, start_new_session=True)
            except OSError as e:
                job.done('failed', None, str(e))
                continue
            self.job, self.killed = job, False
            self.deadline = self.clock() + self.timeout

    def reap(self):
        if self.proc is None or self.proc.poll() is None:
            return
        proc, job = self.proc, self.job
        try:
            err = proc.stderr.read(4000).decode('utf-8', 'replace').strip()
            proc.stderr.close()
        except (OSError, ValueError):
            err = ''
        self.proc = self.job = self.deadline = None
        rc = proc.returncode
        if self.killed:
            job.done('timeout', rc, f'killed after {self.timeout:g} s')
        elif rc == 0:
            job.done('ok', rc, err)
        else:
            job.done('failed', rc, err)
        self.pump()

    def expire(self, now):
        if self.proc is not None and self.deadline is not None and now >= self.deadline and not self.killed:
            self.killed = True
            try:
                self.proc.kill()
            except OSError:
                pass

    def busy(self):
        return self.proc is not None or bool(self.queue)

    def wait_idle(self, limit):
        """Block until everything queued has run (the CLI's --test-event)."""
        end = self.clock() + limit
        while self.busy() and self.clock() < end:
            if self.proc is not None:
                try:
                    self.proc.wait(timeout=max(0.05, min(1.0, end - self.clock())))
                except subprocess.TimeoutExpired:
                    pass
            self.expire(self.clock())
            self.reap()
        return not self.busy()


class HookLimiter:
    """At most per_min hooks a minute in all, and key_per_min per event+sensor."""

    def __init__(self, per_min, key_per_min):
        self.per_min, self.key_per_min = per_min, key_per_min
        self.all = collections.deque()
        self.keys = collections.defaultdict(collections.deque)

    def _prune(self, dq, now):
        while dq and now - dq[0] >= 60:
            dq.popleft()

    def check(self, key, now):
        self._prune(self.all, now)
        self._prune(self.keys[key], now)
        if len(self.all) >= self.per_min:
            return f'more than {self.per_min} hooks a minute'
        if len(self.keys[key]) >= self.key_per_min:
            return f'more than {self.key_per_min} a minute for {key}'
        return None

    def record(self, key, now):
        self.all.append(now)
        self.keys[key].append(now)


class Delivery:
    """Journal every event; start its hook and toast in the user's manager.

    Every event is journalled, whatever happens to its hook. Hooks and toasts
    run through `systemd-run --user --machine=<user>@.host`, so they live in the
    desktop user's own manager with the session's environment (omarchy-hook
    needs $HOME; the toast needs the session bus), and no setuid is needed here.
    """

    def __init__(self, cfg, journal, clock, dry=False):
        self.cfg, self.journal, self.clock, self.dry = cfg, journal, clock, dry
        self.manager_seen = {}  # uid -> (when, up): one question to PID 1 per event, not four
        self.hooks = Runner('hook', cfg['HOOK_QUEUE_MAX'], cfg['HOOK_TIMEOUT'] + 30, clock)
        self.toasts = Runner('toast', 8, 150, clock)
        self.limiter = HookLimiter(cfg['HOOK_RATE_PER_MIN'], cfg['HOOK_KEY_RATE_PER_MIN'])
        self.open = {}          # paired event key -> whether its hook ran for the start
        self.toast_last = {}    # toast key -> when it last toasted
        self.counts = collections.Counter()
        self.recent = collections.deque(maxlen=25)
        self.next_id = 1
        self.on_result = None   # the CLI prints hook/toast results through this
        self.on_request = None  # the daemon records a --test-event's results through this

    # -- who gets them

    def user(self):
        name = self.cfg['HOOK_USER']
        try:
            pw = pwd.getpwnam(name)
        except KeyError:
            return None
        return name, pw.pw_uid

    def manager_down(self, uid):
        """None when the user's systemd manager (user@UID.service) runs, else why not.

        Asked of PID 1 (systemctl is-active, a few milliseconds), which answers
        inside the service's sandbox. Not by looking for /run/user/UID/bus: the
        service cannot see it (ProtectHome= hides /run/user, and without
        CAP_DAC_READ_SEARCH root cannot enter the user's 0700 directory). Nor
        from logind's /run/systemd/users/UID ("private data, do not parse"):
        its STATE= is not kept current, and said "closing" for a lingering user
        whose manager was running.
        """
        now = self.clock()
        seen = self.manager_seen.get(uid)
        if seen is not None and now - seen[0] < 1:
            up = seen[1]
        else:
            try:
                up = subprocess.run([self.cfg['SYSTEMCTL'], 'is-active', '--quiet', f'user@{int(uid)}.service'],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    timeout=5).returncode == 0
            except (OSError, ValueError, subprocess.SubprocessError):
                up = False
            self.manager_seen[uid] = (now, up)
        if up:
            return None
        return f'{self.cfg["HOOK_USER"]} has no user manager running (user@{uid}.service is not active: not logged in)'

    def notify_match(self, ev):
        quals = {ev.state, str(ev.get('level', '')), str(ev.get('kind', ''))}
        for entry in self.cfg['NOTIFY_EVENTS'].split():
            name, _, qual = entry.partition(':')
            if name == ev.name and (not qual or qual in quals):
                return True
        return False

    # -- the event

    def deliver(self, ev):
        ev.id = self.next_id
        self.next_id += 1
        now = self.clock()
        hook = self._hook(ev, now)
        toast = self._toast(ev, now)
        fields = {
            'KITCHEN_EVENT': ev.name,
            'KITCHEN_STATE': ev.state,
            'KITCHEN_SOURCE': ev.via,
            'KITCHEN_EVENT_ID': ev.id,
            'KITCHEN_HOOK': hook,
            'KITCHEN_TOAST': toast,
            'KITCHEN_JSON': json.dumps(ev.payload(), separators=(',', ':')),
        }
        if ev.test:
            fields['KITCHEN_TEST'] = 1
        for k, v in ev.keys:
            name = k.upper()
            if name in ('EVENT', 'STATE', 'SOURCE', 'EVENT_ID', 'HOOK', 'TOAST', 'JSON', 'TEST'):
                name = 'KEY_' + name  # thermal-monitor's source=
            fields['KITCHEN_' + name] = fmt_num(v)
        if not self.dry:
            # A test goes no higher than notice: the check-up counts every err
            # line, and a deploy check must not turn the next day's WARN.
            self.journal.send(ev.message, max(ev.priority, NOTICE) if ev.test else ev.priority, **fields)
        self.counts['events'] += 1
        self.counts[f'hook_{hook}'] += 1
        record = ev.payload()
        record.update({'hook': hook, 'toast': toast, 'message': ev.message})
        self.recent.append(record)
        return hook, toast

    def _hook(self, ev, now):
        if self.dry:
            return 'dry-run'
        if ev.journal_only:
            return 'journal-only'
        if not self.cfg['HOOKS']:
            return 'off'
        u = self.user()
        if u is None:
            return 'no-user'
        key = ev.limit_key
        paired = ev.name in PAIRED
        exempt = False
        if paired and ev.state in CLOSING:
            delivered = self.open.pop(key, None)
            if delivered is False:
                return 'suppressed'  # its start was never delivered
            exempt = delivered is True
        elif paired and key in self.open:
            if not self.open[key]:
                return 'suppressed'
            exempt = True  # a change of a condition whose start was delivered
        opening = paired and ev.state not in CLOSING and not exempt

        def refuse(result):
            if opening:
                self.open[key] = False
            return result

        if not exempt:
            why = self.limiter.check(key, now)
            if why:
                return refuse('rate-limited')
        down = self.manager_down(u[1])
        if down:
            return refuse('no-user-manager')
        job = Job(self.hook_argv(ev, u[0]), f'hook thermal {ev.name} {ev.state}',
                  lambda outcome, rc, err: self._done('hook', ev, outcome, rc, err),
                  precheck=lambda: self.manager_down(u[1]))
        if not self.hooks.submit(job, force=exempt):
            return refuse('queue-full')
        self.limiter.record(key, now)
        if opening:
            self.open[key] = True
        return 'queued'

    def hook_argv(self, ev, user):
        body = json.dumps(ev.payload(), separators=(',', ':'))
        return [self.cfg['SYSTEMD_RUN'], '--user', f'--machine={user}@.host', '--collect', '--quiet', '--wait',
                '--expand-environment=no', f'--description=kitchen-thermal hook: {ev.name} {ev.state}',
                '-p', f'RuntimeMaxSec={self.cfg["HOOK_TIMEOUT"]}',
                f'--setenv=KITCHEN_THERMAL_EVENT={body}',
                self.cfg['HOOK_CMD'], 'thermal', ev.name, ev.state, *ev.args()]

    def _toast(self, ev, now):
        if self.dry or ev.journal_only or ev.state in CLOSING or not self.notify_match(ev):
            return 'no'
        # A 7700X sits at 95 °C under an all-core load by design, so CPU crit
        # toasts only once it has been held (the "held" change event).
        if ev.name == 'cpu-hot' and ev.get('level') == 'crit' and ev.get('held') is None:
            return 'no'
        key = f'{ev.limit_key}:{ev.get("level") or ev.get("kind") or ev.state}'
        last = self.toast_last.get(key)
        if last is not None and now - last < self.cfg['NOTIFY_MIN_SECS']:
            return 'rate-limited'
        u = self.user()
        if u is None:
            return 'no-user'
        down = self.manager_down(u[1])
        if down:
            return 'no-user-manager'
        urgency = 'critical' if ev.priority <= ERR else 'normal'
        title = ('[test] ' if ev.test else '') + TOAST_TITLES.get(ev.name, ev.name)
        argv = [self.cfg['SYSTEMD_RUN'], '--user', f'--machine={u[0]}@.host', '--collect', '--quiet', '--wait',
                '--expand-environment=no', '--description=kitchen-thermal toast', '-p', 'RuntimeMaxSec=120',
                self.cfg['NOTIFY_CMD'], '--urgency', urgency, '--title', title, '--body', ev.message,
                '--app-name', 'kitchen-thermal', '--user', u[0]]
        job = Job(argv, f'toast {ev.name}', lambda outcome, rc, err: self._done('toast', ev, outcome, rc, err),
                  precheck=lambda: self.manager_down(u[1]))
        if not self.toasts.submit(job):
            return 'queue-full'
        self.toast_last[key] = now
        return 'queued'

    def _done(self, what, ev, outcome, rc, err):
        self.counts[f'{what}s_{outcome}'] += 1
        detail = f'exit {rc}' if rc is not None else ''
        if err:
            detail = f'{detail}: {err}' if detail else err
        msg = f'{what} for {ev.name} {ev.state} (event {ev.id}): {outcome}' + (f' ({detail})' if detail else '')
        prio = DEBUG if outcome == 'ok' else WARNING if outcome in ('failed', 'timeout') else NOTICE
        self.journal.send(msg, prio, KITCHEN_HOOK_RESULT=outcome if what == 'hook' else None,
                          KITCHEN_TOAST_RESULT=outcome if what == 'toast' else None,
                          KITCHEN_EVENT_ID=ev.id, KITCHEN_HOOK_EVENT=ev.name, KITCHEN_TEST=1 if ev.test else None)
        if self.on_result:
            self.on_result(what, outcome, rc, err)
        if self.on_request and getattr(ev, 'request', None):
            self.on_request(ev, what, outcome, rc, err)

    # -- the loop's side

    def reap(self):
        self.hooks.reap()
        self.toasts.reap()

    def expire(self, now):
        self.hooks.expire(now)
        self.toasts.expire(now)

    def deadlines(self):
        return [r.deadline for r in (self.hooks, self.toasts) if r.deadline is not None]


# ---- kernel uevents -----------------------------------------------------------------


def parse_uevent(data):
    """A kernel uevent ("ACTION@DEVPATH\\0KEY=VALUE\\0...") as a dict, or None."""
    parts = data.split(b'\0')
    head = parts[0]
    if b'@' not in head:
        return None  # libudev's own format, never on the kernel group
    env = {}
    for p in parts[1:]:
        if b'=' in p:
            k, v = p.split(b'=', 1)
            env[k.decode('utf-8', 'replace')] = v.decode('utf-8', 'replace')
    action, _, devpath = head.decode('utf-8', 'replace').partition('@')
    env.setdefault('ACTION', action)
    env.setdefault('DEVPATH', devpath)
    return env


class UeventOverflow(Exception):
    """The kernel dropped uevents (ENOBUFS): everything must be read again.

    events holds those read before the overflow was reported, which are real.
    """

    def __init__(self, events=()):
        super().__init__('the uevent queue overflowed')
        self.events = list(events)


class UeventSocket:
    """NETLINK_KOBJECT_UEVENT, group 1: the kernel's own uevents, not udev's."""

    def __init__(self, sock=None, check_sender=True):
        if sock is None:
            sock = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC | socket.SOCK_NONBLOCK,
                                 15)  # NETLINK_KOBJECT_UEVENT
            for opt in (33, socket.SO_RCVBUF):  # SO_RCVBUFFORCE needs CAP_NET_ADMIN; SO_RCVBUF is capped
                try:
                    sock.setsockopt(socket.SOL_SOCKET, opt, 1 << 20)
                    break
                except OSError:
                    continue
            sock.bind((0, 1))
        else:
            sock.setblocking(False)
        self.sock, self.check_sender = sock, check_sender

    def fileno(self):
        return self.sock.fileno()

    def read(self):
        """Every uevent waiting now, as dicts. Raises UeventOverflow on ENOBUFS."""
        out = []
        while True:
            try:
                data, addr = self.sock.recvfrom(65536)
            except (BlockingIOError, InterruptedError):
                return out
            except OSError as e:
                if e.errno == errno.ENOBUFS:
                    raise UeventOverflow(out) from None
                raise
            # Only the kernel (port 0) sends on this group; anything else is not a uevent.
            if self.check_sender and isinstance(addr, tuple) and addr[0] != 0:
                continue
            env = parse_uevent(data)
            if env:
                out.append(env)

    def close(self):
        self.sock.close()


# ---- sysfs attributes ---------------------------------------------------------------


class AttrWatch:
    """A sysfs attribute held open for poll(POLLPRI).

    sysfs_notify() makes poll() report POLLPRI|POLLERR until the file is read
    again from the same descriptor, so every read is a pread at 0 on it.
    """

    mask = select.POLLPRI | select.POLLERR

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)

    def fileno(self):
        return self.fd

    def read(self):
        return os.pread(self.fd, 4096, 0).decode('utf-8', 'replace').strip()

    def alive(self):
        """Still the file at its path. A driver reload makes new sysfs files,
        possibly at the same path; the old descriptor then fails with ENODEV
        and polls as ready for ever."""
        try:
            a, b = os.fstat(self.fd), os.stat(self.path)
        except (OSError, TypeError):
            return False
        return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


# ---- level logic --------------------------------------------------------------------

RANK = {'none': 0, 'warn': 1, 'crit': 2}


class LevelTracker:
    """none < warn < crit for one temperature, with hysteresis and a dwell.

    Going up needs every reading to have stayed at or above the threshold for
    dwell seconds (a boost spike is not an event). Going down is immediate once
    the reading is at or below threshold - hyst. When crit has held for
    held_after seconds since the reading reached it, one more transition says
    so ('held').
    """

    def __init__(self, warn, crit, hyst, dwell, held_after):
        self.warn, self.crit, self.hyst, self.dwell, self.held_after = warn, crit, hyst, dwell, held_after
        self.level = 'none'
        self.temp = None
        self.warn_since = self.crit_since = None
        self.episode = None
        self.held_sent = False

    def observe(self, t, now):
        self.temp = t
        if t >= self.warn:
            self.warn_since = now if self.warn_since is None else self.warn_since
        else:
            self.warn_since = None
        if t >= self.crit:
            self.crit_since = now if self.crit_since is None else self.crit_since
        else:
            self.crit_since = None
        return self.evaluate(now)

    def evaluate(self, now):
        """[(state, level)] with state in start/change/end/held."""
        out = []
        t = self.temp
        if t is None:
            return out
        old = new = self.level
        if new == 'crit' and t <= self.crit - self.hyst:
            new = 'warn'
        if new == 'warn' and t <= self.warn - self.hyst:
            new = 'none'
        if RANK[new] < 2 and self.crit_since is not None and now - self.crit_since >= self.dwell:
            new = 'crit'
        elif RANK[new] < 1 and self.warn_since is not None and now - self.warn_since >= self.dwell:
            new = 'warn'
        if new != old:
            if new == 'crit':
                self.episode, self.held_sent = self.crit_since, False
            self.level = new
            if old == 'none':
                out.append(('start', new))
            elif new == 'none':
                out.append(('end', old))
            else:
                out.append(('change', new))
        if self.level == 'crit' and not self.held_sent and self.episode is not None \
                and now - self.episode >= self.held_after:
            self.held_sent = True
            out.append(('held', 'crit'))
        return out

    def next_deadline(self):
        ds = []
        if RANK[self.level] < 2 and self.crit_since is not None:
            ds.append(self.crit_since + self.dwell)
        if RANK[self.level] < 1 and self.warn_since is not None:
            ds.append(self.warn_since + self.dwell)
        if self.level == 'crit' and not self.held_sent and self.episode is not None:
            ds.append(self.episode + self.held_after)
        return min(ds) if ds else None

    def threshold(self, level):
        return self.crit if level == 'crit' else self.warn


class FanState:
    def __init__(self, known):
        self.known = known       # seen spinning, or listed in FAN_WATCH
        self.stalled = False
        self.by_alarm = False
        self.pending = None      # when rpm 0 at a driving pwm was first seen


class RampState:
    def __init__(self):
        self.reported = None     # the pct last reported (or the baseline)
        self.at = -1e18


# ---- the Super I/O ------------------------------------------------------------------


class SuperIO:
    """The nct6799: CPU (TSI0) levels, board alarms, fan ramps and stalls.

    Found by its hwmon name, never by hwmonN, which changes whenever nct6775 is
    reloaded. Reads only; the one kind of chip limit a person may set by hand
    (fanN_min) is honoured through fanN_alarm but never written here.
    """

    PARAMS = ('notify_interval', 'notify_pwm', 'notify_pwm_delta', 'notify_temp_delta')
    # A driver reload is a remove and an add a second apart: only a device that
    # stays away longer than this is worth a thermal-monitor event.
    ABSENT_GRACE_SECS = 15
    # The driver's parameters can be written at runtime and nothing signals
    # it; notify_interval=0 would silence every event. In event mode they are
    # read again this often (four small sysfs files).
    PARAMS_CHECK_SECS = 60

    def __init__(self, d):
        self.d = d
        self.dev = self.devpath = self.hwmon = None
        self.mode, self.reason = None, ''
        self.announced = None  # (mode, reason) of the last thermal-monitor event
        self.params = {}
        self.watches = {}      # attr -> watch
        self.values = {}       # attr -> int
        self.alarms = {}       # attr -> 0/1 (kept across a reload of the driver)
        self.stuck = set()
        self.labels = {}
        self.temp_sel = {}
        self.cpu_attr = None
        self.cpu_sensor = 'tsi0'
        cfg = d.cfg
        self.cpu = LevelTracker(cfg['CPU_WARN'], cfg['CPU_CRIT'], cfg['CPU_HYST'], cfg['CPU_DWELL_SECS'],
                                cfg['CPU_CRIT_TOAST_SECS'])
        self.fans = {}
        self.ramps = {}

    # -- finding the chip

    def find(self):
        root = self.d.paths['sysfs']
        for name_file in sorted(glob.glob(f'{root}/class/hwmon/*/name')):
            try:
                if read_text(name_file) == self.d.cfg['SUPERIO_NAME']:
                    return os.path.dirname(name_file)
            except OSError:
                continue
        return None

    def attr(self, name):
        return f'{self.dev}/{name}'

    def owns(self, devpath):
        return self.devpath is not None and devpath == self.devpath

    def attach(self, via):
        cls = self.find()
        if cls is None:
            self.dev = self.devpath = self.hwmon = None
            self.check_mode()
            return
        root = os.path.realpath(self.d.paths['sysfs'])
        self.dev = os.path.realpath(cls)
        self.devpath = self.dev[len(root):] if self.dev.startswith(root) else self.dev
        self.hwmon = os.path.basename(self.dev)
        self.d.cancel_timer('superio-absent')
        self.labels = {}
        for f in glob.glob(self.attr('temp*_label')):
            m = re.search(r'/(temp\d+)_label$', f)
            try:
                self.labels[m.group(1)] = read_text(f)
            except OSError:
                pass
        self.cpu_attr = None
        for chan, label in sorted(self.labels.items()):
            if label == self.d.cfg['CPU_SENSOR_LABEL']:
                self.cpu_attr = f'{chan}_input'
                self.cpu_sensor = re.sub(r'_temp$', '', label.lower()) or chan
        watch = []
        if self.cpu_attr:
            watch.append(self.cpu_attr)
        for f in sorted(glob.glob(self.attr('pwm*'))):
            name = os.path.basename(f)
            m = re.fullmatch(r'pwm(\d+)', name)
            if not m:
                continue
            n = int(m.group(1))
            sel = read_int(self.attr(f'pwm{n}_temp_sel'))
            self.temp_sel[n] = f'temp{sel}' if sel else None
            # Only automatic modes ramp; a manual pwm stays where it was set.
            enable = read_int(self.attr(f'pwm{n}_enable'))
            if enable is not None and enable >= 2:
                watch.append(name)
        for f in sorted(glob.glob(self.attr('fan*_input'))):
            watch.append(os.path.basename(f))
        for name in watch:
            try:
                self.watches[name] = self.d.open_watch(self.attr(name), self.on_wake, name)
            except OSError as e:
                self.d.log(WARNING, f'cannot watch {self.hwmon}/{name}: {e}')
        self.d.log(INFO, f'found {self.d.cfg["SUPERIO_NAME"]} at {self.hwmon} ({self.devpath}); '
                         f'watching {", ".join(sorted(self.watches)) or "nothing"}'
                         + ('' if self.cpu_attr else f'; no {self.d.cfg["CPU_SENSOR_LABEL"]} channel, no CPU levels'))
        self.check_mode()
        self.resync(via)

    def detach(self):
        for name, w in list(self.watches.items()):
            self.d.close_watch(w)
        self.watches = {}
        self.values = {}
        self.dev = self.devpath = self.hwmon = None
        # Nothing to poll or re-check until it is back: a degraded poll between
        # a reload's remove and add would announce it gone at once, grace or not.
        self.d.cancel_timer('superio-poll')
        self.d.cancel_timer('superio-params')

    def watches_alive(self):
        return all(w.alive() for w in self.watches.values())

    def lost(self):
        """The device went away: wait ABSENT_GRACE_SECS for it to come back."""
        self.d.log(NOTICE, f'{self.hwmon} ({self.d.cfg["SUPERIO_NAME"]}) went away; waiting for it to come back')
        self.detach()
        self.d.set_timer('superio-absent', self.d.clock() + self.ABSENT_GRACE_SECS, self.absent_check)

    def recheck(self, via):
        """After lost uevents or a dead descriptor: hold the live device.

        The one held may be gone, renumbered (reloaded as another hwmonN) or
        reloaded at the same number, whose new files the old descriptors do
        not see.
        """
        cls = self.find()
        if cls is None:
            if self.dev is not None:
                self.lost()
            elif not self.d.has_timer('superio-absent'):
                self.attach(via)  # still nothing: says so (off)
            return
        if self.dev is None or os.path.realpath(cls) != self.dev or not self.watches_alive():
            self.d.log(NOTICE, f'{self.d.cfg["SUPERIO_NAME"]}: the device held ({self.hwmon or "none"}) is not the '
                               f'live one ({os.path.basename(cls)}); attaching again')
            self.detach()
            self.attach(via)
            return
        self.check_mode()
        self.resync(via)

    def read_params(self):
        p = f'{self.d.paths["sysfs"]}/module/nct6775_core/parameters'
        params = {}
        for name in self.PARAMS:
            try:
                params[name] = read_text(f'{p}/{name}')
            except OSError:
                pass
        return params

    def check_mode(self):
        """event, degraded (polling) or off, from the loaded driver's parameters."""
        self.params = self.read_params()
        poll = fmt_num(self.d.cfg['DEGRADED_POLL_SECS'])
        name = self.d.cfg['SUPERIO_NAME']
        if self.dev is None:
            mode, reason = 'off', f'no {name} hwmon device (nct6775 not loaded?)'
        elif 'notify_interval' not in self.params:
            mode, reason = 'degraded', f'the loaded nct6775 has no change notification (stock driver); polling every {poll} s'
        elif to_int(self.params['notify_interval']) == 0:
            mode, reason = 'degraded', f'nct6775 notify_interval is 0; polling every {poll} s'
        elif self.cpu_attr and to_int(self.params.get('notify_temp_delta')) == 0:
            mode, reason = 'degraded', f'nct6775 notify_temp_delta is 0, so the CPU temperature wakes nothing; polling every {poll} s'
        else:
            mode, reason = 'event', f'change notification every {self.params["notify_interval"]} ms'
        self.set_mode(mode, reason)

    def set_mode(self, mode, reason):
        changed = (mode, reason) != (self.mode, self.reason)
        self.mode, self.reason = mode, reason
        if mode == 'degraded':
            if not self.d.has_timer('superio-poll'):
                self.d.set_timer('superio-poll', self.d.clock() + self.d.cfg['DEGRADED_POLL_SECS'], self.poll_tick)
        else:
            self.d.cancel_timer('superio-poll')
        if mode == 'event':
            self.d.set_timer('superio-params', self.d.clock() + self.PARAMS_CHECK_SECS, self.params_tick)
        else:
            self.d.cancel_timer('superio-params')
        if changed:
            self.d.log(INFO if mode == 'event' else WARNING, f'nct6775: {mode}: {reason}')
            self.d.mark_dirty()
        self.announce()

    def announce(self):
        """thermal-monitor degraded when events stop coming, restored when back."""
        prev = self.announced
        if self.mode == 'event':
            if prev is not None and prev[0] != 'event':
                self.d.emit(Event('thermal-monitor', 'restored', [('source', 'nct6775'), ('reason', self.reason)],
                                  'uevent'))
            self.announced = ('event', self.reason)
        elif prev != (self.mode, self.reason):
            self.d.emit(Event('thermal-monitor', 'degraded', [('source', 'nct6775'), ('reason', self.reason)],
                              'degraded-poll' if self.mode == 'degraded' else 'uevent'))
            self.announced = (self.mode, self.reason)

    # -- hwmon add/remove

    def on_hwmon_add(self, devpath):
        path = self.d.paths['sysfs'] + devpath
        try:
            name = read_text(f'{path}/name')
        except OSError:
            return
        if name != self.d.cfg['SUPERIO_NAME']:
            return
        # The same devpath is the device held, unless its remove was lost and
        # this is it back at the same number, with new files
        if self.dev is not None and devpath == self.devpath and self.watches_alive():
            return
        self.detach()
        self.attach('uevent')

    def on_hwmon_remove(self, devpath):
        if self.owns(devpath):
            self.lost()

    def absent_check(self):
        if self.dev is None:
            self.attach('uevent')  # sets off (and announces) if it is still missing

    # -- reading

    def read_attr(self, name):
        w = self.watches.get(name)
        try:
            text = w.read() if w else read_text(self.attr(name))
            return int(text)
        except (OSError, ValueError):
            return None

    def resync(self, via):
        """Read every alarm and watched attribute again and act on what changed."""
        if self.dev is None:
            return
        for f in sorted(glob.glob(self.attr('*_alarm'))):
            name = os.path.basename(f)
            v = read_int(f)
            if v is not None:
                self.on_alarm_value(name, v, via)
        for name in sorted(self.watches):
            v = self.read_attr(name)
            if v is not None:
                self.on_value(name, v, via)

    def poll_tick(self):
        """Degraded mode: the 10 s userspace poll, labelled as such."""
        self.check_mode()
        if self.mode == 'degraded':
            self.resync('degraded-poll')

    def params_tick(self):
        """Event mode: read the driver's parameters again (see PARAMS_CHECK_SECS)."""
        if self.dev is not None:
            self.check_mode()

    def on_wake(self, name):
        w = self.watches.get(name)
        if w is None:
            return
        try:
            v = int(w.read())
        except ValueError:
            return
        except OSError as e:
            if e.errno in (errno.ENODEV, errno.ENOENT) or not w.alive():
                # Unloaded or reloaded under us (every descriptor wakes before
                # the remove uevent comes): find the device again.
                self.recheck('pollwake')
            else:
                self.d.log(NOTICE, f'{self.hwmon}/{name}: {e}')
            return
        self.on_value(name, v, 'pollwake')

    def on_alarm(self, name, via):
        if self.dev is None:
            return
        v = read_int(self.attr(name))
        if v is not None:
            self.on_alarm_value(name, v, via)

    def on_value(self, name, v, via):
        self.values[name] = v
        if name == self.cpu_attr:
            self.cpu_observe(v / 1000, via)
            return
        m = re.fullmatch(r'pwm(\d+)', name)
        if m:
            n = int(m.group(1))
            self.ramp(n, via)
            self.stall_check(n, via)
            return
        m = re.fullmatch(r'fan(\d+)_input', name)
        if m:
            self.stall_check(int(m.group(1)), via)

    # -- alarms

    def on_alarm_value(self, name, v, via):
        m = re.fullmatch(r'(in|temp|fan|intrusion)(\d+)_alarm', name)
        if not m:
            return
        kind, n = m.group(1), int(m.group(2))
        prev = self.alarms.get(name)
        self.alarms[name] = v
        if kind in ('in', 'intrusion'):
            # Voltage alarms sit at 1 because their max limits are 0, and the
            # intrusion alarm is latched: ignore them until they transition,
            # and even then only journal it (no event in the design for them).
            if prev is None:
                if v:
                    self.stuck.add(name)
                return
            if v == prev:
                return
            if name in self.stuck:
                self.stuck.discard(name)
                self.d.log(INFO, f'{name} cleared (it was at 1 when first seen)', KITCHEN_ALARM=name)
            else:
                self.d.log(NOTICE, f'{name} {"on" if v else "off"}', KITCHEN_ALARM=name, KITCHEN_VALUE=v)
            return
        if prev is None and not v:
            return
        if prev is not None and v == prev:
            return
        if kind == 'temp':
            self.board_hot(n, v, via)
        elif kind == 'fan':
            self.fan_alarm(n, v, via)

    def board_hot(self, n, v, via):
        def c(attr):
            x = read_int(self.attr(attr))
            return None if x is None else x / 1000
        sensor = f'temp{n}'
        ev = Event('board-hot', 'start' if v else 'end',
                   [('sensor', sensor), ('label', self.labels.get(sensor, sensor)), ('temp', c(f'{sensor}_input')),
                    ('max', c(f'{sensor}_max')), ('hyst', c(f'{sensor}_max_hyst'))], via)
        # temp7 (SMBUSMASTER 0) is a CPU proxy at 80/75 °C, which a 7700X
        # passes in normal use: journal only.
        self.d.emit(ev, journal_only=f'{sensor}_alarm' in self.d.cfg['JOURNAL_ONLY_ALARMS'].split())

    # -- CPU

    def cpu_observe(self, t, via):
        now = self.d.clock()
        self.handle_cpu(self.cpu.observe(t, now), via)

    def cpu_timer(self):
        v = self.read_attr(self.cpu_attr) if self.cpu_attr and self.dev else None
        now = self.d.clock()
        if v is not None:
            self.values[self.cpu_attr] = v
            out = self.cpu.observe(v / 1000, now)
        else:
            out = self.cpu.evaluate(now)
        self.handle_cpu(out, self.timer_via())

    def handle_cpu(self, transitions, via):
        for state, level in transitions:
            keys = [('level', level), ('temp', self.cpu.temp), ('threshold', self.cpu.threshold(level)),
                    ('sensor', self.cpu_sensor)]
            if state == 'held':
                state = 'change'
                keys.append(('held', self.d.cfg['CPU_CRIT_TOAST_SECS']))
            self.d.emit(Event('cpu-hot', state, keys, via))
        deadline = self.cpu.next_deadline()
        if deadline is None:
            self.d.cancel_timer('cpu')
        else:
            self.d.set_timer('cpu', deadline, self.cpu_timer)
        if transitions:
            self.d.mark_dirty()

    # -- fans

    def pwm_pct(self, n):
        v = self.values.get(f'pwm{n}')
        if v is None and self.dev:
            v = read_int(self.attr(f'pwm{n}'))  # a pwm that is not watched (manual mode)
        return pct_of(v)

    def timer_via(self):
        """The input behind a dwell or spin-up timer's re-read."""
        return 'pollwake' if self.mode == 'event' else 'degraded-poll'

    def ramp(self, n, via):
        v = self.values.get(f'pwm{n}')
        if v is None:
            return
        pct = pct_of(v)
        st = self.ramps.setdefault(n, RampState())
        if st.reported is None:
            st.reported = pct
            return
        if abs(pct - st.reported) < self.d.cfg['FAN_RAMP_STEP_PCT']:
            self.d.cancel_timer(f'ramp{n}')
            return
        now = self.d.clock()
        due = st.at + self.d.cfg['FAN_RAMP_MIN_SECS']
        if now < due:
            # Too soon after the last one: report where it is when allowed to.
            self.d.set_timer(f'ramp{n}', due, lambda: self.ramp_timer(n, via))
            return
        rpm = read_int(self.attr(f'fan{n}_input'))
        if rpm is not None:
            self.values[f'fan{n}_input'] = rpm
        ev = Event('fan-ramp', 'change', [('pwm', f'pwm{n}'), ('pct', pct), ('dir', 'up' if pct > st.reported else 'down'),
                                          ('rpm', rpm), ('src', self.temp_sel.get(n))], via)
        st.reported, st.at = pct, now
        self.d.emit(ev)

    def ramp_timer(self, n, via):
        v = self.read_attr(f'pwm{n}')
        if v is not None:
            self.values[f'pwm{n}'] = v
            self.ramp(n, via)

    def watched_fans(self):
        return {f for f in self.d.cfg['FAN_WATCH'].split()}

    def fan(self, n):
        st = self.fans.get(n)
        if st is None:
            st = self.fans[n] = FanState(known=f'fan{n}' in self.watched_fans())
        return st

    def stall_keys(self, n, rpm):
        return [('fan', f'fan{n}'), ('pwm', f'pwm{n}'), ('pct', self.pwm_pct(n)), ('rpm', rpm)]

    def stall_check(self, n, via):
        rpm = self.values.get(f'fan{n}_input')
        if rpm is None:
            return
        st = self.fan(n)
        if rpm > 0:
            st.known = True
            st.pending = None
            self.d.cancel_timer(f'stall{n}')
            if st.stalled and not st.by_alarm:
                st.stalled = False
                self.d.emit(Event('fan-stall', 'end', self.stall_keys(n, rpm), via))
            return
        if not st.known or st.stalled:
            return
        pct = self.pwm_pct(n)
        if pct is None or pct < self.d.cfg['FAN_STALL_PWM_MIN']:
            # Not driven hard enough to have to spin (SmartFan may stop it).
            st.pending = None
            self.d.cancel_timer(f'stall{n}')
            return
        if st.pending is None:
            st.pending = self.d.clock()
            # A fan takes a moment to spin up after its pwm rises.
            self.d.set_timer(f'stall{n}', st.pending + self.d.cfg['FAN_STALL_SECS'], lambda: self.stall_confirm(n, via))

    def stall_confirm(self, n, via):
        st = self.fan(n)
        st.pending = None
        rpm = self.read_attr(f'fan{n}_input')
        pwm = self.read_attr(f'pwm{n}')
        if rpm is None:
            return
        self.values[f'fan{n}_input'] = rpm
        if pwm is not None:
            self.values[f'pwm{n}'] = pwm
        pct = pct_of(pwm)
        if rpm == 0 and pct is not None and pct >= self.d.cfg['FAN_STALL_PWM_MIN'] and not st.stalled:
            st.stalled, st.by_alarm = True, False
            self.d.emit(Event('fan-stall', 'start', self.stall_keys(n, rpm), via))

    def fan_alarm(self, n, v, via):
        """fanN_alarm: only fires once someone has set fanN_min (never us)."""
        st = self.fan(n)
        rpm = read_int(self.attr(f'fan{n}_input'))
        if v and not st.stalled:
            st.stalled, st.by_alarm = True, True
            self.d.emit(Event('fan-stall', 'start', self.stall_keys(n, rpm) + [('alarm', 1)], via))
        elif not v and st.stalled and st.by_alarm:
            st.stalled = st.by_alarm = False
            self.d.emit(Event('fan-stall', 'end', self.stall_keys(n, rpm) + [('alarm', 0)], via))

    def state(self):
        fans = {}
        for n, st in sorted(self.fans.items()):
            fans[f'fan{n}'] = {'rpm': self.values.get(f'fan{n}_input'), 'known': st.known, 'stalled': st.stalled}
        return {
            'mode': self.mode,
            'reason': self.reason,
            'announced': list(self.announced) if self.announced else None,
            'device': self.hwmon,
            'devpath': self.devpath,
            'params': self.params,
            'watching': sorted(self.watches),
            'cpu': {'sensor': self.cpu_sensor if self.cpu_attr else None, 'attr': self.cpu_attr,
                    'temp': json_num(self.cpu.temp), 'level': self.cpu.level},
            'pwm': {f'pwm{n}': pct_of(self.values.get(f'pwm{n}')) for n in sorted(self.temp_sel)
                    if f'pwm{n}' in self.values},
            'fans': fans,
            'alarms_on': sorted(a for a, v in self.alarms.items() if v and a not in self.stuck),
            'alarms_ignored': sorted(self.stuck),
        }


def to_int(text, default=0):
    try:
        return int(str(text).strip())
    except (TypeError, ValueError):
        return default


# ---- NVMe ---------------------------------------------------------------------------

NVME_IOCTL_ADMIN_CMD = 0xC0484E41  # _IOWR('N', 0x41, struct nvme_admin_cmd), 72 bytes
ADMIN_CMD = struct.Struct('<BBHIIIQQIIIIIIIIII')
FID_TEMP_THRESH, FID_AEN = 0x04, 0x0B
THSEL_UNDER = 1 << 20
# OAES bits for which the stock kernel submits an Asynchronous Event Request
# (NVME_AEN_SUPPORTED: namespace attribute, firmware activation, ANA, discovery).
# Without one of them no AEN of any kind arrives: "Case B", which needs the
# rebuilt nvme-core; this daemon then leaves the drive alone.
OAES_KERNEL_AER = 0x80000B00
AEN_TEMPERATURE, AEN_RELIABILITY, AEN_SPARE = 0x020101, 0x020001, 0x020201
KELVIN_ZERO_MC = 273150


class NvmeError(Exception):
    pass


class NvmeAdmin:
    """Admin passthrough on /dev/nvmeN (needs CAP_SYS_ADMIN), like nvme-health.py.

    Identify and Get Features only read. The one Set Features it will send is
    FID 0Bh (Asynchronous Event Configuration), and the caller only ever adds
    the SMART bits of NVME_AEN_MASK to what the kernel wrote.
    """

    def __init__(self, dev_root='/dev'):
        self.dev_root = dev_root

    def _cmd(self, ctrl, opcode, cdw10=0, cdw11=0, data_len=0):
        buf = ctypes.create_string_buffer(data_len) if data_len else None
        cmd = bytearray(ADMIN_CMD.pack(opcode, 0, 0, 0, 0, 0, 0, ctypes.addressof(buf) if buf is not None else 0,
                                       0, data_len, cdw10, cdw11, 0, 0, 0, 0, 0, 0))
        fd = os.open(f'{self.dev_root}/{ctrl}', os.O_RDONLY | os.O_CLOEXEC)
        try:
            status = fcntl.ioctl(fd, NVME_IOCTL_ADMIN_CMD, cmd)
        finally:
            os.close(fd)
        if status:
            raise NvmeError(f'{ctrl}: admin command 0x{opcode:02x} failed with NVMe status 0x{status:x}')
        return ADMIN_CMD.unpack(cmd)[-1], (buf.raw if buf is not None else b'')

    def identify(self, ctrl):
        return self._cmd(ctrl, 0x06, cdw10=1, data_len=4096)[1]

    def get_feature(self, ctrl, fid, sel=0, cdw11=0):
        return self._cmd(ctrl, 0x0A, cdw10=fid | (sel << 8), cdw11=cdw11)[0]

    def set_aen_config(self, ctrl, value):
        return self._cmd(ctrl, 0x09, cdw10=FID_AEN, cdw11=value)[0]


def parse_identify(b):
    """The Identify Controller fields the arming needs (NVMe base spec, figure 251)."""
    if len(b) < 4096:
        raise NvmeError(f'short Identify Controller data: {len(b)} bytes')
    return {
        'ver': int.from_bytes(b[80:84], 'little'),
        'oaes': int.from_bytes(b[92:96], 'little'),
        'wctemp': int.from_bytes(b[266:268], 'little'),
        'cctemp': int.from_bytes(b[268:270], 'little'),
        'oncs': int.from_bytes(b[520:522], 'little'),
    }


def kelvin(celsius):
    return int(round(celsius + 273.15))


def nvme_level(t_k, current, warn_k, crit_k, clear_k, hot_hyst):
    """normal / warm / hot for a composite temperature in kelvin.

    The drive's comparator fires at >= the over threshold and <= the under
    threshold, both whole kelvin, so the levels are decided in kelvin too.
    """
    if t_k >= crit_k:
        return 'hot'
    if current == 'hot' and t_k > crit_k - hot_hyst:
        return 'hot'
    if t_k >= warn_k:
        return 'warm'
    if current in ('warm', 'hot') and t_k > clear_k:
        return 'warm'
    return 'normal'


NVME_EVENT_LEVEL = {'warm': 'warn', 'hot': 'crit'}


class NvmeDrive:
    def __init__(self, ctrl):
        self.ctrl = ctrl
        self.serial = self.role = self.model = None
        self.managed = False
        self.case = None
        self.ident = None
        self.aen_config = None
        self.armed = False
        self.announced_fail = False
        self.level = 'normal'
        self.temp_k = None
        self.thresholds = None     # (over_k, under_k) as last programmed
        self.defaults = None       # (over_k, under_k) to put back at stop
        self.reason = ''

    @property
    def name(self):
        return self.role or self.ctrl


class Nvme:
    """NVMe temperature and health events from the drives' own AENs (Case A).

    For each drive whose role is in NVME_ARM: make sure the kernel will pass on
    SMART AENs (FID 0Bh bit 1, which the stock kernel clears at every
    controller start), then keep the drive's thresholds (FID 04h, through the
    nvme hwmon temp1_max/temp1_min) so the current temperature sits strictly
    between them. Each crossing is one AEN and one uevent; reading temp1_alarm
    afterwards reads the SMART log with RAE=0, which lets the next one through.
    """

    def __init__(self, d):
        self.d = d
        self.drives = {}

    def roles_to_arm(self):
        return set(self.d.cfg['NVME_ARM'].split())

    def limits(self, role):
        return tuple(kelvin(x) for x in nvme_levels(self.d.cfg, role))

    def ctrl_dir(self, ctrl):
        return f'{self.d.paths["sysfs"]}/class/nvme/{ctrl}'

    def hwmon_dir(self, ctrl):
        for name_file in sorted(glob.glob(f'{self.ctrl_dir(ctrl)}/hwmon*/name')):
            try:
                if read_text(name_file) == 'nvme':
                    return os.path.dirname(name_file)
            except OSError:
                continue
        return None

    def scan(self, arm, via):
        for path in sorted(glob.glob(f'{self.d.paths["sysfs"]}/class/nvme/nvme*')):
            ctrl = os.path.basename(path)
            if re.fullmatch(r'nvme\d+', ctrl):
                self.refresh(ctrl, arm, via)

    def refresh(self, ctrl, arm, via):
        drive = self.drives.get(ctrl) or NvmeDrive(ctrl)
        try:
            serial = read_text(f'{self.ctrl_dir(ctrl)}/serial')
        except OSError:
            return None
        if drive.serial is not None and drive.serial != serial:
            drive = NvmeDrive(ctrl)  # a different drive took the name
        drive.serial = serial
        try:
            drive.model = read_text(f'{self.ctrl_dir(ctrl)}/model')
        except OSError:
            pass
        drive.role = self.d.roles.get(serial)
        # An NVME_ARM entry is a role (the usual way: serials stay in
        # checkup.conf) or, as the check-up also accepts, a serial.
        arm_set = self.roles_to_arm()
        was_managed = drive.managed
        drive.managed = (drive.role is not None and drive.role in arm_set) or serial in arm_set
        problem = nvme_levels_problem(self.d.cfg, drive.role) if drive.managed else None
        self.drives[ctrl] = drive
        if problem:
            drive.reason = f'not armed: {problem}'
        elif not drive.managed:
            drive.reason = 'NVME_ARM is empty' if not arm_set else \
                'not in NVME_ARM' if drive.role else 'no role (checkup.conf NVME_SERIALS)'
        if problem or (was_managed and not drive.managed):
            self.release(drive)  # taken out of NVME_ARM by a reload, or unsafe levels: its own thresholds back
        elif drive.managed and arm:  # only when asked to: --once looks, and never arms
            self.arm(drive, via)
        return drive

    def arm(self, drive, via):
        """Idempotent: safe on every add, connected and resync."""
        admin, ctrl = self.d.nvme_admin, drive.ctrl
        mask = int(self.d.cfg['NVME_AEN_MASK']) & 0x07  # spare, temperature, reliability
        try:
            hw = self.hwmon_dir(ctrl)
            if hw is None:
                raise NvmeError('no nvme hwmon device (yet)')
            drive.ident = parse_identify(admin.identify(ctrl))
            drive.case = 'A' if drive.ident['oaes'] & OAES_KERNEL_AER else 'B'
            cur = admin.get_feature(ctrl, FID_AEN)
            if cur & mask != mask:
                if drive.case != 'A':
                    drive.armed = False
                    drive.aen_config = cur
                    drive.reason = ('Case B: the controller advertises no OAES notice the stock kernel acts on, '
                                    'so it submits no AER; needs the nvme-aen kernel patch')
                    self.d.log(WARNING, f'NVMe {drive.name} ({ctrl}) not armed: {drive.reason}')
                    self.d.mark_dirty()
                    return
                admin.set_aen_config(ctrl, cur | mask)
                new = admin.get_feature(ctrl, FID_AEN)
                if new & mask != mask:
                    raise NvmeError(f'the AEN configuration did not keep 0x{mask:x} (0x{cur:x} -> 0x{new:x})')
                self.d.log(INFO, f'NVMe {drive.name} ({ctrl}): AEN configuration 0x{cur:x} -> 0x{new:x}')
                cur = new
            drive.aen_config = cur
            if drive.defaults is None:
                drive.defaults = self.default_thresholds(drive)
            drive.armed = True
            drive.reason = f'armed (Case {drive.case})'
            self.update_level(drive, via, hw)
            if drive.announced_fail:
                drive.announced_fail = False
                self.d.emit(Event('thermal-monitor', 'restored', [('source', f'nvme-{drive.name}'),
                                                                  ('reason', 'armed again')], via))
        except (OSError, NvmeError) as e:
            was = drive.armed
            drive.armed = False
            drive.reason = f'cannot arm: {e}'
            self.d.log(WARNING, f'NVMe {drive.name} ({ctrl}): {drive.reason}')
            if was and not drive.announced_fail:
                drive.announced_fail = True
                self.d.emit(Event('thermal-monitor', 'degraded', [('source', f'nvme-{drive.name}'),
                                                                  ('reason', str(e))], via))
        self.d.mark_dirty()

    def release(self, drive):
        """Put back the drive's own thresholds if this daemon changed them, and stop managing it.

        FID 0Bh is left as it is: with the drive's own thresholds its extra
        notice only fires at WCTEMP, and the next controller reset clears it.
        """
        if drive.thresholds and drive.defaults and not self.d.dry:
            hw = self.hwmon_dir(drive.ctrl)
            try:
                if hw is None:
                    raise NvmeError('no nvme hwmon device')
                self.write_threshold(hw, 'max', drive.defaults[0])
                self.write_threshold(hw, 'min', drive.defaults[1])
                self.d.log(INFO, f'NVMe {drive.name} ({drive.ctrl}): thresholds back to the drive defaults')
                drive.thresholds = None
            except (OSError, NvmeError) as e:
                self.d.log(WARNING, f'NVMe {drive.name} ({drive.ctrl}): could not restore the thresholds: {e}')
        drive.armed = False
        drive.level = 'normal'
        self.d.mark_dirty()

    def default_thresholds(self, drive):
        """The drive's own thresholds, to put back when the daemon stops."""
        ident = drive.ident or {}
        over, under = ident.get('wctemp') or 0xFFFF, 0
        if ident.get('oncs', 0) & 0x10:  # Get Features Select supported: ask for the defaults
            try:
                over = self.d.nvme_admin.get_feature(drive.ctrl, FID_TEMP_THRESH, sel=1) & 0xFFFF
                under = self.d.nvme_admin.get_feature(drive.ctrl, FID_TEMP_THRESH, sel=1, cdw11=THSEL_UNDER) & 0xFFFF
            except (OSError, NvmeError):
                pass
        return over, under

    def thresholds(self, drive, level, t_k):
        warn_k, crit_k, clear_k = self.limits(drive.role)
        if level == 'normal':
            return warn_k, 0
        if level == 'warm':
            return crit_k, clear_k
        wctemp = (drive.ident or {}).get('wctemp') or 0
        over = wctemp if wctemp and t_k < wctemp else 0xFFFF
        return over, crit_k - int(self.d.cfg['NVME_HOT_HYST'])

    def write_threshold(self, hw, which, k):
        """temp1_max / temp1_min on the nvme hwmon device: Set Features 04h.

        The only sysfs file this daemon ever writes, and only on an nvme hwmon,
        and never in a dry run (--once).
        """
        path = f'{hw}/temp1_{which}'
        if self.d.dry:
            raise NvmeError(f'dry run: not writing {path}')
        if which not in ('max', 'min') or not re.search(r'/nvme\d+/hwmon\d+$', hw) or read_text(f'{hw}/name') != 'nvme':
            raise NvmeError(f'refusing to write {path}')
        mc = k * 1000 - KELVIN_ZERO_MC
        if read_int(path) == mc:
            return False
        with open(path, 'w') as fh:
            fh.write(str(mc))
        return True

    def update_level(self, drive, via, hw=None):
        hw = hw or self.hwmon_dir(drive.ctrl)
        if hw is None:
            raise NvmeError('no nvme hwmon device')
        warn_k, crit_k, clear_k = self.limits(drive.role)
        for _ in range(3):
            mc = read_int(f'{hw}/temp1_input')
            if mc is None:
                raise NvmeError('cannot read temp1_input')
            t_k = int(round((mc + KELVIN_ZERO_MC) / 1000))
            drive.temp_k = t_k
            new = nvme_level(t_k, drive.level, warn_k, crit_k, clear_k, int(self.d.cfg['NVME_HOT_HYST']))
            if new != drive.level:
                old, drive.level = drive.level, new
                temp = t_k - 273
                if old == 'normal':
                    ev = Event('nvme-hot', 'start', [('drive', drive.name), ('level', NVME_EVENT_LEVEL[new]), ('temp', temp)], via)
                elif new == 'normal':
                    ev = Event('nvme-hot', 'end', [('drive', drive.name), ('level', NVME_EVENT_LEVEL[old]), ('temp', temp)], via)
                else:
                    ev = Event('nvme-hot', 'change', [('drive', drive.name), ('level', NVME_EVENT_LEVEL[new]), ('temp', temp)], via)
                self.d.emit(ev)
            over, under = self.thresholds(drive, new, t_k)
            self.write_threshold(hw, 'max', over)
            self.write_threshold(hw, 'min', under)
            drive.thresholds = (over, under)
            # Reading temp1_alarm reads the SMART log with RAE=0, which unmasks
            # the next SMART AEN. Still 1 means the temperature crossed a new
            # threshold while they were being written: go round again.
            if read_int(f'{hw}/temp1_alarm') != 1:
                break
        self.d.mark_dirty()

    def unmask(self, ctrl):
        hw = self.hwmon_dir(ctrl)
        return read_int(f'{hw}/temp1_alarm') if hw else None

    def on_add(self, ctrl, via):
        self.refresh(ctrl, True, via)

    def on_remove(self, ctrl):
        self.drives.pop(ctrl, None)
        self.d.mark_dirty()

    def on_hwmon_add(self, devpath):
        m = re.search(r'/nvme/(nvme\d+)/hwmon\d+$', devpath)
        if m:
            drive = self.drives.get(m.group(1))
            if drive is None or (drive.managed and not drive.armed):
                self.refresh(m.group(1), True, 'uevent')

    def on_aen(self, ctrl, code_text):
        try:
            code = int(code_text, 16)
        except ValueError:
            return
        # A drive first heard of through its own AEN (its add uevent was lost)
        # is armed like one found at an add; refresh() arms only a managed one.
        drive = self.drives.get(ctrl) or self.refresh(ctrl, True, 'aen')
        if drive is None:
            return
        if code == AEN_TEMPERATURE:
            if drive.managed and drive.armed:
                try:
                    self.update_level(drive, 'aen')
                except (OSError, NvmeError) as e:
                    self.d.log(WARNING, f'NVMe {drive.name} ({ctrl}): temperature AEN, but {e}')
            else:
                alarm = self.unmask(ctrl)
                hw = self.hwmon_dir(ctrl)
                t = read_int(f'{hw}/temp1_input') if hw else None
                self.d.log(WARNING, f'NVMe {drive.name} ({ctrl}) sent a temperature AEN '
                                    f'({fmt_num(t / 1000) if t is not None else "?"} °C, alarm {alarm}); '
                                    f'it is not managed here ({drive.reason})')
        elif code in (AEN_RELIABILITY, AEN_SPARE):
            kind = 'reliability' if code == AEN_RELIABILITY else 'spare'
            self.unmask(ctrl)
            self.d.emit(Event('nvme-health', 'info', [('drive', drive.name), ('kind', kind)], 'aen'))
        else:
            self.d.log(INFO, f'NVMe {drive.name} ({ctrl}): AEN {code_text}')

    def rearm_all(self, via):
        for drive in list(self.drives.values()):
            if drive.managed:
                self.arm(drive, via)

    def restore_all(self):
        """At stop: the drive's own thresholds back on every drive this daemon
        programmed, armed or not (a re-arm after a reset may have failed after
        the thresholds were written)."""
        for drive in self.drives.values():
            self.release(drive)

    def mode(self):
        if any(d.armed for d in self.drives.values()):
            return 'event', 'armed: ' + ', '.join(sorted(d.name for d in self.drives.values() if d.armed))
        if not self.roles_to_arm():
            return 'off', 'NVME_ARM is empty'
        return 'off', '; '.join(f'{d.name}: {d.reason}' for d in self.drives.values() if d.managed) or \
            'no drive has a role in NVME_ARM'

    def state(self):
        mode, reason = self.mode()
        drives = {}
        for d in sorted(self.drives.values(), key=lambda x: x.ctrl):
            # Serial numbers stay out: the state is world-readable and ends up in reports.
            drives[d.name] = {
                'ctrl': d.ctrl, 'model': d.model, 'managed': d.managed, 'case': d.case, 'armed': d.armed,
                'reason': d.reason, 'level': d.level,
                'temp': d.temp_k - 273 if d.temp_k is not None else None,
                'aen_config': f'0x{d.aen_config:x}' if d.aen_config is not None else None,
                'oaes': f'0x{d.ident["oaes"]:x}' if d.ident else None,
                'thresholds_c': [x - 273 if x not in (0, 0xFFFF) else None for x in d.thresholds] if d.thresholds else None,
            }
        return {'mode': mode, 'reason': reason, 'drives': drives}


# ---- NVML (the GTX 1650) -----------------------------------------------------------

NVML_OK, NVML_TIMEOUT, NVML_GPU_LOST, NVML_MISMATCH = 0, 10, 15, 18
EV_PSTATE, EV_XID, EV_CLOCK, EV_UNAVAIL, EV_RECOVERY = 0x4, 0x8, 0x10, 0x4000, 0x8000
NVML_WANT = EV_PSTATE | EV_XID | EV_CLOCK | EV_UNAVAIL | EV_RECOVERY   # 0xc01c
NVML_INFINITE = 0xFFFFFFFF
# Cumulative nanoseconds spent in each limiter (nvml.h NVML_FI_DEV_CLOCKS_EVENT_REASON_*).
# The SW power cap (field 74) is left out: a 75 W bus-powered 1650 hits it routinely.
THROTTLE_FIELDS = {269: 'sw-thermal', 270: 'hw-thermal', 271: 'hw-power-brake'}
REASON_BITS = ((0x04, 'sw-power-cap'), (0x08, 'hw-slowdown'), (0x20, 'sw-thermal'), (0x40, 'hw-thermal'),
               (0x80, 'hw-power-brake'))


class _EventData(ctypes.Structure):
    _fields_ = [('device', ctypes.c_void_p), ('eventType', ctypes.c_ulonglong), ('eventData', ctypes.c_ulonglong),
                ('gpuInstanceId', ctypes.c_uint), ('computeInstanceId', ctypes.c_uint)]


class _Value(ctypes.Union):
    _fields_ = [('dVal', ctypes.c_double), ('uiVal', ctypes.c_uint), ('ulVal', ctypes.c_ulong),
                ('ullVal', ctypes.c_ulonglong), ('sllVal', ctypes.c_longlong), ('siVal', ctypes.c_int),
                ('usVal', ctypes.c_ushort)]


class _FieldValue(ctypes.Structure):
    _fields_ = [('fieldId', ctypes.c_uint), ('scopeId', ctypes.c_uint), ('timestamp', ctypes.c_longlong),
                ('latencyUsec', ctypes.c_longlong), ('valueType', ctypes.c_int), ('nvmlReturn', ctypes.c_int),
                ('value', _Value)]


class CtypesNvml:
    """libnvidia-ml through ctypes, only the calls the daemon makes."""

    def __init__(self, library='libnvidia-ml.so.1'):
        C = ctypes
        lib = C.CDLL(library)  # OSError when there is no NVIDIA driver
        P = C.POINTER
        sig = {
            'nvmlInit_v2': [],
            'nvmlShutdown': [],
            'nvmlDeviceGetHandleByIndex_v2': [C.c_uint, P(C.c_void_p)],
            'nvmlDeviceGetSupportedEventTypes': [C.c_void_p, P(C.c_ulonglong)],
            'nvmlEventSetCreate': [P(C.c_void_p)],
            'nvmlDeviceRegisterEvents': [C.c_void_p, C.c_ulonglong, C.c_void_p],
            'nvmlEventSetWait_v2': [C.c_void_p, P(_EventData), C.c_uint],
            'nvmlEventSetFree': [C.c_void_p],
            'nvmlDeviceGetTemperature': [C.c_void_p, C.c_int, P(C.c_uint)],
            'nvmlDeviceGetPerformanceState': [C.c_void_p, P(C.c_int)],
            'nvmlDeviceGetFieldValues': [C.c_void_p, C.c_int, P(_FieldValue)],
        }
        for name, argtypes in sig.items():
            fn = getattr(lib, name)
            fn.argtypes, fn.restype = argtypes, C.c_int
        # Renamed from ...ThrottleReasons in newer NVML; either takes the same arguments.
        self._reasons = getattr(lib, 'nvmlDeviceGetCurrentClocksEventReasons', None) or \
            getattr(lib, 'nvmlDeviceGetCurrentClocksThrottleReasons')
        self._reasons.argtypes, self._reasons.restype = [C.c_void_p, P(C.c_ulonglong)], C.c_int
        lib.nvmlErrorString.argtypes, lib.nvmlErrorString.restype = [C.c_int], C.c_char_p
        self.lib = lib

    def error(self, rc):
        s = self.lib.nvmlErrorString(rc)
        return f'{s.decode() if s else "error"} ({rc})'

    def init(self):
        return self.lib.nvmlInit_v2()

    def shutdown(self):
        return self.lib.nvmlShutdown()

    def device(self, index):
        h = ctypes.c_void_p()
        return self.lib.nvmlDeviceGetHandleByIndex_v2(index, ctypes.byref(h)), h

    def supported_events(self, dev):
        m = ctypes.c_ulonglong()
        return self.lib.nvmlDeviceGetSupportedEventTypes(dev, ctypes.byref(m)), m.value

    def event_set(self):
        s = ctypes.c_void_p()
        return self.lib.nvmlEventSetCreate(ctypes.byref(s)), s

    def register(self, dev, mask, es):
        return self.lib.nvmlDeviceRegisterEvents(dev, mask, es)

    def wait(self, es, timeout_ms):
        d = _EventData()
        rc = self.lib.nvmlEventSetWait_v2(es, ctypes.byref(d), int(timeout_ms) & 0xFFFFFFFF)
        return rc, d.eventType, d.eventData

    def free(self, es):
        return self.lib.nvmlEventSetFree(es)

    def temperature(self, dev):
        t = ctypes.c_uint()
        return self.lib.nvmlDeviceGetTemperature(dev, 0, ctypes.byref(t)), t.value

    def pstate(self, dev):
        p = ctypes.c_int()
        return self.lib.nvmlDeviceGetPerformanceState(dev, ctypes.byref(p)), p.value

    def counters(self, dev):
        fv = (_FieldValue * len(THROTTLE_FIELDS))()
        for i, f in enumerate(THROTTLE_FIELDS):
            fv[i].fieldId = f
        rc = self.lib.nvmlDeviceGetFieldValues(dev, len(THROTTLE_FIELDS), fv)
        return rc, {fv[i].fieldId: fv[i].value.ullVal for i in range(len(THROTTLE_FIELDS)) if fv[i].nvmlReturn == 0}

    def reasons(self, dev):
        r = ctypes.c_ulonglong()
        return self._reasons(dev, ctypes.byref(r)), r.value


class GpuLost(Exception):
    pass


class GpuLogic:
    """gpu-throttle and gpu-hot from one snapshot per wake-up.

    NVML has no temperature event: a clock or P-state change wakes us, and we
    read the cumulative throttle counters (0.7 ms) to see whether a limiter
    acted. The 14 ms clocks-event-reasons call is made only when one moved.
    """

    def __init__(self, cfg):
        self.cfg = cfg
        self.temp = self.pstate = None
        self.counters = {}
        self.throttling = None   # set of reason names while throttling
        self.last_move = None
        self.hot = False
        self.active = []

    def timeout_ms(self):
        c = self.cfg
        if self.throttling:
            return int(c['GPU_THROTTLE_TIMEOUT'] * 1000)
        # Hot counts as busy: a GPU that drops to P8 while still hot cools
        # without any NVML event, and only a look can end gpu-hot.
        if self.hot or (self.pstate is not None and self.pstate < 8):
            return int(c['GPU_BUSY_TIMEOUT'] * 1000)
        if c['GPU_IDLE_HEARTBEAT']:
            return int(c['GPU_IDLE_HEARTBEAT'] * 1000)
        return NVML_INFINITE

    def prime(self, snap, now):
        self.temp, self.pstate, self.counters = snap[0], snap[1], dict(snap[2])
        return self._hot()

    def observe(self, snap, now, reasons):
        t, p, counters = snap
        self.temp, self.pstate = t, p
        moved = sorted({THROTTLE_FIELDS[f] for f, v in counters.items()
                        if f in THROTTLE_FIELDS and f in self.counters and v > self.counters[f]})
        self.counters.update(counters)
        out = []
        if moved:
            self.last_move = now
            mask = reasons()
            self.active = [name for bit, name in REASON_BITS if mask & bit]
            if self.throttling is None:
                self.throttling = set(moved)
                out.append(Event('gpu-throttle', 'start', [('reason', ','.join(moved)), ('temp', t), ('pstate', p)], 'nvml'))
            elif not set(moved) <= self.throttling:
                self.throttling |= set(moved)
                out.append(Event('gpu-throttle', 'change', [('reason', ','.join(sorted(self.throttling))), ('temp', t),
                                                            ('pstate', p)], 'nvml'))
        elif self.throttling is not None and now - self.last_move >= self.cfg['GPU_THROTTLE_QUIET_SECS']:
            out.append(Event('gpu-throttle', 'end', [('reason', ','.join(sorted(self.throttling))), ('temp', t),
                                                     ('pstate', p)], 'nvml'))
            self.throttling = None
            self.active = []
        return out + self._hot()

    def _hot(self):
        t = self.temp
        if t is None:
            return []
        if not self.hot and t >= self.cfg['GPU_HOT']:
            self.hot = True
            return [Event('gpu-hot', 'start', [('temp', t)], 'nvml')]
        if self.hot and t <= self.cfg['GPU_HOT'] - self.cfg['GPU_HYST']:
            self.hot = False
            return [Event('gpu-hot', 'end', [('temp', t)], 'nvml')]
        return []

    def state(self):
        return {'temp': self.temp, 'pstate': self.pstate, 'hot': self.hot,
                'throttling': sorted(self.throttling) if self.throttling else None, 'active_reasons': self.active,
                'wait_timeout_ms': None if self.timeout_ms() == NVML_INFINITE else self.timeout_ms()}


class NvmlThread(threading.Thread):
    """Blocks in nvmlEventSetWait and posts what it finds to the main loop.

    Messages (through post(), which also writes the self-pipe):
      ('mode', mode, reason)   ('xid', kind, code)   ('event', Event)
      ('gpu', state dict)      ('log', priority, text)
    """

    def __init__(self, cfg, post, backend_factory, clock=time.monotonic, sleep=time.sleep):
        super().__init__(name='nvml', daemon=True)
        self.cfg, self.post, self.factory, self.clock, self.sleep = cfg, post, backend_factory, clock, sleep
        self.stopping = False

    def run(self):
        while not self.stopping:
            try:
                retry = self.session()
            except Exception as e:  # a bug here must not end GPU events for good
                self.post(('mode', 'degraded', f'the NVML thread failed: {e!r}'))
                retry = self.cfg['NVML_RETRY_SECS']
            if retry is None or self.stopping:
                return
            self.sleep(retry)

    def open(self):
        """(backend, device, event set, mask), or a ('mode', ...) message and a retry time."""
        try:
            be = self.factory()
        except (OSError, AttributeError) as e:
            return None, ('off', f'no NVML library ({e})'), None
        rc = be.init()
        if rc:
            reason = f'nvmlInit: {be.error(rc)}'
            if rc == NVML_MISMATCH:
                reason += '; an nvidia update is waiting for a reboot'
            return None, ('degraded', reason), self.cfg['NVML_RETRY_SECS']
        rc, dev = be.device(0)
        if rc:
            be.shutdown()
            return None, ('off', f'no NVIDIA GPU: {be.error(rc)}'), None
        rc, sup = be.supported_events(dev)
        mask = NVML_WANT & (sup if rc == 0 else 0)
        rc, es = be.event_set()
        if rc:
            be.shutdown()
            return None, ('degraded', f'nvmlEventSetCreate: {be.error(rc)}'), self.cfg['NVML_RETRY_SECS']
        rc = be.register(dev, mask, es)
        if rc:
            be.free(es)
            be.shutdown()
            return None, ('degraded', f'nvmlDeviceRegisterEvents(0x{mask:x}): {be.error(rc)}'), self.cfg['NVML_RETRY_SECS']
        return (be, dev, es, mask), None, None

    def snapshot(self, be, dev):
        rc, t = be.temperature(dev)
        if rc == NVML_GPU_LOST:
            raise GpuLost()
        rc2, p = be.pstate(dev)
        if rc2 == NVML_GPU_LOST:
            raise GpuLost()
        rc3, counters = be.counters(dev)
        if rc3 == NVML_GPU_LOST:
            raise GpuLost()
        return (t if rc == 0 else None, p if rc2 == 0 else None, counters if rc3 == 0 else {})

    def probe(self):
        """--once: register and read one snapshot, then let go."""
        opened, mode, _ = self.open()
        if opened is None:
            return {'mode': mode[0], 'reason': mode[1]}
        be, dev, es, mask = opened
        try:
            logic = GpuLogic(self.cfg)
            logic.prime(self.snapshot(be, dev), self.clock())
            return {'mode': 'event', 'reason': f'events 0x{mask:x}', 'gpu': logic.state()}
        except GpuLost:
            return {'mode': 'off', 'reason': 'GPU lost'}
        finally:
            be.free(es)
            be.shutdown()

    def handle(self, event_type, data):
        if event_type == EV_XID:
            self.post(('xid', 'xid', int(data)))
        elif event_type == EV_UNAVAIL:
            self.post(('xid', 'unavailable', 0))
        elif event_type == EV_RECOVERY:
            self.post(('xid', 'recovery', int(data)))

    def session(self):
        opened, mode, retry = self.open()
        if opened is None:
            self.post(('mode',) + mode)
            return retry
        be, dev, es, mask = opened
        logic = GpuLogic(self.cfg)
        errors = 0
        try:
            for ev in logic.prime(self.snapshot(be, dev), self.clock()):
                self.post(('event', ev))
            self.post(('mode', 'event', f'events 0x{mask:x}'))
            self.post(('gpu', logic.state()))
            while not self.stopping:
                rc, et, data = be.wait(es, logic.timeout_ms())
                if rc == NVML_OK:
                    self.handle(et, data)
                    # Clock events come ~10/s while boost moves: coalesce them
                    # into one look, but never for more than a second.
                    end = self.clock() + 1.0
                    while self.clock() < end and not self.stopping:
                        rc, et, data = be.wait(es, self.cfg['GPU_COALESCE_MS'])
                        if rc != NVML_OK:
                            break
                        self.handle(et, data)
                    if rc == NVML_TIMEOUT:
                        rc = NVML_OK
                if rc == NVML_GPU_LOST:
                    raise GpuLost()
                if rc not in (NVML_OK, NVML_TIMEOUT):
                    errors += 1
                    if errors >= 10:
                        self.post(('mode', 'degraded', f'nvmlEventSetWait keeps failing: {be.error(rc)}'))
                        return self.cfg['NVML_RETRY_SECS']
                    self.post(('log', WARNING, f'nvmlEventSetWait: {be.error(rc)}; retrying in 5 s'))
                    self.sleep(5)
                    continue
                errors = 0
                snap = self.snapshot(be, dev)

                def reasons():
                    r, m = be.reasons(dev)
                    return m if r == 0 else 0
                for ev in logic.observe(snap, self.clock(), reasons):
                    self.post(('event', ev))
                self.post(('gpu', logic.state()))
        except GpuLost:
            self.post(('xid', 'lost', 0))
            self.post(('mode', 'off', 'the GPU is lost (fallen off the bus)'))
            return self.cfg['NVML_RETRY_SECS']
        finally:
            be.free(es)
            be.shutdown()
        return None


# ---- the kernel-log backstop ---------------------------------------------------------

# journalctl's --grep is only a prefilter; classify_kmsg() decides.
KMSG_GREP = r'NVRM: Xid|fallen off the bus|CTF\) detected|Critical Temperature Fault'
# Each anchored on the prefix the kernel itself puts first: the nvidia
# driver's "NVRM:" and amdgpu's dev_err() "amdgpu <PCI address>:". Kernel
# lines also carry names that devices and users choose (the input core logs
# every new device's name, and /dev/uinput, a USB or a Bluetooth device picks
# its own), so matched anywhere in the line these could be faked.
KMSG_XID = re.compile(r'NVRM: Xid \(PCI:[0-9a-fA-F:.]+\): (\d+)')
KMSG_LOST = re.compile(r'NVRM: .*fallen off the bus')
KMSG_CTF = re.compile(r'amdgpu [0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]: .*'
                      r'(?:GPU over temperature range\((?:SW|HW) CTF\) detected|Critical Temperature Fault\(aka CTF\) detected)')


def classify_kmsg(msg, subsystem=None):
    """(kind, code, gpu) for a kernel line that is a GPU error, else None.

    subsystem is the line's _KERNEL_SUBSYSTEM: amdgpu's dev_err() lines are
    the pci device's own.
    """
    m = KMSG_XID.match(msg)
    if m:
        return 'xid', int(m.group(1)), 'nvidia'
    if KMSG_LOST.match(msg):
        return 'lost', 0, 'nvidia'
    if KMSG_CTF.match(msg) and subsystem in (None, 'pci'):
        return 'ctf', 0, 'amdgpu'
    return None


class KmsgFollower:
    """`journalctl -k -f` for GPU error lines; journald wakes it (inotify)."""

    def __init__(self, d):
        self.d = d
        self.proc = None
        self.buf = b''
        self.use_grep = True
        self.started = None
        self.failures = 0
        self.mode, self.reason = 'off', 'not started'
        self.announced = False

    def argv(self):
        a = [self.d.cfg['JOURNALCTL'], '-k', '-f', '-n', '0', '-o', 'json', '--output-fields=MESSAGE,_KERNEL_SUBSYSTEM']
        if self.use_grep:
            a += ['--grep', KMSG_GREP, '--case-sensitive=yes']
        return a

    def start(self):
        try:
            self.proc = subprocess.Popen(self.argv(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         close_fds=True)
        except OSError as e:
            self.proc = None
            self.failed(f'cannot run journalctl: {e}')
            return
        self.started = self.d.clock()
        fd = self.proc.stdout.fileno()
        os.set_blocking(fd, False)
        self.d.register(fd, select.POLLIN, lambda rev: self.on_readable())
        self.mode, self.reason = 'event', 'following the kernel log'
        self.d.set_timer('kmsg-healthy', self.started + 60, self.healthy)
        self.d.mark_dirty()

    def healthy(self):
        if self.proc is not None and self.proc.poll() is None:
            self.failures = 0
            if self.announced:
                self.announced = False
                self.d.emit(Event('thermal-monitor', 'restored', [('source', 'kmsg'), ('reason', self.reason)], 'kmsg'))

    def on_readable(self):
        fd = self.proc.stdout.fileno()
        while True:
            try:
                data = os.read(fd, 65536)
            except BlockingIOError:
                return
            except OSError:
                data = b''
            if not data:
                self.on_exit()
                return
            self.buf += data
            *lines, self.buf = self.buf.split(b'\n')
            for line in lines:
                self.on_line(line)

    def on_line(self, line):
        try:
            obj = json.loads(line)
        except ValueError:
            return
        msg = obj.get('MESSAGE')
        if isinstance(msg, list):  # journald's JSON for a non-UTF-8 message
            msg = bytes(x & 0xFF for x in msg if isinstance(x, int)).decode('utf-8', 'replace')
        if not isinstance(msg, str):
            return
        sub = obj.get('_KERNEL_SUBSYSTEM')
        hit = classify_kmsg(msg, sub if isinstance(sub, str) else None)
        if hit:
            self.d.gpu_xid(hit[0], hit[1], hit[2], 'kmsg')

    def on_exit(self):
        fd = self.proc.stdout.fileno()
        self.d.unregister(fd)
        rc = self.proc.wait()
        self.proc.stdout.close()
        ran = self.d.clock() - (self.started or 0)
        self.proc = None
        self.d.cancel_timer('kmsg-healthy')
        if self.d.stopping:
            return
        if rc != 0 and self.use_grep and ran < 5:
            # journalctl without PCRE2 refuses --grep: filter here instead.
            self.use_grep = False
            self.d.log(NOTICE, f'journalctl --grep failed (exit {rc}); following the kernel log unfiltered')
            self.start()
            return
        self.failed(f'journalctl exited ({rc}) after {ran:.0f} s')

    def failed(self, why):
        self.failures += 1
        delay = min(300, 5 * 2 ** min(self.failures - 1, 6))
        self.mode, self.reason = 'off', f'{why}; restarting in {delay} s'
        self.d.log(WARNING, f'kernel-log follower: {self.reason}')
        if self.failures >= 3 and not self.announced:
            self.announced = True
            self.d.emit(Event('thermal-monitor', 'degraded', [('source', 'kmsg'), ('reason', why)], 'kmsg'))
        self.d.set_timer('kmsg-restart', self.d.clock() + delay, self.start)
        self.d.mark_dirty()

    def stop(self):
        if self.proc is not None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                self.proc.kill()


# ---- the daemon ---------------------------------------------------------------------


class Daemon:
    def __init__(self, conf_path=CONF_PATH, checkup_path=CHECKUP_CONF_PATH, paths=None, clock=time.monotonic,
                 uevents=None, watch_factory=AttrWatch, nvme_admin=None, nvml_factory=None, journal=None,
                 dry=False, signals=True):
        self.conf_path, self.checkup_path = conf_path, checkup_path
        self.paths = paths or paths_from_environ()
        self.clock = clock
        self.cfg, self.roles, self.config_warnings = load_config(conf_path, checkup_path)
        self.journal = journal or Journal(self.paths['journal'])
        self.delivery = Delivery(self.cfg, self.journal, clock, dry=dry)
        self.dry = dry
        self.watch_factory = watch_factory
        self.nvme_admin = nvme_admin or NvmeAdmin(self.paths['dev'])
        self.nvml_factory = nvml_factory or (lambda: CtypesNvml(self.cfg['NVML_LIBRARY']))
        self.uevents = uevents
        self.use_signals = signals
        self.poller = select.poll()
        self.handlers = {}
        self.timers = {}
        self.stopping = False
        self.dirty = False
        self.started = time.time()
        self.xid_seen = {}
        self.inbox = queue.Queue()
        self.pipe_r = self.pipe_w = None
        self.nvml = None
        self.nvml_state = {'mode': 'off', 'reason': 'not started'}
        self.kmsg = KmsgFollower(self)
        self.superio = SuperIO(self)
        self.nvme = Nvme(self)
        self.uevent_state = {'mode': 'off', 'reason': 'not open'}
        self.pending_signals = []
        self.tests = collections.OrderedDict()  # --test-event requests: nonce -> record
        self.delivery.on_request = self.test_result

    # -- plumbing

    def log(self, priority, message, **fields):
        if not self.dry:
            self.journal.send(message, priority, **fields)

    def emit(self, ev, journal_only=False):
        if journal_only:
            ev.journal_only = True
            ev.priority = INFO
        self.delivery.deliver(ev)
        self.mark_dirty()

    def gpu_xid(self, kind, code, gpu, via):
        """gpu-xid from NVML or the kernel log, once: the two sources report the
        same Xid within moments of each other."""
        now = self.clock()
        window = 60 if kind == 'lost' else self.cfg['XID_DEDUP_SECS']
        key = (gpu, kind, code)
        last = self.xid_seen.get(key)
        self.xid_seen[key] = now
        if last is not None and now - last < window:
            return
        self.emit(Event('gpu-xid', 'info', [('code', code), ('kind', kind), ('gpu', gpu)], via))

    def register(self, fd, mask, callback):
        self.handlers[fd] = callback
        self.poller.register(fd, mask)

    def unregister(self, fd):
        if self.handlers.pop(fd, None) is not None:
            try:
                self.poller.unregister(fd)
            except (KeyError, ValueError):
                pass

    def open_watch(self, path, callback, name):
        w = self.watch_factory(path)
        # Arm it: a fresh sysfs descriptor reports POLLPRI until read once.
        try:
            w.read()
        except OSError:
            pass
        self.register(w.fileno(), w.mask, lambda rev: callback(name))
        return w

    def close_watch(self, w):
        if w.fileno() is not None:
            self.unregister(w.fileno())
        w.close()

    def set_timer(self, name, deadline, fn):
        self.timers[name] = (deadline, fn)

    def cancel_timer(self, name):
        self.timers.pop(name, None)

    def has_timer(self, name):
        return name in self.timers

    def mark_dirty(self):
        self.dirty = True

    def next_timeout(self):
        """Seconds until the next timer, or None: nothing is due, sleep until woken."""
        deadlines = [d for d, _ in self.timers.values()] + self.delivery.deadlines()
        if not deadlines:
            return None
        return max(0.0, min(deadlines) - self.clock())

    def run_timers(self):
        now = self.clock()
        for name, (deadline, fn) in sorted(self.timers.items(), key=lambda kv: kv[1][0]):
            if deadline <= now and self.timers.get(name, (None,))[0] == deadline:
                del self.timers[name]
                try:
                    fn()
                except Exception as e:  # one bad timer must not stop the others
                    self.log(ERR, f'error in timer {name}: {e!r}')

    # -- start and stop

    def start(self):
        self.log(INFO, f'starting (pid {os.getpid()}, config {self.conf_path})')
        for w in self.config_warnings:
            self.log(WARNING, w)
        self.load_previous_state()
        for path in glob.glob(f'{self.runtime_dir()}/test-*.json'):  # a --test-event from before a restart
            try:
                os.unlink(path)
            except OSError:
                pass
        if self.use_signals:
            self.setup_signals()
        self.pipe_r, self.pipe_w = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        self.register(self.pipe_r, select.POLLIN, lambda rev: self.drain_inbox())
        self.open_uevents()
        self.superio.attach('resync')
        self.nvme.scan(arm=True, via='resync')
        if self.cfg['NVML']:
            self.nvml = NvmlThread(self.cfg, self.post, self.nvml_factory, self.clock)
            self.nvml.start()
        else:
            self.nvml_state = {'mode': 'off', 'reason': 'NVML=0'}
        if self.cfg['KMSG_FOLLOW']:
            self.kmsg.start()
        else:
            self.kmsg.mode, self.kmsg.reason = 'off', 'KMSG_FOLLOW=0'
        self.write_state()
        sd_notify('READY=1\nSTATUS=' + self.status_line())

    def status_line(self):
        nm, _ = self.nvme.mode()
        return f'nct6775 {self.superio.mode}, nvme {nm}, nvml {self.nvml_state["mode"]}, kmsg {self.kmsg.mode}'

    def load_previous_state(self):
        """After a restart, do not announce a degraded source again that the
        previous run already announced (a crash loop would toast each time)."""
        try:
            with open(self.cfg['STATE_FILE']) as fh:
                src = json.load(fh).get('sources', {})
            a = src.get('nct6775', {}).get('announced')
            if a:
                self.superio.announced = tuple(a)
            self.nvml_state['announced'] = src.get('nvml', {}).get('announced')
            self.kmsg.announced = bool(src.get('kmsg', {}).get('announced'))
        except (OSError, ValueError, AttributeError, TypeError):
            pass

    def setup_signals(self):
        self.sig_r, self.sig_w = os.pipe2(os.O_NONBLOCK | os.O_CLOEXEC)
        signal.set_wakeup_fd(self.sig_w, warn_on_full_buffer=False)
        for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGCHLD, signal.SIGUSR1):
            signal.signal(s, self.on_signal)
        self.register(self.sig_r, select.POLLIN, lambda rev: self.drain_signals())

    def on_signal(self, signum, frame):
        self.pending_signals.append(signum)

    def drain_signals(self):
        try:
            while os.read(self.sig_r, 256):
                pass
        except BlockingIOError:
            pass
        sigs, self.pending_signals = self.pending_signals, []
        for s in sigs:
            if s in (signal.SIGTERM, signal.SIGINT):
                self.stopping = True
            elif s == signal.SIGHUP:
                self.reload()
            elif s == signal.SIGUSR1:
                self.take_test_requests()

    # -- --test-event, through this process

    def runtime_dir(self):
        return os.path.dirname(self.cfg['STATE_FILE'])

    def take_test_requests(self):
        """Deliver the events `--test-event` left in the runtime directory.

        A root shell writes the request and sends SIGUSR1, so the test event
        goes through this process, in the service's sandbox, exactly as a real
        one would; its hook and toast results come back through state.json.
        Only root (the daemon's own user) can write that directory; a file
        anyone else could have written is refused all the same.
        """
        for path in sorted(glob.glob(f'{self.runtime_dir()}/test-*.json')):
            try:
                st = os.lstat(path)
                with open(path, encoding='utf-8') as fh:
                    req = json.load(fh) if stat.S_ISREG(st.st_mode) else None
            except (OSError, ValueError) as e:
                req, st = None, None
                self.log(WARNING, f'test request {os.path.basename(path)}: cannot read it: {e}')
            try:
                os.unlink(path)
            except OSError:
                pass
            if req is None:
                continue
            if st.st_uid != os.geteuid() or st.st_mode & 0o022:
                self.log(WARNING, f'test request {os.path.basename(path)} refused: not written by uid {os.geteuid()}')
                continue
            nonce = str(req.get('nonce', ''))
            if not re.fullmatch(r'[0-9a-f]{8,64}', nonce):
                continue
            try:
                keys = [(str(k), v) for k, v in req.get('keys', [])]
                ev = Event(str(req.get('event')), str(req.get('state')), keys, 'test', test=True)
            except (ValueError, TypeError) as e:
                self.tests[nonce] = {'error': str(e), 'done': True}
                self.mark_dirty()
                continue
            ev.request = nonce
            record = {'id': None, 'event': ev.name, 'state': ev.state, 'args': ev.args(), 'pending': 0, 'done': False}
            self.tests[nonce] = record
            hook, toast = self.delivery.deliver(ev)
            record.update({'id': ev.id, 'hook': hook, 'toast': toast})
            record['pending'] = (hook == 'queued') + (toast == 'queued')
            record['done'] = record['pending'] == 0
            while len(self.tests) > 8:
                self.tests.popitem(last=False)
            self.mark_dirty()

    def test_result(self, ev, what, outcome, rc, err):
        record = self.tests.get(ev.request)
        if record is None:
            return
        record[f'{what}_result'] = outcome
        detail = (f'exit {rc}' if rc is not None else '') + (f': {err}' if err else '')
        if detail:
            record[f'{what}_detail'] = detail.lstrip(': ')[:400]
        record['pending'] = max(0, record.get('pending', 0) - 1)
        record['done'] = record['pending'] == 0
        self.mark_dirty()

    def reload(self):
        cfg, roles, warnings = load_config(self.conf_path, self.checkup_path)
        # Updated in place, never emptied: the NVML thread reads it meanwhile.
        self.cfg.update(cfg)
        for key in [k for k in self.cfg if k not in cfg]:
            del self.cfg[key]  # an NVME_<role>_* line that was removed
        self.roles = roles
        for w in warnings:
            self.log(WARNING, w)
        c = self.cfg
        t = self.superio.cpu
        t.warn, t.crit, t.hyst, t.dwell, t.held_after = (c['CPU_WARN'], c['CPU_CRIT'], c['CPU_HYST'],
                                                          c['CPU_DWELL_SECS'], c['CPU_CRIT_TOAST_SECS'])
        self.delivery.limiter = HookLimiter(c['HOOK_RATE_PER_MIN'], c['HOOK_KEY_RATE_PER_MIN'])
        self.log(INFO, 'reloaded the settings')
        self.superio.check_mode()
        self.superio.resync('resync')
        self.nvme.scan(arm=True, via='resync')

    def open_uevents(self):
        try:
            if self.uevents is None:
                self.uevents = UeventSocket()
            self.register(self.uevents.fileno(), select.POLLIN, lambda rev: self.on_uevents())
            self.uevent_state = {'mode': 'event', 'reason': 'kernel uevents (netlink group 1)'}
        except OSError as e:
            self.uevents = None
            self.uevent_state = {'mode': 'off', 'reason': f'no uevent socket: {e}'}
            self.log(ERR, f'cannot open the uevent socket: {e}; hwmon and NVMe events are off')

    def shutdown(self):
        sd_notify('STOPPING=1')
        self.stopping = True
        if self.nvml:
            self.nvml.stopping = True
        self.nvme.restore_all()
        self.kmsg.stop()
        self.log(INFO, 'stopped')
        self.write_state()

    # -- the loop

    def run(self):
        self.start()
        try:
            while not self.stopping:
                self.step()
        finally:
            self.shutdown()

    def step(self, max_wait=None):
        timeout = self.next_timeout()
        if max_wait is not None:
            timeout = max_wait if timeout is None else min(timeout, max_wait)
        ms = None if timeout is None else int(math.ceil(timeout * 1000))
        try:
            ready = self.poller.poll(ms)
        except InterruptedError:
            ready = []
        for fd, rev in ready:
            cb = self.handlers.get(fd)
            if cb is not None:
                try:
                    cb(rev)
                except Exception as e:  # one bad input must not stop the others
                    self.log(ERR, f'error handling fd {fd}: {e!r}')
        self.delivery.reap()
        self.delivery.expire(self.clock())
        self.run_timers()
        if self.dirty:
            self.write_state()

    def post(self, msg):
        """From the NVML thread: queue a message and wake the loop."""
        self.inbox.put(msg)
        try:
            os.write(self.pipe_w, b'!')
        except (BlockingIOError, OSError):
            pass

    def drain_inbox(self):
        try:
            while os.read(self.pipe_r, 4096):
                pass
        except BlockingIOError:
            pass
        while True:
            try:
                msg = self.inbox.get_nowait()
            except queue.Empty:
                return
            kind = msg[0]
            if kind == 'event':
                self.emit(msg[1])
            elif kind == 'xid':
                self.gpu_xid(msg[1], msg[2], 'nvidia', 'nvml')
            elif kind == 'mode':
                self.set_nvml_mode(msg[1], msg[2])
            elif kind == 'gpu':
                self.nvml_state['gpu'] = msg[1]
                self.mark_dirty()
            elif kind == 'log':
                self.log(msg[1], msg[2])

    def set_nvml_mode(self, mode, reason):
        prev = self.nvml_state.get('mode')
        announced = self.nvml_state.get('announced')
        self.nvml_state.update({'mode': mode, 'reason': reason})
        self.log(INFO if mode == 'event' else WARNING, f'NVML: {mode}: {reason}')
        # A machine without an NVIDIA GPU is simply "off"; a GPU whose NVML
        # broke (an nvidia update before the reboot, a lost GPU) is news.
        if mode == 'degraded' or (mode == 'off' and prev == 'event'):
            if announced != reason:
                self.nvml_state['announced'] = reason
                self.emit(Event('thermal-monitor', 'degraded', [('source', 'nvml'), ('reason', reason)], 'nvml'))
        elif mode == 'event' and announced:
            self.nvml_state['announced'] = None
            self.emit(Event('thermal-monitor', 'restored', [('source', 'nvml'), ('reason', reason)], 'nvml'))
        self.mark_dirty()

    def on_uevents(self):
        overflow = False
        try:
            events = self.uevents.read()
        except UeventOverflow as e:
            events, overflow = e.events, True
        for env in events:
            self.on_uevent(env)
        if overflow:
            self.resync('the uevent queue overflowed (ENOBUFS)')

    def on_uevent(self, env):
        sub, action, devpath = env.get('SUBSYSTEM'), env.get('ACTION'), env.get('DEVPATH', '')
        if sub == 'hwmon':
            if action == 'add':
                self.superio.on_hwmon_add(devpath)
                self.nvme.on_hwmon_add(devpath)
            elif action == 'remove':
                self.superio.on_hwmon_remove(devpath)
            elif action == 'change' and env.get('NAME', '').endswith('_alarm') and self.superio.owns(devpath):
                self.superio.on_alarm(env['NAME'], 'uevent')
        elif sub == 'nvme':
            ctrl = os.path.basename(devpath)
            if not re.fullmatch(r'nvme\d+', ctrl):
                return
            if action == 'add':
                self.nvme.on_add(ctrl, 'uevent')
            elif action == 'remove':
                self.nvme.on_remove(ctrl)
            elif action == 'change':
                if env.get('NVME_EVENT') == 'connected':
                    self.nvme.on_add(ctrl, 'uevent')
                if env.get('NVME_AEN'):
                    self.nvme.on_aen(ctrl, env['NVME_AEN'])

    def resync(self, why):
        self.log(NOTICE, f'{why}: reading everything again')
        # The lost uevents may have been the Super I/O's remove and add
        self.superio.recheck('resync')
        self.nvme.scan(arm=True, via='resync')

    # -- state

    def state(self):
        d = self.delivery
        nm, nr = self.nvme.mode()
        nvme = self.nvme.state()
        return {
            'version': 1,
            'pid': os.getpid(),
            'started': iso(self.started),
            'updated': iso(time.time()),
            'stopping': self.stopping,
            'sources': {
                'uevent': self.uevent_state,
                'nct6775': self.superio.state(),
                'nvme': nvme,
                'nvml': dict(self.nvml_state),
                'kmsg': {'mode': self.kmsg.mode, 'reason': self.kmsg.reason, 'announced': self.kmsg.announced},
            },
            'hooks': {'user': self.cfg['HOOK_USER'], 'counts': dict(d.counts)},
            'last_events': list(d.recent),
            'accepts': ['test-event'],
            'tests': dict(self.tests),
        }

    def write_state(self):
        self.dirty = False
        if self.dry:
            return
        path = self.cfg['STATE_FILE']
        tmp = f'{path}.tmp'
        try:
            with open(tmp, 'w') as fh:
                json.dump(self.state(), fh, indent=1)
                fh.write('\n')
            os.chmod(tmp, 0o644)
            os.replace(tmp, path)
        except OSError as e:
            if not getattr(self, '_state_warned', False):
                self._state_warned = True
                self.log(WARNING, f'cannot write {path}: {e}')


# ---- the command line ---------------------------------------------------------------

USAGE = __doc__.split('usage: ', 1)[1].strip()


class ReadOnlyAdmin:
    """--once's NVMe admin interface: Identify and Get Features only."""

    def __init__(self, admin):
        self.admin = admin

    def identify(self, ctrl):
        return self.admin.identify(ctrl)

    def get_feature(self, ctrl, fid, sel=0, cdw11=0):
        return self.admin.get_feature(ctrl, fid, sel=sel, cdw11=cdw11)

    def set_aen_config(self, ctrl, value):
        raise NvmeError('--once sends no Set Features')


def once_state(d):
    """What --once prints: every source detected once, nothing changed (d is dry)."""
    d.nvme_admin = ReadOnlyAdmin(d.nvme_admin)
    d.superio.attach('resync')
    d.nvme.scan(arm=False, via='resync')
    # Read-only look at each drive the daemon would arm: Identify and Get
    # Features only (as root; as a user the ioctl is refused and says so).
    for drive in d.nvme.drives.values():
        if drive.managed and not drive.reason.startswith('not armed:'):
            try:
                drive.ident = parse_identify(d.nvme_admin.identify(drive.ctrl))
                drive.case = 'A' if drive.ident['oaes'] & OAES_KERNEL_AER else 'B'
                drive.aen_config = d.nvme_admin.get_feature(drive.ctrl, FID_AEN)
                drive.reason = f'would arm (Case {drive.case})' if drive.case == 'A' or \
                    drive.aen_config & d.cfg['NVME_AEN_MASK'] else 'Case B: would not arm'
            except (OSError, NvmeError) as e:
                drive.reason = f'cannot read: {e}'
    if d.cfg['NVML']:
        d.nvml_state = NvmlThread(d.cfg, lambda m: None, d.nvml_factory).probe()
    else:
        d.nvml_state = {'mode': 'off', 'reason': 'NVML=0'}
    d.kmsg.mode, d.kmsg.reason = ('off', 'not started by --once')
    state = d.state()
    state['config_warnings'] = d.config_warnings
    state['cpu_would_be'] = d.superio.cpu.level
    return state


def cmd_once(args):
    state = once_state(Daemon(args.config, args.checkup_config, dry=True, signals=False))
    json.dump(state, sys.stdout, indent=1)
    print()
    return 0


def cmd_dump_state(args):
    cfg, _, _ = load_config(args.config, args.checkup_config)
    try:
        with open(cfg['STATE_FILE']) as fh:
            sys.stdout.write(fh.read())
    except OSError as e:
        print(f'kitchen-thermald: no state at {cfg["STATE_FILE"]} ({e.strerror}); is kitchen-thermal.service running?',
              file=sys.stderr)
        return 1
    return 0


SERVICE = 'kitchen-thermal.service'


def service_main_pid(systemctl):
    """kitchen-thermal.service's main PID, or None when it is not running."""
    try:
        out = subprocess.run([systemctl, 'show', '-P', 'MainPID', SERVICE], capture_output=True, text=True,
                             timeout=15).stdout.strip()
        return int(out) or None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def hand_to_daemon(ev, cfg, pid, kill=os.kill, clock=time.monotonic, sleep=time.sleep, pickup_secs=5.0):
    """Have the running daemon deliver a test event: (its record, None) or (record or None, why not).

    The request goes into the runtime directory (root's), SIGUSR1 tells the
    daemon, and its hook and toast results come back through state.json.
    """
    state_file = cfg['STATE_FILE']

    def record(nonce=None):
        try:
            with open(state_file, encoding='utf-8') as fh:
                st = json.load(fh)
        except (OSError, ValueError):
            return None
        return st if nonce is None else (st.get('tests') or {}).get(nonce)

    st = record()
    if st is None:
        return None, f'cannot read {state_file}'
    if st.get('pid') != pid or 'test-event' not in (st.get('accepts') or []):
        return None, (f'the running daemon (pid {pid}) does not take test events: it is older than this '
                      f'script. Restart it (sudo systemctl restart {SERVICE}) and try again')
    nonce = os.urandom(8).hex()
    runtime = os.path.dirname(state_file)
    tmp, path = f'{runtime}/.test-{nonce}.tmp', f'{runtime}/test-{nonce}.json'
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
        with os.fdopen(fd, 'w') as fh:
            json.dump({'nonce': nonce, 'event': ev.name, 'state': ev.state, 'keys': [[k, v] for k, v in ev.keys]}, fh)
        os.replace(tmp, path)
        kill(pid, signal.SIGUSR1)
    except OSError as e:
        for f in (tmp, path):
            try:
                os.unlink(f)
            except OSError:
                pass
        return None, f'cannot hand the event to the daemon: {e}'
    end, seen = clock() + pickup_secs, None
    while True:
        rec = record(nonce)
        if rec is not None and seen is None:
            seen, end = clock(), clock() + cfg['HOOK_TIMEOUT'] + 45
        if rec is not None and rec.get('done'):
            return rec, None
        if clock() >= end:
            break
        sleep(0.2)
    if seen is None:
        try:
            os.unlink(path)
        except OSError:
            pass
        return None, f'the daemon (pid {pid}) did not take the event within {pickup_secs:g} s'
    return rec, f'no result from the daemon after {cfg["HOOK_TIMEOUT"] + 45:g} s'


def print_results(hook, toast, results):
    print(f'  hook:    {hook}')
    print(f'  toast:   {toast}')
    for what, outcome, detail in results:
        print(f'  {what} finished: {outcome}' + (f' ({detail})' if detail else ''))
    ok = all(outcome == 'ok' for _, outcome, _ in results)
    return 0 if ok and hook in ('queued', 'journal-only', 'off') else 1


def cmd_test_event(args, rest):
    if len(rest) < 2:
        print('usage: kitchen-thermald.py [--local] --test-event EVENT STATE [KEY=VALUE...]', file=sys.stderr)
        return 2
    name, state, pairs = rest[0], rest[1], rest[2:]
    keys = []
    for p in pairs:
        k, eq, v = p.partition('=')
        if not eq:
            print(f'kitchen-thermald: {p!r} is not KEY=VALUE', file=sys.stderr)
            return 2
        try:
            v = to_number(v)
        except ValueError:
            pass
        keys.append((k, v))
    try:
        ev = Event(name, state, keys, 'test', test=True)
    except ValueError as e:
        print(f'kitchen-thermald: {e} (events: {", ".join(EVENTS)}; states: {", ".join(STATES)})', file=sys.stderr)
        return 2
    cfg, _, warnings = load_config(args.config, args.checkup_config)
    for w in warnings:
        print(f'kitchen-thermald: {w}', file=sys.stderr)

    # Through the service when it runs: that is what proves a deploy, since
    # its sandbox is not this shell's.
    pid = None if args.local or os.geteuid() != 0 else service_main_pid(cfg['SYSTEMCTL'])
    if pid:
        rec, why = hand_to_daemon(ev, cfg, pid)
        if rec is None:
            print(f'kitchen-thermald: {why}', file=sys.stderr)
            return 1
        if rec.get('error'):
            print(f'kitchen-thermald: the daemon refused the event: {rec["error"]}', file=sys.stderr)
            return 1
        print(f'event {rec.get("id")}: {ev.name} {ev.state} {" ".join(ev.args())} (delivered by {SERVICE}, pid {pid})')
        print(f'  journal: sent (SYSLOG_IDENTIFIER={IDENT}, KITCHEN_TEST=1)')
        results = [(what, rec[f'{what}_result'], rec.get(f'{what}_detail', '')) for what in ('hook', 'toast')
                   if f'{what}_result' in rec]
        rc = print_results(rec.get('hook'), rec.get('toast'), results)
        if why:
            print(f'kitchen-thermald: {why}', file=sys.stderr)
            return 1
        return rc

    if not args.local:
        print(f'kitchen-thermald: {SERVICE} is not running' + ('' if os.geteuid() == 0 else ' or this is not root') +
              ', so this shell delivers the event itself, outside the service\'s sandbox: '
              'this does not show that the service can deliver it', file=sys.stderr)
    journal = Journal(paths_from_environ()['journal'])
    delivery = Delivery(cfg, journal, time.monotonic)
    results = []
    delivery.on_result = lambda what, outcome, rc, err: results.append(
        (what, outcome, ((f'exit {rc}' if rc is not None else '') + (f': {err}' if err else '')).lstrip(': ')))
    hook, toast = delivery.deliver(ev)
    print(f'event {ev.id}: {ev.name} {ev.state} {" ".join(ev.args())}')
    print(f'  journal: sent (SYSLOG_IDENTIFIER={IDENT}, KITCHEN_TEST=1)')
    ok = delivery.hooks.wait_idle(cfg['HOOK_TIMEOUT'] + 45) and delivery.toasts.wait_idle(160)
    rc = print_results(hook, toast, results)
    return rc if ok else 1


class Args:
    config = CONF_PATH
    checkup_config = CHECKUP_CONF_PATH
    local = False


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    args = Args()
    action, rest = 'run', []
    while argv:
        a = argv.pop(0)
        if a in ('-h', '--help'):
            print('usage: ' + USAGE)
            print('\noptions: --config FILE (default %s)  --checkup-config FILE (default %s)' % (CONF_PATH, CHECKUP_CONF_PATH))
            return 0
        if a == '--config' and argv:
            args.config = argv.pop(0)
        elif a == '--checkup-config' and argv:
            args.checkup_config = argv.pop(0)
        elif a == '--once':
            action = 'once'
        elif a == '--local':
            args.local = True
        elif a == '--dump-state':
            action = 'dump'
        elif a == '--test-event':
            action, rest = 'test', argv
            argv = []
        else:
            print(f'kitchen-thermald: unknown argument {a!r}; see --help', file=sys.stderr)
            return 2
    if action == 'once':
        return cmd_once(args)
    if action == 'dump':
        return cmd_dump_state(args)
    if action == 'test':
        return cmd_test_event(args, rest)
    Daemon(args.config, args.checkup_config).run()
    return 0


if __name__ == '__main__':
    sys.exit(main())
