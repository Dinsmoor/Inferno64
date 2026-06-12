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
# Host C runtime flavour for the mk bootstrap (lib9/mk select *-$(SYSTYPE).c).
SYSTYPE := posix
OBJDIR  := $(SYSTARG)/$(OBJTYPE)
MK      := $(ROOT)/$(OBJDIR)/bin/mk
# emu is the full GUI configuration (X11 + libfreetype + libtk + libdraw).
# FreeType 2.13.2 is now vendored under libfreetype/libfreetype, the LP64
# graphics path (libmemdraw/libdraw word width) is fixed, and the desktop
# (wm/wm) runs, so the GUI build is the default.  Use CONF=emu-g for a
# graphics-less headless build (faster; what the tests/dis suite runs under).
CONF    := emu

# Build profiles.  PROFILE selects an optimization + arch + instrumentation
# bundle by overriding the arch mkfile's OLEVEL / MTUNE / DBGFLAGS on the mk
# command line (an mk command-line assignment wins over the mkfile's).  The
# mkfile defaults ARE the debug profile, so PROFILE=debug passes no override.
#
#   debug  (default)  -g -Og + DISPTRCHECK (GC pointer checker) + EMU_DEBUG_DEFAULTS
#                     (EMUCRASH dump+core on by default).  The find-the-bug build.
#   release           -g -O2, portable -march baseline, no instrumentation.
#   bleedingedge      -g -O3 -march=native, no instrumentation.  Host-tuned.
#
# Convenience targets `make debug|release|bleedingedge` (below) just re-invoke
# with PROFILE set; you can also say e.g. `make all PROFILE=release`.  Report
# RELATIVE benchmark numbers on debug builds (the checker taxes interp and JIT
# equally); use release/bleedingedge for absolute numbers.
PROFILE ?= debug
# Override values MUST be single tokens (no space, no '=') -- mk forwards
# command-line assignments into recursive sub-mk via $MKFLAGS without re-quoting,
# so a multi-word or '='-bearing value gets mangled in a subdir build.  Hence
# OLEVEL (opt level) and MTUNE (-march target; the '=' is in the mkfile's CFLAGS,
# not here) rather than a single OPTFLAGS/MARCH string.  See the arch mkfiles.
ifeq ($(PROFILE),debug)
PROF_MK :=
else ifeq ($(PROFILE),release)
PROF_MK := DBGFLAGS= OLEVEL=-O2
else ifeq ($(PROFILE),bleedingedge)
PROF_MK := DBGFLAGS= OLEVEL=-O3 MTUNE=native
else
$(error unknown PROFILE '$(PROFILE)'; use debug | release | bleedingedge)
endif
BUILDMODE := $(PROFILE)
MKARGS  := ROOT=$(ROOT) SYSHOST=$(SYSHOST) SYSTARG=$(SYSTARG) OBJTYPE=$(OBJTYPE) $(PROF_MK)
EMUARGS := $(MKARGS) CONF=$(CONF)

# Parallel compiles: mk runs up to $NPROC jobs concurrently within each
# directory. Default to all host CPUs minus one (clamped to >= 1) -- full
# parallel build while leaving one core of headroom for the desktop/editor.
# This same formula is the default for every build entry point in the tree
# (os/native.mk for the native kernels, the test drivers). Override with
# `make NPROC=8 all`.
NPROC   ?= $(shell n=$$(nproc 2>/dev/null || echo 1); j=$$((n-1)); [ $$j -ge 1 ] && echo $$j || echo 1)

export NPROC
export PATH := $(ROOT)/$(OBJDIR)/bin:$(PATH)
export ROOT

# Vendored-library cache (no third-party tools -- just make + the compiler +
# coreutils).  These are large third-party C trees that change only when their
# source is manually updated, yet they dominate the C build time.  For these,
# _emu skips the nuke+rebuild when a CONTENT signature of everything that could
# affect the archive is unchanged (see mkfiles/libcache.sh); any edit/add/remove
# of a vendored file, a header, a build flag, the ABI, or the compiler busts the
# signature and forces a full rebuild -- so a dependency update can't be served
# stale.  Everything else (incl. the toolchain-coupled limbo/libinterp/emu and
# the whole .dis tree) always rebuilds.  `make all NOCACHE=1` forces a full
# rebuild of these too; `make nuke`/`clean` drop the stamps.
CACHED_LIBS := libfreetype libmbedtls libstb
LIBCACHE    := $(ROOT)/mkfiles/libcache.sh
ifneq ($(NOCACHE),)
CACHED_LIBS :=
endif

