#!/usr/bin/env python3
"""Amiga hunk executable structural validator.

A hunkexe starts with HUNK_HEADER, then a table holding one size entry per
hunk, then the hunk blocks themselves. The top two bits of a size entry are the
memory requirement (Amiga hunk format / doshunks.h):

  00 any, fast preferred   10 fast required (bit 31, HUNKB_FAST)
  01 chip required (bit 30, HUNKB_CHIP)
  11 an extra longword follows with the exact flags

HUNK_NAME carries a section name and is counted as one length longword plus
the name itself, so a parser that does not know it rejects every real
executable.
"""
from pathlib import Path
import struct, sys

HUNK_UNIT=0x3E7; HUNK_NAME=0x3E8; HUNK_CODE=0x3E9; HUNK_DATA=0x3EA
HUNK_BSS=0x3EB; HUNK_RELOC32=0x3EC; HUNK_RELOC16=0x3ED; HUNK_RELOC8=0x3EE
HUNK_EXT=0x3EF; HUNK_SYMBOL=0x3F0; HUNK_DEBUG=0x3F1; HUNK_END=0x3F2
HUNK_HEADER=0x3F3; HUNK_OVERLAY=0x3F5; HUNK_BREAK=0x3F6
HUNKB_ADVISORY=29; HUNKB_CHIP=30; HUNKB_FAST=31
MEM_ANY=0; MEM_CHIP=1; MEM_FAST=2; MEM_EXT=3   # bit 30 = chip, bit 31 = fast
MEMNAMES={MEM_ANY:'any (fast preferred)',MEM_FAST:'fast required',MEM_CHIP:'chip required',MEM_EXT:'explicit flags'}

p=Path(sys.argv[1] if len(sys.argv)>1 else 'build/neon_vectors')
b=p.read_bytes(); off=0
def u32():
    global off
    if off+4>len(b): raise ValueError('truncated at offset %d'%off)
    v=struct.unpack_from('>I',b,off)[0]; off+=4; return v
try:
    if u32()!=HUNK_HEADER: raise ValueError('not HUNK_HEADER')
    libs=[]
    while True:
        # The header block is a list of library name pointers, not a count.
        n=u32()
        if n==0: break
        libs.append(n)
    table=u32(); first=u32(); last=u32()
    if last<first or table!=last-first+1: raise ValueError('bad hunk table')
    sizes=[]; memflags=[]
    for _ in range(table):
        v=u32()
        kind=(v>>30)&3
        if kind==MEM_EXT:
            memflags.append(u32()&0x7fffffff); sizes.append((v&0x3fffffff)*4)
        else:
            memflags.append({MEM_ANY:MEM_ANY,MEM_FAST:MEM_FAST,MEM_CHIP:MEM_CHIP}[kind]); sizes.append((v&0x3fffffff)*4)
    hunks=0; names=[]; kinds=[]
    while off<len(b):
        t=u32()&0x3fffffff
        if t in (HUNK_CODE,HUNK_DATA):
            # The count has to be read into a local first: "off += u32()*4" would
            # add to the value off had before u32() advanced it, landing the
            # parser four bytes short and reading payload words as hunk types.
            n=u32()
            if off+n*4>len(b): raise ValueError('truncated hunk payload')
            off+=n*4; hunks+=1; kinds.append('code' if t==HUNK_CODE else 'data')
        elif t==HUNK_BSS: u32(); hunks+=1; kinds.append('bss')
        elif t==HUNK_NAME:
            # The type long is followed by a counted block: a negative longword
            # count that includes itself, then the characters. Anything else is
            # a layout this parser does not understand, so say so loudly.
            cnt=struct.unpack('>i',b[off:off+4])[0]; off+=4
            if cnt>=0: raise ValueError('HUNK_NAME is not followed by a negative longword count (got %d)'%cnt)
            total=(-cnt-1)*4
            if off+total>len(b): raise ValueError('truncated HUNK_NAME')
            names.append(b[off:off+total].split(b'\0')[0].decode('latin-1'))
            off+=total
        elif t in (HUNK_RELOC32,HUNK_RELOC16,HUNK_RELOC8):
            if t==HUNK_RELOC32:
                while True:
                    n=u32()
                    if n==0: break
                    u32(); off+=n*4
            else: raise ValueError('hunkexe should not contain 16/8 bit relocation hunks (0x%x)'%t)
        elif t==HUNK_SYMBOL:
            while True:
                n=u32()
                if n==0: break
                off+=n*4; u32()
        elif t==HUNK_DEBUG:
            n=u32()
            if off+n*4>len(b): raise ValueError('truncated HUNK_DEBUG')
            off+=n*4
        elif t==HUNK_END: pass
        elif t in (HUNK_OVERLAY,HUNK_BREAK): raise ValueError('overlay hunk, not a plain executable')
        elif t==HUNK_EXT: raise ValueError('external reference hunk: unresolved symbol, not an executable')
        else: raise ValueError('unsupported/invalid hunk type 0x%x at %d'%(t,off-4))
    if off!=len(b): raise ValueError('trailing bytes')
    if hunks!=table: raise ValueError('hunk count %d != table %d'%(hunks,table))
    print(f'HUNK OK: {p} bytes={len(b)} hunks={hunks} types={kinds} sizes={sizes}')
    for i,(kind,size,mem) in enumerate(zip(kinds,sizes,memflags)):
        print(f'  hunk {i}: {kind:4} {size:6} bytes  memory={MEMNAMES.get(mem,"0x%08x"%mem)}')
    if names: print('  names: '+', '.join(names))
    if libs: print(f'  libraries: {len(libs)}')
except Exception as e:
    print('HUNK INVALID:',e,file=sys.stderr); sys.exit(1)
