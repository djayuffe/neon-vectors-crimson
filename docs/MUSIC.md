# Music / Paula

`assets/neon.mod` is a deterministic four-channel, 31-instrument `M.K.` ProTracker module with
four patterns, produced by `tools/generate_assets.py`.

Channels: square bass, sine-like lead/arpeggio, descending synthesised kick, and a fixed-seed
noise hi-hat. The arrangement cycles A-minor-centred Am–F–C–G. The tonal samples loop the whole
sample; the percussion declares the traditional minimal loop (length 1) and the player converts that
post-trigger state into a dedicated silence word in chip RAM, so one-shot drums end silently
instead of repeating sample bytes.

All sample data is **unsigned and centred on 128**: Paula plays 8-bit samples as unsigned
bytes. Signed data masked with `&255` would sit near full scale and click at every loop point.
The hi-hat decays exponentially. The validator asserts both properties.

## Timing

At PAL 50 Hz and ProTracker BPM 125 one vertical blank is one tracker tick; speed 6 gives six
ticks per row. The first row sets `F06` explicitly. `tools/emu_test.py` verifies that rows start
on ticks that are multiples of six frames apart.

## Retrigger sequence

For every row, for each channel that has a sample and a period:

1. Set the channel's volume (sample default, or `Cxx`).
2. Clear that channel's DMACON bit, then write location, **length in words**, and period.
   (`AUDxLEN` is the word count, not count − 1; 0 would mean 65 536 words, so a zero-length
   sample is written as 1.)
3. Cache the loop location/length — or, for a one-shot, the silence word with length 1.

When all channels have been prepared, two raster lines are waited, the triggered channels are
re-enabled in one DMACON write (Paula latches location and length at that moment), two more
lines are waited, and then the cached loop/terminal location and length are written for the
next pass.

Audio DMA is enabled only by this sequence — never at startup — so no channel runs without a
valid sample.

The channel registers are addressed through `a1 = CUSTOM + AUD0LCH + channel*16` and the offsets
`0/4/6/8(a1)` (location, length, period, volume): the register numbers themselves are too large for
the 8-bit displacement of an indexed addressing mode.

## Supported semantics

Notes with sample and period, sample default volume, `Cxx` (volume) and `F01..F1F` (speed).
The validator refuses modules using any other effect, including BPM-mode `F20` and above, rather
than playing them wrongly.

The emulation test checks, for every trigger, the channel, sample start inside the module, length,
period and volume against the module data, and the loop/terminal registers loaded afterwards.
