#!/usr/bin/env python3
"""Verify deterministic generation AND freshness without changing shipped assets."""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ('logo.raw', 'font.raw', 'neon.mod', 'logo_preview.png')


def main():
    with tempfile.TemporaryDirectory(prefix='neon-repro-') as tmp:
        outputs = [Path(tmp)/'first', Path(tmp)/'second']
        for output in outputs:
            subprocess.run([sys.executable, str(ROOT/'tools/generate_assets.py'),
                            '--output', str(output)], check=True)
        errors = []
        for name in FILES:
            generated = (outputs[0]/name).read_bytes()
            if generated != (outputs[1]/name).read_bytes():
                errors.append(name + ': generation is not deterministic')
            shipped = ROOT/'assets'/name
            if not shipped.is_file() or shipped.read_bytes() != generated:
                errors.append(name + ': shipped asset is stale; run make assets')
            print(hashlib.sha256(generated).hexdigest(), 'assets/' + name)
        if errors:
            print('REPRODUCIBILITY FAILED\n' + '\n'.join(errors), file=sys.stderr)
            return 1
    print('REPRODUCIBILITY OK: deterministic and current')
    return 0


if __name__ == '__main__':
    sys.exit(main())
