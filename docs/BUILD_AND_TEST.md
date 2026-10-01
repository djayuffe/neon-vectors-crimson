# Build and test matrix

## What is verified

| Check | Command | Status |
| --- | --- | --- |
| Asset semantics + 68000 source rules | `make validate` | passes |
| Asset determinism | `make verify-repro` | passes |
| Validator self-test | `make mutants` | 33/33 injected faults caught |
| 68000 assembly | `make` | assembles with VASM 2.0f, no errors |
| Hunk executable structure | `make` (`hunkcheck.py`) | valid; 3 hunks (code, data, chip data) |
| Behaviour on an emulated 68000 | `make emutest` | passes (PAL, `--loader-chip`, `--alloc-fast`, `--ntsc`) |
| Emulation-test self-test | `make emu-mutants` | 25/25 injected faults caught, after an unmodified baseline run passes |
| Cycle-exact emulator | FS-UAE, A500 config, AROS ROM | runs, animates, exits cleanly; audio not audited by ear |
| Genuine Kickstart ROM | FS-UAE / WinUAE / Amiberry | **not run** |
| Real PAL OCS/ECS machine | — | **not run** |

## Host-side

```sh
make            # assets -> validate -> assemble -> hunk check
make mutants
make emutest    # needs: pip install machine68k
make emu-mutants  # slow: one emulated run per injected fault
make release    # clean, build, reproducibility, manifest
```

`make` needs `vasmm68k_mot` on `PATH`, in `tools/bin/` (`make toolchain`), or via `VASM=`.
`-kick1hunks` emits classic Kickstart-compatible hunks (no 16-bit relocations; 32-bit PC-relative
relocations are rejected), which is why all data is addressed absolutely rather than with `(pc)`.

The emulation test additionally runs:

```sh
python3 tools/emu_test.py --frames 1700 --snap 1500   # a full song loop
python3 tools/emu_test.py --alloc-fast                 # chip allocation fails: must exit 20, leak nothing
python3 tools/emu_test.py --loader-chip                # loader honours the chip flag
python3 tools/emu_test.py --ntsc --frames 100          # 262-line frame: must not hang
python3 tools/emu_test.py --png docs/screenshot.png    # refresh the README image
```

## Emulator acceptance checklist (still to do)

Use an A500-class PAL configuration: 68000, OCS or ECS, 512 KiB+ chip RAM, **cycle-exact**
chipset emulation. Start from a Shell and run `neon_vectors`, then confirm:

- [ ] logo is stable and unclipped; raster band animates without Copper corruption
- [ ] the starfield flies outward from the centre in three brightnesses; no trails or flicker; wireframe stays in front of the stars
- [ ] scroller moves left smoothly and inserts clean columns; text wraps at the end
- [ ] all four channels audible; drums retrigger; no persistent buzz after a one-shot; no noise burst at start
- [ ] the wireframe cube and octahedron rotate and sway smoothly with no half-drawn frames; all edges solid
- [ ] the logo ripples smoothly with no torn or jumping rows; the four floor bars glide without flicker
- [ ] no visible tearing in the starfield or scroller (per-frame work ≈ 77 k cycles average, 84 k worst, of ≈ 142 k)
- [ ] the screen edges are clean: the extra fetch word must not show a stripe at the left edge
- [ ] left mouse button exits; the previous display returns; the system keeps running
- [ ] run it repeatedly: memory is returned each time (check `avail`)

For a physical-machine release also run on a real PAL OCS/ECS Amiga (A500/A600/A1200).

## Scope

This is a PAL cracktro, not a universal PAL/NTSC application and not a general ProTracker replay
library. `vamos` is not a valid runtime test for it: it does not emulate the custom chips.
