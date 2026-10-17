#!/usr/bin/env python3
"""AGA visual effects generator: parallax background, glow effects, plasma."""
import math

def starfield_background(w, h, density=0.02):
    """Generate a starfield background with parallax depth.
    Returns list of (x, y, depth_class) tuples.
    """
    import random
    if w <= 0 or h <= 0 or not 0 <= density <= 1:
        raise ValueError("positive dimensions and density in [0, 1] required")
    rng = random.Random(42)
    stars = []
    num_stars = int(w * h * density)
    for _ in range(num_stars):
        x = rng.randint(0, w - 1)
        y = rng.randint(0, h - 1)
        depth = rng.choice([0, 1, 2])  # 0=far (dim), 1=mid, 2=near (bright)
        stars.append((x, y, depth))
    return stars

def plasma_effect(w, h, time_offset=0):
    """Generate a simple plasma-like effect using Perlin-style sine waves.
    Returns grid of colour indices 0..3 (for palette).
    """
    if w <= 0 or h <= 0:
        raise ValueError("positive dimensions required")
    grid = []
    for y in range(h):
        row = []
        for x in range(w):
            # Combine multiple sine waves at different scales
            v = math.sin((x + time_offset) * 0.05) * 0.5
            v += math.sin((y + time_offset) * 0.04) * 0.3
            v += math.sin((x + y + time_offset * 0.7) * 0.02) * 0.2
            col = int((v + 1) * 1.5) % 4  # 0..3
            row.append(col)
        grid.append(row)
    return grid

def glow_sphere(x, y, radius, intensity=1.0):
    """Generate a radial glow at (x, y) with falloff.
    Returns list of (dx, dy, glow_value) for pixels within radius.
    """
    if radius < 0 or not 0 <= intensity <= 1:
        raise ValueError("nonnegative radius and intensity in [0, 1] required")
    if radius == 0:
        return [(x, y, int(7 * intensity))] if intensity >= 1/7 else []
    glow = []
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            d_sq = dx * dx + dy * dy
            if d_sq <= radius * radius:
                d = math.sqrt(d_sq)
                # Quadratic falloff
                g = max(0, 1 - (d / radius) ** 2)
                val = int(g * 7 * intensity)
                if val > 0:
                    glow.append((x + dx, y + dy, val))
    return glow

def color_cycle_palette(base_pal, cycles=16):
    """Generate palette cycling data for animation.
    Shifts colors smoothly through the palette over time.
    """
    if not base_pal or cycles < 1:
        raise ValueError("nonempty palette and positive cycles required")
    cycles_data = []
    for c in range(cycles):
        offset = c * len(base_pal) // cycles
        shifted = base_pal[offset:] + base_pal[:offset]
        cycles_data.append(shifted)
    return cycles_data

if __name__ == '__main__':
    print("; AGA Effects Tables (tools/effects_aga.py)")
    print(f"; Starfield: {len(starfield_background(320, 256))} stars with depth")
    print("; Plasma: procedurally generated each frame")
    print("; Glow effects: vertex-based radial bloom")
