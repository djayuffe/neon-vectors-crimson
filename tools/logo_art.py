#!/usr/bin/env python3
"""Procedural 16 colour logo art for the Uber Cracking Service intro.

Pure geometry, no image libraries, fully deterministic. The word UBER is built from stroked
line and arc primitives (a distance field), then lit like an embossed metal bevel with an
extruded drop shadow. CRACKING SERVICE is chiselled from the 5x7 font, flanked by wing
ornaments. The result is a 320x64 image of colour indices 0..15, which the build stores as
four bitplanes, together with the matching palette.

Colour roles (indices):
   0 background              8 extrusion shadow
   1 outline                 9 deep shadow
   2..6 face ramp (dark..light); index 4 is recoloured per row by the Copper (gold sheen)
   7 specular highlight     10..13 steel ramp (subtitle, wings)
  14 accent (rules)         15 spark white
"""
import math

W, H = 320, 64
SS = 3                       # supersampling per axis

PALETTE = [0x001, 0x100, 0x631, 0x963, 0xFC4, 0xFE9, 0xFFC, 0xFFF,
           0x424, 0x212, 0x246, 0x468, 0x6AC, 0xADF, 0xD42, 0xFFF]

# ---- 5x7 glyphs (only the letters this logo needs) -------------------------------------------
GLYPHS = {
    ' ': ['00000'] * 7,
    'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
    'C': ['01111', '10000', '10000', '10000', '10000', '10000', '01111'],
    'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'],
    'G': ['01111', '10000', '10000', '10111', '10001', '10001', '01111'],
    'I': ['01110', '00100', '00100', '00100', '00100', '00100', '01110'],
    'K': ['10001', '10010', '10100', '11000', '10100', '10010', '10001'],
    'N': ['10001', '11001', '10101', '10011', '10001', '10001', '10001'],
    'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'],
    'S': ['01111', '10000', '10000', '01110', '00001', '00001', '11110'],
    'V': ['10001', '10001', '10001', '10001', '10001', '01010', '00100'],
}


# ---- distance field primitives -----------------------------------------------------------------
def d_seg(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def d_arc(px, py, cx, cy, r, a0, a1):
    """Distance to the circular arc from angle a0 to a1 (degrees, y down, a0 <= a1)."""
    ang = math.degrees(math.atan2(py - cy, px - cx))
    for k in (-360, 0, 360):
        if a0 <= ang + k <= a1:
            return abs(math.hypot(px - cx, py - cy) - r)
    e0 = (cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0)))
    e1 = (cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1)))
    return min(math.hypot(px - e0[0], py - e0[1]), math.hypot(px - e1[0], py - e1[1]))


LW, LH, STROKE = 30.0, 36.0, 4.6      # letter box and half stroke width


def letter(ch, ox, oy):
    """Primitives (as closures over distance) for one geometric letter with its box at (ox, oy)."""
    r = STROKE
    t, m, b = oy + r, oy + LH / 2, oy + LH - r                 # top / middle / bottom centre lines
    l, rr = ox + r, ox + LW - r
    if ch == 'U':
        cx, cy, R = (l + rr) / 2, b - (rr - l) / 2, (rr - l) / 2
        return [lambda x, y: d_seg(x, y, l, t, l, cy), lambda x, y: d_seg(x, y, rr, t, rr, cy),
                lambda x, y: d_arc(x, y, cx, cy, R, 0, 180)]
    if ch == 'E':
        return [lambda x, y: d_seg(x, y, l, t, l, b), lambda x, y: d_seg(x, y, l, t, rr, t),
                lambda x, y: d_seg(x, y, l, m, rr - 4, m), lambda x, y: d_seg(x, y, l, b, rr, b)]
    if ch == 'B':
        r1, r2 = (m - t) / 2, (b - m) / 2
        bx = rr - 2
        return [lambda x, y: d_seg(x, y, l, t, l, b), lambda x, y: d_seg(x, y, l, t, bx - r1, t),
                lambda x, y: d_arc(x, y, bx - r1, t + r1, r1, -90, 90), lambda x, y: d_seg(x, y, l, m, bx - r1, m),
                lambda x, y: d_seg(x, y, l, b, bx - r2, b), lambda x, y: d_arc(x, y, bx - r2, m + r2, r2, -90, 90)]
    if ch == 'R':
        r1 = (m - t) / 2 + 1
        bx = rr - 1
        return [lambda x, y: d_seg(x, y, l, t, l, b), lambda x, y: d_seg(x, y, l, t, bx - r1, t),
                lambda x, y: d_arc(x, y, bx - r1, t + r1, r1, -90, 90), lambda x, y: d_seg(x, y, l, t + 2 * r1, bx - r1, t + 2 * r1),
                lambda x, y: d_seg(x, y, l + 8, t + 2 * r1, rr + 1, b)]
    raise ValueError(ch)


def sample_field(prims, x, y):
    return min(p(x, y) for p in prims)


