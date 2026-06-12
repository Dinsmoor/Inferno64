#!/bin/sh
# run.sh SECTION ... -- compile and run the C unit tests for one or more
# library "sections" (lib9, libbio, libmp, libsec, libmath, ...).
#
# DUAL-ABI: this source tree targets both the 64-bit (LP64) and 32-bit (ILP32)
# Dis ABIs.  The tests must build and pass under either, so we do NOT hardcode a
# compiler or width here -- the C compiler and the -DLINUX_<ARCH> define are
# derived from the active architecture's mk file (mkfiles/mkfile-$SYSTARG-$OBJTYPE),
# the same settings the libraries themselves were built with.  Tests link
# against that arch's static libs under $OBJDIR/lib, and the arch's lib9.h sets
# the right widths (ulong/uintptr 32- or 64-bit; vlong/uvlong always 64-bit).
#
# Each section is a directory tests/cunit/<section>/ of test_*.c files; each is
# compiled against the section's lib (+ dependencies) and run.  A test prints
# "ALLPASS <name>" / "FAILED <name> <n>" as its last line (see cunit.h).  Exit
# status is non-zero if any test fails to build, run, or pass.
#
# Env (set by the Makefile, with sane defaults):
#   ROOT     repo root
#   OBJDIR   <SYSTARG>/<OBJTYPE>  (e.g. Linux/aarch64, Linux/386)
#   RUN      executor prefix for the test binaries — empty for native,
#            "qemu-arm -L /usr/arm-linux-gnueabihf" etc. for a cross
#            OBJDIR (see cross.sh)
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}
OBJDIR=${OBJDIR:-Linux/aarch64}
SYSTARG=${OBJDIR%/*}
OBJTYPE=${OBJDIR##*/}
LIBDIR=$ROOT/$OBJDIR/lib
ARCHMK=$ROOT/mkfiles/mkfile-$SYSTARG-$OBJTYPE
[ -f "$ARCHMK" ] || { echo "run.sh: no arch mkfile $ARCHMK" >&2; exit 2; }

# Derive the compiler+arch flags and the platform define from the arch mk file,
# so we compile tests exactly as the libraries were compiled.  CC= carries the
# driver and width flags (e.g. "gcc -c -march=armv8-a", "cc -c -m32"); drop the
# compile-only "-c" since we compile+link in one step.
CC=$(sed -n 's/^CC=[ \t]*//p' "$ARCHMK" | sed 's/ -c\( \|$\)/ /' )
PLATDEF=$(grep -oE '\-DLINUX_[A-Z0-9_]+' "$ARCHMK" | head -1)
[ -n "${CC:-}" ] || { echo "run.sh: could not derive CC from $ARCHMK" >&2; exit 2; }
INCL="-I$ROOT/$OBJDIR/include -I$ROOT/include -I$SCRIPT_DIR"
CFLAGS="-O $PLATDEF $INCL"

# Map a section to the link line (most-derived lib first, lib9 + -lm last).
libs_for() {
	case $1 in
	lib9)      echo "$LIBDIR/lib9.a -lm";;
	libbio)    echo "$LIBDIR/libbio.a $LIBDIR/lib9.a -lm";;
	libmp)     echo "$LIBDIR/libmp.a $LIBDIR/lib9.a -lm";;
	libsec)    echo "$LIBDIR/libsec.a $LIBDIR/libmp.a $LIBDIR/lib9.a -lm";;
	libmath)   echo "$LIBDIR/libmath.a $LIBDIR/lib9.a -lm";;
	libdraw)   echo "$LIBDIR/libdraw.a $LIBDIR/lib9.a -lm";;
	libmemdraw) echo "$LIBDIR/libmemdraw.a $LIBDIR/libmemlayer.a $LIBDIR/libdraw.a $LIBDIR/lib9.a -lm";;
	libmemlayer) echo "$LIBDIR/libmemlayer.a $LIBDIR/libmemdraw.a $LIBDIR/libdraw.a $LIBDIR/lib9.a -lm";;
	*)         echo "$LIBDIR/$1.a $LIBDIR/lib9.a -lm";;
	esac
}

echo "cunit: OBJDIR=$OBJDIR CC='$CC' $PLATDEF"
rc=0
for section in "$@"; do
	dir=$SCRIPT_DIR/$section
	[ -d "$dir" ] || { echo "skip $section (no tests/cunit/$section/)"; continue; }
	libs=$(libs_for "$section")
	out=$dir/.out
	mkdir -p "$out"
	echo "=== test_${section}_unit ==="
	for src in "$dir"/test_*.c; do
		[ -e "$src" ] || { echo "  (no test_*.c)"; break; }
		base=$(basename "$src" .c)
		bin=$out/$base
		if ! $CC $CFLAGS -o "$bin" "$src" "$SCRIPT_DIR/shim.c" $libs 2>"$out/$base.cc.log"; then
			echo "  CCERR $base"; sed 's/^/    /' "$out/$base.cc.log"; rc=1; continue
		fi
		# timeout: a unit test that loops is a FAIL, not a wedged gate
		if timeout 60 ${RUN:-} "$bin" >"$out/$base.run.log" 2>&1; then
			echo "  PASS  $(tail -1 "$out/$base.run.log")"
		else
			s=$?
			[ "$s" = 124 ] && echo "(timeout: killed after 60s)" >>"$out/$base.run.log"
			echo "  FAIL  $base"; sed 's/^/    /' "$out/$base.run.log"; rc=1
		fi
	done
done
exit $rc
