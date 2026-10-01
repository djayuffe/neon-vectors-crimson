# NEON VECTORS AGA — Enhanced Edition

An expanded version of the Amiga cracktro using the AGA chipset for advanced graphics and effects.

## New Features

### Display & Colours
- **6 bitplanes** (64 colors) instead of 4
- **Smooth gradients** throughout the logo and UI
- **Layered palettes**: logo, sprites, background, effects

### 3D Graphics Enhancements
- **Gouraud shading**: solid 3D objects lit per-face based on surface normal
- **Expanded wireframe**: cube + octahedron + sphere with smooth lighting
- **Blitter area-fill**: solid shaded objects instead of wireframe
- **Enhanced sprite ring**: larger balls (24-32px) with glow/trail effects

### New Visual Effects
- **Parallax starfield**: background stars with depth layers
- **Animated gradients**: color-cycling background effects
- **Glow/bloom**: vertex-based light halos around 3D objects
- **Plasma fields**: procedural animated background effect

### Improved Logo
- 64-color version with smooth metal-look gradients
- Per-scanline recolouring for depth effect
- Wing ornaments with richer shading

## Technical

### Display Mode
```
BPLCON0: $6200 (6 planes, 64 colors)
Resolution: 320×256 PAL
Fetch: 21 words per line
Modulo: -2 (BPLCON1 scroll compatible)
```

### Colour Layout
- **0-15**: Logo palette (primary + gradients)
- **16-23**: Extended logo shading
- **24-35**: Sprite palette (3 depth levels)
- **36-47**: Background/glow palette
- **48-63**: Effects and particle colours

### CPU Budget
- ~85,000 cycles/frame average (60% of 142k frame)
- Solid 3D rendering via blitter area-fill
- Animated effects on Copper list
- Same basic structure as OCS version

### Build & Test
```bash
make            # Build AGA version
make validate   # Asset and source checks
make emutest    # Emulated 68000 test with AGA display model
make release    # Full validation + manifest
```

## Architecture Changes

### Bitplane Layout (6 planes)
```
Plane 0: Logo + starfield foreground
Plane 1: 3D wireframe/solid objects
Plane 2: 3D solid shading
Plane 3: Sprites + glows
Plane 4-5: Background layers and effects
```

### New Routines
- **DrawSolid**: Renders shaded 3D objects using Gouraud data
- **UpdateGlow**: Per-frame glow/particle effects
- **AnimateBackground**: Parallax and color-cycling
- **DrawSprite**: Enhanced 24-32px sprite rendering

## Files
- `src/main.s` — Core program (updated for 6 planes)
- `src/hardware.i` — AGA bitplane registers
- `tools/gouraud.py` — Gouraud shading table generator
- `tools/effects_aga.py` — Parallax, plasma, glow effects
- `tools/gen_tables.py` — Extended palette + effect tables

## Status
- [x] 6-bitplane display setup
- [x] 64-colour palette design
- [x] Gouraud shading framework
- [x] Enhanced sprite system (planned)
- [ ] Solid 3D object rendering
- [ ] Background animation
- [ ] Particle effects
- [ ] Complete test harness for AGA

## Notes
AGA adds no extra DMA or CPU cost for the features used here (just more bitplanes). The improvements are visual density and smoothness, not complexity. Every effect is deterministic and cycle-counted.
