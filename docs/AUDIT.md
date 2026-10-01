# Code audit

Scope: every file in the repository — the three assembly sources, the Makefile, all Python
tools, the bootstrap script and the documentation. Method: line-by-line review against the
Amiga Exec/graphics.library autodocs and the OCS register map; assembling with VASM 2.0f
(`-m68000 -kick1hunks -Fhunkexe`); and running the assembled binary on an emulated 68000
(`tools/emu_test.py`). Several defects below were found by the assembler or the emulator and
were **not** visible to the repository's own validator, which encoded some of the same wrong
assumptions.

**Headline:** the previous revision did not assemble at all, and had it assembled it would not
have run — Copper DMA would never have been enabled and the very first Exec call would have
failed. The docs claimed the source was "validated", which was only true of the validator's
own (partly incorrect) rules.

## Severity legend

**Blocker** — does not assemble or cannot run. **High** — crash, hang, wrong hardware state or
data corruption on real hardware. **Medium** — visibly or audibly wrong. **Low** — robustness,
tooling or documentation.

## Source: does not assemble (Blocker)

| # | Where | Defect | Fix |
| --- | --- | --- | --- |
| 1 | `main.s`, `modplayer.s` | ~30 writes to data through PC-relative operands (`move.l d0,gfx_base(pc)`); PC-relative is never a legal destination, and data lives in a different hunk | Data is addressed absolutely (the hunk loader relocates it) |
| 2 | `main.s`, `modplayer.s` | `addi.l #n,aN` and `addi/andi` with an address-register or memory operand forms that do not exist (`andi.w mem,dn`) | `adda.l`, `lea`, `and.w` |
| 3 | `modplayer.s` | `AUD0VOL(a6,d7.w)`, `AUD0LCH(a6,d7.w)`: the brief extension word holds −128..127 but these offsets are 160–168 | Channel base formed with `LEA` into `a1`; registers addressed `0/4/6/8(a1)` |
| 4 | `main.s`, `modplayer.s` | Immediate counts outside 1..8: `addq.w #73`, `lsr.l #24`, `lsr.l #12` | `add.w`, `rol.l #8`, two `lsr.w` |

## Source: cannot run correctly (High)

