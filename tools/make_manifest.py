#!/usr/bin/env python3
"""Write or verify SHA-256 hashes of shipped project files, excluding build state."""
from pathlib import Path
import argparse
import hashlib
import sys

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'.git', 'build', '__pycache__', '.venv', 'venv', '.pytest_cache'}
SKIP_NAMES = {'MANIFEST.sha256', '.DS_Store', 'a.out', '.generated'}
SKIP_SUFFIXES = {'.pyc', '.pyo', '.o', '.obj', '.tmp', '.bak', '.orig', '.rej', '.lst'}


def manifest(root):
    entries = []
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root)
        if path.is_symlink() or not path.is_file():
            continue
        if set(rel.parts[:-1]) & SKIP_DIRS or rel.parts[:2] in (('tools', 'bin'), ('tools', 'vendor')):
            continue
        if path.name in SKIP_NAMES or path.name.startswith('.generated-') or path.suffix in SKIP_SUFFIXES:
            continue
        entries.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + rel.as_posix() + '\n')
    return ''.join(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='fail on missing/stale manifest without writing')
    parser.add_argument('-v', action='store_true', help='print manifest entries')
    args = parser.parse_args()
    content = manifest(ROOT)
    path = ROOT/'MANIFEST.sha256'
    if args.check:
        if not path.is_file() or path.read_text() != content:
            print('MANIFEST FAILED: run make manifest after reviewing changes', file=sys.stderr)
            return 1
    else:
        path.write_text(content)
    print('manifest: %d files%s' % (len(content.splitlines()), ' verified' if args.check else ''))
    if args.v:
        print(content, end='')
    return 0


if __name__ == '__main__':
    sys.exit(main())
