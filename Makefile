# Reliable fresh-build wrapper for Inferno emu on aarch64.
#
# mk's dependency tracking is unreliable for incremental changes, so this
# Makefile always nukes object files before rebuilding each component.
# Build order matches EMUDIRS in the top-level mkfile.

ROOT    := $(realpath $(dir $(firstword $(MAKEFILE_LIST))))
SYSHOST := Linux
SYSTARG := Linux
OBJTYPE := aarch64
OBJDIR  := $(SYSTARG)/$(OBJTYPE)
MK      := $(ROOT)/$(OBJDIR)/bin/mk
MKARGS  := ROOT=$(ROOT) SYSHOST=$(SYSHOST) SYSTARG=$(SYSTARG) OBJTYPE=$(OBJTYPE)

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
	libdynld    \
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
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) clean); \
		else \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) nuke); \
		fi; \
		(cd $(ROOT)/$$dir && $(MK) $(MKARGS) install); \
	done
	@echo
	@echo "Build complete: $(ROOT)/$(OBJDIR)/bin/emu"

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
