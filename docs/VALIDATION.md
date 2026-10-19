# Validation contract

Validation has complementary layers. The assembler is the authority on encodings and
relocations; the emulation test checks behaviour within its hardware model; the static validator and its
mutation self-test keep known mistakes from coming back.

| Layer | Command | Checks |
| --- | --- | --- |
| Static | `make validate` | assets and source rules below; gates the build |
| Self-test | `make mutants` | validator must detect all 33 injected faults |
| Assembler | `make` | VASM assembles; `hunkcheck.py` parses the executable |
| Behaviour | `make emutest` | real binary on an emulated 68000 |
| Behaviour self-test | `make emu-mutants` | an unmodified baseline run passes, then all 25 injected faults are caught (slow) |

## `tools/validate.py` — assets

Exact planar asset sizes, the `M.K.` signature, song/order/pattern/sample extent consistency,
sample volumes and loop bounds, period range, sample numbers, every effect used by the tune
(only notes, `Cxx`, `F01..F1F`), signed sample centring and bounded kick sample steps, hi-hat decay, and logo ink
inside x = 1..318.

## `tools/validate.py` — source

- Symbol cross-reference of the whole translation unit: every label, `EQU` and local label
  referenced is defined; global labels are unique.
- 68000 encoding hazards that a host-side check can see: indexed displacement outside −128..127
  (symbolic ones are evaluated), PC-relative operands (as destination, or for data in another
  hunk), `addi/subi/andi/ori/eori/cmpi` targeting an address register, quick
  add/sub/shift counts outside 1..8, writes to read-only custom registers, explicit short
  branches.
- Library calls: the register class of every argument (`OpenLibrary`/`CloseLibrary`/
  `LoadView`/`FreeMem`/`TypeOfMem` take their pointer in `a1`, `CopyMem` takes `a0` = source and
  `a1` = destination, `AllocMem` takes `d0`/`d1`) must have been set after the previous call;
  the scanner fails if it finds no calls at all.
- Constants: library vectors (`CopyMem` −624, `TypeOfMem` −534, …), `GfxBase` offsets, the
  `DMAF_*` bit positions (copper `$0080`, bitplane `$0100`, master `$0200`, …), `MEMF_*`, `SILENCE_WORD`.
- Structure: Copper list ends in `$FFFF,$FFFE`; WAIT words have bit 0 set; the standard
  `DIWSTRT/DIWSTOP/DDFSTRT/DDFSTOP/BPLCON0` values are present; the animated slot is a `COLOR00`
  pair; `PatchCopper` patches data words (2/6, 10/14, 18/22, 26/30) and never register words;
  `StarAddress` never writes the plane base; every code subroutine has an `rts`.
- Ordering: `Forbid` before `Disable`, `Enable` before `Permit`, `MOD_Stop` before `LoadView`,
  `ExecBase` loaded before the first `jsr`, `INTENA`/`INTREQ` masked before custom DMA starts.
- Chip memory: `AllocChipMem` verifies with `TypeOfMem` before copying and releases a non-chip
  block; chip-payload labels are only named in their definitions and in `reloc_table`.

Rules that used to exist and were **removed** because they were wrong: "memory-to-memory
`MOVE` is illegal", "`ADDA.W` is 68020+", "`BSET Dn,<mem>` is 68020+" — all three are valid
68000 instructions.

## `tools/mutate.py`

Copies the tree, injects 33 faults one at a time (swapped scheduler calls, patching a register
word, a wrong silence value, typos in symbols and labels, broken Copper terminator/WAIT, duplicated
labels, direct chip-label use, short branches, symbolic and numeric oversize index
displacements, PC-relative destination and read, `addi` to `aN`, oversize shift count, a write to
`DMACONR`, wrong standard/DIW/DMAF/LVO/GfxBase constants, a removed `TypeOfMem` check, and wrong
argument registers for `CopyMem`, `FreeMem`, `CloseLibrary`, `OpenLibrary`, `LoadView`) and
requires the validator to report each. It exits non-zero if any fault is missed.

## `tools/emu_test.py`

