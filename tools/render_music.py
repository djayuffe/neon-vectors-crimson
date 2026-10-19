#!/usr/bin/env python3
"""Render a MOD preview with libopenmpt, replacing the output only on success."""
import argparse
import array
import math
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('module', nargs='?', type=Path, default=ROOT/'assets/neon.mod')
    parser.add_argument('--output', type=Path, default=ROOT/'build/music_preview.wav')
    parser.add_argument('--seconds', type=float, default=61.44)
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or args.seconds <= 0:
        parser.error('--seconds must be a finite positive duration')
    if not args.module.is_file():
        parser.error('module does not exist: %s' % args.module)
    if args.output.resolve() == args.module.resolve() or args.output.suffix.lower() != '.wav':
        parser.error('--output must be a WAV path different from the source module')
    if shutil.which('openmpt123') is None:
        print('music preview needs openmpt123 on PATH', file=sys.stderr)
        return 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='music-render-', dir=args.output.parent) as folder:
            rendered = Path(folder)/'preview.wav'
            result = subprocess.run(['openmpt123', '--batch', '--no-float', '--no-progress',
                                     '--end-time', str(args.seconds), '-o', str(rendered),
                                     str(args.module.resolve())], capture_output=True, text=True)
            if result.returncode:
                print('music render failed: '+result.stderr.strip(), file=sys.stderr)
                return 1
            with wave.open(str(rendered), 'rb') as sound:
                duration = sound.getnframes()/sound.getframerate()
                if sound.getsampwidth() != 2 or abs(duration-args.seconds) > .1:
                    raise ValueError('unexpected preview PCM format or duration')
                samples = array.array('h', sound.readframes(sound.getnframes()))
                if sys.byteorder != 'little':
                    samples.byteswap()
            peak = max(abs(value) for value in samples)
            clipped = sum(value in (-32768,32767) for value in samples)
            os.replace(rendered,args.output)
        level = 'silence' if peak == 0 else '%.2f dBFS' % (20*math.log10(peak/32768))
        print('%s: %.3f seconds, peak %s, %d clipped samples (libopenmpt host mix)' %
              (args.output,duration,level,clipped))
        return 0
    except (OSError, ValueError, wave.Error) as error:
        print('music preview failed: %s' % error, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