# ---- rendering -----------------------------------------------------------------------------------
def build():
    img = [[0] * W for _ in range(H)]

    # --- UBER: 4 letters, 3 px gaps -> total width 4*30 + 3*5
    gap = 5
    total = 4 * LW + 3 * gap
    x0 = (W - total) / 2
    prims = []
    for i, ch in enumerate('UBER'):
        prims += letter(ch, x0 + i * (LW + gap), 4.0)
    field = lambda x, y: sample_field(prims, x, y)

    def inside_depth(x, y):
        return STROKE - field(x, y)          # > 0 inside the stroke, deepest on the centre line

    light = (-0.62, -0.78)                   # light from the top left
    BEV = 3.3
    for y in range(H):
        for x in range(W):
            if not (x0 - 8 <= x <= x0 + total + 8 and 0 <= y <= 46):
                continue
            # coverage by supersampling
            cov = 0
            for sy in range(SS):
                for sx in range(SS):
                    if inside_depth(x + (sx + .5) / SS, y + (sy + .5) / SS) > 0:
                        cov += 1
            cov /= SS * SS
            if cov > 0.5:
                d = inside_depth(x + .5, y + .5)
                e = 0.7
                gx = (min(d, BEV) - min(inside_depth(x + .5 - e, y + .5), BEV)) - (min(inside_depth(x + .5 + e, y + .5), BEV) - min(d, BEV))
                # gradient of the clamped height field (central difference), then Lambert-style shading
                hx = (min(inside_depth(x + .5 + e, y + .5), BEV) - min(inside_depth(x + .5 - e, y + .5), BEV)) / (2 * e)
                hy = (min(inside_depth(x + .5, y + .5 + e), BEV) - min(inside_depth(x + .5, y + .5 - e), BEV)) / (2 * e)
                lum = 0.5 - 0.5 * (hx * light[0] + hy * light[1]) / 0.6    # 0 dark .. 1 bright on the bevel
                if d < 0.9:
                    idx = 1                                              # outline
                elif d >= BEV - 0.2:
                    idx = 4                                              # flat face (Copper gradient colour)
                else:
                    k = max(0.0, min(1.0, lum))
                    idx = 2 if k < 0.25 else 3 if k < 0.45 else 5 if k < 0.7 else 6 if k < 0.9 else 7
                img[y][x] = idx
    # extrusion: two shadow copies behind, offset down-right, drawn only where nothing else is
    for off, col in ((4, 9), (2, 8)):
        for y in range(H - 1, -1, -1):
            for x in range(W - 1, -1, -1):
                if img[y][x] in (0, 8, 9) and 0 <= y - off and 0 <= x - off and img[y - off][x - off] in (1, 2, 3, 4, 5, 6, 7):
                    if img[y][x] == 0 or col == 8:
                        img[y][x] = col

    # --- CRACKING SERVICE: chiselled 2x font with a drop shadow
    text = 'CRACKING SERVICE'
    sc = 2
    tw = len(text) * 6 * sc - sc
    tx0, ty0 = (W - tw) // 2, 46
    mask = set()
    for i, ch in enumerate(text):
        g = GLYPHS[ch]
        for gy in range(7):
            for gx in range(5):
                if g[gy][gx] == '1':
                    for yy in range(sc):
                        for xx in range(sc):
                            mask.add((tx0 + i * 6 * sc + gx * sc + xx, ty0 + gy * sc + yy))
    for (x, y) in mask:                                        # shadow first
        for dx, dy in ((1, 1), (2, 2)):
            if (x + dx, y + dy) not in mask and 0 <= x + dx < W and 0 <= y + dy < H and img[y + dy][x + dx] == 0:
                img[y + dy][x + dx] = 9
    for (x, y) in mask:
        up = (x, y - 1) in mask
        left = (x - 1, y) in mask
        down = (x, y + 1) in mask
        right = (x + 1, y) in mask
        if not up or not left:
            idx = 13                                          # lit edge
        elif not down or not right:
            idx = 10                                          # shaded edge
        else:
            idx = 12 if (y - ty0) < 7 else 11                 # two-tone face
        img[y][x] = idx

    # --- wing ornaments: stacked slanted bars, tapering towards the logo
    for side in (-1, 1):
        for k, (length, col) in enumerate(((66, 11), (58, 12), (48, 13), (38, 12), (28, 11))):
            yb = 12 + k * 7
            xs = 14 if side < 0 else W - 15 - length
            for yy in range(4):
                for xx in range(length):
                    xp = xs + xx
                    # slanted ends
                    cut = (3 - yy) if side < 0 else yy
                    if xx < cut or xx >= length - (3 - cut):
                        continue
                    if 0 <= yb + yy < H and img[yb + yy][xp] == 0:
                        img[yb + yy][xp] = (col if yy not in (0,) else 13) if yy < 3 else 10
    # --- frame rules and spark pixels
    for x in range(20, W - 20):
        img[1][x] = 14
        img[62][x] = 14
        if img[2][x] == 0:
            img[2][x] = 9
    for (sx, sy) in ((int(x0) - 3, 12), (int(x0 + total) + 2, 30), (W // 2 + 10, 4)):
        for dx, dy in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
            if 0 <= sx + dx < W and 0 <= sy + dy < H:
                img[sy + dy][sx + dx] = 15
    return img


def to_planes(img):
    """img[y][x] colour indices -> four bitplanes (bytes, 40 bytes per row, MSB first)."""
    planes = []
    for p in range(4):
        out = bytearray()
        for y in range(H):
            for xb in range(0, W, 8):
                b = 0
                for bit in range(8):
                    b |= ((img[y][xb + bit] >> p) & 1) << (7 - bit)
                out.append(b)
        planes.append(bytes(out))
    return planes


def preview_rgb(img, scale=3):
    rows = []
    for y in range(H):
        row = bytearray()
        for x in range(W):
            c = PALETTE[img[y][x]]
            row += bytes([((c >> 8) & 15) * 17, ((c >> 4) & 15) * 17, (c & 15) * 17]) * scale
        rows += [bytes(row)] * scale
    return rows


if __name__ == '__main__':
    import struct, sys, zlib
    img = build()
    rows = preview_rgb(img)
    raw = b''.join(b'\0' + bytes(r) for r in rows)
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W * 3, H * 3, 8, 2, 0, 0, 0)) + \
          chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
    open(sys.argv[1] if len(sys.argv) > 1 else 'logo_art_preview.png', 'wb').write(png)
