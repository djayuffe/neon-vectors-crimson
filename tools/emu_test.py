#!/usr/bin/env python3
"""Run the real assembled intro on an emulated 68000 and check what it does.

This is a behavioural test, not a cycle-exact Amiga emulator. It executes the
actual Hunk executable on the Musashi 68000 core (pip install machine68k) and
models just enough of the machine to judge the program:

  * Exec and graphics.library are stubs that take their arguments in the
    registers the real libraries use (a1 = name, a0 = source, ...), so a call
    with the wrong register convention fails here. Scratch registers
    (d1/a0/a1) are trashed on return, like the real ones may.
  * The custom chips are RAM-backed. DMACON/INTENA/INTREQ/ADKCON are decoded with
    SET/CLR semantics, VPOSR/VHPOSR follow a PAL beam derived from executed CPU
    cycles, and the Copper list in chip RAM is interpreted to render a frame.
  * Paula channel starts are latched when the DMA bit turns on and compared with
    what the MOD file says should play.

It does NOT prove the program works on real hardware: no blitter, no DMA cycle
stealing (so CPU timing is optimistic), no sprites, no Kickstart behaviour.
Use an emulator such as FS-UAE/WinUAE/Amiberry for that.

Usage: emu_test.py [--frames N] [--png FILE] [--alloc-fast] [--loader-chip]
"""
import argparse, math, os, shutil, struct, subprocess, sys, tempfile, zlib
from pathlib import Path

try:
    import machine68k as m68k
except ImportError:
    print('emu_test needs the Musashi binding:  pip install machine68k', file=sys.stderr)
    sys.exit(77)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_tables
LINE_CYCLES = 454                 # 227 colour clocks * 2 CPU cycles at 7.09 MHz
FRAME_LINES = 312
FRAME_CYCLES = LINE_CYCLES * FRAME_LINES
CUSTOM = 0xDFF000
CIAAPRA = 0xBFE001
EXEC, GFX = 0x1000, 0x3000
SENTINEL = 0x0800
STACK = 0x10000
CHIP_POOL, CHIP_END = 0x100000, 0x200000
FAST_POOL = 0x400000
FAST_SIZE_LIMIT = 0xE00000
R = m68k.Register
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)
        print('  FAIL:', msg)
    return cond


# --- assemble a copy with symbols ---------------------------------------------
def source_equs():
    """Numeric EQUs of src/main.s and src/hardware.i (the layout constants the test relies on)."""
    import re
    vals = {}
    for f in ('src/hardware.i', 'src/main.s'):
        for line in (ROOT / f).read_text().splitlines():
            m = re.match(r'([A-Za-z_]\w*)\s+(?:EQU|equ)\s+([^;]+)', line)
            if m:
                expr = m.group(2).strip()
                try:
                    vals[m.group(1)] = int(eval(re.sub(r'\$([0-9A-Fa-f]+)', r'0x\1', expr), {}, dict(vals)))
                except Exception:
                    pass
    return vals


def find_vasm():
    for c in (os.environ.get('VASM'), shutil.which('vasmm68k_mot'), str(ROOT / 'tools/bin/vasmm68k_mot')):
        if c and Path(c).exists():
            return c
    sys.exit('emu_test: no vasmm68k_mot (run "make toolchain" or set VASM)')


def assemble(out):
    r = subprocess.run([find_vasm(), '-m68000', '-kick1hunks', '-Fhunkexe', '-I', str(ROOT / 'src'),
                        '-o', str(out), str(ROOT / 'src/main.s')], capture_output=True, text=True, cwd=ROOT)
    if r.returncode:
        sys.exit('emu_test: assembly failed\n' + r.stdout + r.stderr)


# --- Hunk loader ---------------------------------------------------------------
def parse_hunks(b):
    off = 0
    def u32():
        nonlocal off
        v = struct.unpack_from('>I', b, off)[0]; off += 4; return v
    assert u32() == 0x3F3
    while u32():
        pass
    n, first, last = u32(), u32(), u32()
    sizes, mem = [], []
    for _ in range(n):
        v = u32(); sizes.append((v & 0x3FFFFFFF) * 4); mem.append(v >> 30)
    hunks = []; cur = None; syms = {}
    while off < len(b):
        t = u32() & 0x3FFFFFFF
        if t == 0x3E8:                       # HUNK_NAME
            cnt = -struct.unpack_from('>i', b, off)[0]; off += 4 + (cnt - 1) * 4
        elif t in (0x3E9, 0x3EA):
            k = u32(); cur = dict(data=b[off:off + k * 4], relocs=[]); off += k * 4; hunks.append(cur)
        elif t == 0x3EB:
            k = u32(); hunks.append(dict(data=bytes(k * 4), relocs=[])); cur = hunks[-1]
        elif t == 0x3EC:
            while True:
                k = u32()
                if not k:
                    break
                tgt = u32(); cur['relocs'] += [(tgt, u32()) for _ in range(k)]
        elif t == 0x3F0:
            while True:
                k = u32() & 0xFFFFFF
                if not k:
                    break
                name = b[off:off + k * 4].split(b'\0')[0].decode('latin-1'); off += k * 4
                syms[name] = (len(hunks) - 1, u32())
        elif t == 0x3F2:
            pass
        else:
            raise ValueError('hunk type %x' % t)
    return sizes, mem, hunks, syms