See the README. The harness stubs Exec and graphics.library with the real register conventions
(including `a6` = library base), trashes scratch registers on return, models SET/CLR registers, the
beam counter, a Copper interpreter (with the `$FFDF` wrap) and Paula start latching, and — for the
graphics — a **blitter model**: line mode following the Hardware Reference Manual's register-level
algorithm, and the D-only rectangle clear. Any other blit is reported rather than guessed at.

It asserts memory balance (with guard bytes around the allocation), register and stack
preservation, restored chipset state, exactly one loop iteration per frame, the CPU budget, the
single-buffered deadlines (wave and bar rows before the beam reaches the logo, stars before the
starfield, scroller before its strip), the display fetch setup and the displayed logo under the wave,
alternating wireframe buffers, every audio trigger and reload against the module, and pixel-exact
planes against independent Python reference models: the logo, every star position and depth class,
every scroller pixel, the wave and bar rows, and the wireframe (reference matrix, motion path,
perspective and Bresenham) — the last on
**every frame**, including the rows outside the band.

The harness was itself mutation-tested (`make emu-mutants`): swapped octant table entries,
`ONEDOT` set, no double buffering, a short band clear, a wrong rotation-matrix sign, missing star
erase, a scroller overrun, blitter DMA never enabled, a missing Copper wrap, a wrong wave step, a
wave that is never reset, a wrong display modulo, misplaced bar writes, an ignored sway, `AUDxLEN` off by one,
swapped `CopyMem` arguments, missing frame-sync edge detection, leaked memory, a masked
vertical-blank interrupt before `WaitTOF`, an unpatched sprite pointer, an off-by-one `HSTART`, sprite
DMA never enabled, a ring wobble ignoring the tilt, and a wireframe vertex sign error.

That harness first runs the **unmodified** program and requires it to pass. Without that step a
broken emulator stub or a missing dependency would make every mutant "fail" by crashing, which
looks identical to a genuine detection. `tools/mutate.py` applies the same reasoning: it fails
explicitly if the unmutated tree does not validate, because a validator that rejects everything
proves nothing about the faults it should catch.

What it cannot prove: DMA cycle stealing, real beam timing, blitter *timing*, and anything about
how the picture or sound *looks* or *sounds* on a real Amiga. The blitter's line mode was checked
against real emulated hardware by running the program in FS-UAE.

## Reproducibility

`tools/verify_repro.py` generates the logo, font, PNG preview and MOD twice and requires
identical generated bytes and equality with the shipped assets, using temporary output
directories so verification does not rewrite the checkout. `MANIFEST.sha256` lists every shipped file
(`shasum -a 256 -c MANIFEST.sha256`).

## Host tooling regressions

`make test` checks valid and malformed Hunk executables, every truncated prefix of
a minimal executable, counted library/section names, section allocation limits,
missing terminators, relocation targets and alignment. It also exercises lighting
normalization, zero-radius glows, helper input boundaries and local RNG isolation.

Hunk parsing is import-safe and rejects unsupported formats explicitly. The MOD
validator rejects unsupported finetune, period-only notes and empty sample triggers;
truncated assets fail with diagnostics before pattern decoding.

## Startup failure injection

`--open-fail`, `--alloc-fail` and `--alloc-fast` are mutually exclusive scenarios.
Each requires return code 20, preserved registers and stack, balanced library and
memory ownership, unchanged DMA/interrupt/audio control state, no display takeover,
and the exact expected cleanup call sequence. These checks run in `make test` when
VASM and machine68k are available; otherwise that optional test reports a skip.

## Choreography references

The harness derives expected visual pulse values directly from MOD note history,
checks them after every completed frame and checks all eight sprite pages against
independent scene-tilt references. Gallery captures validate the scene palette and
light level against an independent floor calculation. Host tests cover the pulse
decay, non-triggering events, palette-bank extents and monotonic light levels.
Mutation cases include a missing onset cue, wrong palette stride and lost second-scene tilt.

Long-run scroller checks compare the stored character/column position modulo the
message length, while pixel reconstruction uses total elapsed shifts. This keeps
the previous message tail visible after a wrap. The distribution snapshot at frame
4490 exercises the first wrap of the current message within the 6,400-frame run.

## Scene logo expansion (2026-10-18)