| # | Defect | Fix |
| --- | --- | --- |
| 5 | **DMACON bit values wrong** in `hardware.i`: `DMAF_COPPER=$0400`, `DMAF_RASTER=$0200`, `DMAF_MASTER=$0100`. On hardware bit 7 is Copper, bit 8 bitplane, bit 9 master, bit 10 blitter priority. The startup write would have enabled *no* Copper DMA — a black screen | Correct values from `hardware/dmabits.h`; constants asserted by the validator |
| 6 | `OldOpenLibrary` called with the name in `a0`; it takes `a1`. (It is also obsolete: see #30.) The same error for `CloseLibrary`, `LoadView`, `FreeMem`, `TypeOfMem` (all `a1`) — the docs said the original code was "fixed" to these wrong registers | All call sites use the real conventions; documented in `hardware.i` |
| 7 | `CopyMem` had source and destination swapped (real: `a0` = source, `a1` = dest), and its vector was `-618`; the real offset is `-624` (-618 is another Exec function) | Fixed both; the emulator stub asserts the direction |
| 8 | `move.l reloc_table(pc),a4` loads the table's first **entry**, not its address, and the loop ran 9 times for 8 entries, re-basing one longword past the table | `lea reloc_table,a4`; count from `RELOC_COUNT-1` |
| 9 | Audio DMA was enabled in the startup `DMACON` write, before any channel had a sample: `AUDxLEN=0` means 65 536 words, so each channel would replay 128 KB of arbitrary memory as noise until its first note | Audio DMA is left off at start; each channel is enabled by its first note. The emulator asserts that no channel ever starts without a sample |
| 10 | `AUDxLEN` was written as *words − 1* (and docs asserted this). The register holds the length in words; every sample played one word short, and the loop register was also written minus one | Length written as-is, with a zero-length guard |
| 11 | `BeamLine` clobbered `d1`, which `WaitLines` uses as its "previous line" register, so the 2-line waits around each DMA retrigger did not wait; it also left stale bits in the upper word of `d0` | `BeamLine` reads VPOSR:VHPOSR as one long, returns only `d0` |
| 12 | `WaitFrameSync` returned immediately whenever the beam was already past the sync line, so the loop could run several times per frame (tracker faster than 50 Hz) | Leave the sync zone first, then enter it (edge detection) |
| 13 | `ADKCON` was "cleared" with `#$8000`, which is a SET write of no bits — it clears nothing | `#$7FFF` |
| 14 | A write to `DMACONR`, a read-only register | Removed |
| 15 | Scroller ran **one iteration too many** per row, shifting the last word of the row above (and, for row 0, reading outside the band), and assumed `MOVEQ` clears the X flag — it does not | Correct count; `andi #$EF,ccr` clears X explicitly |
| 16 | Stars: the byte offset (`y*40 + x/8`) was computed once for the *initial* x and never updated, so stars just flickered inside one byte instead of crossing the screen; in `InitStars` the row was also scaled wrongly (`y/8` before `*40`, placing them on lines 16–23); and `UpdateStars` drew at the old x but stored x+1, so the erase pass cleared a different pixel and left permanent trails | Row offset only is stored; `StarAddress` adds `x/8`; x is advanced *before* it is drawn so erase always hits the drawn pixel |
| 17 | Allocated chip memory was never freed on the normal exit path (leak until reboot) | `FreeMem` after the hardware is released |
| 18 | Teardown wrote BPLCON0/1/2 and the modulos back from snapshots taken while another View was active | Removed; `LoadView` + the restarted system Copper list own those registers |
| 19 | On a 262-line frame `WaitFrameSync` waited forever for line 300 with interrupts disabled — a hard lockup | The wait also ends when the beam wraps; covered by `emu_test --ntsc` |

## Source: visible or audible problems (Medium)

| # | Defect | Fix |
| --- | --- | --- |
| 20 | Per-frame work exceeded the ~25 000-cycle vertical-blank window (worst case ≈ 27 000 cycles before DMA contention), so drawing could run into the visible display (tearing) | Scroller shifts ten longwords per row instead of twenty words (≈ 22 000 cycles worst case, measured) |
| 21 | Stars were drawn in `COLOR04` = `$124` on a `$001` background — effectively invisible | `COLOR04` = `$8BF` |
| 22 | The scroller band is 16 lines high but the 8-line font was drawn only into the top 8 lines | Each font row is drawn on two lines (double height) |

## Tooling

| # | File | Defect | Fix |
| --- | --- | --- | --- |
| 23 | `tools/hunkcheck.py` | Memory-requirement bits swapped: reported a chip hunk as "fast required" (bit 30 is chip, bit 31 fast) although its own docstring said otherwise | Constants corrected; verified against the real `data_c` hunk |
| 24 | `tools/validate.py` | Enforced wrong facts: `OldOpenLibrary`/`CloseLibrary`/`LoadView`/`FreeMem`/`TypeOfMem` in `a0`, `CopyMem` dest/source order, `LVO_CopyMem=-618`, the wrong `DMAF_*` values. A validator that encodes the bug cannot find it | Corrected |
| 25 | `tools/validate.py` | Rejected legal 68000 code on false grounds: memory-to-memory `MOVE`, `ADDA.W`, `BSET Dn,<mem>` are all valid 68000 instructions | Rules removed; VASM is the authority for encodings |
| 26 | `tools/validate.py` | Missed real defects: symbolic index displacements, PC-relative destinations, `addi` to an address register, out-of-range quick immediates, writes to read-only registers. The argument scanner's look-back window also crossed the previous call, so `a1` set for `FreeMem` satisfied `CloseLibrary` | New rules; scan stops at the previous call. 32 mutants now, all caught |
| 27 | `Makefile` / repo | Stamp files (`assets/.generated`, `build/.validated`) and `__pycache__` were shipped, and `MANIFEST.sha256` was stale relative to them | `.gitignore`; manifest regenerated |
| 28 | Whole project | Nothing ran the program. All claims about runtime behaviour were untested | `tools/emu_test.py`: behavioural test on an emulated 68000, and a run in FS-UAE (see "Verified in FS-UAE") |
| 29 | `tools/bootstrap_vasm.sh` | Failed silently on networks that block HTTPS | Documented `VASM_URL` override |
| 30 | `main.s` | Found by running under FS-UAE with the AROS ROM: the obsolete `OldOpenLibrary` (LVO −408) raises a `TRAP #11` software failure in AROS before the intro starts | `OpenLibrary` (−552, name in `a1`, version 0 in `d0`) — standard since Kickstart 1.2 |
| 31 | `main.s` | **ExecBase was passed in `a5`.** The AmigaOS calling convention is that the library base is in `a6` for every call, including Exec. Original Kickstart's Exec never reads it, which hid the bug; AROS's Exec does, and every Exec call crashed (even a program that only calls `Forbid`/`Permit`) | All library calls use `a6`; `emu_test.py` asserts `a6 = base` at every call and `validate.py` rejects any other base register |
| 32 | `main.s` | **Teardown hung forever.** `Enable()` and `WaitTOF()` ran while `INTENA` still had the vertical-blank interrupt masked (the saved `INTENA` was only restored *after* the waits). `WaitTOF` sleeps until that interrupt fires. The screen went dark and the Shell never came back. This hazard exists on real Kickstart too | `ADKCON`/`INTENA`/`DMACON` are restored before `Enable`/`Permit`/`WaitTOF`; the emulator's `WaitTOF` stub now fails if the VERTB interrupt is masked |

## Documentation

The previous docs described behaviour that the code did not have and stated several incorrect
facts. All were rewritten; notably: the "(dest, source)" `CopyMem` signature, "`AUDxLEN` counts
words minus one", "memory-to-memory `MOVE` cannot be encoded on a 68000", "`ADDA.W` is 68020+",
"`BSET Dn,<mem>` is 68020+", the `DMAF_*` bit table, the claim that the defects in the "closure
pass" had been fixed, and the `(pc)`-relative-data advice in `BUILD_AND_TEST.md` (it is the
reason the source could not be assembled).

