#!/usr/bin/env python3
"""Mutation self-test of tools/emu_test.py: inject faults into the graphics, audio and
startup code and require the emulated-68000 test to fail each time.

Slow (every mutant is a full emulated run), so it is separate from `make mutants`.
Requires machine68k (pip install machine68k).
"""
import shutil, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
M = Path(tempfile.gettempdir()) / 'neon_vectors_emumut'

MUTANTS = [
    ('octant table: two entries swapped', 'src/main.s',
     '        dc.b $11,$15,$19,$1D ', '        dc.b $11,$15,$1D,$19 ', 'wireframe'),
    ('ONEDOT set (gappy shallow lines)', 'src/main.s',
     '        dc.b $11,$15,$19,$1D ', '        dc.b $13,$15,$19,$1D ', 'wireframe'),
    ('wireframe not double buffered', 'src/main.s',
     '        eori.w  #1,wire_front\n        bsr     PatchCopper', '        bsr     PatchCopper', 'alternate'),
    ('band clear far too short', 'src/main.s',
     '(MID_H<<6)|(SCREEN_W_BYTES/2),BLTSIZE', '((MID_H-60)<<6)|(SCREEN_W_BYTES/2),BLTSIZE', 'wireframe'),
    ('rotation matrix m20 sign', 'src/main.s',
     '        move.w  sy,d0\n        neg.w   d0\n        move.w  d0,12(a2)', '        move.w  sy,d0\n        move.w  d0,12(a2)', 'wireframe'),
    ('star erase missing (trails)', 'src/main.s',
     '        and.b   d1,0(a0,d2.w)', '        nop', 'plane 0'),
    ('scroller shifts one longword too many', 'src/main.s',
     'moveq   #SCREEN_W_BYTES/4-1,d6', 'moveq   #SCREEN_W_BYTES/4,d6', 'plane 0'),
    ('blitter DMA never enabled', 'src/main.s',
     'DMAF_COPPER|DMAF_BLITTER|DMAF_SPRITE),DMACON(a6)', 'DMAF_COPPER|DMAF_SPRITE),DMACON(a6)', 'blitter'),
    ('Copper wrap below line 255 missing', 'src/main.s',
     '        dc.w $FFDF,$FFFE                    ; wrap: lines below are 256 + WAIT line\n', '', 'Copper wrap'),
    ('wavy logo: wrong row phase step', 'src/main.s',
     '        addq.w  #3,d4\n        dbra    d7,.w', '        addq.w  #4,d4\n        dbra    d7,.w', 'wavy logo'),
    ('wave never reset after the logo', 'src/main.s',
     '        dc.w BPLCON1,$0000\n', '', 'BPLCON1'),
    ('display modulo wrong (extra fetch word not skipped)', 'src/main.s',
     'BPL1MOD,$FFFE,BPL2MOD,$FFFE', 'BPL1MOD,$0000,BPL2MOD,$0000', 'fetch setup'),
    ('copper bars written to the wrong word', 'src/main.s',
     '        move.w  (a3),6(a1,d1.w)', '        move.w  (a3),4(a1,d1.w)', 'floor bar'),
    ('wireframe sway ignored', 'src/main.s',
     '        move.w  d0,wire_cx\n', '        move.w  #MID_CX,wire_cx\n', 'wireframe'),
    ('sprite ring sorted farthest first', 'src/main.s',
     '        cmp.w   d5,d2\n        ble     .place', '        cmp.w   d5,d2\n        bge     .place', 'sprite'),
    ('sprite pointer not patched', 'src/main.s',
     '        move.w  d0,6(a2)\n        swap    d0\n        move.w  d0,2(a2)\n', '        swap    d0\n', 'sprite'),
    ('sprite HSTART off by one', 'src/main.s',
     'addi.w  #$81-8,d3', 'addi.w  #$81-7,d3', 'sprite'),
    ('sprite DMA never enabled', 'src/main.s',
     'DMAF_BLITTER|DMAF_SPRITE),DMACON(a6)', 'DMAF_BLITTER),DMACON(a6)', 'sprite DMA'),
    ('ring wobble ignores the tilt', 'src/main.s',
     '        addi.w  #RING_TILT,d1\n', '        move.w  #RING_TILT,d1\n', 'sprite'),
    ('wireframe vertex sign handling wrong', 'src/main.s',
     '.mx:\n        sub.l   0(a5),d3\n        sub.l   4(a5),d4\n        sub.l   8(a5),d5', '.mx:\n        add.l   0(a5),d3\n        sub.l   4(a5),d4\n        sub.l   8(a5),d5', 'wireframe'),
    ('AUDxLEN written as words minus one', 'src/modplayer.s',
     '        move.w  d5,4(a1)\n        move.w  d1,6(a1)', '        subq.w  #1,d5\n        move.w  d5,4(a1)\n        move.w  d1,6(a1)', 'audio'),
    ('CopyMem source/destination swapped', 'src/main.s',
     '        lea     chipdata_begin,a0\n        move.l  chip_base,a1', '        lea     chipdata_begin,a1\n        move.l  chip_base,a0', 'CopyMem'),
    ('no frame-sync edge detection', 'src/main.s',
     '.leave:\n        bsr     BeamLine\n        cmp.w   #FRAME_SYNC_LINE,d0\n        bhs     .leave', '.leave:', 'frame'),
    ('chip memory never freed', 'src/main.s',
     '        jsr     LVO_FreeMem(a6)\n\n        move.l  gfx_base,a1                ; CloseLibrary', '        move.l  gfx_base,a1                ; CloseLibrary', 'leaked'),
    ('teardown waits with the VERTB interrupt masked', 'src/main.s',
     '        move.w  old_intena,d0\n        andi.w  #$7FFF,d0\n        ori.w   #$8000,d0\n        move.w  d0,INTENA(a6)\n', '', 'hang'),
]