class Amiga:
    def __init__(self, exe, loader_chip, alloc_fast):
        self.mach = m68k.Machine(m68k.CPUType.M68000, 15 * 1024)
        self.cpu, self.mem = self.mach.cpu, self.mach.mem
        self.alloc_fast = alloc_fast
        self.t = 0
        self.nest_forbid = self.nest_disable = 0
        self.chip_ptr, self.fast_ptr = CHIP_POOL, FAST_POOL
        self.allocs = {}
        self.calls = []
        self.loadviews = []
        self.opened = []
        self.gfx_open = 0
        # initial "system" state, deliberately non-trivial so a restore is visible
        self.dmacon = 0x03EF
        self.intena = 0xE02C
        self.adkcon = 0x1100
        self.intreq = 0
        self.cop1lc = 0
        self.init = (self.dmacon, self.intena, self.adkcon)
        self.latches = []            # (t, ch, ptr, len, per, vol)
        self.audio_on = [False] * 4
        self.raw = b'\0' * 10
        self.frame_marks = []        # WaitFrameSync entry times
        self.exit_marks = []
        self.pending_loopcheck = []
        self.loopregs = []           # (t, ch, ptr, len) sampled after a row
        self.chip_block = None
        self.blit_lines = self.blit_clears = 0
        self.frame_hook = None
        self.bpl2_seen = []          # BPL2PT (wireframe buffer) in the Copper list, per frame
        self.t_marks = {}            # symbol -> [(time)]
        self.mouse_down_at = None
        self.load(exe, loader_chip)

    # memory helpers
    def chip_alloc(self, size):
        a = (self.chip_ptr + 7) & ~7
        self.chip_ptr = a + size + 64
        assert self.chip_ptr < CHIP_END
        return a

    def fast_alloc(self, size):
        a = (self.fast_ptr + 7) & ~7
        self.fast_ptr = a + size + 64
        assert self.fast_ptr < FAST_SIZE_LIMIT
        return a

    def load(self, exe, loader_chip):
        self.sizes, memf, self.hunks, self.syms = parse_hunks(exe.read_bytes())
        self.bases = []
        for sz, mf in zip(self.sizes, memf):
            self.bases.append(self.chip_alloc(sz) if (mf == 1 and loader_chip) else self.fast_alloc(sz))
        self.hunk_mem = memf
        for i, h in enumerate(self.hunks):
            self.mem.w_block(self.bases[i], h['data'])
        for i, h in enumerate(self.hunks):
            for tgt, o in h['relocs']:
                a = self.bases[i] + o
                self.mem.w32(a, (self.mem.r32(a) + self.bases[tgt]) & 0xFFFFFFFF)
        self.orig = [self.mem.r_block(self.bases[i], self.sizes[i]) for i in range(len(self.hunks))]

    def sym(self, name):
        h, o = self.syms[name]
        return self.bases[h] + o

    # library stubs
    def install(self):
        mem = self.mem
        mem.w32(4, EXEC)
        mem.w32(GFX + 34, 0x5555)       # ActiView
        mem.w32(GFX + 38, 0x6666)       # copinit
        self.view, self.copinit = 0x5555, 0x6666
        exec_fns = {-120: self.f_disable, -126: self.f_enable, -132: self.f_forbid, -138: self.f_permit,
                    -198: self.f_allocmem, -210: self.f_freemem, -552: self.f_openlib, -414: self.f_closelib,
                    -534: self.f_typeofmem, -624: self.f_copymem}
        gfx_fns = {-222: self.f_loadview, -228: self.f_waitblit, -270: self.f_waittof,
                   -456: self.f_ownblit, -462: self.f_disownblit}
        self.stubs = {EXEC + k: v for k, v in exec_fns.items()}
        self.stubs.update({GFX + k: v for k, v in gfx_fns.items()})
        self.stub_base = {EXEC + k: EXEC for k in exec_fns}
        self.stub_base.update({GFX + k: GFX for k in gfx_fns})
        self.stub_ranges = [(EXEC - 700, EXEC), (GFX - 500, GFX)]
        # custom register defaults
        mem.w16(CUSTOM + 0x02, self.dmacon); mem.w16(CUSTOM + 0x1C, self.intena)
        mem.w16(CUSTOM + 0x10, self.adkcon)
        mem.w8(CIAAPRA, 0xFF)

    def ret(self):
        sp = self.cpu.r_reg(R.A7)
        self.cpu.w_pc(self.mem.r32(sp)); self.cpu.w_reg(R.A7, sp + 4)

    def scratch(self, d0=None):
        c = self.cpu
        if d0 is not None:
            c.w_reg(R.D0, d0 & 0xFFFFFFFF)
        c.w_reg(R.D1, 0xDEAD0001); c.w_reg(R.A0, 0xDEAD0002); c.w_reg(R.A1, 0xDEAD0003)

    def reg(self, r):
        return self.cpu.r_reg(r)

    def f_forbid(self):
        self.nest_forbid += 1; self.calls.append('Forbid'); self.scratch(); self.ret()

    def f_permit(self):
        check(self.nest_forbid > 0, 'Permit without Forbid'); self.nest_forbid -= 1
        self.calls.append('Permit'); self.scratch(); self.ret()

    def f_disable(self):
        check(self.nest_forbid > 0, 'Disable called outside Forbid')
        self.nest_disable += 1; self.intena &= ~0x4000; self.sync_read_regs()
        self.calls.append('Disable'); self.scratch(); self.ret()

    def f_enable(self):
        check(self.nest_disable > 0, 'Enable without Disable'); self.nest_disable -= 1
        if not self.nest_disable:
            self.intena |= 0xC000
        self.sync_read_regs(); self.calls.append('Enable'); self.scratch(); self.ret()

    def f_allocmem(self):
        size, flags = self.reg(R.D0), self.reg(R.D1)
        check(not self.nest_disable, 'AllocMem called with interrupts disabled')
        self.calls.append('AllocMem')
        if self.alloc_fast or not (flags & 2):
            a = self.fast_alloc(size)
        else:
            a = self.chip_alloc(size)
        self.mem.w_block(a - 16, b'\xA5' * 16); self.mem.w_block(a + size, b'\xA5' * 16)
        self.mem.w_block(a, b'\x55' * size)          # no MEMF_CLEAR: memory arrives dirty
        self.allocs[a] = (size, flags)
        self.scratch(a); self.ret()

    def f_freemem(self):
        a, size = self.reg(R.A1), self.reg(R.D0)
        self.calls.append('FreeMem')
        check(a in self.allocs, 'FreeMem of a block that was not allocated (a1=$%X)' % a)
        if a in self.allocs:
            check(self.allocs[a][0] == size, 'FreeMem size %d != allocated %d' % (size, self.allocs[a][0]))
            for base, off in ((a - 16, 0), (a + size, 0)):
                check(self.mem.r_block(base, 16) == b'\xA5' * 16, 'memory guard around the allocation was overwritten')
            del self.allocs[a]
        self.scratch(); self.ret()

    def f_typeofmem(self):
        a = self.reg(R.A1)
        self.calls.append('TypeOfMem')
        self.scratch(0x2 if a < CHIP_END else 0x4); self.ret()

    def f_copymem(self):
        src, dst, n = self.reg(R.A0), self.reg(R.A1), self.reg(R.D0)
        self.calls.append('CopyMem')
        check(src in self.bases, 'CopyMem source $%X is not a hunk base (source/dest swapped?)' % src)
        check(dst in self.allocs, 'CopyMem destination $%X is not an allocated block' % dst)
        if src in self.bases and dst in self.allocs:
            check(n <= self.allocs[dst][0], 'CopyMem length exceeds the allocation')
            self.mem.w_block(dst, self.mem.r_block(src, n))
        self.scratch(); self.ret()

    def f_openlib(self):
        name = self.mem.r_cstr(self.reg(R.A1)) if self.reg(R.A1) < 0xE00000 else ''
        self.calls.append('OpenLibrary')
        ok = check(name == 'graphics.library', 'OpenLibrary name pointer (a1) does not point at "graphics.library": %r' % name)
        self.gfx_open += 1 if ok else 0
        self.scratch(GFX if ok else 0); self.ret()

    def f_closelib(self):
        self.calls.append('CloseLibrary')
        check(self.reg(R.A1) == GFX, 'CloseLibrary base (a1) is not the opened library')
        self.gfx_open -= 1; self.scratch(); self.ret()

    def f_loadview(self):
        v = self.reg(R.A1)
        self.calls.append('LoadView'); self.loadviews.append(v)
        self.scratch(); self.ret()

    def f_waitblit(self):
        self.calls.append('WaitBlit'); self.scratch(); self.ret()

    def f_ownblit(self):
        self.calls.append('OwnBlitter'); self.scratch(); self.ret()

    def f_disownblit(self):
        self.calls.append('DisownBlitter'); self.scratch(); self.ret()

    def f_waittof(self):
        check(not self.nest_disable, 'WaitTOF with interrupts disabled would hang on real hardware')
        check((self.intena & 0x4020) == 0x4020, 'WaitTOF would hang: the vertical-blank interrupt is masked (INTENA=$%04X)' % self.intena)
        self.calls.append('WaitTOF')
        self.t = (self.t // FRAME_CYCLES + 1) * FRAME_CYCLES
        self.scratch(); self.ret()

    # chipset model
    def sync_read_regs(self):
        w = self.mem.w16
        w(CUSTOM + 0x02, self.dmacon); w(CUSTOM + 0x1C, self.intena)
        w(CUSTOM + 0x1E, self.intreq); w(CUSTOM + 0x10, self.adkcon)

    def beam(self):
        line = (self.t // LINE_CYCLES) % FRAME_LINES
        hpos = min((self.t % LINE_CYCLES) // 2, 0xE3)
        self.mem.w32(CUSTOM + 4, ((line >> 8) << 16) | ((line & 0xFF) << 8) | hpos)

    @staticmethod
    def setclr(state, v):
        return (state | (v & 0x7FFF)) if v & 0x8000 else (state & ~v & 0x7FFF)

    def blit(self):
        """Execute the blit that a write to BLTSIZE just started (instantly; BBUSY is never seen set).

        Only the two modes this program uses exist: line mode (BLTCON1 bit 0) following the
        Hardware Reference Manual's register-level algorithm, and a D-only clear. Anything
        else is reported instead of being guessed at."""
        m = self.mem
        if (self.dmacon & 0x240) != 0x240:
            failures.append('blit started with master/blitter DMA off (DMACON=$%04X)' % self.dmacon); return
        s16 = lambda v: v - 0x10000 if v & 0x8000 else v
        con0, con1, size = m.r16(CUSTOM + 0x40), m.r16(CUSTOM + 0x42), m.r16(CUSTOM + 0x58)
        h, w = (size >> 6) or 1024, (size & 63) or 64
        if con1 & 1:                                                     # ---- line mode
            self.blit_lines += 1
            if w != 2 or (con0 & 0x0F00) != 0x0B00 or (con0 & 0xFF) != 0xCA or (con1 & 2):
                failures.append('unsupported line-mode setup BLTCON0=$%04X BLTCON1=$%04X BLTSIZE=$%04X' % (con0, con1, size)); return
            ash = con0 >> 12
            acc = s16(m.r32(CUSTOM + 0x50) & 0xFFFF)
            amod, bmod = s16(m.r16(CUSTOM + 0x64)), s16(m.r16(CUSTOM + 0x62))
            cptr, dptr = m.r32(CUSTOM + 0x48), m.r32(CUSTOM + 0x54)
            cmod, dmod = s16(m.r16(CUSTOM + 0x60)), s16(m.r16(CUSTOM + 0x66))
            check(cptr == dptr and cmod == dmod, 'line mode: C and D must address the same bitmap')
            check(m.r16(CUSTOM + 0x74) == 0x8000 and m.r16(CUSTOM + 0x72) == 0xFFFF and
                  m.r16(CUSTOM + 0x44) == 0xFFFF and m.r16(CUSTOM + 0x46) == 0xFFFF, 'line mode: A data/B data/word masks not preloaded')
            sud, sul, aul = (con1 >> 4) & 1, (con1 >> 3) & 1, (con1 >> 2) & 1
            sign = bool(con1 & 0x40)
            check(sign == (acc < 0), 'line mode: SIGN bit does not match the sign of BLTAPT')
            maj = -1 if aul else 1
            mnr = -1 if sul else 1
            ptr = dptr
            pix = []
            def step_x(d):
                nonlocal ash, ptr
                ash += d
                if ash == 16: ash = 0; ptr += 2
                if ash < 0: ash = 15; ptr -= 2
            for _ in range(h):
                word = m.r16(ptr) | (0x8000 >> ash)
                m.w16(ptr, word)
                if sign:
                    acc += bmod
                    (step_x(maj) if sud else None)
                    if not sud: ptr += maj * dmod
                else:
                    acc += amod
                    if sud:
                        step_x(maj); ptr += mnr * dmod
                    else:
                        ptr += maj * dmod; step_x(mnr)
                sign = acc < 0
        else:                                                            # ---- rectangle, D only
            self.blit_clears += 1
            if con0 != 0x0100:
                failures.append('unsupported blit BLTCON0=$%04X (only the D-only clear is modelled)' % con0); return
            dptr, dmod = m.r32(CUSTOM + 0x54), s16(m.r16(CUSTOM + 0x66))
            for _ in range(h):
                m.w_block(dptr, bytes(w * 2))
                dptr += w * 2 + dmod

    def poll_custom(self):
        if self.mem.r16(CUSTOM + 0x58):
            self.blit()
            self.mem.w16(CUSTOM + 0x58, 0)          # so an identical BLTSIZE write is seen again
        raw = self.mem.r_block(CUSTOM + 0x96, 10)
        if raw == self.raw:
            return
        old = self.raw; self.raw = raw
        dm, ie, ir, ak = (struct.unpack('>H', raw[i:i + 2])[0] for i in (0, 4, 6, 8))
        if raw[0:2] != old[0:2]:
            self.dmacon = self.setclr(self.dmacon, dm) & 0x07FF
            self.check_audio_edges()
        if raw[4:6] != old[4:6]:
            self.intena = self.setclr(self.intena, ie)
        if raw[6:8] != old[6:8]:
            self.intreq = self.setclr(self.intreq, ir)
        if raw[8:10] != old[8:10]:
            self.adkcon = self.setclr(self.adkcon, ak)
        self.sync_read_regs()

    def check_audio_edges(self):
        for ch in range(4):
            on = bool(self.dmacon & 0x200) and bool(self.dmacon & (1 << ch))
            if on and not self.audio_on[ch]:
                base = CUSTOM + 0xA0 + ch * 16
                self.latches.append((self.t, ch, self.mem.r32(base), self.mem.r16(base + 4),
                                     self.mem.r16(base + 6), self.mem.r16(base + 8)))
            self.audio_on[ch] = on

    def cop_events(self):
        """Interpret the Copper list once per frame: [(line, register, value)]."""
        ev, line, a = [], 0, self.cop1lc_addr()
        for _ in range(4096):
            w1, w2 = self.mem.r16(a), self.mem.r16(a + 2); a += 4
            if w1 & 1:
                if (w1, w2) == (0xFFFF, 0xFFFE):
                    return ev, True
                line = max(line, w1 >> 8)
            else:
                ev.append((line, w1, w2))
        return ev, False

    def cop1lc_addr(self):
        return self.mem.r32(CUSTOM + 0x80)

    # execution
    def run(self, frames, snap_frame):
        cpu, mem = self.cpu, self.mem
        self.install()
        mem.w32(0, STACK)
        cpu.pulse_reset()
        cpu.w_pc(self.bases[0]); cpu.w_reg(R.A7, STACK - 4)
        mem.w32(STACK - 4, SENTINEL)
        sentinel_regs = [0x11110000 + i for i in range(1, 8)] + [0x22220000 + i for i in range(7)]
        for i in range(1, 8):
            cpu.w_reg(R.D0 + i, sentinel_regs[i - 1])
        for i in range(7):
            cpu.w_reg(R.A0 + i, sentinel_regs[7 + i])
        self.sentinel_regs = sentinel_regs
        wfs = self.sym('WaitFrameSync')
        self.exit_pc = None
        self.in_wfs = False
        self.exit_times = []
        self.mark_pcs = {self.sym('UpdateSprites'): 'sprites', self.sym('UpdateStars'): 'stars', self.sym('UpdateScroller'): 'scroller', self.sym('DrawWire'): 'wire'}
        self.snapshot = None
        steps = 0
        while True:
            pc = cpu.r_pc()
            fn = self.stubs.get(pc)
            if fn:
                # AmigaOS convention: the library base is in a6. Kickstart's Exec happens not to
                # read it, but AROS's does, so a call with the base elsewhere crashes there.
                if cpu.r_reg(R.A6) != self.stub_base[pc]:
                    failures.append('library call at $%X made without the library base in a6 (a6=$%X)' % (pc, cpu.r_reg(R.A6)))
                    return False
                fn(); continue
            if pc == SENTINEL:
                break
            for lo, hi in self.stub_ranges:
                if lo <= pc < hi:
                    failures.append('jump into an unimplemented library vector at $%X' % pc); return False
            if pc == self.exit_pc:
                self.exit_times.append(self.t); self.exit_pc = None; self.in_wfs = False
            tm = self.mark_pcs.get(pc)
            if tm:
                self.t_marks.setdefault(tm, []).append(self.t)
            if pc == wfs and not self.in_wfs:
                self.in_wfs = True                  # one entry per call, not per pass of its spin loop
                self.exit_pc = mem.r32(cpu.r_reg(R.A7))
                self.frame_marks.append(self.t)
                cl = mem.r32(CUSTOM + 0x80)
                if cl:
                    # BPL2PT words sit at offsets 10/14 from cop_bpl1, which is the label after the header
                    cb = cl + self.sym('cop_bpl1') - self.sym('copper')
                    self.bpl2_seen.append((mem.r16(cb + 10) << 16) | mem.r16(cb + 14))
                    if self.frame_hook:
                        self.frame_hook(len(self.frame_marks), self.bpl2_seen[-1])
                self.sample_loop_regs()
                n = len(self.frame_marks)
                if n == snap_frame and FRAME_LINES == 312:
                    self.snapshot = self.render()
                if n == frames:
                    mem.w8(CIAAPRA, 0xFF & ~0x40)      # press the left mouse button
            n = cpu.execute(1).cycles
            self.t += n
            steps += 1
            self.beam()
            self.poll_custom()
            if self.t > (frames + 40) * FRAME_CYCLES:
                failures.append('program did not exit within 40 frames after the mouse press')
                return False
        return True

    def render(self):
        """Interpret the Copper list and bitplanes exactly as the chipset would show them."""
        mem = self.mem
        out = dict(dmacon=self.dmacon, intena=self.intena)
        out['shifts'] = (mem.r32(self.sym('scroll_ptr')) - self.sym('scroll_text')) * 8 + mem.r8(self.sym('glyph_col'))
        a = mem.r32(CUSTOM + 0x80)
        ev, line, terminated, wrapped = [], 0, False, False
        for _ in range(4096):
            w1, w2 = mem.r16(a), mem.r16(a + 2); a += 4
            if w1 & 1:
                if (w1, w2) == (0xFFFF, 0xFFFE):
                    terminated = True; break
                if (w1, w2) == (0xFFDF, 0xFFFE):
                    wrapped = True; line = max(line, 255)       # vertical counter wraps: later WAITs are 256 + n
                else:
                    line = max(line, (256 if wrapped else 0) + (w1 >> 8))
            else:
                ev.append((line, w1, w2))
        out['terminated'] = terminated
        first = {}
        for ln, r, v in ev:
            if ln == 0:
                first[r] = v
        out['first'] = first
        ptr = {}
        for i in range(4):
            ptr[i] = (first.get(0xE0 + 4 * i, 0) << 16) | first.get(0xE2 + 4 * i, 0)
        out['ptr'] = ptr
        out['spr_ptr'] = [(first.get(0x120 + 4 * i, 0) << 16) | first.get(0x122 + 4 * i, 0) for i in range(8)]
        pal = {i: 0 for i in range(32)}
        evs = sorted(ev, key=lambda e: e[0])
        pending = list(evs)
        pal_by_line, bplcon1_by_line = {}, {}
        cur, scroll = dict(pal), 0
        for y in range(FRAME_LINES):
            while pending and pending[0][0] <= y:
                _, r, v = pending.pop(0)
                if 0x180 <= r < 0x1C0:
                    cur[(r - 0x180) // 2] = v
                elif r == 0x102:
                    scroll = v
            pal_by_line[y] = dict(cur)
            bplcon1_by_line[y] = scroll
        diwstrt, diwstop = first.get(0x8E, 0), first.get(0x90, 0)
        y0 = diwstrt >> 8
        y1 = (diwstop >> 8) | 0x100
        out['diw'] = (y0, y1)
        # Bitplane fetch: (DDFSTOP-DDFSTRT)/8+1 words per line, the first of which is hidden left of
        # the window when DDFSTRT is earlier than $38 (16 pixels per 8 colour clocks); BPLCON1 delays
        # the data by its nibble: odd planes (1, 3) use bits 3-0, even planes (2) bits 7-4.
        ddfstrt, ddfstop = first.get(0x92, 0x38), first.get(0x94, 0xD0)
        words = (ddfstop - ddfstrt) // 8 + 1
        hidden = (0x38 - ddfstrt) * 2
        mod = first.get(0x108, 0)
        mod = mod - 0x10000 if mod & 0x8000 else mod
        pitch = words * 2 + mod
        out['ddf'] = (ddfstrt, ddfstop, words, mod, pitch, hidden)
        img = []
        planes_px = []
        for y in range(y0, y1):
            k = y - y0
            sc = bplcon1_by_line[y]
            shifts = (sc & 15, (sc >> 4) & 15, sc & 15, (sc >> 4) & 15)
            rowpix = []
            for x in range(320):
                v = 0
                for p in range(4):
                    f = hidden + x - shifts[p]
                    if f >= 0:
                        byte = mem.r8(ptr[p] + k * pitch + (f >> 3))
                        v |= ((byte >> (7 - (f & 7))) & 1) << p
                rowpix.append(v)
            planes_px.append(rowpix)
            pal_l = pal_by_line[y]
            img.append([pal_l[v] for v in rowpix])
        # hardware sprites over the playfield (sprite 0 in front); colour 0 is transparent
        for n in range(7, -1, -1):
            a_ = out['spr_ptr'][n]
            pos, ctl = mem.r16(a_), mem.r16(a_ + 2)
            vstart, vstop = (pos >> 8) | ((ctl & 4) << 6), (ctl >> 8) | ((ctl & 2) << 7)
            hstart = ((pos & 255) << 1) | (ctl & 1)
            for ln in range(max(0, vstop - vstart)):
                wa, wb = mem.r16(a_ + 4 + ln * 4), mem.r16(a_ + 6 + ln * 4)
                row = vstart + ln - 44
                for bit in range(16):
                    c = ((wa >> (15 - bit)) & 1) | (((wb >> (15 - bit)) & 1) << 1)
                    x = hstart - 0x81 + bit
                    if c and 0 <= x < 320 and 0 <= row < len(img):
                        # BPLCON2 PF1P = code: the playfield is in front of sprites 2*code and up
                        if n >= 2 * (first.get(0x104, 0) & 7) or planes_px[row][x] == 0:
                            img[row][x] = pal_by_line[vstart + ln][16 + 4 * (n // 2) + c]
        out['spr_pages'] = [mem.r_block(out['spr_ptr'][n], 80) for n in range(8)]
        out['px'] = planes_px
        out['img'] = img
        out['planes'] = [mem.r_block(ptr[p] + 2, 10240) for p in range(4)]
        out['pal_by_line'] = pal_by_line
        out['bplcon1_by_line'] = bplcon1_by_line
        return out

    def sample_loop_regs(self):
        for ch in self.pending_loopcheck:
            base = CUSTOM + 0xA0 + ch * 16
            self.loopregs.append((self.t, ch, self.mem.r32(base), self.mem.r16(base + 4)))
        prev = self.frame_marks[-2] if len(self.frame_marks) > 1 else 0
        self.pending_loopcheck = sorted({l[1] for l in self.latches if l[0] > prev})


# --- checks ---------------------------------------------------------------------

# --- reference models ---------------------------------------------------------------
# Independent Python versions of what the program computes, written from the design, not
# transcribed from the assembly: the 16 bit LCG, the star projection, the 7 bit rotation
# matrix and perspective, and an ordinary integer Bresenham line. Integer semantics match
# the 68000 (MULS/DIVS truncate toward zero, ASR floors).
def trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def ref_stars(nupdates, nstars, consts):
    ZMIN, ZRANGE, ZSPEED, ZMID, ZNEAR, PROJ_F, CX, CY, Y0, H = consts
    recip = lambda z: int(round(PROJ_F * 256 / z))
    seed = 1
    def rand():
        nonlocal seed
        seed = (seed * 25173 + 13849) & 0xFFFF
        return seed
    st = []
    for _ in range(nstars):
        x = (rand() & 511) - 255
        y = ((((rand() & 255) - 128) * 5) >> 3)
        z = (((rand() & 255) * ZRANGE) >> 8) + ZMIN
        st.append([x, y, z])
    for _ in range(nupdates):
        for q in st:
            q[2] -= ZSPEED
            if q[2] < ZMIN:
                q[2] += ZRANGE
                q[0] = (rand() & 511) - 255
                q[1] = ((((rand() & 255) - 128) * 5) >> 3)
    out = []                                    # (x, y, class) of every star that is on screen
    for x, y, z in st:
        sx = (((x * recip(z)) >> 8) + CX) & 0xFFFF
        sy = (((y * recip(z)) >> 8) + CY) & 0xFFFF
        if sx >= 320 or ((sy - Y0) & 0xFFFF) >= H:
            continue
        out.append((sx, sy, 3 if z <= ZNEAR else 2 if z <= ZMID else 1))
    return out


def ref_bresenham(x1, y1, x2, y2):
    dx, dy = abs(x2 - x1), abs(y2 - y1)
    sx, sy = (1 if x2 > x1 else -1), (1 if y2 > y1 else -1)
    pts = []
    if dx >= dy:
        d, x, y = 2 * dy - dx, x1, y1
        for _ in range(dx + 1):
            pts.append((x, y))
            if d >= 0:
                y += sy; d += 2 * (dy - dx)
            else:
                d += 2 * dy
            x += sx
    else:
        d, x, y = 2 * dx - dy, x1, y1
        for _ in range(dy + 1):
            pts.append((x, y))
            if d >= 0:
                x += sx; d += 2 * (dx - dy)
            else:
                d += 2 * dx
            y += sy
    return pts


def ref_wire(k, verts, edges, consts):
    import math
    D, ZOFF, CX, CY, SWAY, ZOOM = consts
    tab = [int(round(127 * math.sin(2 * math.pi * i / 256))) for i in range(256)]
    sin = lambda a: tab[a & 255]
    cos = lambda a: tab[(a + 64) & 255]
    m7 = lambda a, b: (a * b) >> 7
    def matrix(ax, ay, az):
        sx, cx, sy, cy, sz, cz = sin(ax), cos(ax), sin(ay), cos(ay), sin(az), cos(az)
        return [m7(cz, cy),
                m7(m7(cz, sy), sx) - m7(sz, cx),
                m7(m7(cz, sy), cx) + m7(sz, sx),
                m7(sz, cy),
                m7(m7(sz, sy), sx) + m7(cz, cx),
                m7(m7(sz, sy), cx) - m7(cz, sx),
                -sy, m7(cy, sx), m7(cy, cx)]
    def project(m, v):
        x, y, z = v
        xr = (m[0] * x + m[1] * y + m[2] * z) >> 7
        yr = (m[3] * x + m[4] * y + m[5] * z) >> 7
        zc = ((m[6] * x + m[7] * y + m[8] * z) >> 7) + zoff
        r = int(round(D * 256 / zc))
        return (((xr * r) >> 8) + cx, ((yr * r) >> 8) + CY)
    cx = CX + ((sin(k) * SWAY) >> 7)              # sways with the x angle,
    zoff = ZOFF + ((sin(2 * k) * ZOOM) >> 7)      # breathes with the y angle
    ma = matrix(k, 2 * k, k)
    mb = matrix(2 * k, -k, -2 * k)
    proj = [project(ma, v) for v in verts[:8]] + [project(mb, v) for v in verts[8:]]
    pix = set()
    for i, j in edges:
        pix.update(ref_bresenham(proj[i][0], proj[i][1], proj[j][0], proj[j][1]))
    return pix, proj


def ref_ring(f, wire_cx, consts):
    """The eight sprite buffers (position words, bitmap lines, terminator) for frame f."""
    RING_R, TILT, ZOFF, MIDCY, NEAR, MID, D = consts
    tab = [int(round(127 * math.sin(2 * math.pi * i / 256))) for i in range(256)]
    sin = lambda a: tab[a & 255]
    cos = lambda a: tab[(a + 64) & 255]
    tilt = TILT + (sin(2 * f) >> 4)
    st, ct, sr, cr = sin(tilt), cos(tilt), sin(f), cos(f)
    A, B, C, Dm, F = cr, (st * sr) >> 7, sr, -((st * cr) >> 7), ct
    balls = []
    for i in range(8):
        th = 3 * f + 32 * i
        x0 = (RING_R * cos(th)) >> 7
        z0 = (RING_R * sin(th)) >> 7
        xx = (x0 * A + z0 * B) >> 7
        yy = (x0 * C + z0 * Dm) >> 7
        zz = (z0 * F) >> 7
        zc = zz + ZOFF
        r = int(round(D * 256 / zc))
        balls.append((zc, ((xx * r) >> 8) + wire_cx, ((yy * r) >> 8) + MIDCY))
    order = sorted(range(8), key=lambda i: (balls[i][0], i))     # stable: nearest first
    bufs = []
    for rank, bi in enumerate(order):
        zc, sx, sy = balls[bi]
        size = 16 if zc < NEAR else 12 if zc < MID else 8
        v0 = 44 + sy - size // 2
        v1 = v0 + size
        h = sx + 0x81 - 8
        pos = ((v0 & 255) << 8) | ((h >> 1) & 255)
        ctl = ((v1 & 255) << 8) | (((v0 >> 8) & 1) << 2) | (((v1 >> 8) & 1) << 1) | (h & 1)
        data = struct.pack('>HH', pos, ctl)
        for a, b in gen_tables.ball_lines(size):
            data += struct.pack('>HH', a, b)
        bufs.append(data + bytes(4))
    return bufs


def png(path, w, h, rows):
    raw = b''.join(b'\0' + bytes(r) for r in rows)
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                     chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', type=int, default=800, help='frames to run before pressing the mouse button')
    ap.add_argument('--png', help='write the rendered frame as a PNG')
    ap.add_argument('--snap', type=int, default=700, help='frame to render and check')
    ap.add_argument('--alloc-fast', action='store_true', help='make AllocMem return fast RAM (failure path)')
    ap.add_argument('--ntsc', action='store_true', help='262 line frame: the PAL-only intro must still run and exit, not hang')
    ap.add_argument('--loader-chip', action='store_true', help='let the loader honour the chip hunk flag')
    args = ap.parse_args()
    global FRAME_LINES, FRAME_CYCLES
    if args.ntsc:
        FRAME_LINES = 262; FRAME_CYCLES = LINE_CYCLES * FRAME_LINES

    tmp = Path(tempfile.mkdtemp(prefix='neon_emu_'))
    exe = tmp / 'neon_vectors_sym'
    assemble(exe)
    mod = (ROOT / 'assets/neon.mod').read_bytes()
    logo_all = (ROOT / 'assets/logo.raw').read_bytes()
    logo_planes = [logo_all[i * 2560:(i + 1) * 2560] for i in range(4)]
    logo = logo_planes[0]
    font = (ROOT / 'assets/font.raw').read_bytes()

    a = Amiga(exe, args.loader_chip, args.alloc_fast)
    a.consts = source_equs()
    snap_frame = min(args.snap, args.frames - 1)
    # Every frame, the wireframe buffer the Copper is showing must equal the reference frame
    # exactly, including the rows outside the band. A single snapshot can miss stale pixels
    # that only occur in rows the object seldom reaches.
    wire_fail = []
    wire_frames = [0]
    def wire_each_frame(n, bpl2):
        if n < 3 or wire_fail:
            return
        eq = a.consts
        if not a.ready_verts:
            a.ready_verts = True
            a.wv = [struct.unpack('>3h', a.mem.r_block(a.sym('verts') + 6 * i, 6)) for i in range(14)]
            eb = a.mem.r_block(a.sym('edges'), a.sym('edges_end') - a.sym('edges'))
            a.we = [(eb[i], eb[i + 1]) for i in range(0, len(eb), 2)]
        pix, _ = ref_wire(n - 2, a.wv, a.we, (eq['WIRE_D'], eq['WIRE_ZOFF'], eq['MID_CX'], eq['MID_CY'], eq['WIRE_SWAY'], eq['WIRE_ZOOM']))
        want = bytearray(10240)
        want[eq['LOGO_Y'] * 40:(eq['LOGO_Y'] + eq['LOGO_H']) * 40] = a.logo_p1
        for x, y in pix:
            if 0 <= x < 320 and 0 <= y < 256:
                want[y * 40 + (x >> 3)] |= 0x80 >> (x & 7)
        got = a.mem.r_block(bpl2 + 2, 10240)
        wire_frames[0] += 1
        if got != bytes(want):
            bad = [i // 40 for i in range(10240) if got[i] != want[i]]
            wire_fail.append('frame %d: displayed wireframe buffer differs from the reference in %d bytes (rows %s...)' % (n, len(bad), sorted(set(bad))[:6]))
    a.ready_verts = False
    a.logo_p1 = logo_planes[1]
    a.frame_hook = wire_each_frame
    print('running %d frames ...' % args.frames)
    ok = a.run(args.frames, snap_frame)
    mem = a.mem

    # ---------------------------------------------------------------- exit state
    print('exit path')
    if args.alloc_fast:
        check(a.cpu.r_reg(R.D0) == 20, 'alloc failure must return RETURN_FAIL (20), got %d' % a.cpu.r_reg(R.D0))
        check(not a.allocs, 'memory leaked after failed chip allocation')
        check(a.gfx_open == 0, 'graphics.library left open')
        check('LoadView' not in a.calls, 'display was taken over although allocation failed')
        finish()
        return
    if not ok:
        finish(); return
    c = a.cpu
    check(c.r_reg(R.D0) == 0, 'return code d0 = %d, expected 0' % c.r_reg(R.D0))
    for i in range(1, 8):
        check(c.r_reg(R.D0 + i) == a.sentinel_regs[i - 1], 'd%d not preserved' % i)
    for i in range(7):
        check(c.r_reg(R.A0 + i) == a.sentinel_regs[7 + i], 'a%d not preserved' % i)
    check(c.r_reg(R.A7) == STACK, 'stack pointer not restored (sp=$%X)' % c.r_reg(R.A7))
    check(a.nest_forbid == 0 and a.nest_disable == 0, 'Forbid/Disable nesting not balanced')
    check(not a.allocs, 'chip memory leaked: %s' % {hex(k): v for k, v in a.allocs.items()})
    check(a.gfx_open == 0, 'graphics.library not closed')
    check(a.loadviews == [0, a.view], 'LoadView calls %s, expected [NULL, old view]' % a.loadviews)
    check(mem.r32(CUSTOM + 0x80) == a.copinit, 'COP1LC is not the system copinit list ($%X)' % mem.r32(CUSTOM + 0x80))
    i_dm, i_ie, i_ak = a.init
    check(a.dmacon == (i_dm & 0x07F0), 'DMACON $%04X != restored $%04X (audio must stay off)' % (a.dmacon, i_dm & 0x07F0))
    check(a.intena & 0x3FFF == i_ie & 0x3FFF and a.intena & 0x8000, 'INTENA $%04X not restored from $%04X' % (a.intena, i_ie))
    check(a.adkcon == i_ak, 'ADKCON $%04X not restored from $%04X' % (a.adkcon, i_ak))
    order = [x for x in a.calls if x in ('Forbid', 'Disable', 'Enable', 'Permit')]
    check(order == ['Forbid', 'Disable', 'Enable', 'Permit'], 'scheduler call order %s' % order)
    for i, h in enumerate(a.hunks):
        now = mem.r_block(a.bases[i], a.sizes[i])
        if i == 0:
            check(now == a.orig[i], 'code hunk was modified while running')
        if a.hunk_mem[i] == 1 and not args.loader_chip:
            check(now == a.orig[i], 'the link-time chip hunk was modified: code used a link-time address instead of the chip copy')

    if args.ntsc:
        print('  NTSC frame: intro ran and exited without hanging (timing is not meaningful here)')
        finish(); return

    # ---------------------------------------------------------------- frame pacing
    print('frame pacing')
    fm = a.frame_marks
    # (the first interval contains the start-up work and may span two frames)
    deltas = {(y // FRAME_CYCLES) - (x // FRAME_CYCLES) for x, y in zip(fm[1:], fm[2:])}
    check(deltas == {1}, 'the main loop must advance exactly one frame per iteration, saw frame deltas %s' % sorted(deltas))
    work = [t1 - t0 for t0, t1 in zip(a.exit_times, fm[1:])]
    worst = max(work)
    print('  per-frame CPU work: avg %d, worst %d cycles (%.0f%% of a frame; no DMA contention or blitter time modelled)'
          % (sum(work) // len(work), worst, 100.0 * worst / FRAME_CYCLES))
    check(worst < 0.85 * FRAME_CYCLES, 'the main loop needs %.0f%% of a frame: too close to dropping frames (and the 50 Hz tracker tick)' % (100.0 * worst / FRAME_CYCLES))
    # Single-buffered drawing must finish before the beam reaches what it draws. Stars are
    # drawn first and live in rows 76..195 (display line 120 and below); the scroller strip
    # starts at display line 244. `scroller` is entered when the stars are done and `wire`
    # when the scroller is done; both times are measured from the moment the loop left the
    # frame-sync wait, converted to the beam line it was at.
    logo_slack, spr_slack = [], []
    star_slack, scr_slack = [], []
    for i, t0 in enumerate(a.exit_times[:len(a.t_marks.get('wire', []))]):
        line0 = (t0 // LINE_CYCLES) % FRAME_LINES
        lines_to = lambda target: ((FRAME_LINES - line0) + target) * LINE_CYCLES
        logo_slack.append(lines_to(44 + 8) - (a.t_marks['sprites'][i] - t0))
        spr_slack.append(lines_to(44 + 56) - (a.t_marks['stars'][i] - t0))
        star_slack.append(lines_to(44 + 76) - (a.t_marks['scroller'][i] - t0))
        scr_slack.append(lines_to(44 + 200) - (a.t_marks['wire'][i] - t0))
    ts = [m - e for m, e in zip(a.t_marks['scroller'], a.exit_times)]
    tw = [m - m2 for m, m2 in zip(a.t_marks['wire'], a.t_marks['scroller'])]
    tall = [t1 - t0 for t0, t1 in zip(a.exit_times, fm[1:])]
    print('  cost split (avg cycles): mod+raster+stars %d, scroller %d, wireframe+rest %d'
          % (sum(ts) // len(ts), sum(tw) // len(tw), sum(tall[:len(ts)]) // len(ts) - sum(ts) // len(ts) - sum(tw) // len(tw)))
    print('  wave+bars finish %d cycles before the beam reaches the logo; sprites %d before the ring; stars %d before the starfield; scroller %d before its strip (worst frame)'
          % (min(logo_slack), min(spr_slack), min(star_slack), min(scr_slack)))
    check(min(spr_slack) > 0, 'the sprite buffers are still being rewritten when the beam reaches the ring (%d cycles late)' % -min(spr_slack))
    check(min(logo_slack) > 0, 'the wave and bar rows are still being rewritten when the beam reaches the logo (%d cycles late)' % -min(logo_slack))
    check(min(star_slack) > 0, 'stars are still being drawn when the beam reaches the starfield band (flicker/tearing)')
    check(min(scr_slack) > 0, 'the scroller is still being shifted when the beam reaches its strip (tearing)')
    # Wireframe buffers must alternate every frame: the Copper never points at the buffer being drawn.
    bp = a.bpl2_seen[1:]
    check(len(set(bp)) == 2 and all(x != y for x, y in zip(bp, bp[1:])),
          'BPL2PT must alternate between exactly two wireframe buffers every frame, saw %s' % sorted(set(hex(x) for x in bp)))
    print('  %d line blits and %d band clears issued' % (a.blit_lines, a.blit_clears))

    # ---------------------------------------------------------------- audio
    print('audio')
    sl = mod[950]
    pats = max(mod[952:952 + sl]) + 1
    smp = []
    off = 1084 + pats * 1024
    for i in range(31):
        o = 20 + i * 30
        ln = int.from_bytes(mod[o + 22:o + 24], 'big'); ls = int.from_bytes(mod[o + 26:o + 28], 'big')
        ll = int.from_bytes(mod[o + 28:o + 30], 'big'); vol = mod[o + 25]
        smp.append((off, ln, ls, ll, vol)); off += ln * 2
    ptr_mod = mem.r32(a.sym('reloc_table') + 16)
    chip_mod_lo, chip_mod_hi = ptr_mod, ptr_mod + len(mod)
    silence = mem.r32(a.sym('reloc_table') + 12)
    expected = []
    order_tab = mod[952:952 + sl]
    n_rows = (len(fm) - 1) // 6 + 1          # the loop body runs len(fm) times; rows start on iterations 1, 7, 13, ...
    for r in range(n_rows):
        base = 1084 + order_tab[(r // 64) % sl] * 1024 + (r % 64) * 16
        for ch in range(4):
            b0, b1, b2, b3 = mod[base + ch * 4: base + ch * 4 + 4]
            sn = (b0 & 0xF0) | (b2 >> 4); per = ((b0 & 15) << 8) | b1
            if sn and per:
                o, ln, ls, ll, vol = smp[sn - 1]
                expected.append((r, ch, o, max(ln, 1), per, vol, ls, ll))
    got = [(l[1], l[2] - chip_mod_lo, l[3], l[4], l[5]) for l in a.latches]
    exp = [(e[1], e[2], e[3], e[4], e[5]) for e in expected]
    check(len(got) == len(exp), 'audio triggers: got %d, expected %d' % (len(got), len(exp)))
    bad = [(i, g, e) for i, (g, e) in enumerate(zip(got, exp)) if g != e]
    check(not bad, 'audio trigger mismatch (idx, got (ch,offset,words,period,vol), expected): %s' % bad[:3])
    for lt in a.latches:
        check(chip_mod_lo <= lt[2] and lt[2] + lt[3] * 2 <= chip_mod_hi, 'Paula would fetch outside the module: $%X len %d' % (lt[2], lt[3]))
    rows_t = sorted({l[0] // FRAME_CYCLES for l in a.latches})
    if len(rows_t) > 2:
        gaps = {y - x for x, y in zip(rows_t, rows_t[1:])}
        check(gaps <= {6, 12, 18, 24}, 'tracker rows not a multiple of 6 frames apart: gaps %s' % sorted(gaps))
    want = {}
    for e in expected:
        o, ln, ls, ll = e[2], e[3], e[6], e[7]
        want.setdefault(e[1], []).append((o + ls * 2 + chip_mod_lo, ll) if ll > 1 else (silence, 1))
    seen = {}
    for (t, ch, p, ln) in a.loopregs:
        seen.setdefault(ch, []).append((p, ln))
    for ch in range(4):
        if ch in want and ch in seen:
            n = min(len(want[ch]), len(seen[ch]))
            check(seen[ch][:n] == want[ch][:n], 'channel %d loop/terminal registers wrong: got %s want %s'
                  % (ch, [(hex(x), y) for x, y in seen[ch][:2]], [(hex(x), y) for x, y in want[ch][:2]]))
    print('  %d channel starts over %d rows match the module' % (len(got), n_rows))
    check(mem.r16(silence) == 0x8080 if a.hunk_mem[2] != 1 or args.loader_chip else True, 'silence word is not $8080')

    # ---------------------------------------------------------------- display
    print('display (frame %d)' % snap_frame)
    sn = a.snapshot
    if not check(sn is not None, 'no frame snapshot was taken'):
        finish(); return
    check(sn['terminated'], 'Copper list does not end with $FFFF,$FFFE')
    check((sn['dmacon'] & 0x3E0) == 0x3E0, 'master, bitplane, Copper, blitter and sprite DMA are not all enabled (DMACON=$%04X)' % sn['dmacon'])
    check(all(l[3] >= 1 and l[2] != 0 for l in a.latches), 'a channel was started with no sample loaded (Paula would play noise): %s' % [l for l in a.latches if l[3] < 1 or l[2] == 0][:2])
    check(sn['diw'] == (0x2C, 0x12C), 'display window lines %s, expected (44, 300)' % (sn['diw'],))
    scr = mem.r32(a.sym('reloc_table') + 0)
    P = 10240
    check(sn['first'].get(0x104) == 2, 'BPLCON2 is $%04X, expected 2 (far sprites behind the playfield)' % sn['first'].get(0x104, 0))
    check(sn['ddf'][:4] == (0x30, 0xD0, 21, -2), 'display fetch setup (DDFSTRT, DDFSTOP, words, modulo) is %s' % (sn['ddf'][:4],))
    check(sn['ptr'][0] == scr - 2, 'plane 0 pointer $%X != $%X (planes start one word early)' % (sn['ptr'][0], scr - 2))
    check(sn['ptr'][2] == scr + 3 * P - 2, 'plane 2 pointer $%X != $%X' % (sn['ptr'][2], scr + 3 * P - 2))
    check(sn['ptr'][1] in (scr + P - 2, scr + 2 * P - 2), 'plane 1 pointer $%X is not one of the two plane 1 buffers' % sn['ptr'][1])
    check(sn['ptr'][3] - sn['ptr'][1] == 3 * P, 'plane 3 front buffer $%X does not match the plane 1 front buffer $%X' % (sn['ptr'][3], sn['ptr'][1]))
    n = snap_frame
    equ = lambda name: a.consts[name]
    # ---- expected planes
    e0, e1, e2, e3 = bytearray(P), bytearray(P), bytearray(P), bytearray(P)
    def setpix(plane, x, y):
        plane[y * 40 + (x >> 3)] |= 0x80 >> (x & 7)
    LOGO_Y, LOGO_H, MID_Y0, MID_H = equ('LOGO_Y'), equ('LOGO_H'), equ('MID_Y0'), equ('MID_H')
    SCROLL_Y = equ('SCROLL_Y')
    for e_, lp in zip((e0, e1, e2, e3), logo_planes):
        e_[LOGO_Y * 40:(LOGO_Y + LOGO_H) * 40] = lp
    stars = ref_stars(n - 1, equ('NSTARS'), (equ('ZMIN'), equ('ZRANGE'), equ('ZSPEED'), equ('ZMID'), equ('ZNEAR'),
                                              equ('PROJ_F'), equ('MID_CX'), equ('MID_CY'), MID_Y0, MID_H))
    for x, y, cl in stars:
        if cl & 1: setpix(e2, x, y)
        if cl & 2: setpix(e0, x, y)
    tb = bytes(mem.r_block(a.sym('scroll_text'), 400)).split(b'\0')[0]
    shifts = sn['shifts']
    check(shifts == (n - 1) // 2, 'scroller advanced %d pixels in %d frames, expected %d' % (shifts, n - 1, (n - 1) // 2))
    def stream_bit(kk, row):
        if kk < 0:
            return 0
        ch = tb[(kk // 8) % len(tb)]
        g = ch - 32 if 32 <= ch < 127 else 0
        return (font[g * 8 + row // 2] >> (7 - (kk % 8))) & 1
    for y in range(16):
        for x in range(320):
            if stream_bit(shifts - (319 - x), y):
                setpix(e0, x, SCROLL_Y + y)
    verts = [struct.unpack('>3h', mem.r_block(a.sym('verts') + 6 * i, 6)) for i in range(14)]
    eb = mem.r_block(a.sym('edges'), a.sym('edges_end') - a.sym('edges'))
    edges = [(eb[i], eb[i + 1]) for i in range(0, len(eb), 2)]
    wire_ok = n >= 3
    if wire_ok:
        pix, proj = ref_wire(n - 2, verts, edges, (equ('WIRE_D'), equ('WIRE_ZOFF'), equ('MID_CX'), equ('MID_CY'), equ('WIRE_SWAY'), equ('WIRE_ZOOM')))
        outside = [p for p in pix if not (0 <= p[0] < 320 and MID_Y0 <= p[1] < MID_Y0 + MID_H)]
        check(not outside, 'the wireframe leaves its %d line band: %s' % (MID_H, outside[:3]))
        for x, y in pix:
            if 0 <= x < 320 and 0 <= y < 256:
                setpix(e1, x, y)
    def diff(name, got, want):
        bad = [i for i in range(P) if got[i] != want[i]]
        rows = sorted({i // 40 for i in bad})
        check(not bad, '%s differs from the expected image in %d bytes (rows %s...)' % (name, len(bad), rows[:6]))
        return not bad
    for m_ in wire_fail:
        check(False, m_)
    ok0 = diff('plane 0 (logo + mid stars + scroller)', sn['planes'][0], e0)
    ok2 = diff('plane 2 (far + near stars)', sn['planes'][2], e2)
    ok1 = diff('plane 1 (logo + wireframe, displayed buffer)', sn['planes'][1], e1) if wire_ok else True
    ok3 = diff('plane 3 (logo, displayed buffer)', sn['planes'][3], e3)
    # ---- palette / Copper
    pbl = sn['pal_by_line']
    import logo_art
    check(all(pbl[44 + 2][k] == logo_art.PALETTE[k] for k in (1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)),
          'the logo palette is not loaded by the Copper header')
    check(pbl[44 + 8][4] == 0xFFF, 'logo face colour at its top row is $%03X, expected white' % pbl[44 + 8][4])
    check(pbl[44 + 50][4] != pbl[44 + 8][4], 'the logo face colour has no vertical gradient')
    check(all(pbl[44 + 100][k] == gen_tables.MID_PALETTE[k] for k in range(1, 16)), 'the middle band palette is not loaded below the logo')
    check(pbl[44 + 100][1] == 0xAAD, 'middle band mid-star colour is $%03X, expected $AAD' % pbl[44 + 100][1])
    check(all(pbl[44 + 100][i] == 0x3FC for i in (2, 3, 6, 7)), 'wireframe colours (2, 3, 6, 7) differ')
    # ---- sprite ring: the eight buffers exactly, and the sprite palette
    sin_tab = [int(round(127 * math.sin(2 * math.pi * i / 256))) for i in range(256)]
    prev_cx = equ('MID_CX') + ((sin_tab[(n - 2) & 255] * equ('WIRE_SWAY')) >> 7) if n >= 2 else equ('MID_CX')
    ring = ref_ring(n - 1, prev_cx, (equ('RING_R'), equ('RING_TILT'), equ('WIRE_ZOFF'), equ('MID_CY'), equ('BALL_NEAR'), equ('BALL_MID'), equ('WIRE_D')))
    ring_bad = []
    for r_, want_ in enumerate(ring):
        got_ = sn['spr_pages'][r_][:len(want_)]
        if got_ != want_:
            ring_bad.append((r_, got_[:4].hex(), want_[:4].hex()))
    check(not ring_bad, 'sprite ring buffers differ on %d of 8 sprites; first (rank, got header, want header): %s' % (len(ring_bad), ring_bad[:2]))
    spr_base = mem.r32(a.sym('reloc_table') + 40)
    page_ok = True
    for r_, want_ in enumerate(ring):
        size = (len(want_) - 8) // 4
        cls = {16: 0, 12: 1, 8: 2}[size]
        if sn['spr_ptr'][r_] != spr_base + (r_ * 3 + cls) * equ('SPR_BYTES'):
            page_ok = False
    check(page_ok, 'a sprite pointer does not address the prebuilt page for its rank and ball size')
    check(all(pbl[44 + 2][c] == v for c, v in gen_tables.spr_palette_regs()), 'the sprite palette is not loaded by the Copper header')
    # ---- wavy logo: BPLCON1 per row, and the logo as actually displayed
    px = sn['px']
    f = n - 1                                          # frame_no after n-1 completed iterations
    sine = [int(round(127 * math.sin(2 * math.pi * i / 256))) for i in range(256)]
    wave_bad, shown_bad = [], 0
    for r in range(LOGO_H):
        want_sc = gen_tables.wave_tab()[(((f << 2) & 0xFFFF) + 3 * r) & 255]
        v = want_sc & 15
        got_sc = sn['bplcon1_by_line'][44 + LOGO_Y + r]
        if got_sc != want_sc:
            wave_bad.append((r, got_sc, want_sc))
        for x in range(v, 320):                        # (the first v pixels show the previous row's tail)
            want_idx = sum(((logo_planes[k][r * 40 + ((x - v) >> 3)] >> (7 - ((x - v) & 7))) & 1) << k for k in range(4))
            if px[LOGO_Y + r][x] != want_idx:
                shown_bad += 1
    check(not wave_bad, 'wavy logo: BPLCON1 differs on %d rows, first (row, got, want) %s' % (len(wave_bad), wave_bad[:2]))
    check(shown_bad == 0, 'the displayed logo differs from the logo shifted by BPLCON1 in %d pixels (fetch/modulo model)' % shown_bad)
    others = [y for y in range(256) if not LOGO_Y <= y < LOGO_Y + LOGO_H and sn['bplcon1_by_line'][44 + y] != 0]
    check(not others, 'BPLCON1 is not back to 0 outside the logo (rows %s...)' % others[:4])
    # ---- copper-bar floor (all of it lies below display line 255, so this also proves the Copper wrap)
    FY0, FH = gen_tables.FLOOR_Y0, gen_tables.FLOOR_H
    rows = list(gen_tables.floor_base())
    bc = gen_tables.bar_colors()
    for k in range(gen_tables.NBARS):
        top = ((sine[(((f * (k + 2)) & 0xFFFF) + 64 * k) & 255] * 13) >> 7) + FH // 2 - 4
        for j in range(8):
            if 0 <= top + j < FH:
                rows[top + j] = bc[k * 8 + j]
    got_rows = [pbl[44 + FY0 + i][0] for i in range(FH)]
    check(got_rows == rows, 'floor bar rows (below display line 255, after the Copper wrap) differ: first %s' %
          [(i, hex(g), hex(w)) for i, (g, w) in enumerate(zip(got_rows, rows)) if g != w][:2])
    pal = [0x102,0x203,0x304,0x405,0x506,0x607,0x708,0x819,0x92A,0xA3B,0xB4C,0xC5D,0xD6E,0xE7F,0xD6E,0xC5D,
           0xB4C,0xA3B,0x92A,0x819,0x708,0x607,0x506,0x405,0x304,0x203,0x102,0x213,0x324,0x435,0x546,0x657]
    check(pbl[44 + 73][0] in pal, 'raster slot colour $%03X is not from the colour table' % pbl[44 + 73][0])
    print('  wireframe buffer verified on each of %d frames' % wire_frames[0])
    if ok0 and ok1 and ok2 and ok3 and not wire_fail:
        print('  logo, %d stars, scroller and the %d-edge wireframe (%d pixels) match the reference models exactly'
              % (len(stars), len(edges), len(pix) if wire_ok else 0))
    if args.png:
        pal_rgb = lambda v: bytes(((v >> 8) & 15) * 17 for _ in range(1)) + bytes(((v >> 4) & 15) * 17 for _ in range(1)) + bytes((v & 15) * 17 for _ in range(1))
        rows = []
        for row in sn['img']:
            r = b''.join(pal_rgb(v) * 2 for v in row)
            rows += [r, r]
        png(Path(args.png), 640, len(rows), rows)
        print('  wrote', args.png)
    finish()


def finish():
    if failures:
        print('\nEMULATION TEST FAILED (%d)' % len(failures))
        sys.exit(1)
    print('\nEMULATION TEST PASSED')


if __name__ == '__main__':
    main()
