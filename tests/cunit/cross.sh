#!/usr/bin/env bash
#
# cross.sh OBJTYPE [section...] -- the cross-ABI canary.
#
# Cross-builds the portable C libraries for Linux/<OBJTYPE> with that
# arch's mkfile toolchain (mkfiles/mkfile-Linux-<OBJTYPE>), then compiles
# and runs the cunit sections under qemu-user.  This is what keeps the
# 32-bit ILP32 ABI (arm) and big-endian byte order (m68k) honest while
# every developer machine is 64-bit little-endian:
#
#   tests/cunit/cross.sh arm        # ILP32 LE canary (32-bit ABI still works)
#   tests/cunit/cross.sh m68k       # ILP32 BE canary (byte order still works)
#
# Object files use the arch's Plan 9 letter ($O: 5=arm, 2=68020), so the
# cross objects coexist with the host build's *.o in the same source
# dirs -- no clean/nuke dance, no stale-ABI contamination either way.
#
# Scope: the portable, generated-header-free libs (lib9 libbio libmp
# libsec libmath).  libinterp/libdraw stay host-only: their builds want
# per-ABI generated module headers, which must not be regenerated for a
# foreign ABI in a live tree.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}
OBJTYPE=${1:?usage: cross.sh OBJTYPE [section...]}
shift
SECTIONS=${@:-"lib9 libbio libmp libsec libmath"}
LIBS="lib9 libbio libmp libsec libmath"

ARCHMK=$ROOT/mkfiles/mkfile-Linux-$OBJTYPE
[ -f "$ARCHMK" ] || { echo "cross.sh: no arch mkfile $ARCHMK" >&2; exit 2; }
CCBIN=$(sed -n 's/^CC=[ \t]*//p' "$ARCHMK" | awk '{print $1}')

case $OBJTYPE in
arm)  QEMU="qemu-arm -L /usr/arm-linux-gnueabihf";;
m68k) QEMU="qemu-m68k -L /usr/m68k-linux-gnu";;
386)  QEMU="qemu-i386 -L /usr/lib/i386-linux-gnu";;
*)    echo "cross.sh: no qemu-user mapping for '$OBJTYPE'" >&2; exit 2;;
esac

command -v "$CCBIN" >/dev/null || {
	echo "cross.sh: $CCBIN not installed (apt install gcc-...-linux-gnu*)" >&2; exit 2; }
command -v "${QEMU%% *}" >/dev/null || {
	echo "cross.sh: ${QEMU%% *} not installed (apt install qemu-user)" >&2; exit 2; }

# host mk drives the cross build, same as any other OBJTYPE
HOSTM=$(uname -m | sed 's/arm64/aarch64/; s/x86_64/amd64/')
MK=$ROOT/Linux/$HOSTM/bin/mk
[ -x "$MK" ] || { echo "cross.sh: $MK missing (make all first)" >&2; exit 2; }
PATH=$ROOT/Linux/$HOSTM/bin:$PATH	# lib mkfiles recurse with a bare `mk`
# tree-wide parallelism default: nproc-1 clamped to >= 1 (mk reads $NPROC)
if [ -z "${NPROC:-}" ]; then
	n=$(nproc 2>/dev/null || echo 1)
	NPROC=$(( n > 1 ? n - 1 : 1 ))
fi
export NPROC

mkdir -p "$ROOT/Linux/$OBJTYPE/lib"
echo "cross.sh: building $LIBS for Linux/$OBJTYPE ($CCBIN)"
for lib in $LIBS; do
	(cd "$ROOT/$lib" && "$MK" ROOT="$ROOT" SYSHOST=Linux SYSTARG=Linux OBJTYPE="$OBJTYPE" install >/dev/null) || {
		echo "cross.sh: $lib failed to build for $OBJTYPE" >&2; exit 1; }
done

exec env ROOT="$ROOT" OBJDIR="Linux/$OBJTYPE" RUN="$QEMU" \
	sh "$SCRIPT_DIR/run.sh" $SECTIONS
