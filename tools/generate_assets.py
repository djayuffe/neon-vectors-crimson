#!/usr/bin/env python3
"""Deterministically generate every binary asset used by NEON VECTORS.
No host fonts, Pillow, timestamps, randomness without a fixed seed, or external tools.
"""
from pathlib import Path
import math, struct, random, zlib
ROOT=Path(__file__).resolve().parents[1]
A=ROOT/'assets'; A.mkdir(exist_ok=True)

# 5x7 glyphs. Lowercase is intentionally rendered as uppercase for the demo font.
G={
' ':['00000']*7,'!':['00100','00100','00100','00100','00100','00000','00100'],
'-':['00000','00000','00000','11111','00000','00000','00000'],
'.':['00000','00000','00000','00000','00000','00110','00110'],
'/':['00001','00010','00100','01000','10000','00000','00000'],
':':['00000','00110','00110','00000','00110','00110','00000'],
'?':['01110','10001','00001','00010','00100','00000','00100'],
'0':['01110','10001','10011','10101','11001','10001','01110'],
'1':['00100','01100','00100','00100','00100','00100','01110'],
'2':['01110','10001','00001','00010','00100','01000','11111'],
'3':['11110','00001','00001','01110','00001','00001','11110'],
'4':['00010','00110','01010','10010','11111','00010','00010'],
'5':['11111','10000','10000','11110','00001','00001','11110'],
'6':['01110','10000','10000','11110','10001','10001','01110'],
'7':['11111','00001','00010','00100','01000','01000','01000'],
'8':['01110','10001','10001','01110','10001','10001','01110'],
'9':['01110','10001','10001','01111','00001','00001','01110'],
'A':['01110','10001','10001','11111','10001','10001','10001'],
'B':['11110','10001','10001','11110','10001','10001','11110'],
'C':['01111','10000','10000','10000','10000','10000','01111'],
'D':['11110','10001','10001','10001','10001','10001','11110'],
'E':['11111','10000','10000','11110','10000','10000','11111'],
'F':['11111','10000','10000','11110','10000','10000','10000'],
'G':['01111','10000','10000','10111','10001','10001','01111'],
'H':['10001','10001','10001','11111','10001','10001','10001'],
'I':['01110','00100','00100','00100','00100','00100','01110'],
'J':['00001','00001','00001','00001','10001','10001','01110'],
'K':['10001','10010','10100','11000','10100','10010','10001'],
'L':['10000','10000','10000','10000','10000','10000','11111'],
'M':['10001','11011','10101','10101','10001','10001','10001'],
'N':['10001','11001','10101','10011','10001','10001','10001'],
'O':['01110','10001','10001','10001','10001','10001','01110'],
'P':['11110','10001','10001','11110','10000','10000','10000'],
'Q':['01110','10001','10001','10001','10101','10010','01101'],
'R':['11110','10001','10001','11110','10100','10010','10001'],
'S':['01111','10000','10000','01110','00001','00001','11110'],
'T':['11111','00100','00100','00100','00100','00100','00100'],
'U':['10001','10001','10001','10001','10001','10001','01110'],
'V':['10001','10001','10001','10001','10001','01010','00100'],
'W':['10001','10001','10001','10101','10101','10101','01010'],
'X':['10001','10001','01010','00100','01010','10001','10001'],
'Y':['10001','10001','01010','00100','00100','00100','00100'],
'Z':['11111','00001','00010','00100','01000','10000','11111'],
}

def glyph8(ch):
    key=ch.upper()
    rows=G.get(key)
    if rows is None:
        # Deterministic visible fallback for printable characters not used by the demo.
        v=ord(ch)&0x7f
        rows=['11111']+[f'{((v>>(r%7))|((v<<(7-r))&0x7f))&0x1f:05b}' for r in range(5)]+['11111']
    out=[]
    for r in range(7):
        bits=rows[r]
        b=0
        for x,c in enumerate(bits):
            if c=='1': b |= 1 << (6-x)  # centered in 8 pixels, columns 1..5
        out.append(b)
    out.append(0)
    return bytes(out)

# ---------- deterministic 8x8 font ASCII 32..126 ----------
fraw=b''.join(glyph8(chr(c)) for c in range(32,127))
(A/'font.raw').write_bytes(fraw)