# Build order.  Derived (not hand-copied) from the top-level mkfile's EMUDIRS
# block so `mk` and this wrapper can never disagree about what gets built -- a
# directory missing from the list is a silently-never-compiled component, the
# staleness class this build exists to prevent.  The order there encodes deps:
# utils/iyacc<limbo<libinterp, utils/{data2c,ndate}<emu.  If this extraction
# ever yields an empty list (mkfile reformatted), the build fails loudly below.
EMUDIRS := $(shell awk '/^EMUDIRS=/{f=1} f{l=$$0; sub(/^EMUDIRS=/,"",l); gsub(/\\/,"",l); print l} f&&$$0!~/\\$$/{exit}' $(ROOT)/mkfile)
ifeq ($(strip $(EMUDIRS)),)
$(error could not extract EMUDIRS from $(ROOT)/mkfile -- check the EMUDIRS block format)
endif

# The Limbo source tree.  appl/mkfile descends (via mksubdirs) into acme,
# charon, cmd, lib, math, wm, ... and each leaf compiles its .b to .dis and
# installs them under $(ROOT)/dis/.
APPLDIR := appl

.PHONY: all emu dis _emu _dis bootstrap guard-half clean nuke test_all_unit lint lint-update lint-all test_jitperf check debug release bleedingedge run help warn-running-emu

# Bare `make` builds the system.  Without this, GNU make's default goal would be
# the first target in the file ($(MK), the mk-bootstrap path target), so `make`
# with no args would silently do nothing useful -- a footgun (you'd think you
# built and then run a stale tree).  `make` == `make all`.
.DEFAULT_GOAL := all

# Bootstrap mk itself.  Chicken-and-egg: the whole build is driven by mk, but a
# fresh tree or git worktree has no mk binary yet (it is build output, not
# tracked).  makemk.sh compiles libregexp/libbio/lib9 and mk with the host
# gcc and installs mk into $(OBJDIR)/bin.  This rule fires automatically as a
# prerequisite of the build, but only when the mk binary is actually missing.
$(MK):
	@echo "=== bootstrapping mk (host gcc; no mk binary yet) ==="
	cd $(ROOT) && env ROOT=$(ROOT) SYSTARG=$(SYSTARG) OBJTYPE=$(OBJTYPE) SYSTYPE=$(SYSTYPE) sh makemk.sh

# Explicit entry point: `make bootstrap` (re)builds mk if it is missing.
bootstrap: $(MK)
	@echo "mk available: $(MK)"

# C unit tests for the host libraries (tests/cunit/<section>/test_*.c).
#   make test_lib9_unit      run one section's tests
#   make test_all_unit       run every section that has tests
# Tests link against the already-built static libs in $(OBJDIR)/lib, so build
# the C side first (make all).
TEST_RUN := ROOT=$(ROOT) OBJDIR=$(OBJDIR) sh $(ROOT)/tests/cunit/run.sh

# Full system: C side first (so the limbo compiler exists), then the Dis tree.
# This is the ONLY coherent build and should be your default.
all: warn-running-emu _emu _dis
	@echo "$(BUILDMODE)" > $(ROOT)/$(OBJDIR)/.buildmode
	@echo
	@echo "Build complete (emu + Dis tree, $(BUILDMODE)): $(ROOT)/$(OBJDIR)/bin/$(CONF)"

# Loud (non-fatal) warning if an emu is running while we rebuild the tree:
# overwriting its .dis/binaries underneath a live emu corrupts it and produces
# "fake" faults that look like real bugs.  We do NOT auto-kill (it may be a
# shared desktop) -- the user restarts it after the build.
warn-running-emu:
	@if command -v pgrep >/dev/null 2>&1 && pgrep -x emu >/dev/null 2>&1; then \
		echo "*****************************************************************" >&2; \
		echo "WARNING: an emu process is running while you rebuild this tree."   >&2; \
		echo "  Rebuilding changes its .dis/binaries underneath it and can"      >&2; \
		echo "  crash it with faults that look like real bugs.  Stop and"        >&2; \
		echo "  restart that emu AFTER this build finishes."                     >&2; \
		echo "*****************************************************************" >&2; \
	fi

# Build-profile convenience targets: a full `make all` in the named profile.
#   make debug          -g -Og + DISPTRCHECK + EMUCRASH-on  (default; find-the-bug)
#   make release        -g -O2, portable baseline, no instrumentation
#   make bleedingedge   -g -O3 -march=native, no instrumentation (host-tuned)
debug release bleedingedge:
	@$(MAKE) PROFILE=$@ all

