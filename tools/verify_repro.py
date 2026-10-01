#!/usr/bin/env python3
from pathlib import Path
import hashlib, subprocess, sys
ROOT=Path(__file__).resolve().parents[1]
FILES=['assets/logo.raw','assets/font.raw','assets/neon.mod','assets/logo_preview.png']
def hashes(): return {f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in FILES}
subprocess.run([sys.executable,str(ROOT/'tools/generate_assets.py')],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
a=hashes()
subprocess.run([sys.executable,str(ROOT/'tools/generate_assets.py')],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
b=hashes()
if a!=b:
    print('REPRODUCIBILITY FAILED')
    for f in FILES:
        if a[f]!=b[f]: print(f' - {f}: {a[f]} != {b[f]}')
    raise SystemExit(1)
print('REPRODUCIBILITY OK')
for f in FILES: print(a[f],f)
