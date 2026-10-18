"""Regression tests for malformed executables and experimental table boundaries."""
import random
import struct
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import effects_aga
import gouraud
import hunkcheck


def words(*values):
    return struct.pack('>%dI' % len(values), *values)


class HunkTests(unittest.TestCase):
    header = words(0x3F3, 0, 1, 0, 0, 1)
    section = words(0x3E9, 1, 0x4E754E75)

    def test_valid_and_every_truncation(self):
        binary = self.header + self.section + words(0x3F2)
        self.assertEqual(hunkcheck.validate(binary)[0], ['code'])
        for length in range(len(binary)):
            with self.subTest(length=length), self.assertRaises(ValueError):
                hunkcheck.validate(binary[:length])

    def test_counted_names(self):
        binary = (words(0x3F3, 1) + b'lib\0' + words(0, 1, 0, 0, 1, 0x3E8, 1) +
                  b'foo\0' + self.section + words(0x3F2))
        self.assertEqual(hunkcheck.validate(binary)[3], ['foo'])

    def test_invalid_structure_and_relocations(self):
        cases = [self.header+self.section, self.header+words(0x3F2),
                 self.header+words(0x3E9, 2, 0, 0, 0x3F2),
                 self.header+self.section+self.section+words(0x3F2)]
        for target, offset in ((1, 0), (0, 1), (0, 2), (0, 4)):
            cases.append(self.header+self.section+words(0x3EC, 1, target, offset, 0, 0x3F2))
        for case in cases:
            with self.subTest(binary=case), self.assertRaises(ValueError):
                hunkcheck.validate(case)
        hunkcheck.validate(self.header+self.section+words(0x3EC, 1, 0, 0, 0, 0x3F2))


class EffectTests(unittest.TestCase):
    def test_starfield_reproducibility_without_global_rng_changes(self):
        before = random.getstate()
        stars = effects_aga.starfield_background(32, 16)
        self.assertEqual(before, random.getstate())
        self.assertEqual(stars, effects_aga.starfield_background(32, 16))

    def test_invalid_parameters(self):
        for operation in (lambda: effects_aga.starfield_background(0, 10),
                          lambda: effects_aga.starfield_background(10, 10, -1),
                          lambda: effects_aga.plasma_effect(-1, 10),
                          lambda: effects_aga.glow_sphere(0, 0, -1),
                          lambda: effects_aga.color_cycle_palette([], 1),
                          lambda: gouraud.sphere_shades(1, 8)):
            with self.assertRaises(ValueError):
                operation()

    def test_glow_and_normalized_lighting(self):
        self.assertEqual(effects_aga.glow_sphere(3, 4, 0), [(3, 4, 7)])
        self.assertEqual(gouraud.vertex_shade(0, 0, 0), 0)
        self.assertEqual(gouraud.vertex_shade(*gouraud.LIGHT), 7)
        self.assertEqual(gouraud.vertex_shade(*(10*c for c in gouraud.LIGHT)), 7)
        self.assertTrue(all(0 <= v <= 7 for v in gouraud.sphere_shades()))


