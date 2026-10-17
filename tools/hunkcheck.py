#!/usr/bin/env python3
"""Validate the classic HUNK executable subset emitted by this project's VASM flags.

Rejects overlays, unresolved externals, short relocations and unknown block types.
This is a structural checker, not an Amiga DOS loader.
"""
from pathlib import Path
import struct
import sys


def validate(data):
    off = 0

    def take(count):
        nonlocal off
        if count < 0 or count > len(data) - off:
            raise ValueError('truncated block at offset %d' % off)
        result = data[off:off+count]
        off += count
        return result

    def word():
        return struct.unpack('>I', take(4))[0]

    def string():
        return take(word()*4).split(b'\0')[0].decode('latin-1')

    if word() != 0x3F3:
        raise ValueError('not HUNK_HEADER')
    # Resident library names are counted strings, terminated by a zero length.
    while True:
        length = word()
        if not length:
            break
        take(length*4)
    table, first, last = word(), word(), word()
    if first != 0 or not table or last != table-1:
        raise ValueError('expected a complete non-overlay hunk table starting at zero')
    if table > (len(data)-off)//4:
        raise ValueError('truncated hunk table')
    sizes, flags = [], []
    for _ in range(table):
        entry = word()
        flags.append(word() if entry >> 30 == 3 else entry >> 30)
        sizes.append((entry & 0x3FFFFFFF)*4)
    kinds, names = [], []
    active = False
    payload_size = 0
    while off < len(data):
        kind = word() & 0x3FFFFFFF
        if kind == 0x3E8:  # HUNK_NAME: positive longword count
            names.append(string())
        elif kind in (0x3E9, 0x3EA, 0x3EB):
            if active or len(kinds) >= table:
                raise ValueError('missing HUNK_END or excess section')
            payload_size = word()*4
            if payload_size > sizes[len(kinds)]:
                raise ValueError('section exceeds allocated hunk size')
            kinds.append({0x3E9: 'code', 0x3EA: 'data', 0x3EB: 'bss'}[kind])
            active = True
            if kind != 0x3EB:
                take(payload_size)
        elif kind == 0x3EC:
            if not active:
                raise ValueError('relocations outside section')
            while True:
                count = word()
                if not count:
                    break
                if word() >= table:
                    raise ValueError('relocation target outside hunk table')
                if count > (len(data)-off)//4:
                    raise ValueError('truncated relocation group')
                for _ in range(count):
                    pos = word()
                    if pos & 1 or pos+4 > payload_size:
                        raise ValueError('relocation offset outside section or misaligned')
        elif kind == 0x3F0:
            if not active:
                raise ValueError('symbols outside section')
            while True:
                length = word()
                if not length:
                    break
                take(length*4)
                if word() > sizes[len(kinds)-1]:
                    raise ValueError('symbol outside section')
        elif kind == 0x3F1:
            if not active:
                raise ValueError('debug block outside section')
            take(word()*4)
        elif kind == 0x3F2:
            if not active:
                raise ValueError('unexpected HUNK_END')
            active = False
        else:
            raise ValueError('unsupported hunk type 0x%x' % kind)
    if active or len(kinds) != table:
        raise ValueError('incomplete hunk sections')
    return kinds, sizes, flags, names


def main():
    path = Path(sys.argv[1] if len(sys.argv)>1 else 'build/neon_vectors')
    try:
        data = path.read_bytes()
        kinds, sizes, flags, names = validate(data)
    except (OSError, ValueError) as error:
        print('HUNK INVALID:', error, file=sys.stderr)
        return 1
    print('HUNK OK: %s bytes=%d hunks=%d types=%s sizes=%s memory=%s' %
          (path, len(data), len(kinds), kinds, sizes, flags))
    return 0


if __name__ == '__main__':
    sys.exit(main())
