#!/usr/bin/env python3
"""Write MANIFEST.sha256 for every shipped file.

Build output, Python caches and vendored toolchains are not part of a release,
so they are excluded; otherwise the manifest changes whenever somebody simply
ran the build or the validators.
"""
from pathlib import Path
import hashlib, sys

R=Path(__file__).resolve().parents[1]
SKIP_DIRS={'.git','build','__pycache__','vendor','tools/vendor','tools/bin','.venv','venv'}
SKIP_SUFFIXES={'.pyc','.pyo','.o','.obj','.tmp','.bak','.orig','.rej','.DS_Store'}
SKIP_NAMES={'MANIFEST.sha256','.DS_Store','a.out'}
files=[]
for p in sorted(R.rglob('*')):
    if not p.is_file(): continue
    parts=set(p.parts)
    if parts & SKIP_DIRS: continue
    if p.suffix in SKIP_SUFFIXES or p.name in SKIP_NAMES: continue
    # Build stamps are state, not content: they are rewritten on every build.
    if p.name.startswith('.'): continue
    files.append(p)
expected=[p for p in sorted((R/'tools').glob('*.py')) if p.is_file()]
missing=[p.name for p in expected if p not in files]
if missing:
    print('manifest: refusing to rewrite, these tools are excluded:',', '.join(missing))
    sys.exit(1)
with (R/'MANIFEST.sha256').open('w') as f:
    for p in files:
        f.write(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(R).as_posix()+'\n')
print('manifest:',len(files),'files')
if len(sys.argv)>1 and sys.argv[1]=='-v':
    for p in files: print('  ',p.relative_to(R).as_posix())