class AssetValidationTests(unittest.TestCase):
    def test_malformed_and_unsupported_mods_have_diagnostics(self):
        import shutil
        import subprocess
        import tempfile
        root = Path(__file__).resolve().parents[1]
        original = (root/'assets/neon.mod').read_bytes()
        with tempfile.TemporaryDirectory(prefix='neon-invalid-mod-') as tmp:
            work = Path(tmp)
            (work/'tools').mkdir()
            shutil.copy(root/'tools/validate.py', work/'tools/validate.py')
            shutil.copytree(root/'src', work/'src')
            shutil.copytree(root/'assets', work/'assets')
            cases = [original[:100], original[:1100]]
            fine = bytearray(original); fine[44] = 1; cases.append(fine)
            note = bytearray(original); note[1084] &= 15; note[1086] &= 15; cases.append(note)
            arp = bytearray(original); arp[1086] &= 0xF0; arp[1087] = 0x12; cases.append(arp)
            unsigned = bytearray(original)
            start = 1084 + (max(original[952:952+original[950]])+1)*1024
            unsigned[start:] = bytes(v ^ 128 for v in unsigned[start:])
            cases.append(unsigned)
            for index, data in enumerate(cases):
                with self.subTest(case=index):
                    (work/'assets/neon.mod').write_bytes(data)
                    result = subprocess.run([sys.executable, str(work/'tools/validate.py')],
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('VALIDATION FAILED', result.stdout)
                    self.assertNotIn('Traceback', result.stderr)

    def test_manifest_excludes_toolchains_but_includes_gitignore(self):
        import tempfile
        import make_manifest
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ('tools/bin/assembler', 'tools/vendor/vasm/source.c', '.git/config',
                         'build/program', 'assets/.generated', 'assets/.generated-1234', '.gitignore', 'src/main.s'):
                path = root/name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('test')
            names = [line.split('  ', 1)[1] for line in make_manifest.manifest(root).splitlines()]
            self.assertEqual(names, ['.gitignore', 'src/main.s'])


class BuildTests(unittest.TestCase):
    def test_parallel_recovery_content_changes_and_readonly_verification(self):
        import os
        import shutil
        import subprocess
        import tempfile
        root = Path(__file__).resolve().parents[1]
        assembler = os.environ.get('VASM') or shutil.which('vasmm68k_mot')
        if not assembler and (root/'tools/bin/vasmm68k_mot').is_file():
            assembler = str(root/'tools/bin/vasmm68k_mot')
        if not assembler or not shutil.which('make'):
            self.skipTest('build regression needs Make and VASM')
        with tempfile.TemporaryDirectory(prefix='neon-build-test-') as tmp:
            work = Path(tmp)
            for name in ('src', 'assets', 'tools'):
                shutil.copytree(root/name, work/name,
                                ignore=shutil.ignore_patterns('bin', 'vendor', '__pycache__'))
            shutil.copy(root/'Makefile', work/'Makefile')
            spaced = work/'assembler tools'/'vasmm68k_mot'
            spaced.parent.mkdir()
            spaced.symlink_to(Path(assembler).resolve())
            env = dict(os.environ, VASM=str(spaced), PYTHONDONTWRITEBYTECODE='1')

            def run(*args):
                return subprocess.run(args, cwd=work, env=env, capture_output=True, text=True)

            def build(*goals):
                result = run('make', '-j8', 'PYTHON='+sys.executable, *goals)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                return result.stdout

            build()
            for name in ('logo.raw', 'font.raw', 'neon.mod', 'logo_preview.png'):
                (work/'assets'/name).unlink()
            self.assertEqual(build().count('tools/generate_assets.py\n'), 1)
            with (work/'tools/logo_art.py').open('a') as stream:
                stream.write('\n# Content dependency regression, without a timestamp delay.\n')
            self.assertEqual(build().count('tools/generate_assets.py\n'), 1)
            self.assertEqual(build('assets', 'all').count('tools/generate_assets.py\n'), 1)
            font = work/'assets/font.raw'
            font.write_bytes(b'broken')
            result = run('make', '-j8', 'PYTHON='+sys.executable)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('font size', result.stdout)
            result = run(sys.executable, 'tools/verify_repro.py')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('stale', result.stderr)
            self.assertEqual(font.read_bytes(), b'broken')


class StartupFailureTests(unittest.TestCase):
    def test_all_startup_failure_paths(self):
        import importlib.util
        import os
        import shutil
        import subprocess
        root = Path(__file__).resolve().parents[1]
        if importlib.util.find_spec('machine68k') is None:
            self.skipTest('startup execution checks need machine68k')
        if not (os.environ.get('VASM') or shutil.which('vasmm68k_mot') or
                (root/'tools/bin/vasmm68k_mot').is_file()):
            self.skipTest('startup execution checks need VASM')
        for flag in ('--open-fail', '--alloc-fail', '--alloc-fast'):
            with self.subTest(flag=flag):
                result = subprocess.run([sys.executable, str(root/'tools/emu_test.py'),
                                         flag, '--frames', '4', '--snap', '3'],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('EMULATION TEST PASSED', result.stdout)

    def test_failure_checks_detect_register_and_library_leaks(self):
        import importlib.util
        import os
        import shutil
        import subprocess
        import tempfile
        root = Path(__file__).resolve().parents[1]
        assembler = os.environ.get('VASM') or shutil.which('vasmm68k_mot')
        if not assembler and (root/'tools/bin/vasmm68k_mot').is_file():
            assembler = str(root/'tools/bin/vasmm68k_mot')
        if not assembler or importlib.util.find_spec('machine68k') is None:
            self.skipTest('startup mutation checks need machine68k and VASM')
        original = (root/'src/main.s').read_text()
        mutations = (
            ('--open-fail',
             '.open_fail:\n        movem.l (sp)+,d0-d7/a0-a6',
             '.open_fail:\n        movem.l (sp)+,d0-d7/a0-a6\n        moveq #1,d1',
             'd1 not preserved'),
            ('--alloc-fail',
             '.alloc_fail:\n        move.l  4.w,a6\n        move.l  gfx_base,a1\n        jsr     LVO_CloseLibrary(a6)',
             '.alloc_fail:\n        move.l  4.w,a6\n        move.l  gfx_base,a1',
             'graphics.library not closed'),
        )
        with tempfile.TemporaryDirectory(prefix='neon-startup-mutant-') as tmp:
            work = Path(tmp)
            for name in ('tools', 'assets', 'src'):
                shutil.copytree(root/name, work/name,
                                ignore=shutil.ignore_patterns('bin', 'vendor', '__pycache__'))
            for flag, old, new, diagnostic in mutations:
                with self.subTest(flag=flag):
                    self.assertIn(old, original)
                    (work/'src/main.s').write_text(original.replace(old, new, 1))
                    result = subprocess.run([sys.executable, str(work/'tools/emu_test.py'),
                                             flag, '--frames', '4', '--snap', '3'],
                                            env=dict(os.environ, VASM=assembler),
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('FAIL: '+diagnostic, result.stdout)
                    self.assertNotIn('Traceback', result.stderr)


class EffectsMusicTests(unittest.TestCase):
    def test_motion_lookup_preserves_fixed_point_path(self):
        import math
        import gen_tables
        expected = [((round(127*math.sin(2*math.pi*k/256))*13)>>7)+13 for k in range(256)]
        self.assertEqual(gen_tables.bar_motion(), expected)
        wave = gen_tables.wave_tab()
        self.assertEqual(len(wave), 256)
        self.assertTrue(all(2 <= (v & 15) <= 14 and v >> 4 == v & 15 for v in wave))
        pulse = gen_tables.raster_palette()
        self.assertEqual(len(pulse), 32)
        self.assertEqual(pulse[0], 0x210)
        self.assertEqual(pulse[16], 0xFFF)
        self.assertEqual(pulse[1], pulse[-1])

    def test_music_voices_arrangement_and_sample_endpoints(self):
        root = Path(__file__).resolve().parents[1]
        mod = (root/'assets/neon.mod').read_bytes()
        order = list(mod[952:952+mod[950]])
        self.assertEqual(order, [0,1,2,1,3,2,4,5])
        self.assertEqual(len(set(order)), 6)
        offset = 1084+(max(order)+1)*1024
        count = 0
        for instrument in range(31):
            header = 20+instrument*30
            size = int.from_bytes(mod[header+22:header+24], 'big')*2
            data = [v if v < 128 else v-256 for v in mod[offset:offset+size]]
            offset += size
            if not size:
                continue
            count += 1
            self.assertLessEqual(abs(sum(data)/size), 8)
            loop = int.from_bytes(mod[header+28:header+30], 'big')
            if loop <= 1:
                self.assertEqual((data[0], data[-1]), (0,0))
            else:
                self.assertLessEqual(max(abs(data[i]-data[i-1]) for i in range(size)), 40)
        self.assertEqual(count, 8)
        self.assertEqual(offset, len(mod))


class ReleasePackageTests(unittest.TestCase):
    def test_archive_is_reproducible_and_checksums_every_payload(self):
        import hashlib
        import tempfile
        import zipfile
        import package_release
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root/'neon_vectors'
            binary.write_bytes(HunkTests.header+HunkTests.section+words(0x3F2))
            first, second = root/'first.zip', root/'second.zip'
            one = package_release.write_package(binary, first, 'a'*40)
            two = package_release.write_package(binary, second, 'a'*40)
            self.assertEqual(one, two)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(set(archive.namelist()),
                                 {'neon_vectors', 'README.txt', 'BUILD_INFO.txt', 'SHA256SUMS'})
                for line in archive.read('SHA256SUMS').decode().splitlines():
                    digest, name = line.split('  ', 1)
                    self.assertEqual(hashlib.sha256(archive.read(name)).hexdigest(), digest)
                self.assertEqual(archive.getinfo('neon_vectors').external_attr >> 16, 0o100755)
                self.assertIn('a'*40, archive.read('BUILD_INFO.txt').decode())
            with self.assertRaises(ValueError):
                package_release.write_package(binary, first, 'main')
            binary.write_bytes(b'broken')
            with self.assertRaises(ValueError):
                package_release.write_package(binary, first, 'a'*40)


class ChoreographyTests(unittest.TestCase):
    def test_scene_lighting_banks_are_bounded_and_distinct(self):
        import gen_tables
        banks = gen_tables.bar_palettes()
        self.assertEqual(len(banks), 8*4*32)
        self.assertTrue(all(0 <= value <= 0xFFF for value in banks))
        self.assertEqual(len({tuple(banks[scene*128:scene*128+32]) for scene in range(8)}), 8)
        for scene in range(8):
            for colour in range(32):
                shades = [banks[scene*128+level*32+colour] for level in range(4)]
                for shift in (0,4,8):
                    components = [(shade>>shift)&15 for shade in shades]
                    self.assertEqual(components, sorted(components))

    def test_onset_reference_uses_notes_and_decays_to_zero(self):
        import importlib.util
        if importlib.util.find_spec('machine68k') is None:
            self.skipTest('emulation reference needs machine68k')
        import emu_test
        module = bytearray(1084+1024)
        module[950] = 1
        # A kick on row 0, with a valid period, then no more notes.
        module[1084:1088] = bytes((1,172,0x30,0))
        self.assertEqual([emu_test.ref_visual_pulse(frame,module) for frame in (0,1,2,15,16,40)],
                         [0,15,14,1,0,0])
        module[1084:1088] = bytes((0,0,0x30,0))
        self.assertEqual(emu_test.ref_visual_pulse(1,module),0)
        module[1084:1088] = bytes((1,172,0x10,0))
        self.assertEqual(emu_test.ref_visual_pulse(1,module),0)


class ReferencePhaseTests(unittest.TestCase):
    def test_constant_time_phase_matches_frame_by_frame_accumulation(self):
        import importlib.util
        if importlib.util.find_spec('machine68k') is None:
            self.skipTest('emulation reference needs machine68k')
        import emu_test
        for updates in (0,1,254,255,256,257,2047,2048,4096,6144,6400,65535):
            with self.subTest(updates=updates):
                expected = sum(emu_test.scene(frame)[1] for frame in range(1,updates+1))
                self.assertEqual(emu_test.spin_phase(updates), expected)
        with self.assertRaises(ValueError):
            emu_test.spin_phase(-1)


class ScrollerWrapTests(unittest.TestCase):
    def test_message_wrap_preserves_the_already_displayed_tail(self):
        import importlib.util
        import os
        import re
        import shutil
        import subprocess
        import tempfile
        root = Path(__file__).resolve().parents[1]
        assembler = os.environ.get('VASM') or shutil.which('vasmm68k_mot')
        if not assembler and (root/'tools/bin/vasmm68k_mot').is_file():
            assembler = str(root/'tools/bin/vasmm68k_mot')
        if not assembler or importlib.util.find_spec('machine68k') is None:
            self.skipTest('scroller execution check needs machine68k and VASM')
        with tempfile.TemporaryDirectory(prefix='neon-scroll-wrap-') as tmp:
            work = Path(tmp)
            for name in ('tools','assets','src'):
                shutil.copytree(root/name, work/name,
                                ignore=shutil.ignore_patterns('bin','vendor','__pycache__'))
            source = work/'src/main.s'
            text, count = re.subn(r'(?m)(^scroll_text:\n)[ \t]*dc\.b[^\n]*',
                                  lambda match: match[1]+'        dc.b " AB ",0',
                                  source.read_text(), count=1)
            self.assertEqual(count,1)
            source.write_text(text)
            # The four-character message wraps after 64 frames. At frame 80,
            # old text pixels remain on screen despite a small wrapped phase.
            result = subprocess.run([sys.executable,str(work/'tools/emu_test.py'),
                                     '--frames','100','--snap','80'],
                                    env=dict(os.environ,VASM=assembler),
                                    capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('EMULATION TEST PASSED',result.stdout)
