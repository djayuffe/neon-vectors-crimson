#!/usr/bin/env python3
"""Mutation harness: every deliberate fault must be caught by tools/validate.py."""
import shutil, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
M = Path(tempfile.gettempdir()) / 'neon_vectors_mut'

def reset():
    if M.exists():
        shutil.rmtree(M)
    M.mkdir(parents=True)
    for d in ('src', 'tools', 'assets'):
        shutil.copytree(R / d, M / d)

def run():
    p = subprocess.run([sys.executable, str(M / 'tools/validate.py')], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def mutate(name, rel, old, new, expect_in_error=None):
    reset()
    f = M / rel
    s = f.read_text()
    if old and old not in s:
        print(f'{name:<40} SETUP ERROR: pattern not found'); return False
    f.write_text(s.replace(old, new, 1) if old else new)
    rc, out = run()
    if rc == 0:
        print(f'{name:<40} NOT CAUGHT'); return False
    if expect_in_error and expect_in_error not in out:
        print(f'{name:<40} caught, but message unexpected:\n{out}'); return False
    first = [l for l in out.splitlines() if l.strip().startswith('-')]
    print(f'{name:<40} caught: {first[0].strip()[:70] if first else out.splitlines()[-1][:70]}')
    return True

print('=== baseline ===')
reset()
rc, out = run()
print('unmutated copy'.ljust(40), 'OK (no errors)' if rc == 0 else 'BROKEN:\n' + out)
base_ok = rc == 0
print()
print('=== mutations ===')
results = []
M_ = mutate
results.append(M_('Forbid/Disable swapped', 'src/main.s',
    '        jsr     LVO_Forbid(a6)\n        jsr     LVO_Disable(a6)\n        lea     CUSTOM,a6',
    '        jsr     LVO_Disable(a6)\n        jsr     LVO_Forbid(a6)\n        lea     CUSTOM,a6', 'Forbid before Disable'))
results.append(M_('Enable/Permit swapped', 'src/main.s',
    '        jsr     LVO_Enable(a6)             ; interrupts before any wait\n        jsr     LVO_Permit(a6)',
    '        jsr     LVO_Permit(a6)\n        jsr     LVO_Enable(a6)', 'Enable before Permit'))
results.append(M_('PatchCopper writes register word', 'src/main.s',
    'move.w  d0,6(a1)', 'move.w  d0,4(a1)', 'PatchCopper'))
results.append(M_('silence word 0 instead of 8080', 'src/main.s',
    'SILENCE_WORD    EQU $8080', 'SILENCE_WORD    EQU 0', 'SILENCE_WORD'))
results.append(M_('undefined symbol typo', 'src/main.s',
    'bsr     ClearScreen', 'bsr     ClearScreeen', 'undefined symbol'))
results.append(M_('undefined local label', 'src/main.s',
    '        bpl     .sc_chr_ok', '        bpl     .sc_chrr_ok', 'undefined local label'))
results.append(M_('copper end marker lost', 'src/main.s',
    'dc.w $FFFF,$FFFE', 'dc.w $8001,$FFFE', 'end with'))
results.append(M_('WAIT position bit 0 cleared', 'src/main.s',
    'dc.w $8801,$FFFE', 'dc.w $8800,$FFFE', 'custom register range'))
results.append(M_('duplicate global label', 'src/main.s',
    'ClearScreen:', 'ClearScreen:\nClearScreen:', 'duplicate global label'))
results.append(M_('chipdata label used from code', 'src/main.s',
    '        move.l  ptr_screen,a0\n        moveq   #0,d0',
    '        move.l  screen,a0\n        moveq   #0,d0', 'chipdata label'))
results.append(M_('short branch bsr.s', 'src/main.s',
    '        bsr     MOD_Tick', '        bsr.s   MOD_Tick', 'short branch'))
results.append(M_('symbolic indexed displacement too large', 'src/modplayer.s',
    '        move.w  d5,8(a1)\n\n        tst.w   d1', '        move.w  d5,AUD0VOL(a6,d7.w)\n\n        tst.w   d1', 'brief extension'))
results.append(M_('numeric indexed displacement 200', 'src/main.s',
    '        move.w  0(a0,d0.w),d1', '        move.w  200(a0,d0.w),d1', 'brief extension'))
results.append(M_('PC-relative destination', 'src/main.s',
    '        move.l  d0,gfx_base\n', '        move.l  d0,gfx_base(pc)\n', 'PC-relative'))
results.append(M_('PC-relative read of another hunk', 'src/main.s',
    '        move.l  gfx_base,a6\n        sub.l', '        move.l  gfx_base(pc),a6\n        sub.l', 'PC-relative'))
results.append(M_('ADDI to an address register', 'src/main.s',
    '        adda.l  #PLANE_SIZE*4+LOGO_Y*SCREEN_W_BYTES,a2', '        addi.l  #PLANE_SIZE*4+LOGO_Y*SCREEN_W_BYTES,a2', 'address register'))
results.append(M_('quick shift count above 8', 'src/modplayer.s',
    '        rol.l   #8,d2', '        lsr.l   #24,d2', 'outside 1..8'))
results.append(M_('write to DMACONR', 'src/main.s',
    '        move.w  #DMAF_ALL,DMACON(a6)\n\n        move.l  gfx_base,a6',
    '        move.w  #DMAF_ALL,DMACON(a6)\n        move.w  #0,DMACONR(a6)\n\n        move.l  gfx_base,a6', 'read-only'))
results.append(M_('wrong standard DIW value', 'src/main.s',
    'dc.w DIWSTRT,$2C81', 'dc.w DIWSTRT,$2C91', 'standard value'))
results.append(M_('raster slot not a COLOR00 pair', 'src/main.s',
    'cop_raster_color:\n        dc.w COLOR00,$013', 'cop_raster_color:\n        dc.w COLOR01,$013',
    'COLOR00 MOVE pair'))
results.append(M_('DMACON copper bit wrong', 'src/hardware.i',
    'DMAF_COPPER  EQU $0080', 'DMAF_COPPER  EQU $0400', 'DMAF bit'))
results.append(M_('DMACON raster bit wrong', 'src/hardware.i',
    'DMAF_RASTER  EQU $0100', 'DMAF_RASTER  EQU $0200', 'DMAF bit'))
results.append(M_('LoadView LVO wrong', 'src/hardware.i',
    'LVO_LoadView      EQU -222', 'LVO_LoadView      EQU -224', 'library offsets'))
results.append(M_('ActiView GfxBase offset wrong', 'src/hardware.i',
    'GfxBase_ActiView  EQU 34', 'GfxBase_ActiView  EQU 30', 'GfxBase offsets'))
results.append(M_('TypeOfMem check removed', 'src/main.s',
    '        move.l  d0,a1                      ; TypeOfMem(a1 = address)\n        jsr     LVO_TypeOfMem(a6)', '        move.w  #0,d0', 'MEMF_CHIP'))
results.append(M_('CopyMem source/dest registers', 'src/main.s',
    '        lea     chipdata_begin,a0\n        move.l  chip_base,a1', '        lea     chipdata_begin,d3\n        move.l  chip_base,a1',
    'argument'))
results.append(M_('FreeMem pointer in a0', 'src/main.s',
    '        move.l  chip_base,a1               ; FreeMem(a1 = block, d0 = size)\n        move.l  #CHIPDATA_SIZE,d0\n        jsr     LVO_FreeMem(a6)\n\n        move.l  gfx_base,a1',
    '        move.l  chip_base,a0               ; FreeMem\n        move.l  #CHIPDATA_SIZE,d0\n        jsr     LVO_FreeMem(a6)\n\n        move.l  gfx_base,a1',
    'argument'))
results.append(M_('CloseLibrary argument in a0', 'src/main.s',
    '        move.l  gfx_base,a1                ; CloseLibrary(a1 = library)', '        move.l  gfx_base,a0                ; CloseLibrary',
    'argument'))
results.append(M_('OpenLibrary name in a0', 'src/main.s',
    '        lea     gfx_name,a1                 ; OpenLibrary(a1 = name, d0 = version)', '        lea     gfx_name,a0                 ; OpenLibrary',
    'argument'))
results.append(M_('LoadView(NULL) clears wrong reg', 'src/main.s',
    '        sub.l   a1,a1                      ; LoadView(a1 = NULL) detaches the View', '        sub.l   a0,a0                      ; LoadView',
    'argument'))
results.append(M_('library base in a5', 'src/main.s',
    '        jsr     LVO_Forbid(a6)', '        jsr     LVO_Forbid(a5)', 'convention is a6'))
results.append(M_('CopyMem LVO wrong', 'src/hardware.i',
    'LVO_CopyMem       EQU -624', 'LVO_CopyMem       EQU -618', 'memory/copy/scheduling'))
results.append(M_('Forbid LVO wrong', 'src/hardware.i',
    'LVO_Forbid        EQU -132', 'LVO_Forbid        EQU -130', 'memory/copy/scheduling'))
results = [r for r in results if r is not None]
print()
print(f'mutations caught: {sum(1 for r in results if r)}/{len(results)}')
# A harness that stops finding its own anchors looks exactly like a clean run,
# so an unmutated but failing tree, or a mutation whose pattern vanished, must
# not be reported as success.
if not base_ok:
    print('FAIL: the unmutated tree does not validate; mutations prove nothing')
sys.exit(0 if results and all(results) and base_ok else 1)
