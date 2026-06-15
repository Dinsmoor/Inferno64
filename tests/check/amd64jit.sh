#!/usr/bin/env bash
#
# amd64jit.sh -- prove the x86-64 Dis JIT (libinterp/comp-amd64.c) is
# bit-identical to the interpreter, from a non-amd64 host, under qemu-x86_64.
#
# The dev box for this LP64 fork is aarch64, so the amd64 backend would
# otherwise never run in CI and could rot silently (it is off by default --
# `emu -c1` -- so a normal build never exercises it).  This cell:
#
#   1. cross-builds the amd64 emu-g with the x86_64 toolchain;
#   2. runs tests/check/amd64jit.dis under emu -c0 (interp) and -c1 (JIT);
#   3. requires byte-identical output.  A mismatch is a JIT codegen bug.
#
# Isolation: amd64 and aarch64 share Plan 9 object letter `o`, so a cross-build
# overwrites the host's *.o in the shared source dirs.  This cell therefore runs
# SERIALLY (it is grouped with the kernel cells in run.sh, never in a parallel
# lane) and rebuilds the host tree (`make all`) on exit.  The only mutated
# tracked file, mkfiles/mkfile-Linux-amd64, is restored via `git checkout`.
# Because of the host rebuild this cell is a couple of minutes -- like a kernel
# cell -- and is worth it: nothing else exercises the amd64 codegen at runtime.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${ROOT:-$(cd "$HERE/../.." && pwd)}"
cd "$ROOT" || exit 2

MKF="mkfiles/mkfile-Linux-amd64"
CROSS=x86_64-linux-gnu-
CC="${CROSS}gcc"
QEMU=qemu-x86_64
HOSTM=$(uname -m | sed 's/arm64/aarch64/; s/x86_64/amd64/')
LIMBO="$ROOT/Linux/$HOSTM/bin/limbo"

skip() { echo "1..0 # SKIP $*"; exit 0; }
command -v "$CC"   >/dev/null || skip "$CC not installed (apt install gcc-x86-64-linux-gnu)"
command -v "$QEMU" >/dev/null || skip "$QEMU not installed (apt install qemu-user)"
[ -x "$LIMBO" ] || { echo "Bail out! host limbo missing ($LIMBO) -- run 'make all'"; exit 2; }

# On amd64 itself there is no cross step and no contamination: just build+run.
NATIVE=0; [ "$HOSTM" = amd64 ] && NATIVE=1

WORK=$(mktemp -d)
built=0
cleanup() {
	git checkout -- "$MKF" 2>/dev/null || cp "$WORK/mkf.orig" "$MKF" 2>/dev/null
	# the cross-build wrote x86-64 *.o into the shared source dirs; rebuild the
	# host tree so the dev/gate tree is left pristine.
	if [ "$built" = 1 ] && [ "$NATIVE" = 0 ]; then
		echo "# restoring host tree (make all) ..."
		make all >"$WORK/restore.log" 2>&1 || echo "WARN: host restore failed -- run 'make all'" >&2
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT
cp "$MKF" "$WORK/mkf.orig"

EMU="$ROOT/Linux/amd64/bin/emu-g"
if [ "$NATIVE" = 0 ]; then
	# Patch the amd64 target mkfile: x86_64 cross toolchain + static link
	# (qemu-user has no dynamic loader for the guest).
	sed -i \
		-e "s#^AR=\t\tar#AR=\t\t${CROSS}ar#" \
		-e "s#^AS=\t\tgcc -c -m64#AS=\t\t${CC} -c -m64#" \
		-e "s#^CC=\t\tgcc -c -m64#CC=\t\t${CC} -c -m64#" \
		-e "s#^LD=\t\tgcc -m64#LD=\t\t${CC} -m64 -static#" \
		"$MKF"
	WRAP="$WORK/emu-g"
	{ echo '#!/bin/sh'; echo "exec $QEMU $EMU \"\$@\""; } >"$WRAP"; chmod +x "$WRAP"
else
	WRAP="$EMU"
fi

echo "# building amd64 emu-g ($([ $NATIVE = 1 ] && echo native || echo "$CC")) ..."
if ! make OBJTYPE=amd64 CONF=emu-g FORCE=1 emu >"$WORK/build.log" 2>&1; then
	echo "Bail out! amd64 emu-g build failed"; tail -30 "$WORK/build.log" | sed 's/^/  /'; exit 1
fi
built=1
[ -x "$EMU" ] || { echo "Bail out! built emu-g not found at $EMU"; exit 1; }

# Compile the fixture with the host limbo (the .dis wire format is arch-neutral)
# and place it where emu's namespace (rooted at $ROOT) can reach it.
DIS="$ROOT/tmp.amd64jit.dis"
if ! "$LIMBO" -I "$ROOT/module" -o "$DIS" "$HERE/amd64jit.b" >"$WORK/limbo.log" 2>&1; then
	echo "Bail out! fixture failed to compile"; sed 's/^/  /' "$WORK/limbo.log"; rm -f "$DIS"; exit 1
fi

run() {  # <flags> -> stdout (teardown noise stripped)
	timeout 240 "$WRAP" $1 -r"$ROOT" /dis/sh.dis -c "/tmp.amd64jit.dis" </dev/null 2>/dev/null \
		| grep -v 'to shut down'
}

echo "1..1"
C0=$(run "");  C1=$(run "-c1")
rm -f "$DIS"

if [ -z "$C0" ]; then
	echo "not ok 1 - amd64 JIT bit-identity (interpreter produced no output)"; exit 1
fi
if [ "$C0" = "$C1" ]; then
	echo "ok 1 - amd64 JIT bit-identical to interpreter ($(printf '%s\n' "$C0" | wc -l) lines)"
	exit 0
fi
echo "not ok 1 - amd64 JIT output differs from interpreter"
diff <(printf '%s\n' "$C0") <(printf '%s\n' "$C1") | sed 's/^/  /' | head -40
exit 1
