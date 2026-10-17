# Music and Paula

`assets/neon.mod` is a deterministic four-channel, 31-slot `M.K.` module. Seven
slots are populated: saw bass, pulse lead, kick, snare, closed hat, open hat and pad.
Five patterns follow order `0,1,2,1,3,2,4,4`, built around Am–F–C–G. At speed six,
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
