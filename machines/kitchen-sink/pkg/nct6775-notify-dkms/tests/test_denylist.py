#!/usr/bin/python3
# Static tests for patch 0002, the read-only register dump. They read the
# patched nct6775-platform.c and check that:
#
# - the hard-coded denylists are exactly the chip's read-to-clear registers:
#   the hardware monitor's interrupt status registers, and configuration
#   space's GPIO and wake-up event status registers; nothing in the dump lists
#   (including the second byte of a word-sized register) is on them;
# - the register lists are the ones experiments E1 and E1b ask for;
# - the code can only reach the hardware monitor through the one guarded
#   helper, reads configuration space only after checking its denylist,
#   writes nothing but the logical-device select, checks the dump parameter
#   before any I/O, and makes root-only files for the platform driver only.
#
# The VM test (tests/vm) proves the same at runtime against a fake chip.
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
UPSTREAM = ['nct6775-core.c', 'nct6775-platform.c', 'nct6775-i2c.c', 'nct6775.h', 'lm75.h']

sys.dont_write_bytecode = True

# NCT6796D datasheet v0.6: Interrupt Status Registers 1, 2 and 4 (bank 0),
# 3 (bank 4), bank 5 0x67 and bank C 0x02/0x03 are "Read Clear".
READ_TO_CLEAR = {0x041, 0x042, 0x045, 0x450, 0x567, 0xC02, 0xC03}

# NCT6796D datasheet v0.6, section 24: the configuration registers marked
# "Read-Clear", as (logical device, register). Logical devices 7, 8 and 9:
# the GPIO event status registers; A: CRE3, the event status (thermal
# shutdown, PSIN, keyboard and mouse wake-up) firmware reads at _PTS/_WAK.
SIO_READ_TO_CLEAR = {(0x07, 0xE3), (0x07, 0xE7), (0x07, 0xF7),
                     (0x08, 0xE3), (0x08, 0xF3),
                     (0x09, 0xE3), (0x09, 0xE7), (0x09, 0xE8), (0x09, 0xF7),
                     (0x0A, 0xE3)}

# Experiment E1b in the approved design
E1B = ([0x018, 0x039, 0x03A, 0x040, 0x043, 0x044, 0x046, 0x04C] +
       list(range(0x152, 0x157)) + [0x451, 0x566, 0x621, 0x622] +
       list(range(0xC04, 0xC09)) + [0xC0C, 0xC0D] + list(range(0xC1A, 0xC2C)))

# Experiment E1: (logical device or None for global, register)
E1 = ([(None, r) for r in range(0x1A, 0x30)] +
      [(0x0B, 0x30)] + [(0x0B, r) for r in range(0x60, 0x66)] + [(0x0B, 0x70)] +
      [(0x0B, r) for r in range(0xE0, 0x100)] +
      [(0x0A, 0xE7)] + [(0x0A, r) for r in range(0xF2, 0xF8)] +
      [(0x0D, 0xE2)])


def patched_tree():
    """The vendored sources with the package's patches applied, in a temp dir."""
    tmp = tempfile.mkdtemp(prefix='nct6775-denylist-')
    hw = os.path.join(tmp, 'drivers', 'hwmon')
    os.makedirs(hw)
    for f in UPSTREAM:
        shutil.copy(os.path.join(PKG, f), hw)
    for p in sorted(f for f in os.listdir(PKG) if re.match(r'\d{4}-.*\.patch$', f)):
        subprocess.run(['patch', '-d', tmp, '-Np1', '--fuzz=0', '--no-backup-if-mismatch', '-s',
                        '-i', os.path.join(PKG, p)], check=True)
    return tmp


def read(path):
    with open(path) as f:
        return f.read()


TREE = patched_tree()
PLATFORM = read(os.path.join(TREE, 'drivers/hwmon/nct6775-platform.c'))
CORE = read(os.path.join(TREE, 'drivers/hwmon/nct6775-core.c'))
I2C = read(os.path.join(TREE, 'drivers/hwmon/nct6775-i2c.c'))
shutil.rmtree(TREE)


