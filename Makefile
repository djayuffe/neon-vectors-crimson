PYTHON ?= python3
VASM ?= $(shell command -v vasmm68k_mot 2>/dev/null || true)
LOCAL_VASM := tools/bin/vasmm68k_mot
VASMFLAGS = -m68000 -kick1hunks -Fhunkexe -nosym -I./src
TARGET = build/neon_vectors
SRCS = src/main.s src/hardware.i src/modplayer.s
GEN = tools/generate_assets.py
ASSETS = assets/logo.raw assets/font.raw assets/neon.mod assets/logo_preview.png
# The generated assets are checked in, so they are only rebuilt when the
# generator changes. A stamp instead of a phony per-file target keeps "make -j"
# from running the generator while the assembler reads the files: everything
# that needs the assets depends on this single target.
# Content fingerprints also detect generator edits sharing a timestamp.
ASSET_KEY := $(shell $(PYTHON) -c 'import hashlib; from pathlib import Path; print(hashlib.sha256(b"".join(Path(p).read_bytes() for p in ("tools/generate_assets.py", "tools/logo_art.py"))).hexdigest()[:16])')
STAMP := assets/.generated-$(ASSET_KEY)
all: $(TARGET) hunkcheck

$(STAMP): $(GEN) tools/logo_art.py
	@mkdir -p assets
	$(PYTHON) $(GEN)
	@rm -f assets/.generated assets/.generated-*
	@touch $@

# Missing assets invalidate the single producer even when its stamp exists.
# This also prevents concurrent generator processes under make -j.
ifneq ($(strip $(filter-out $(wildcard $(ASSETS)),$(ASSETS))),)
.PHONY: $(STAMP)
endif
$(ASSETS): $(STAMP)
	@test -f $@

# A forced refresh and a concurrent build still share one asset producer.
ifneq ($(filter assets,$(MAKECMDGOALS)),)
.PHONY: $(STAMP)
endif
assets: $(STAMP)

validate: $(ASSETS)
	$(PYTHON) tools/validate.py

# Proves the validator can fail: injects known faults and requires each to be
# reported. Not part of "all", because it copies the tree and re-runs the
# validator dozens of times.
mutants:
	$(PYTHON) tools/mutate.py

test:
	$(PYTHON) -m unittest discover -s tests -v

verify-repro:
	$(PYTHON) tools/verify_repro.py

# Runs the assembled program on an emulated 68000 (needs: pip install machine68k).
# Uses a symbol-carrying build; gallery additionally captures each scene.
gallery: all
	$(PYTHON) tools/emu_test.py --frames 2100 --snap 1850 --gallery-dir build/scene-gallery

# Eight seconds of silent, actual executable output. Needs ffmpeg on PATH.
preview: all
	$(PYTHON) tools/emu_test.py --frames 1450 --snap 1148 --record-dir build/preview-frames
	ffmpeg -hide_banner -loglevel error -y -framerate 50 -i build/preview-frames/frame-%04d.png -frames:v 400 -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart build/demo-preview.mp4

emutest:
	$(PYTHON) tools/emu_test.py

# Self-test of the emulation test: inject faults, require each to fail it (slow).
emu-mutants:
	$(PYTHON) tools/mutate_emu.py

manifest:
	$(PYTHON) tools/make_manifest.py

toolchain:
	@tools/bootstrap_vasm.sh >/dev/null

# This small executable is always validated and assembled. Content edits within
# one filesystem timestamp interval must not reuse an unchecked binary.
FORCE:

$(TARGET): FORCE $(ASSETS) $(SRCS) | build
	$(PYTHON) tools/validate.py
	@if [ -n "$(VASM)" ]; then A="$(VASM)"; elif [ -x "$(LOCAL_VASM)" ]; then A="$(LOCAL_VASM)"; else echo "No VASM. Run 'make toolchain' after supplying tools/vendor/vasm, or install vasmm68k_mot."; exit 2; fi; \
	"$$A" $(VASMFLAGS) -o $@ src/main.s

hunkcheck: $(TARGET)
	$(PYTHON) tools/hunkcheck.py $(TARGET)

build:
	@mkdir -p build

# clean keeps the generated assets: they are part of the release and are
# reproducible with "make assets", while "make clean" should not turn a
# checkout into something that no longer matches its own manifest.
clean:
	rm -rf build

distclean: clean
	rm -f assets/logo.raw assets/font.raw assets/neon.mod assets/logo_preview.png $(STAMP)

# "clean all" in one recipe must not overlap under -j.
.NOTPARALLEL: release

# A release verifies reviewed checksums; only the explicit manifest target writes them.
release:
	$(PYTHON) tools/make_manifest.py --check
	$(MAKE) clean
	$(MAKE) all
	$(MAKE) test
	$(MAKE) mutants
	$(MAKE) verify-repro

# Package only a clean source revision after all release gates pass.
dist: release
	$(PYTHON) tools/emu_test.py --frames 6400 --snap 4490
	$(PYTHON) tools/emu_test.py --loader-chip --frames 100 --snap 80
	$(PYTHON) tools/emu_test.py --ntsc --frames 100
	$(PYTHON) tools/package_release.py

.PHONY: preview gallery dist FORCE test all assets validate mutants verify-repro emutest emu-mutants manifest toolchain hunkcheck clean distclean release