# The easy "just try it" path: do a full coherent build (quietly) and open the
# Inferno graphical desktop.  It ALWAYS rebuilds (a full `make all`, which is
# cheap -- the vendored libs are content-cached) rather than launching whatever
# binary happens to be lying around -- so `make run` can never start a stale
# tree, and it honestly is the
# RUNPROFILE it claims (the old "only build if the binary is missing" launched a
# stale, mislabeled binary).  Override profile/size: make run RUNPROFILE=debug
# RUNGEOM=1920x1080.
RUNGEOM    ?= 1280x800
RUNPROFILE ?= bleedingedge
run:
	@if [ -z "$$DISPLAY" ]; then \
		echo "make run needs an X display, but \$$DISPLAY is empty." >&2; \
		echo "" >&2; \
		echo "On a headless box (no monitor / over SSH), run the desktop over VNC:" >&2; \
		echo "    make all && scripts/headless_vnc.sh" >&2; \
		echo "        starts Xvfb + a VNC server, launches the desktop, and prints" >&2; \
		echo "        exactly how to connect (SSH tunnel + VNC client).  scripts/headless_vnc.sh stop  tears it down." >&2; \
		echo "" >&2; \
		echo "Or skip the GUI entirely and get just a text shell:" >&2; \
		echo "    make all && ./$(OBJDIR)/bin/emu -r\"$(ROOT)\" /dis/sh.dis" >&2; \
		echo "" >&2; \
		echo "Otherwise, run 'make run' from a graphical desktop session." >&2; \
		exit 1; \
	fi
	@echo "Building Inferno ($(RUNPROFILE), full coherent build) ..."
	@if ! $(MAKE) PROFILE=$(RUNPROFILE) all >/tmp/inferno-build.log 2>&1; then \
		echo "build failed -- last 20 lines of /tmp/inferno-build.log:" >&2; \
		tail -20 /tmp/inferno-build.log >&2; \
		exit 1; \
	fi
	@echo "Starting the Inferno desktop ($(RUNGEOM)) ..."
	@$(ROOT)/$(OBJDIR)/bin/emu -r"$(ROOT)" -g$(RUNGEOM) wm/wm

# Half builds are GATED.  `make emu` (C side only) and `make dis` (Dis tree
# only) each leave the two halves out of sync -- a stale .dis against a freshly
# built compiler/ABI is the exact incoherence that caused the truncated-pointer
# crash (mismatched Transport signature).  So the bare targets refuse to run;
# the coherent path is `make all`.  To force a deliberate half build, opt in:
#   make emu FORCE=1
#   make dis FORCE=1
guard-half:
	@if [ -z "$(FORCE)" ]; then \
		echo "refusing half build '$(MAKECMDGOALS)': rebuilds only one half and" >&2; \
		echo "leaves emu and the .dis tree out of sync (stale-.dis ABI skew)." >&2; \
		echo "Use 'make all' (coherent full build), or force: make $(MAKECMDGOALS) FORCE=1" >&2; \
		exit 2; \
	fi

emu: guard-half _emu
dis: guard-half _dis

_emu: $(MK)
	@set -e; \
	cached=" $(CACHED_LIBS) "; \
	for dir in $(EMUDIRS); do \
		echo; \
		if [ "$$dir" = "emu" ]; then \
			echo "=== $$dir ==="; \
			(cd $(ROOT)/$$dir && $(MK) $(EMUARGS) clean); \
			(cd $(ROOT)/$$dir && $(MK) $(EMUARGS) install); \
		elif [ "$${cached#* $$dir }" != "$$cached" ]; then \
			stamp=`PROFILE='$(PROFILE)' CONF='$(CONF)' SYSTARG='$(SYSTARG)' OBJTYPE='$(OBJTYPE)' sh $(LIBCACHE) stampfile $$dir`; \
			sig=`PROFILE='$(PROFILE)' CONF='$(CONF)' SYSTARG='$(SYSTARG)' OBJTYPE='$(OBJTYPE)' sh $(LIBCACHE) sig $$dir`; \
			if [ -f "$$stamp" ] && [ "`cat "$$stamp"`" = "$$sig" ] && [ -f $(ROOT)/$(OBJDIR)/lib/$$dir.a ]; then \
				echo "=== $$dir (cached: unchanged, skipping rebuild) ==="; \
				continue; \
			fi; \
			echo "=== $$dir (vendored: cache miss -> full rebuild) ==="; \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) nuke); \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) install); \
			echo "$$sig" > "$$stamp"; \
		else \
			echo "=== $$dir ==="; \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) nuke); \
			(cd $(ROOT)/$$dir && $(MK) $(MKARGS) install); \
		fi; \
	done
	@echo
	@echo "C build complete: $(ROOT)/$(OBJDIR)/bin/$(CONF)"

# Compile the Limbo source tree to .dis with the freshly built compiler.
# Requires the C side (the limbo binary) to be built first; `make all` ensures
# that ordering.  nuke clears stale .dis (in both the source dirs and dis/) so
# the tree is rebuilt clean from source.
_dis: $(MK)
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
	@rm -f $(ROOT)/$(OBJDIR)/lib/.sig-* 2>/dev/null || true

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
	@rm -f $(ROOT)/$(OBJDIR)/lib/.sig-* 2>/dev/null || true

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
# Requires clang and a built tree (make all) so `mk -n -a` can report flags.
LINT_RUN := $(MKARGS) MK=$(MK) sh $(ROOT)/tests/lint/run.sh

