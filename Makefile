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
# emu-g is the graphics-less emu configuration.  The full GUI emu config pulls
# in libfreetype, whose upstream sources are not vendored in this tree, so the
# CLI/headless build is the reliable target for running Limbo.
CONF    := emu-g
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