## Checked and found correct

The Copper list structure and `PatchCopper` offsets; `DIWSTRT/DIWSTOP/DDFSTRT/DDFSTOP/BPLCON0`
for 320×256 PAL lores with three planes; the GfxBase offsets (`ActiView` 34, `copinit` 38); the
other Exec/graphics LVOs; `Forbid` → `Disable` and `Enable` → `Permit` ordering; the MOD header
layout and the replay core's row/period/sample decoding; the asset generator's unsigned 8-bit
sample centring; the reproducibility of the generated assets.

## Addendum: graphics revision

The wireframe, starfield and gradient work (see `RELEASE_NOTES.md`) was built and verified with the
methods above. Its development-time findings were: `CalcMatrix` clobbered the caller's vertex pointer
(seen immediately in FS-UAE as a missing octahedron and stray marks); the blitter `ONEDOT` bit has
to be left clear for ordinary lines; the first CPU cost (about 96 000 cycles per frame) was too close
to the frame budget and was reduced to about 71 000; and the emulation harness double-counted the
frame-sync spin loop. All are fixed or explained, and each has a matching fault in `make emu-mutants`.

## Verified in FS-UAE

The final build was run in FS-UAE 3 (WinUAE core, cycle-exact) configured as an A500 (68000, OCS,
1 MiB chip + 512 KiB slow RAM, PAL) with the free **AROS** Kickstart replacement ROM (the pair
shipped in Amiberry's `roms/` directory), the executable on a mounted directory and started from
a Startup-Sequence. Observed: the logo, raster band, drifting stars and scrolling text render; the
scroller advances between frames; a left click exits; the AROS Shell prompt returns and the next
Startup-Sequence command runs. This run found defects #30–#32, none of which the stubbed emulation
test could see — stubs accept whatever they are given — which is why the test now also enforces the
register-base and interrupt-mask rules.

What that run does **not** show: audio was not listened to; the machine was AROS, not a real
Kickstart 1.3/3.x ROM; and no real hardware was used.

## Remaining risks (not code defects)

- Not run on real hardware or with a genuine Commodore Kickstart ROM. The FS-UAE run above used
  AROS. In the emulated-CPU test DMA cycle stealing is not modelled, so the CPU headroom figure is
  optimistic; the vblank window has ~13 % margin over the worst frame.
- The unsynchronised custom-register beam read is a single long access, which is correct on a
  68000 but is the kind of thing worth eyeballing on real hardware.
- No Workbench start-up message handling; start from a Shell.