lint:
	@$(LINT_RUN)

lint-all:
	@$(LINT_RUN) --all

lint-update:
	@$(LINT_RUN) --update

# JIT-vs-interpreter throughput benchmark: a pure-Limbo STFT spectrogram run
# under emu -c0 (interp), -c1 (JIT), and -c1 -B (JIT, no bounds checks), for
# both a float and a fixed-point kernel. Prints a speedup table and asserts the
# interp/JIT outputs are byte-identical. Needs a built tree (make all).
#   make test_jitperf            run the default battery
#   make test_jitperf ARGS=...   pass extra flags to the runner
test_jitperf:
	@sh $(ROOT)/tests/jitperf/runbench.sh $(ARGS)

# Pre-push gate.  Runs the per-platform capability matrix declared in
# tests/check/platforms/$(SYSTARG)-$(OBJTYPE).manifest: builds every required
# CONF (emu, emu-g, and a release link-check), runs every required test suite
# (cunit, dis+web under the declared run-modes, jitperf), and prints a
# PASS/FAIL/SKIP/TODO matrix.  Exits nonzero iff a `require' cell fails.  This is
# what catches a config that breaks only the headless build, or a release build
# that rots, before it reaches master.  Builds debug, does a release link-check,
# and restores the debug tree -- expect a few minutes.
#   make check       run the gate for the current platform
check:
	@ROOT=$(ROOT) SYSTARG=$(SYSTARG) OBJTYPE=$(OBJTYPE) MAKE='$(MAKE)' bash $(ROOT)/tests/check/run.sh

# Debug build of the "Valgrind for Dis pointers" checker (#5): rebuild
# libinterp's gc.c with -DDISPTRCHECK and relink emu. The result validates
# every GC-reachable Dis pointer slot (via its type's pointer map) against the
# live heap and reports a truncated/corrupt pointer the first GC after it is
# installed. Slow; debug only. Run `make all` afterwards to restore production.
.PHONY: emu-disptrcheck
emu-disptrcheck:
	@cc=`sed -n 's/^CC=[ 	]*//p' $(ROOT)/mkfiles/mkfile-$(SYSTARG)-$(OBJTYPE)`; \
	rm -f $(ROOT)/libinterp/gc.o $(ROOT)/emu/$(SYSTARG)/o.emu; \
	(cd $(ROOT)/libinterp && $(MK) $(MKARGS) "CC=$$cc -DDISPTRCHECK" install) && \
	(cd $(ROOT)/emu/$(SYSTARG) && $(MK) $(EMUARGS) install) && \
	echo "DISPTRCHECK emu installed at $(ROOT)/$(OBJDIR)/bin/$(CONF); run 'make all' to revert."

# Quick reference.  `make help` -> this.
help:
	@echo "Inferno build -- make wraps mk (mk compiles per component; make"
	@echo "orchestrates, sets the LP64 env, and bootstraps mk).  Current target:"
	@echo "  $(SYSTARG)/$(OBJTYPE)   profile=$(PROFILE)   CONF=$(CONF)"
	@echo
	@echo "Build:"
	@echo "  make            full coherent build (== make all), debug profile"
	@echo "  make release    full build, -O2 portable baseline, no instrumentation"
	@echo "  make bleedingedge  full build, -O3 -march=native"
	@echo "  make run        full build (RUNPROFILE=$(RUNPROFILE)) + launch the GUI desktop"
	@echo "                  (headless box? 'make all && scripts/headless_vnc.sh' runs it over VNC)"
	@echo
	@echo "Verify / maintain:"
	@echo "  make check      per-platform build+test gate (run before pushing)"
	@echo "  make test_all_unit   C unit tests      make lint   64->32 narrowing lint"
	@echo "  make clean      remove objects         make nuke   remove objects + .dis"
	@echo "  make bootstrap  (re)build mk if missing"
	@echo
	@echo "Override: OBJTYPE=amd64  CONF=emu-g  NPROC=8  PROFILE=...  NOCACHE=1"
	@echo
	@echo "Every build is a full nuke+rebuild of BOTH halves (C side + .dis tree)"
	@echo "on purpose: it is the only coherent build (a stale .dis against a freshly"
	@echo "built ABI is a real, debugged crash class).  Half builds (make emu / make"
	@echo "dis) are gated behind FORCE=1.  The heavy vendored libs (freetype, mbedtls,"
	@echo "stb) are skipped when a content signature shows them unchanged; any edit to"
	@echo "their source/headers/flags rebuilds them.  NOCACHE=1 forces a full rebuild."