The eight harmonic logo banks pass a 2,100-frame execution, including the visual
loop boundary. Every frame checks all 64 Copper scroll words against the scene
reference. Both a removed scene selector and an incorrect row phase are detected
by targeted mutation runs after a passing baseline. All 18 host tests, 33 static
mutants and deterministic asset reproduction pass. Worst modeled work is 111,018
CPU cycles (about 78% of a PAL frame); the minimum starfield margin is 3,306 cycles.
The model excludes DMA contention and blitter duration; physical hardware and
cycle-exact acceptance remain open. Gallery images were regenerated from this run.

## Sculpted paths and aurora (2026-10-18)

Final acceptance covers 2,100 frames and all eight scene midpoints, including the
visual loop boundary. All fifteen CPU-written aurora bands and eight sprite pages
are compared on every frame; the snapshot also checks displayed background colours.
The full-cycle path bounds regression keeps sprites clear of the logo artwork and
scroller. All 19 host tests, 33 static mutations and deterministic asset reproduction
pass. A passing 300-frame baseline precedes three targeted fault injections: wrong
aurora phase, wrong orbit-bank stride and swapped chip-copy source/destination.
All three are caught with the expected diagnostics. Chip-loader and NTSC no-hang
100-frame runs pass as well.

Worst modeled work is 112,040 cycles (79% of a PAL frame), average 95,549; minimum
starfield deadline margin is 2,200 cycles. Copper instruction count remains 924
words. No chip data is added; the new tables add 11 KiB of ordinary data. DMA
contention, blitter duration, genuine Kickstart and physical hardware acceptance
remain outside this host model. Gallery and cover images come from the final run.

## 68000 optimization and energy bridges (2026-10-18)

The matrix/scroller/effect revision passes 6,400 frames, including two complete
music loops and the message wrap (snapshot 4,490). Its 155,088 line blits and 1,653
audio starts over 1,067 rows match the references. A subsequent fixed-Copper
batching revision passes 2,100 frames covering all eight scenes and their loop
boundary; all 64 logo rows and fifteen aurora bands match on every frame. That
final revision also passes all 19 host tests, 33 static mutations, reproducible
assets and the 100-frame chip-loader check. Targeted mutation checks detect
missing energy bridges, corrupt shared matrix products, shifted scroller row
bounds, wrong rotation sign, lost buffering and corrupt logo/aurora phases.

Comparable 2,100-frame runs give:

| Modeled CPU measure | Previous version | Final optimized version |
| --- | --- | --- |
| Average frame | 95,549 cycles | 84,928 cycles |
| Worst frame | 112,040 cycles | 109,720 cycles |
| Worst share of PAL frame | 79% | 77% |
| Average scroller stage | 5,836 cycles | 4,492 cycles |
| Minimum starfield deadline margin | 2,200 cycles | 3,044 cycles |
| Line blits | 47,952 | 50,416 |

Average work falls about 11% while 2,464 additional music-triggered links are
drawn. The model does not include DMA contention or blitter duration. These
numbers measure improvements in the host model; they do not establish the
physical machine's maximum or replace genuine Kickstart/hardware acceptance.
The final gallery includes an executable-rendered energy-cage frame at 1,148.

## Eased scene joins and paired link decay (2026-10-18)

All eight sprite path/tilt joins, including Afterglow back into Ignition, pass a
2,100-frame execution with every-frame sprite-page and wireframe comparisons.
The table endpoint regression checks that each blend starts within one unit of
the previous path and reaches the destination exactly. Full-cycle sprite bounds
remain clear of the logo artwork and scroller. The paired edge reference covers
the entire nonzero music envelope and clears at zero.

All 20 host tests, 33 static mutations, deterministic assets and the 100-frame
chip-loader run pass. Passing baselines precede targeted mutations for skipped
orbit easing, skipped tilt easing, suppressed links and links stuck at full
strength; each is caught with the expected rendering diagnostic.

Average modeled work is 85,150 cycles, worst 109,402 (77% of a PAL frame), with
2,852 cycles minimum starfield margin. The run issues 50,592 line blits, compares
2,098 displayed object buffers and verifies 482 audio starts across 350 rows.
Transition lookup data adds 8 KiB plus 512 bytes of ordinary RAM, with no change
to chip allocation or Copper instruction count. The host model still excludes
DMA contention and blitter duration; real hardware acceptance remains open.
Gallery and energy-cage images were refreshed from this executable run.
