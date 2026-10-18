#!/usr/bin/env python3
"""Create a reproducible, self-contained Amiga distribution from a clean checkout."""
from pathlib import Path
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import zipfile
import hunkcheck

ROOT = Path(__file__).resolve().parents[1]
README = """NEON VECTORS CRIMSON

PAL Motorola 68000 / OCS or ECS Amiga demo.
Copy neon_vectors to an Amiga filesystem and run it from a Shell:

  neon_vectors

Press the left mouse button to exit and restore the system display.
Return code: 0 on success, 20 if startup resources are unavailable.
Use a PAL machine with sufficient free chip RAM (512 KiB configuration or more).
The program takes over graphics and audio while running.

This candidate passes host validation and emulated-68000 checks. Final acceptance
on physical hardware, genuine Kickstart and perceptual audio remains outstanding.
The CPU test does not model DMA contention or blitter timing.

Source and build instructions:
https://github.com/djayuffe/neon-vectors-crimson

SHA256SUMS verifies every other file in this archive. BUILD_INFO.txt identifies
the clean source revision. The archive contains no ROMs or third-party toolchain.
"""


def write_package(executable, destination, revision):
    if not re.fullmatch(r'[0-9a-f]{40,64}', revision):
        raise ValueError('expected a full Git source revision')
    binary = executable.read_bytes()
    hunkcheck.validate(binary)
    entries = {
        'neon_vectors': binary,
        'README.txt': README.encode('ascii'),
        'BUILD_INFO.txt': ('Source revision: '+revision+'\nTarget: PAL 68000 OCS/ECS\n').encode('ascii'),
    }
    entries['SHA256SUMS'] = ''.join(
        hashlib.sha256(data).hexdigest()+'  '+name+'\n'
        for name, data in sorted(entries.items())).encode('ascii')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Fixed metadata and stored entries avoid host timestamps and compression-version drift.
    with tempfile.NamedTemporaryFile(dir=destination.parent, suffix='.tmp', delete=False) as temp:
        temporary = Path(temp.name)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_STORED) as archive:
            for name, data in sorted(entries.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (0o100755 if name == 'neon_vectors' else 0o100644) << 16
                archive.writestr(info, data)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return hashlib.sha256(destination.read_bytes()).hexdigest()


def main():
    try:
        state = subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=ROOT)
        if state.strip():
            raise ValueError('distribution requires a clean committed checkout')
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        output = ROOT/'build/neon_vectors_crimson.zip'
        digest = write_package(ROOT/'build/neon_vectors', output, revision)
        print(digest+'  '+str(output))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print('PACKAGE FAILED:', error, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
