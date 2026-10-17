# AGA experiments: status and limits

The shipped demo displays **four bitplanes / 16 colours** using OCS/ECS registers.
It does not implement a 64-colour AGA renderer, filled Gouraud objects, plasma or
glow compositing. Earlier descriptions of these as completed features were incorrect.

`tools/effects_aga.py`, `tools/gouraud.py` and `gen_tables.aga_palette()` are host-side
prototypes. They are not imported by the asset generator or linked into the demo.
The lighting helper computes Lambert light levels; it does not rasterize polygons
or perform Gouraud interpolation. Its CLI keeps its historical filename for users.

A future AGA implementation needs explicit feature detection, palette-bank handling,
separate display buffers, DMA-budget measurements and a renderer with independent
pixel references. Simply changing `BPLCON0` to six planes is insufficient: on OCS/ECS,
six ordinary planes select extra-half-bright colours, rather than 64 independent
palette entries. Extra planes also consume DMA bandwidth.

See the [Commodore AA chipset documentation](https://shanson.com/spencer/Amiga-AA-Chipset.pdf)
and [implementation plan](plan_aga.md) before extending the hardware path.
