PYTHON ?= python3
VASM ?= $(shell command -v vasmm68k_mot 2>/dev/null || true)
LOCAL_VASM := tools/bin/vasmm68k_mot
VASMFLAGS = -m68000 -kick1hunks -Fhunkexe -nosym -I./src
TARGET = build/neon_vectors
SRCS = src/main.s src/hardware.i src/modplayer.s
GEN = tools/generate_assets.py
# The generated assets are checked in, so they are only rebuilt when the
# generator changes. A stamp instead of a phony per-file target keeps "make -j"
# from running the generator while the assembler reads the files: everything
# that needs the assets depends on this single target.
STAMP = assets/.generated
# Validation is a real prerequisite of the build, not just a phony alias, so a
# failing check stops make before the assembler is invoked.
CHECKED = build/.validated

all: $(TARGET) hunkcheck

$(STAMP): $(GEN)
	@mkdir -p assets
	$(PYTHON) $(GEN)
	@touch $@

assets: $(STAMP)

$(CHECKED): $(STAMP) $(SRCS) tools/validate.py | build
	$(PYTHON) tools/validate.py
	@touch $@

validate: $(CHECKED)

# Proves the validator can fail: injects known faults and requires each to be
# reported. Not part of "all", because it copies the tree and re-runs the
# validator dozens of times.
mutants:
	$(PYTHON) tools/mutate.py

verify-repro:
	$(PYTHON) tools/verify_repro.py

# Runs the assembled program on an emulated 68000 (needs: pip install machine68k).
# Uses its own symbol-carrying build, so it does not depend on "make".
emutest:
	$(PYTHON) tools/emu_test.py

# Self-test of the emulation test: inject faults, require each to fail it (slow).
emu-mutants:
	$(PYTHON) tools/mutate_emu.py

manifest:
	$(PYTHON) tools/make_manifest.py

toolchain:
	@tools/bootstrap_vasm.sh >/dev/null

$(TARGET): $(CHECKED) $(SRCS) | build
	@if [ -n "$(VASM)" ]; then A="$(VASM)"; elif [ -x "$(LOCAL_VASM)" ]; then A="$(LOCAL_VASM)"; else echo "No VASM. Run 'make toolchain' after supplying tools/vendor/vasm, or install vasmm68k_mot."; exit 2; fi; \
	$$A $(VASMFLAGS) -o $@ src/main.s

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

release: clean all verify-repro manifest

.PHONY: all assets validate mutants verify-repro emutest emu-mutants manifest toolchain hunkcheck clean distclean release
