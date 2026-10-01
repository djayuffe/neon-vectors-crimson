# Release notes

## Effects revision

- **Wavy logo:** each logo row has its own `BPLCON1` scroll move in the Copper list, rewritten every
  frame from a sine table. Hardware scroll needs one extra fetch word per line, so the display now uses
  `DDFSTRT` $30, planes that start two bytes early and a modulo of −2.
- **Copper bars:** four raster bars (magenta, cyan, gold, green) glide at different speeds in the
  floor below the scroller; the floor rows are repainted every frame.
- **Gradients per row:** the logo colours now change on every row instead of every second row.
- **Motion path:** the wireframe sways ±64 pixels left and right and breathes in and out as it rotates.
- **Logic:** the music tick now runs after the time-critical drawing, the wave uses a lookup table
  instead of a multiply per row, and the starfield was trimmed to 56 stars, so every single-buffered
  part still finishes before the beam reaches it (margins: logo rows ~19 000 cycles, stars ~18 000,
  scroller ~64 000) with the worst frame at 59 % of the CPU budget.
- **Validator:** a Copper MOVE of `$FFFE` (the new `BPLxMOD`) is no longer mistaken for a WAIT, and
  MOVEs must target a custom register.
- **Tests:** the emulation harness's display model now covers the fetch window, modulo and per-row
  `BPLCON1`; new reference checks cover the wave rows, the displayed logo, the bar rows and the
  wireframe motion path; and the new deadline for the wave/bar rows. `make emu-mutants` grew from
  14 to 19 faults (all caught); `make mutants` stays 33/33.

Status: host checks, both mutation self-tests and the emulated-CPU test pass, and the program runs and
exits cleanly in FS-UAE (A500, AROS ROM) with the new effects visible. Not verified with a genuine
Kickstart ROM or on real hardware.

## Graphics revision — UBER CRACKING SERVICE

- **Branding:** the logo is now `UBER` over `CRACKING SERVICE`, and the scroller opens with
  "UBER CRACKING SERVICE PRESENTS: NEON VECTORS".
- **3D starfield:** 64 perspective-projected stars flying out of the screen, in three depth
  brightnesses built from the free bitplane combinations; a reciprocal table replaces the divisions.
- **3D wireframe:** a cube and a counter-rotating octahedron (24 edges), rotated with 7-bit matrices,
  perspective-projected, and drawn with the **blitter in line mode** into a **double-buffered**
  bitplane (the Copper's plane 1 pointer flips every frame), so a half-drawn frame is never shown.
- **Proper graphics:** Copper gradients through the logo, the background, the middle band and the
  scroller strip; a floor of colour bars (the Copper wraps below line 255); the scroller strip is
  framed. `COLOR01` changes per band, so one bitplane serves as logo text, star and scroller.
- **Tests:** `emu_test.py` gained a blitter model (line mode and rectangle clear), Copper wrap
  handling, exact reference models for the starfield and wireframe math, a CPU-budget check, the
  single-buffer deadline checks, and a per-frame check of the displayed wireframe buffer.
  `make emu-mutants` (new) injects 14 faults into the program and requires the emulation test to fail
  each time. `make mutants` stays 33/33.
- **Found while building it:** the blitter's `ONEDOT` bit must be left clear for ordinary lines
  (set, shallow lines come out with gaps); the rotation routine first clobbered the caller's vertex
  pointer (visible at once in FS-UAE as a missing octahedron); the first version of the starfield
  and wireframe needed about 96 000 cycles per frame — reciprocal tables, once-per-frame blitter
  constants and cheaper address arithmetic brought that to about 71 000; and the test harness itself
  counted the spin of the frame-sync loop as extra frames.

Status: host checks, both mutation self-tests and the emulated-CPU test pass, and the program runs
and exits cleanly in FS-UAE (A500, AROS ROM) with all the new graphics visible. Not yet verified
with a genuine Kickstart ROM or on real hardware.

## Audit revision

Full audit of the code, tooling and documentation; see [`docs/AUDIT.md`](docs/AUDIT.md) for the
complete list (32 defects).

**The program now assembles and runs.** The previous revision could not be assembled: it
contained PC-relative destinations, out-of-range indexed displacements, invalid immediates and
address-register forms of `addi`. Behind those were functional bugs that would have stopped it
working even once it assembled.

Highlights:

- Correct `DMACON` bit positions (the old values would never have enabled the Copper).
- Correct Exec/graphics.library register conventions and vector offsets (`a1` for names, libraries
  and blocks; `CopyMem` source/dest order and `-624`); library base in `a6` (AROS crashed on `a5`);
  `OpenLibrary` instead of the obsolete `OldOpenLibrary`.
- Teardown no longer hangs: the vertical-blank interrupt is re-enabled before `WaitTOF`.
- Relocation table loop and base address fixed; chip memory freed on exit.
- Audio: no noise burst at start (audio DMA was enabled with no sample), correct `AUDxLEN`, working
  2-line waits (`BeamLine` no longer clobbers `d1`).
- Frame loop synchronises once per frame (edge detection); no lock-up on a 262-line frame.
- Scroller shifts the right number of longwords, clears X explicitly, draws double-height text and
  fits the vblank window; stars actually move across the screen and leave no trails and are visible.
- `hunkcheck.py` memory flags fixed; `validate.py` corrected and extended; `mutate.py` now 32
  faults; wrong claims in the docs removed.
- New `tools/emu_test.py` and `make emutest`: the real binary is executed on an emulated 68000.
- New README, `docs/AUDIT.md`, `.gitignore`, `docs/screenshot.png`.

Status: host checks, the mutation self-test and the emulated-CPU test pass, and the program runs and
exits cleanly in FS-UAE (A500, AROS ROM). Not yet verified with a genuine Kickstart ROM or on real
hardware (checklist in `docs/BUILD_AND_TEST.md`).

## Earlier revisions

Earlier revisions (per-project history before this repository) introduced the generated assets,
the validator, the reproducibility check, the VASM bootstrap and the Hunk parser. Their changelog
entries claimed fixes that were not in the code or were wrong; those claims have been dropped.
