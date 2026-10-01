#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/tools/bin/vasmm68k_mot"
VENDOR="$ROOT/tools/vendor"
SRC=${VASM_SRC:-"$VENDOR/vasm"}
# If HTTPS is blocked on your network you can pass VASM_URL=http://... yourself;
# the tarball is not signed, so review what you build from an unencrypted fetch.
URL=${VASM_URL:-"https://sun.hasenbraten.de/vasm/release/vasm.tar.gz"}
mkdir -p "$ROOT/tools/bin" "$VENDOR"
if command -v vasmm68k_mot >/dev/null 2>&1; then command -v vasmm68k_mot; exit 0; fi
if [ -x "$OUT" ]; then echo "$OUT"; exit 0; fi
if [ ! -f "$SRC/Makefile" ]; then
  TMP="$VENDOR/vasm.tar.gz"
  echo "Fetching VASM source from $URL" >&2
  if command -v curl >/dev/null 2>&1; then curl -fL "$URL" -o "$TMP"
  elif command -v wget >/dev/null 2>&1; then wget -O "$TMP" "$URL"
  else echo "Need curl/wget, or set VASM_SRC to an unpacked VASM source tree." >&2; exit 2; fi
  rm -rf "$SRC"; mkdir -p "$SRC"
  tar -xzf "$TMP" -C "$SRC" --strip-components=1
fi
make -C "$SRC" CPU=m68k SYNTAX=mot
cp "$SRC/vasmm68k_mot" "$OUT"
chmod +x "$OUT"
echo "$OUT"
