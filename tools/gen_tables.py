#!/usr/bin/env python3
"""Print the generated tables that are pasted into src/main.s.

    python3 tools/gen_tables.py copper   # Copper colour-gradient WAIT/MOVE lines
    python3 tools/gen_tables.py sintab   # 256-entry sine table, amplitude 127
    python3 tools/gen_tables.py recip_star | recip_wire   # reciprocal tables that replace divisions
    python3 tools/gen_tables.py floor_base | bar_colors   # copper-bar floor tables
    python3 tools/gen_tables.py wave_tab                  # BPLCON1 values of the wavy logo
    python3 tools/gen_tables.py palette                   # the logo's 16 colour palette (Copper header)
    python3 tools/gen_tables.py balls | spr_palette       # hardware sprite ball bitmaps and their colours

The output is deterministic. It is kept as a script (rather than generated at build
time) so the assembler input stays a single readable file that the validator can parse.
"""
import math, sys

def lerp(c0, c1, t):
    out = 0
    for sh in (8, 4, 0):
        a, b = (c0 >> sh) & 15, (c1 >> sh) & 15
        out |= int(round(a + (b - a) * t)) << sh
    return out

def ramp(stops, t):
    """stops: [(pos, colour)], t in 0..1"""
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if t <= p1:
            return lerp(c0, c1, 0 if p1 == p0 else (t - p0) / (p1 - p0))
    return stops[-1][1]

import logo_art
DISPLAY_TOP = 44            # first display line; screen y maps to line y + 44

FLOOR_Y0, FLOOR_H = 222, 34          # copper-bar floor: rows 222..255, one WAIT per row
NBARS = 4

def floor_base():
    """Static floor colour per row (a dark ember ramp) that the animated bars are drawn over."""
    fl = [(0.0, 0x100), (0.55, 0x211), (1.0, 0x511)]
    return [ramp(fl, i / (FLOOR_H - 1)) for i in range(FLOOR_H)]

def raster_palette():
    """32-frame ember-to-gold pulse with a continuous loop endpoint."""
    stops = [(0, 0x210), (0.45, 0xC32), (0.75, 0xFA6), (1, 0xFFF)]
    return [ramp(stops, (1-math.cos(2*math.pi*k/32))/2) for k in range(32)]


def bar_motion():
    """Precomputed bar tops, matching the 68000 fixed-point sine arithmetic."""
    return [((round(127 * math.sin(2 * math.pi * k / 256)) * 13) >> 7) + FLOOR_H // 2 - 4
            for k in range(256)]


def bar_colors():
    """NBARS bars of 8 rows each: a colour with a soft bright core (intensity 1-2-3-4-4-3-2-1 / 4)."""
    bases = [0xF22, 0xF82, 0xFD3, 0xF4A]            # red, orange, amber, hot pink
    prof = [1, 2, 3, 4, 4, 3, 2, 1]
    out = []
    for base in bases:
        for pk in prof:
            colour = lerp(0x001, base, pk / 4)
            out.append(lerp(colour, 0xFFF, 0.4 if pk == 4 else 0.12) if pk >= 3 else colour)
    return out

MID_PALETTE = [0x001, 0x89A, 0x6DF, 0x6DF, 0x456, 0xDDE, 0x6DF, 0x6DF,
               0x57B, 0x57B, 0xBDF, 0xBDF, 0x57B, 0x57B, 0xBDF, 0xBDF]
# index = plane0 + 2*plane1 + 4*plane2 + 8*plane3:
#   1 mid star | 4 far star | 5 near star | planes 1 or 3 set: object shades (1: wire / shade 1,
#   3 only: shade 2, 1 and 3: shade 3), so an object always hides the stars behind it.

def fmt_palette(pal, first=0):
    """dc.w lines that load pal[first:] into COLOR<first>.. (four MOVEs per line)."""
    out = []
    for i in range(first, 16, 4):
        out.append('        dc.w ' + ','.join('COLOR%02d,$%03X' % (i + k, pal[i + k]) for k in range(4) if i + k < 16))
    return '\n'.join(out)

def mid_palette():
    """Palette reload for the middle band (COLOR00 is left to the animated bar slot)."""
    return fmt_palette(MID_PALETTE, 1)

def header_palette():
    return fmt_palette(logo_art.PALETTE, 0)

