# Build and release checks

## Host checks

```sh
make -j4                   # assets, validation, assembly, Hunk structure
make test                  # host regressions, including malformed inputs
make mutants               # static validator self-test
make verify-repro          # deterministic generation and shipped-asset freshness
python3 tools/make_manifest.py --check
```

Python 3.8+ and Make are required. VASM may come from PATH, `tools/bin/vasmm68k_mot`,
or `VASM=/absolute/path`. The bootstrap accepts an existing `VASM_SRC` tree and
never deletes it. Build flags restrict output to classic 68000/Kickstart hunks.

`make assets` forces regeneration. Ordinary builds fingerprint both generator files by content and track
all asset files, including missing assets. Validation runs before assembly; a
changed asset is checked before assembly. This small executable is validated and
assembled on every build so edits sharing a coarse filesystem timestamp cannot
reuse an unchecked binary. `make release` verifies the reviewed manifest, then runs clean, build, host
regressions, static mutations and reproducibility in order, including when invoked with `-j`.

## Machine-code checks

Install the optional Musashi binding with `python3 -m pip install machine68k`.

```sh
python3 tools/emu_test.py --frames 3200 --snap 1850  # all scenes and full song loop
python3 tools/emu_test.py --loader-chip             # loader places DMA hunk in chip RAM
python3 tools/emu_test.py --open-fail               # graphics.library unavailable
python3 tools/emu_test.py --alloc-fail              # AllocMem returns NULL
python3 tools/emu_test.py --alloc-fast              # reject non-chip allocation; exit 20
python3 tools/emu_test.py --ntsc --frames 100        # PAL wait must not hang on NTSC
python3 tools/emu_test.py --png docs/screenshot.png  # refresh rendered preview
make emu-mutants                                    # slow; baseline must pass first
```

Each mutation runs in an isolated temporary checkout. A failure is accepted only
when the harness emits the expected diagnostic; an unrelated Python crash is not
evidence that the injected fault was detected.

Current audit results and remaining acceptance limits are recorded in
[AUDIT.md](AUDIT.md). Timing printed by the harness counts CPU instructions and
omits DMA stealing and blitter duration. It is not a cycle-exact performance proof.

## Hardware/emulator acceptance

Use a PAL A500-class 68000/OCS or ECS configuration with enough free chip RAM.
Supply a legal ROM or an appropriate replacement ROM. Start `neon_vectors` from
a Shell, then check:

- Logo scroll, gradients, stars and text are stable and unclipped, including the
  extra fetch word at the left edge and Copper waits after display line 255.
- All eight sections play and repeat after about 41 seconds. Object edges remain
  solid and the sprite ring respects depth priority.
- All eight instruments sound intentional; drums retrigger and end without a
  sustained buzz. Listen across the full 61.44-second song loop.
- No tearing appears under cycle-exact DMA contention, especially in the stars.
- Left click restores the prior display and Shell. Repeated runs return memory
  (`avail`) and leave the system usable.

Genuine Kickstart and physical PAL OCS/ECS acceptance remain to be performed for
this revision. Historical FS-UAE observations are not fresh validation of changed
audio or beam timing. NTSC support and the proposed AGA renderer are not release
features.

## Distribution candidate

After reviewing changes, run `make manifest`, commit them, and run `make dist`.
Distribution requires `machine68k`: the gate executes 6,400 frames to cover the
full music/scene schedule alignment, then the chip-loader scenario and NTSC escape
check before packaging.
Release checks fail on a stale manifest rather than rewriting it. Packaging requires
a clean committed checkout and produces `build/neon_vectors_crimson.zip` with the
executable, Amiga Shell instructions, full source revision and payload checksums.
Fixed ZIP metadata makes repeated packaging of the same inputs byte-identical.
The executable entry has executable permissions; no ROMs or toolchain are included.

`make dist` is a packaging gate, not physical-machine certification. Complete the
hardware and listening acceptance checks before publishing a final hardware release.

## Record and run a preview

`make preview` builds the demo, runs 1,450 emulated frames and captures frames
1,000–1,399 at their nominal PAL rate. FFmpeg encodes `build/demo-preview.mp4`
(640×512, 50 fps, eight seconds, silent). Install `machine68k` and FFmpeg first.
`build/preview-frames` holds the source PNG sequence and can be removed after
encoding. The 400-frame limit prevents stale extra PNGs extending the clip.

For a longer acceptance run with the same preview:

```sh
python3 tools/emu_test.py --frames 6400 --snap 4490 --record-dir build/preview-frames
ffmpeg -y -framerate 50 -i build/preview-frames/frame-%04d.png -frames:v 400 -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart build/demo-preview.mp4
```

`--record-start` and `--record-count` select another consecutive window. The
window must fit inside the run and start at frame three or later. Captures do
not alter emulated CPU timing. These visual models do not replace DMA/blitter
or genuine Kickstart acceptance in a full Amiga emulator or physical machine.

## Audition tracker edits

`make music-preview` renders the current generated module to
`build/music_preview.wav` using `openmpt123`. Output is staged in a temporary
folder and replaces the previous WAV only after a successful render and format
check. The command reports duration, peak level and clipped samples. Rendering
uses the host libopenmpt mixer rather than emulated Paula audio.

Edit the explicit note/volume arrangement in `tools/generate_assets.py`, then run
`make assets all test verify-repro` and `make music-preview`. The replay harness
also checks sample-less `Cxx` volume envelopes and rests on every emulated frame.