# ---------- deterministic planar logo ----------
# A 320x64 sixteen colour image drawn procedurally by tools/logo_art.py (distance-field letters
# with bevel lighting, extrusion shadow, chiselled subtitle, wing ornaments), stored as four
# bitplanes of 40 bytes per row, one after the other (2560 bytes each).
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import logo_art
W, H = logo_art.W, logo_art.H
img = logo_art.build()
raw = b''.join(logo_art.to_planes(img))
(A/'logo.raw').write_bytes(raw)

def png_chunk(tag,data):
    return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
scale=2
scan=b''.join(b'\x00'+bytes(r) for r in logo_art.preview_rgb(img,scale))
png=b'\x89PNG\r\n\x1a\n'+png_chunk(b'IHDR',struct.pack('>IIBBBBB',W*scale,H*scale,8,2,0,0,0))+png_chunk(b'IDAT',zlib.compress(scan,9))+png_chunk(b'IEND',b'')
(A/'logo_preview.png').write_bytes(png)

# ---------- deterministic ProTracker MOD ----------
periods={}; names=['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']; base=[856,808,762,720,678,640,604,570,538,508,480,453]
for octv in range(1,5):
    for i,n in enumerate(names): periods[f'{n}{octv}']=max(113,base[i]>>(octv-1))
def u8(v): return 0 if v<0 else 255 if v>255 else v
# Paula plays 8 bit samples as unsigned, so every waveform is centred on 128.
# Writing the signed value straight out (or masking it with &255) puts the
# whole sample near full scale and produces an audible DC step in the loop.
def pcm_sine(n=128,amp=80): return bytes(u8(128+int(amp*math.sin(2*math.pi*i/n))) for i in range(n))
def pcm_square(n=128,amp=70): return bytes(u8(128+amp if i<n//2 else 128-amp) for i in range(n))
def pcm_kick(n=512):
    out=[]; ph=0.0
    for i in range(n):
        t=i/n; ph+=2*math.pi*(90*(1-t)+25)/8000; out.append(u8(128+int(110*math.exp(-6*t)*math.sin(ph))))
    return bytes(out)
def pcm_hat(n=256):
    rng=random.Random(68000)
    return bytes(u8(128+int(90*math.exp(-5*i/n)*rng.uniform(-1,1))) for i in range(n))
samples=[('BASS',pcm_square()),('LEAD',pcm_sine()),('KICK',pcm_kick()),('HAT',pcm_hat())]
while len(samples)<31: samples.append(('',b''))
header=bytearray(b'NEON VECTORS - OCS CRACKTRO'.ljust(20,b' ')[:20])
for name,data in samples:
    if len(data)%2: data+=b'\0'
    length=len(data)//2; vol=48 if name else 0; loop_len=length if name in ('BASS','LEAD') else 1
    header+=name.encode()[:22].ljust(22,b' ')+struct.pack('>HBBHH',length,0,vol,0,loop_len)
header+=bytes([4,0])+bytes([0,1,2,3]+[0]*124)+b'M.K.'
def ev(sample=0,note=None,fx=0,param=0):
    p=periods.get(note,0) if note else 0
    return bytes([(sample&0xf0)|((p>>8)&15),p&255,((sample&15)<<4)|(fx&15),param&255])
patterns=[]; chords=[['A2','C3','E3'],['F2','A2','C3'],['C3','E3','G3'],['G2','B2','D3']]; bass=['A1','F1','C2','G1']
for pat in range(4):
    pb=bytearray()
    for row in range(64):
        c1=ev(1,bass[pat]) if row%4==0 else ev(); c2=ev(2,chords[pat][(row//2)%3]) if row%2==0 else ev()
        c3=ev(3,'C2') if row%8==0 else ev(); c4=ev(4,'C3') if row%4==2 else ev()
        if pat==0 and row==0: c1=ev(1,bass[pat],0xF,6)
        pb+=c1+c2+c3+c4
    patterns.append(pb)
mod=header+b''.join(patterns)+b''.join(data+(b'\0' if len(data)%2 else b'') for _,data in samples)
(A/'neon.mod').write_bytes(mod)
print(f'generated logo={len(raw)} font={len(fraw)} mod={len(mod)} bytes')
