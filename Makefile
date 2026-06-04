# Reliable fresh-build wrapper for Inferno emu on aarch64.
#
# mk's dependency tracking is unreliable for incremental changes, so this
# Makefile always nukes object files before rebuilding each component.
# Build order matches EMUDIRS in the top-level mkfile.
#
# `make all` builds BOTH halves of the system:
#   1. the C side  -- libraries, the limbo compiler, and the emu binary;
#   2. the Dis tree -- the Limbo source under appl/ compiled to .dis with the
#      compiler just built.  .dis are build output (gitignored), not tracked,
#      so they must be regenerated from source; this is what makes a compiler
#      fix actually reach the running system.

ROOT    := $(realpath $(dir $(firstword $(MAKEFILE_LIST))))
SYSHOST := Linux
SYSTARG := Linux
# Target architecture (LP64).  Override on a native x86-64 host with
#   make OBJTYPE=amd64 all
# Both aarch64 and amd64 are LP64, so they share the entire Dis ABI / .dis tree;
# only the per-arch glue (mkfiles, Linux/$OBJTYPE/include, emu asm) differs.
OBJTYPE ?= aarch64
OBJDIR  := $(SYSTARG)/$(OBJTYPE)
MK      := $(ROOT)/$(OBJDIR)/bin/mk
# emu is the full GUI configuration (X11 + libfreetype + libtk + libdraw).
# FreeType 2.13.2 is now vendored under libfreetype/libfreetype, the LP64
# graphics path (libmemdraw/libdraw word width) is fixed, and the desktop
# (wm/wm) runs, so the GUI build is the default.  Use CONF=emu-g for a
# graphics-less headless build (faster; what the tests/lp64 suite runs under).
CONF    := emu
MKARGS  := ROOT=$(ROOT) SYSHOST=$(SYSHOST) SYSTARG=$(SYSTARG) OBJTYPE=$(OBJTYPE)
EMUARGS := $(MKARGS) CONF=$(CONF)

export PATH := $(ROOT)/$(OBJDIR)/bin:$(PATH)
export ROOT

# Build order: each entry depends on all prior entries.
# utils/iyacc must precede limbo (grammar files), limbo must precede libinterp.
# utils/data2c and utils/ndate must precede emu (used during emu link).
EMUDIRS := \
	lib9        \
	libbio      \
	libmp       \
	libsec      \
	libmath     \
	utils/iyacc \
	limbo       \
	libinterp   \
	libkeyring  \
	libdraw     \
	libprefab   \
	libtk       \
	libfreetype \
	libmemdraw  \
	libmemlayer \
	utils/data2c \
	utils/ndate \
	emu

# The Limbo source tree.  appl/mkfile descends (via mksubdirs) into acme,
# charon, cmd, lib, math, wm, ... and each leaf compiles its .b to .dis and
# installs them under $(ROOT)/dis/.
APPLDIR := appl

.PHONY: all emu dis clean nuke test_all_unit lint lint-update lint-all

# C unit tests for the host libraries (tests/cunit/<section>/test_*.c).
#   make test_lib9_unit      run one section's tests
#   make test_all_unit       run every section that has tests
# Tests link against the already-built static libs in $(OBJDIR)/lib, so build
# the C side first (make emu / make all).
TEST_RUN := ROOT=$(ROOT) OBJDIR=$(OBJDIR) sh $(ROOT)/tests/cunit/run.sh

# Full system: C side first (so the limbo compiler exists), then the Dis tree.
all: emu dis
	@echo
	@echo "Build complete (emu + Dis tree): $(ROOT)/$(OBJDIR)/bin/$(CONF)"

emu:
	@set -e; \
	for dir in $(EMUDIRS); do \
		echo; \
		echo "=== $$dir ==="; \
		if [ "$$dir" = "emu" ]; then \
			(cd $(ROOT)/$$dir && $(MK) $(EMUARGS) clean); \
			(cd $(ROOT)/$$dir && $(MK) $(EMUARGS) install); \
		else \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) nuke); \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) install); \
		fi; \
	done
	@echo
	@echo "C build complete: $(ROOT)/$(OBJDIR)/bin/$(CONF)"

# Compile the Limbo source tree to .dis with the freshly built compiler.
# Requires the C side (the limbo binary) to be built first; `make all` ensures
# this, or run `make emu` before `make dis`.  nuke clears stale .dis (in both
# the source dirs and dis/) so the tree is rebuilt clean from source.
dis:
	@echo; echo "=== appl (Dis tree -> $(ROOT)/dis) ==="
	@set -e; \
	(cd $(ROOT)/$(APPLDIR) && $(MK) $(MKARGS) nuke); \
	(cd $(ROOT)/$(APPLDIR) && $(MK) $(MKARGS) install)
	@echo
	@echo "Dis tree complete: $(ROOT)/dis"

clean:
	@set -e; \
	for dir in $(EMUDIRS); do \
		echo "--- clean $$dir ---"; \
		(cd $(ROOT)/$$dir && $(MK) $(MKARGS) clean) || true; \
	done
	@echo "--- clean $(APPLDIR) ---"
	@(cd $(ROOT)/$(APPLDIR) && $(MK) $(MKARGS) clean) || true

nuke:
	@set -e; \
	for dir in $(EMUDIRS); do \
		echo "--- nuke $$dir ---"; \
		if [ "$$dir" = "emu" ]; then \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) clean) || true; \
		else \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) nuke) || true; \
		fi; \
	done
	@echo "--- nuke $(APPLDIR) ---"
	@(cd $(ROOT)/$(APPLDIR) && $(MK) $(MKARGS) nuke) || true

# Run a single section's unit tests, e.g. `make test_lib9_unit`.
test_%_unit:
	@$(TEST_RUN) $*

# Run every section that has a tests/cunit/<section>/ directory.
test_all_unit:
	@secs=`for d in $(ROOT)/tests/cunit/*/; do [ -d "$$d" ] && basename "$$d"; done`; \
	$(TEST_RUN) $$secs

# clang -Wshorten-64-to-32 narrowing lint (LP64 bug class). Replays the real
# per-file compile flags through clang; diffs against tests/lint/baseline.txt.
#   make lint          report NEW narrowings vs baseline (nonzero if any)
#   make lint-all      list every narrowing site
#   make lint-update   regenerate the baseline (after triaging)
# Requires clang and a built tree (make emu) so `mk -n -a` can report flags.
LINT_RUN := $(MKARGS) MK=$(MK) sh $(ROOT)/tests/lint/run.sh

lint:
	@$(LINT_RUN)

lint-all:
	@$(LINT_RUN) --all

lint-update:
	@$(LINT_RUN) --update
