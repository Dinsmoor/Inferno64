# Reliable fresh-build wrapper for Inferno emu on aarch64.
#
# mk's dependency tracking is unreliable for incremental changes, so this
# Makefile always nukes object files before rebuilding each component.
# Build order matches EMUDIRS in the top-level mkfile.

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

.PHONY: all emu clean nuke

all emu:
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
	@echo "Build complete: $(ROOT)/$(OBJDIR)/bin/$(CONF)"

clean:
	@set -e; \
	for dir in $(EMUDIRS); do \
		echo "--- clean $$dir ---"; \
		(cd $(ROOT)/$$dir && $(MK) $(MKARGS) clean) || true; \
	done

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
