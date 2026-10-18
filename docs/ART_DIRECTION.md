# Crimson visual identity

Neon Vectors Crimson follows a classic Amiga demo vocabulary: bevelled display
lettering, disciplined 12-bit colour ramps, native pixel ornament, Copper-driven
light and a scrolling scene greeting. Artwork and lettering are generated directly from the repository’s geometry
and pixel alphabets.

## Colour roles

| Role | Treatment | Source |
| --- | --- | --- |
| Main lettering | White/cream highlights through gold into copper | `logo_art.PALETTE`, Copper face ramp |
| Identity and ornament | Rose/copper subtitle, ruby framing, dark red extrusion | Logo bitmap and palette |
| Geometry | Ice cyan, with cooler secondary blue shades | `MID_PALETTE` |
| Stars | Slate, grey-blue and near-white depth steps | Middle-band indices 4, 1 and 5 |
| Text | Cream to white to gold, over oxblood | Copper scroller band |
| Floor | Ember shadow, red/orange/amber/ruby bars and bright cores | `floor_base`, `bar_colors` |
| Sprite ring | Gold and ruby in front; cooler blues at distance | Sprite pair palettes |

A quieter midnight field gives the moving geometry priority. Bright colours are
reserved for lettering, vector lines, sprite highlights and bar cores rather than
applied to every background band.

## Pixel craft and typography

The UBER / CRACKING SERVICE mark remains the central identity. Chamfered corner
brackets and compact NEON, CRIMSON, PAL and 50HZ labels frame it without competing
with the main letters. Labels use an explicit 3x5 pixel alphabet. Every detail is
stored in the same four native bitplanes and receives the real logo ripple.

The scrolling message speaks in the language of the machine and its scene:
"COPPER FIRE AND ICE-COLD VECTORS" and greetings to coders, pixel artists and tracker
musicians. It states four channels and eight instruments accurately and ends with
the left-mouse exit instruction. Keep new copy uppercase and use supported font
characters and retain the original group attribution when editing greetings.

## Editing and review

Edit artwork in `tools/logo_art.py`, colour ramps in `tools/gen_tables.py` and text
at `scroll_text` in `src/main.s`. Regenerate assets with `make assets`. Palette and
Copper generator output must also be copied into its corresponding assembly
blocks; asset generation does not rewrite assembly source.

Review the actual machine-code render, not only `assets/logo_preview.png`: the
preview image cannot show the running Copper gradients or per-row hardware scroll.
Check logo ink bounds, label legibility, star/vector contrast, sprite priority and
the scroller strip at native scale. Run the full section cycle and asset-freshness
checks before committing a new visual revision.
