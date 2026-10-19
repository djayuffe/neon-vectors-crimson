# Music and Paula

`assets/neon.mod` is a deterministic four-channel, 31-slot `M.K.` module. Eight
slots are populated: saw bass, pulse lead, kick, snare, closed hat, open hat, pad and chime.
Eight distinct patterns follow order `0,1,2,3,4,5,6,7`, built around Am–F–C–G,
with an E7 turnaround into A minor at the end. At speed six,
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
six ticks per row. Implemented commands are `Axy` (tick volume slide), `Cxx` (volume, clamped to 64) and
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

## Arrangement and timbre

| Pattern | Role |
| --- | --- |
| 0 | Sparse bass-and-pad introduction |
| 1 | Full groove and chord arpeggios |
| 2 | Main melodic hook and final-bar snare fill |
| 3 | Reversed chord answers, bass pickups and ghost snare |
| 4 | Sparse breakdown with a graduated drum return |
| 5 | Answering lead phrase and chime responses |
| 6 | Full hook with selected quiet echo retriggers |
| 7 | Final hook, E7 dominant and an explicit silent turnaround |

The bass alternates roots, fifths and octave pickups, with row-volume envelopes
and approach notes. Lead phrases use scale tones beyond the triads. Written rests
send sample-less `C00`; otherwise a looped sample would keep sounding across the
rest. Other volume-only rows decay the existing voice without restarting its PCM.
Hat accents, ghost snares and graduated fills give the groove more variation.

The kick has a short pitched transient and exponential low-frequency sweep.
Closed hats use high-passed deterministic noise; open hats have a longer decay.
The pad adds a quiet third harmonic. Loop seams, signed PCM/DC balance and zero
one-shot endpoints retain the asset quality checks. The final row explicitly
zeros all four channel volumes before the next loop starts.

The music uses explicit notes, `A0x` decay, `Cxx` volume/cuts and `F06` speed. It needs no
additional channels, runtime synthesis, BPM changes or unsupported tracker effects.
The executable harness checks actual Paula volume words every frame, including
volume-only rows, as well as DMA starts and reloads.

For an optional host-rendered listening preview (requires `openmpt123`):

```sh
make music-preview
```

This writes `build/music_preview.wav` atomically, so repeated renders safely replace
the old preview. For another output path or duration, use
`python3 tools/render_music.py --output build/audition.wav --seconds 61.44`.
The source module is never overwritten.

This uses libopenmpt’s mixing and filters, rather than emulated Paula output.
Compare it with a cycle-exact Amiga run when judging the final soundtrack.

Kick, snare and chime notes also emit a visual onset cue. This uses decoded
sample-and-period events, with a short visual envelope, while retaining the
existing audio DMA trigger and reload sequence. The visual response begins on
the following display update; it uses neither an extra audio channel nor a new
interrupt handler.

The onset envelope drives the floor and logo separator brightness banks, while
energy links decay in opposing pairs. The separator combines the cue with a slow
128-frame scene-coloured glow; it no longer runs an independent white flash.

## Tick-level volume slides

`Axy` slides on ticks 1 through speed−1, leaving the row's first tick unchanged.
At speed six this gives five 20 ms decay steps. The upper nibble adds volume when
nonzero, taking priority over the lower nibble; otherwise the lower nibble
subtracts volume. Values clamp to 0–64. `A00` does nothing, and a new row replaces
the previous slide instead of carrying it into blank rows. These rules match the
[ProTracker 2.3D replay reference](https://raw.githubusercontent.com/8bitbubsy/pt2-clone/master/src/pt2_replayer.c).

Bass releases, pad tails and non-echo lead answers now use tick slides instead of
an immediate row-volume step. Written rests still use `C00` for a definite cut.
The player keeps four RAM volume words and four signed slide bytes, synchronized
on note defaults, `Cxx` and every slide tick. It never reads back AUDxVOL: the
[hardware register reference](https://www.amigadev.elowar.com/read/ADCD_2.1/Hardware_Manual_guide/node0060.html)
marks these registers write-only. The static validator rejects the known readback
fault, while execution checks both the RAM shadow and written Paula values.
