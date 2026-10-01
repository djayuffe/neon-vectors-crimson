#!/usr/bin/env python3
"""Gouraud-shaded 3D solid object rendering for AGA version.

Generates vertex lighting values for flat-shaded 3D objects. A cube and sphere
are lit from a fixed direction; each face gets a base colour that's shaded
based on its normal's dot product with the light direction. The result is
written as a lookup table (vertex -> shading level 0-7) that the 68k code
uses to pick the final colour for each face.

The generated tables are pasted into src/main.s and used by DrawSolid.
"""
import math

LIGHT = (-0.5, -0.7, 0.5)  # light direction, normalized
n = math.sqrt(sum(c * c for c in LIGHT))
LIGHT = tuple(c / n for c in LIGHT)

def vertex_shade(nx, ny, nz):
    """Face normal -> shading level 0 (dark) to 7 (bright) based on lighting."""
    lam = max(0, nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2])  # clamped dot product
    return int(round(lam * 7))  # 0..7

def cube_faces():
    """Cube: 6 faces, each with a normal and 4 vertices.
    Returns list of (face_normal, vertex_shades) tuples.
    """
    faces = [
        ((1, 0, 0), [vertex_shade(1, 0, 0)] * 4),    # right
        ((-1, 0, 0), [vertex_shade(-1, 0, 0)] * 4),  # left
        ((0, 1, 0), [vertex_shade(0, 1, 0)] * 4),    # top
        ((0, -1, 0), [vertex_shade(0, -1, 0)] * 4),  # bottom
        ((0, 0, 1), [vertex_shade(0, 0, 1)] * 4),    # front
        ((0, 0, -1), [vertex_shade(0, 0, -1)] * 4),  # back
    ]
    return faces

def sphere_shades(rings=8, segments=8):
    """Sphere: generate shading for a regular grid of vertices.
    Returns list of shading values 0..7 per vertex.
    """
    shades = []
    for r in range(rings):
        lat = math.pi * r / (rings - 1)  # latitude: 0 (north) to pi (south)
        for s in range(segments):
            lon = 2 * math.pi * s / segments  # longitude: 0 to 2pi
            nx = math.sin(lat) * math.cos(lon)
            ny = math.cos(lat)
            nz = math.sin(lat) * math.sin(lon)
            shades.append(vertex_shade(nx, ny, nz))
    return shades

if __name__ == '__main__':
    print("; Gouraud shading tables (tools/gouraud.py)")
    print("; Cube faces: 6 * 4 vertices, shading 0..7 per vertex")
    cube = cube_faces()
    for i, (normal, shades) in enumerate(cube):
        print(f"cube_shades_{i}:  dc.b " + ",".join(str(s) for s in shades))

    print("\n; Sphere: 8 rings x 8 segments = 64 vertices, shading 0..7")
    sphere = sphere_shades(8, 8)
    for i in range(0, len(sphere), 16):
        print("        dc.b " + ",".join(str(sphere[j]) for j in range(i, min(i+16, len(sphere)))))