def populate():
    if M.exists():
        shutil.rmtree(M)
    M.mkdir(parents=True)
    for d in ('src', 'tools', 'assets'):
        shutil.copytree(R / d, M / d, ignore=shutil.ignore_patterns('bin', '__pycache__'))
    bin_dir = R / 'tools/bin'
    if bin_dir.exists():
        shutil.copytree(bin_dir, M / 'tools/bin')

def emu():
    return subprocess.run([sys.executable, str(M / 'tools/emu_test.py'), '--frames', '300', '--snap', '250'],
                          capture_output=True, text=True)

def run(name, rel, old, new, expect):
    populate()
    f = M / rel
    s = f.read_text()
    if old not in s:
        print(f'{name:<50} SETUP ERROR: pattern not found'); return False
    f.write_text(s.replace(old, new, 1))
    p = emu()
    out = p.stdout + p.stderr
    if p.returncode == 0:
        print(f'{name:<50} NOT CAUGHT'); return False
    fails = [l.strip() for l in out.splitlines() if l.strip().startswith('FAIL')]
    if expect and not any(expect.lower() in l.lower() for l in fails) and 'Traceback' not in out:
        print(f'{name:<50} caught, but without "{expect}": {fails[:1]}'); return True
    print(f'{name:<50} caught: {(fails[0] if fails else out.splitlines()[-1])[:70]}')
    return True

if __name__ == '__main__':
    # Prove the emulator test can pass before asking it to fail. Without this a
    # broken harness or a missing dependency would "catch" every mutant by
    # crashing, which is indistinguishable from a real detection.
    populate()
    base = emu()
    base_ok = base.returncode == 0
    print(f'baseline: {"PASSED (mutants must now be caught)" if base_ok else "BROKEN"}')
    if not base_ok:
        print((base.stdout + base.stderr).splitlines()[-1][:90])
    print()
    results = [run(*m) for m in MUTANTS]
    print(f'\nemulation mutants caught: {sum(results)}/{len(results)}')
    sys.exit(0 if base_ok and all(results) else 1)