def copper():
    ent = []                # (y, regs) ; regs None = animated slot, 'wave' = wavy logo row, 'bar' = floor row
    # Logo band, y 8..71: a 16 colour picture whose palette is in the Copper header. Every row
    # recolours the background (COLOR00) and the face colour (COLOR04: a white-to-orange metal
    # gradient) and has a BPLCON1 move that UpdateWave rewrites every frame.
    face = [(0.0, 0xFFF), (0.25, 0xFEC), (0.55, 0xFB6), (1.0, 0xC43)]
    bg = [(0.0, 0x001), (1.0, 0x211)]
    for i in range(64):
        ent.append((8 + i, [('COLOR00', ramp(bg, i / 63)), ('COLOR04', ramp(face, max(0.0, min(1.0, (i - 4) / 36)))), ('BPLCON1', 0x88)]))
    ent.append((72, None))                                   # animated raster slot, then the wave reset
    # Middle band, y 76..195: mid-distance star colour plus a soft glow behind.
    ent.append((76, [('COLOR00', 0x001), ('COLOR01', 0x89A)]))
    mid = [(0.0, 0x001), (0.5, 0x012), (1.0, 0x001)]
    for i in range(1, 15):
        ent.append((76 + 8 * i, [('COLOR00', ramp(mid, i / 14))]))
    # Scroller strip, y 197..218: frame lines, dark bar, gradient text colour.
    ent.append((196, [('COLOR00', 0x001)]))
    ent.append((197, [('COLOR00', 0xB43)]))
    ent.append((198, [('COLOR00', 0x211)]))
    sc = [(0.0, 0xFC9), (0.5, 0xFFF), (1.0, 0xD75)]
    for i in range(8):
        ent.append((200 + 2 * i, [('COLOR01', ramp(sc, i / 7))]))
    ent.append((218, [('COLOR00', 0xB43)]))
    ent.append((219, [('COLOR00', 0x001)]))
    # Copper-bar floor, y 222..255: one COLOR00 move per row; UpdateBars repaints them each frame.
    fb = floor_base()
    for i in range(FLOOR_H):
        ent.append((FLOOR_Y0 + i, ('bar', fb[i])))
    ent.sort(key=lambda e: e[0])
    lines, wrapped = [], False
    first_wave = first_bar = True
    for y, regs in ent:
        v = DISPLAY_TOP + y
        if v > 255 and not wrapped:
            lines.append('        dc.w $FFDF,$FFFE                    ; wrap: lines below are 256 + WAIT line')
            wrapped = True
        pos = ((v - 256) if wrapped else v) << 8 | 1
        if regs is None:
            lines.append('        dc.w $%04X,$FFFE                    ; y=72: animated slot, then the wave ends' % pos)
            lines.append('cop_raster_color:')
            lines.append('        dc.w COLOR00,$013                   ; animated by UpdateRaster each frame')
            lines.append('        dc.w BPLCON1,$0000')
            lines.append(mid_palette())
        elif isinstance(regs, tuple):
            if first_bar:
                lines.append('cop_bars:                                   ; 34 rows of WAIT + COLOR00, 8 bytes each (value at +6)')
                first_bar = False
            lines.append('        dc.w $%04X,$FFFE,COLOR00,$%04X' % (pos, regs[1]))
        else:
            if first_wave:
                lines.append('cop_wave:                                   ; 64 rows, 16 bytes each (BPLCON1 value at +14)')
                first_wave = False
            body = ','.join('%s,$%04X' % (r, val) for r, val in regs)
            lines.append('        dc.w $%04X,$FFFE,%s' % (pos, body))
    lines.append('        dc.w $FFFF,$FFFE')
    return '\n'.join(lines)

def wave_tab():
    # Fundamental + second harmonic: a layered ripple, safely inside 2..14 pixels.
    vals = []
    for k in range(256):
        phase = 2 * math.pi * k / 256
        v = 8 + round(4 * math.sin(phase) + 2 * math.sin(2 * phase))
        vals.append(v | (v << 4))
    return vals

# ---- hardware sprite balls --------------------------------------------------------------------
BALL_SIZES = (16, 12, 8)             # near, mid, far; each drawn centred in a 16 pixel wide sprite
SPR_PALETTE = [                      # three shades (dark, mid, bright) for each pair of sprites
    [0xA50, 0xFB3, 0xFFD],           # sprites 0,1: the nearest balls
    [0x711, 0xD43, 0xFC9],
    [0x146, 0x4AF, 0xCEF],
    [0x113, 0x35A, 0x8BE]]           # sprites 6,7: the farthest balls

