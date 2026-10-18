# Music and Paula

`assets/neon.mod` is a deterministic four-channel, 31-slot `M.K.` module. Eight
slots are populated: saw bass, pulse lead, kick, snare, closed hat, open hat, pad and chime.
Six patterns follow order `0,1,2,1,3,2,4,5`, built around Am–F–C–G. At speed six,
512 rows last 3,072 PAL frames (61.44 seconds), independently of the visual loop.

## Sample format

Paula consumes **signed 8-bit two’s-complement PCM**. Zero (`$00`) is silence;
`$80` represents −128. A terminal word is therefore `$0000`. Commodore’s
[AmigaMail audio article](https://amigadev.elowar.com/read/ADCD_2.1/AmigaMail_Vol2_guide/node00DF.html)
explicitly distinguishes signed sample values from an unsigned pointer declaration.

The generator converts its synthesis values into signed bytes, uses seeded local
noise generators, balances the pulse duty-cycle amplitudes and centres the saw ramp.
The validator decodes signed bytes before checking DC offset, kick continuity and
hat decay. Tonal samples loop; percussion reloads a dedicated silent chip-RAM word.
These numerical checks do not replace listening to the resulting audio.

## Timing and supported commands

At PAL 50 Hz and tracker BPM 125, one frame is one tracker tick. `F06` establishes
six ticks per row. Implemented commands are `Cxx` (volume, clamped to 64) and
`F01..F1F` (speed). Arpeggios in this tune are explicit notes rather than effect 0.
BPM changes, arpeggio effects, finetune, and period-only notes are unsupported and
rejected by the asset validator. Sample-only events set default volume but do not
start a note; use a sample and period together for every note trigger.

## DMA retrigger

For each triggered channel the player clears its DMA bit, writes sample location,
length in **words**, period and volume, and caches the loop or silence reload.
After preparing all channels it waits two raster lines, enables their DMA bits
together, waits two more lines and installs reload locations and lengths. A zero
AUDxLEN means 65,536 words, so the player always uses at least one word.

The behavioural harness compares each DMA start and reload against module data,
including `Cxx` overrides. Teardown disables audio DMA and clears volumes rather
than resuming another client’s DMA against changed sample registers.

## Arrangement and timbre revision

The bass uses six harmonics rather than a discontinuous ramp. The quarter-duty
lead is circularly smoothed without changing its period; pad notes have stronger
phrase accents. One-shot samples have short attacks and zero-ending release ramps.
A decaying two-partial chime answers phrases, while quiet off-beat lead echoes and
a distinct final pattern build the finale. All variation uses supported notes and
volume commands; the player’s effect set and six-tick timing are unchanged.

For an optional host-rendered listening preview (requires `openmpt123`):

```sh
mkdir -p build
openmpt123 --batch --no-float --end-time 61.44 -o build/music_preview.wav assets/neon.mod
```

This uses libopenmpt’s mixing and filters, rather than emulated Paula output.
Compare it with a cycle-exact Amiga run when judging the final soundtrack.

Kick, snare and chime notes also emit a visual onset cue. This uses decoded
sample-and-period events, with a short visual envelope, while retaining the
existing audio DMA trigger and reload sequence. The visual response begins on
the following display update; it uses neither an extra audio channel nor a new
interrupt handler.