def c_array(src, name):
    """The integer initialisers of `static const u16 <name>[] = { ... };`."""
    m = re.search(r'static const u16 ' + re.escape(name) + r'\[\] = \{(.*?)\};', src, re.S)
    assert m, f'{name} not found'
    body = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    return [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', body)]


def function(src, name):
    """The text of a C function definition, from its name to the closing brace."""
    m = re.search(r'^[^\n]*\b' + re.escape(name) + r'\([^;{]*\)\n\{\n(.*?)^\}\n', src, re.S | re.M)
    assert m, f'function {name} not found'
    return m.group(1)


def dump_code():
    """Everything patch 0002 added between its header comment and the regmap config."""
    start = PLATFORM.index('Read-only register dump in debugfs')
    end = PLATFORM.index('static const struct regmap_config nct6775_regmap_config')
    return re.sub(r'/\*.*?\*/', '', PLATFORM[start:end], flags=re.S)


def nct6799_word_sized(core=CORE):
    """nct6775_reg_is_word_sized() for the nct6779..nct6799 kinds, as Python."""
    fn = function(core, 'nct6775_reg_is_word_sized')
    m = re.search(r'case nct6799:\s*return (.*?);', fn, re.S)
    assert m, 'nct6799 case not found in nct6775_reg_is_word_sized'
    expr = m.group(1).replace('||', ' or ').replace('&&', ' and ')
    return eval('lambda reg: bool(' + expr + ')')  # noqa: S307 - our own vendored source


def touched(platform=PLATFORM, core=CORE):
    """Every hardware-monitor address the dump list makes the chip read."""
    word = nct6799_word_sized(core)
    out = set()
    for reg in c_array(platform, 'nct6775_dump_hm_regs'):
        out.add(reg)
        if word(reg):
            out.add(reg + 1)
    return out


def lds(platform=PLATFORM):
    return {n: int(v, 16) for n, v in re.findall(r'#define (NCT6775_LD_\w+)\s+(0x[0-9a-fA-F]+)', platform)}


def ld_value(text, platform=PLATFORM):
    return lds(platform)[text] if text.startswith('NCT6775_LD_') else int(text, 16)


def sio_list(platform=PLATFORM):
    """nct6775_dump_sio_regs as [(logical device or None, register)]."""
    m = re.search(r'\} nct6775_dump_sio_regs\[\] = \{(.*?)\n\};', platform, re.S)
    assert m, 'nct6775_dump_sio_regs not found'
    regs = []
    for ld, first, last in re.findall(r'\{\s*(-1|NCT6775_LD_\w+|0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\}',
                                      m.group(1)):
        ldn = None if ld == '-1' else ld_value(ld, platform)
        regs += [(ldn, r) for r in range(int(first, 16), int(last, 16) + 1)]
    return regs


def sio_never_read(platform=PLATFORM):
    """nct6775_dump_sio_never_read as [(logical device, register)]."""
    m = re.search(r'\} nct6775_dump_sio_never_read\[\] = \{(.*?)\n\};', platform, re.S)
    assert m, 'nct6775_dump_sio_never_read not found'
    body = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    return [(ld_value(ld, platform), int(reg, 16))
            for ld, reg in re.findall(r'\{\s*(NCT6775_LD_\w+|0x[0-9a-fA-F]+),\s*(0x[0-9a-fA-F]+)\s*\}', body)]


class Denylist(unittest.TestCase):
    def test_is_exactly_the_read_to_clear_registers(self):
        never = c_array(PLATFORM, 'nct6775_dump_never_read')
        self.assertEqual(len(never), len(set(never)))
        self.assertEqual(set(never), READ_TO_CLEAR)

    def test_dump_list_avoids_it_including_word_reads(self):
        hm = c_array(PLATFORM, 'nct6775_dump_hm_regs')
        t = touched()
        self.assertFalse(t & READ_TO_CLEAR, sorted(hex(r) for r in t & READ_TO_CLEAR))
        # Word reads stay inside the list too (0x153/0x154, 0x155/0x156)
        self.assertTrue(t <= set(hm), sorted(hex(r) for r in t - set(hm)))
        word = nct6799_word_sized()
        self.assertEqual({r for r in hm if word(r)}, {0x153, 0x155})

    def test_the_check_catches_a_bad_list(self):
        # A read-to-clear register slipped into the list, and a listed
        # register that became word-sized (so its neighbour 0x045 is read)
        bad_list = PLATFORM.replace('0x040,\t\t\t/*', '0x040, 0x041,\t/*', 1)
        self.assertIn(0x041, touched(bad_list) & READ_TO_CLEAR)
        bad_core = CORE.replace('return reg == 0x150 ||', 'return reg == 0x044 || reg == 0x150 ||', 1)
        self.assertNotEqual(bad_core, CORE)
        self.assertIn(0x045, touched(PLATFORM, bad_core) & READ_TO_CLEAR)

    def test_config_space_list_is_exactly_its_read_to_clear_registers(self):
        never = sio_never_read()
        self.assertEqual(len(never), len(set(never)))
        self.assertEqual(set(never), SIO_READ_TO_CLEAR)

    def test_config_space_dump_avoids_them(self):
        listed = set(sio_list())
        self.assertFalse(listed & SIO_READ_TO_CLEAR, sorted(listed & SIO_READ_TO_CLEAR))

    def test_the_config_space_check_catches_a_bad_list(self):
        # Widening logical device A to E0-FF would take in CRE3
        bad = PLATFORM.replace('{ NCT6775_LD_ACPI, 0xe7, 0xe7 },', '{ NCT6775_LD_ACPI, 0xe0, 0xff },', 1)
        self.assertNotEqual(bad, PLATFORM)
        self.assertIn((0x0A, 0xE3), set(sio_list(bad)) & SIO_READ_TO_CLEAR)

    def test_word_size_rule_is_the_one_evaluated(self):
        # If the core's rule changes shape, the evaluation above needs a look
        word = nct6799_word_sized()
        self.assertTrue(word(0x150) and word(0x4c0) and word(0x409) and not word(0x40a))
        self.assertFalse(any(word(r) for r in READ_TO_CLEAR))


class RegisterLists(unittest.TestCase):
    def test_hm_list_is_e1b(self):
        hm = c_array(PLATFORM, 'nct6775_dump_hm_regs')
        self.assertEqual(len(hm), len(set(hm)))
        self.assertEqual(hm, E1B)

    def test_sio_list_is_e1(self):
        regs = sio_list()
        self.assertEqual(regs, E1)
        room = int(re.search(r'#define NCT6775_DUMP_SIO_MAX\s+(\d+)', PLATFORM).group(1))
        self.assertLessEqual(len(regs), room)


class Structure(unittest.TestCase):
    def test_one_guarded_path_to_the_hardware_monitor(self):
        code = dump_code()
        self.assertEqual(len(re.findall(r'\bnct6775_read_value\(', code)), 1)
        helper = function(PLATFORM, 'nct6775_dump_hm_read')
        self.assertIn('nct6775_read_value(', helper)
        self.assertLess(helper.index('nct6775_dump_denied(reg)'), helper.index('nct6775_read_value('))
        self.assertIn('nct6775_dump_denied(reg + 1)', helper)
        self.assertIn('nct6775_dump_hm_read(', function(PLATFORM, 'nct6775_hm_regs_show'))

    def test_config_space_read_only_after_the_check(self):
        sio = function(PLATFORM, 'nct6775_sio_regs_show')
        # Two reads in all: the select as found, and the guarded register read
        self.assertEqual(len(re.findall(r'->sio_inb\(', sio)), 2)
        guarded = re.search(r'if \(nct6775_dump_sio_denied\(dev, reg\)\)\n\t+val\[n\] = -EPERM;\n'
                            r'\t+else\n\t+val\[n\] = sio_data->sio_inb\(sio_data, reg\);', sio)
        self.assertTrue(guarded, 'the register read is not behind nct6775_dump_sio_denied()')
        # dev is the logical device the entry names (-1: global, never denied)
        self.assertIn('int dev = nct6775_dump_sio_regs[i].ld;', sio)
        helper = function(PLATFORM, 'nct6775_dump_sio_denied')
        self.assertIn('nct6775_dump_sio_never_read[i].ld', helper)
        self.assertIn('nct6775_dump_sio_never_read[i].reg', helper)

    def test_writes_nothing_but_the_logical_device_select(self):
        code = dump_code()
        for forbidden in (r'\bnct6775_write_value\(', r'\bnct6775_write_temp\(', r'\bregmap_\w+\(',
                          r'\bsio_outb\(', r'\boutb(_p)?\(', r'\binb(_p)?\(', r'\bsuperio_\w+\('):
            self.assertIsNone(re.search(forbidden, code), forbidden)
        self.assertEqual(len(re.findall(r'->sio_select\(', code)), 2)
        # The select is put back to what it was at entry
        sio = function(PLATFORM, 'nct6775_sio_regs_show')
        self.assertIn('ld = sio_data->sio_inb(sio_data, SIO_REG_LDSEL);', sio)
        self.assertIn('sio_data->sio_select(sio_data, ld);', sio)
        self.assertLess(sio.index('sio_select(sio_data, ld)'), sio.index('sio_exit(sio_data)'))

    def test_parameter_gates_every_read_before_any_io(self):
        self.assertRegex(PLATFORM, r'\nstatic bool dump;\nmodule_param\(dump, bool, 0644\);')
        for fn in ('nct6775_hm_regs_show', 'nct6775_sio_regs_show'):
            body = function(PLATFORM, fn)
            self.assertIn('if (!READ_ONCE(dump))\n\t\treturn -EPERM;', body)
            self.assertLess(body.index('READ_ONCE(dump)'), body.index('mutex_lock('))

    def test_files_are_root_only_and_platform_only(self):
        init = function(PLATFORM, 'nct6775_debugfs_init')
        self.assertIn('debugfs_create_file("sio_regs", 0400,', init)
        self.assertIn('debugfs_create_file("hm_regs", 0400,', init)
        self.assertNotRegex(init, r'debugfs_create_file\([^)]*, 0[0-7][1-7][0-7],')
        self.assertIn('sio_data->access != access_direct', init)
        self.assertIn('data->kind != nct6796 && data->kind != nct6799', init)
        self.assertEqual(I2C, read(os.path.join(PKG, 'nct6775-i2c.c')))
        self.assertNotIn('debugfs', CORE)


if __name__ == '__main__':
    unittest.main(verbosity=1)
