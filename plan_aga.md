# AGA Version Plan: NEON VECTORS Enhanced

## Display Enhancements
- **Bitplanes**: 6 planes (64 colors) instead of 4
- **Resolution**: Stay at 320×256 PAL but with richer colors
- **Palette**: 64 unique colors with smooth gradients

## 3D & Graphics Improvements
1. **Solid 3D Objects** (using blitter area fill)
   - Cube with Gouraud shading (face colors based on lighting)
   - Octahedron with per-face shading
   - Sphere or torus with smooth lighting

2. **Enhanced Sprite Ring**
   - Larger balls (24-32px) with better shading
   - Trail/glow effects behind balls
   - More balls (12-16 instead of 8)

3. **Background Effects**
   - Animated gradient/plasma field
   - Parallax scrolling layers
   - Animated starfield in background

4. **Particle Effects**
   - Sparkles or trailing effects
   - Energy waves
   - Color-cycling animations

## New Visual Layers
- Logo: 64-color version with better gradients
- Wireframe: 3D solid objects with Gouraud shading
- Sprites: Enhanced ball ring with trails
- Background: Parallax/animated effects
- Scroller: Enhanced text effects

## Performance Budget
- AGA modes are same cycle cost as OCS/ECS
- Extra bitplanes add modest DMA
- Blitter area-fill for solid objects instead of line drawing
- More complex Copper list for per-scanline effects

## Implementation Order
1. Update display to 6 bitplanes
2. Regenerate logo with 64 colors
3. Add Gouraud-shaded 3D objects
4. Enhance sprite effects
5. Add background animation
6. Update Copper for new palettes/effects
