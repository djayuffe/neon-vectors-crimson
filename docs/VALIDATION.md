# Validation contract

There are four independent layers. The assembler is the authority on encodings and
relocations; the emulation test is the authority on behaviour; the static validator and its
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
(only notes, `Cxx`, `F01..F1F`), unsigned sample centring with no DC step, hi-hat decay, and logo ink
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
  pair; `PatchCopper` patches data words (2/6, 10/14, 18/22) and never register words;
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
identical SHA-256 hashes. `MANIFEST.sha256` lists every shipped file
(`shasum -a 256 -c MANIFEST.sha256`).