def ball_lines(size):
    """size lines of (plane A word, plane B word): colour = A + 2*B, 0 transparent, shaded like a sphere
    lit from the top left (1 dark, 2 mid, 3 bright)."""
    out = []
    r = size / 2.0
    L = (-0.5, -0.6, 0.62)
    n = math.sqrt(sum(c * c for c in L))
    L = tuple(c / n for c in L)
    for y in range(size):
        a = b = 0
        for x in range(size):
            dx, dy = (x + 0.5 - r) / r, (y + 0.5 - r) / r
            d2 = dx * dx + dy * dy
            col = 0
            if d2 <= 1.0:
                nz = math.sqrt(1 - d2)
                lam = max(0.0, dx * L[0] + dy * L[1] + nz * L[2])
                col = 3 if lam > 0.78 else 2 if lam > 0.38 else 1
            bit = 15 - (x + (16 - size) // 2)
            a |= (col & 1) << bit
            b |= (col >> 1) << bit
        out.append((a, b))
    return out

def balls():
    vals = []
    for sz in BALL_SIZES:
        for a, b in ball_lines(sz):
            vals += [a, b]
    return vals

RING_R = 70
def ring_tab():
    """256 entries of (x0, z0) = (RING_R * cos, RING_R * sin) >> 7 for the ball ring."""
    vals = []
    for k in range(256):
        c = int(round(127 * math.sin(2 * math.pi * ((k + 64) & 255) / 256)))
        sn = int(round(127 * math.sin(2 * math.pi * k / 256)))
        vals += [(RING_R * c) >> 7, (RING_R * sn) >> 7]
    return vals

def spr_palette_regs():
    regs = []
    for pair, cols in enumerate(SPR_PALETTE):
        for c, v in enumerate(cols):
            regs.append((16 + 4 * pair + 1 + c, v))
    return regs

def spr_palette():
    regs = spr_palette_regs()
    out = []
    for i in range(0, len(regs), 4):
        out.append('        dc.w ' + ','.join('COLOR%02d,$%03X' % r for r in regs[i:i + 4]))
    return '\n'.join(out)

def words(vals, per=16):
    return '\n'.join('        dc.w ' + ','.join('$%03X' % v for v in vals[i:i + per]) for i in range(0, len(vals), per))

def recip_star():
    # 256 entries: round(PROJ_F * 256 / z) for z = 32..255 (z below 32 never occurs).
    vals = [0] * 32 + [int(round(128 * 256 / z)) for z in range(32, 256)]
    return '\n'.join('        dc.w ' + ','.join('%d' % v for v in vals[i:i + 16]) for i in range(0, 256, 16))

def recip_wire():
    # 416 entries: round(WIRE_D * 256 / zc) for zc = 150..415 (the distance stays about 227..373).
    vals = [0] * 150 + [int(round(220 * 256 / z)) for z in range(150, 416)]
    return '\n'.join('        dc.w ' + ','.join('%d' % v for v in vals[i:i + 16]) for i in range(0, 416, 16))

def sintab():
    vals = [int(round(127 * math.sin(2 * math.pi * k / 256))) for k in range(256)]
    return '\n'.join('        dc.w ' + ','.join('%d' % v for v in vals[i:i + 16]) for i in range(0, 256, 16))



# ---- 64-colour AGA palette ----
def aga_palette():
    """64 colours: logo (0-15), logo alt (16-23), sprites (24-35), background (36-47), effects (48-63)."""
    pal = [0x001] * 64
    # Logo palette: expanded 16-colour (0-15) + smooth transitions (16-23)
    logo_base = [0x001, 0x100, 0x631, 0x963, 0xFC4, 0xFE9, 0xFFC, 0xFFF,
                 0x424, 0x212, 0x246, 0x468, 0x6AC, 0xADF, 0xD42, 0xFFF]
    pal[0:16] = logo_base
    # Extra gradients for smooth shading
    pal[16:24] = [0x975, 0xA86, 0xB97, 0xCA8, 0xDB9, 0xECA, 0xFDB, 0xFFF]
    # Sprite palette: 3 depth levels * 4 pairs = 12 colours
    pal[24:36] = [0xA50, 0xFB3, 0xFFD, 0x924, 0xE5A, 0xFCE,
                  0x146, 0x4AF, 0xCEF, 0x113, 0x35A, 0x8BE]
    # Background: gradients and effects
    pal[36:48] = [0x001, 0x011, 0x022, 0x033, 0x044, 0x055,
                  0x066, 0x077, 0x088, 0x099, 0x0AA, 0x0BB]
    # Effects: glow, plasma, particles
    pal[48:64] = [0xF00, 0xF10, 0xF20, 0xF30, 0xF40, 0xF50,
                  0x0F0, 0x1F0, 0x2F0, 0x3F0, 0x4F0, 0x5F0,
                  0x00F, 0x10F, 0x20F, 0x30F]
    return pal


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    tables = {'copper': copper, 'sintab': sintab, 'recip_star': recip_star, 'recip_wire': recip_wire,
           'floor_base': lambda: words(floor_base()), 'bar_colors': lambda: words(bar_colors(), 8),
           'wave_tab': lambda: words(wave_tab()), 'palette': header_palette,
           'balls': lambda: words(balls(), 8), 'spr_palette': spr_palette,
           'ring_tab': lambda: '\n'.join('        dc.w ' + ','.join('%d' % v for v in ring_tab()[i:i + 16]) for i in range(0, 512, 16)),
           'raster_palette': lambda: words(raster_palette(), 16),
           'bar_motion': lambda: words(bar_motion(), 16),
           'aga_palette': lambda: words(aga_palette(), 8),
           'row_offsets': lambda: words([y * 40 for y in range(256)], 16)}
    parser.add_argument('table', choices=sorted(tables))
    args = parser.parse_args()
    print(tables[args.table]())
