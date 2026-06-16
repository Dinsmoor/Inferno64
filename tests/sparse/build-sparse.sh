#!/bin/sh
#
# tests/sparse/build-sparse.sh — fetch + build the `sparse` semantic checker
# (Linus Torvalds' C front-end) into tests/sparse/.sparse/, no system install.
#
# sparse is not packaged here and we have no root; it is a small self-contained
# checker that builds with the host gcc and runs in-place.  The Dis-pointer /
# LP64 width analysis (tests/sparse/run.sh) drives this binary.
#
# Usage: sh tests/sparse/build-sparse.sh   ->  prints the path to the binary.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DEST=$HERE/.sparse
BIN=$DEST/sparse
REPO=https://git.kernel.org/pub/scm/devel/sparse/sparse.git

if [ -x "$BIN" ]; then
	echo "$BIN"
	exit 0
fi

if ! command -v git >/dev/null 2>&1; then
	echo "build-sparse: git not found" >&2; exit 2
fi

rm -rf "$DEST.src"
echo "build-sparse: cloning sparse ..." >&2
git clone --depth 1 "$REPO" "$DEST.src" >&2 2>&1 || { echo "build-sparse: clone failed" >&2; exit 2; }
echo "build-sparse: building sparse ..." >&2
( cd "$DEST.src" && make sparse ) >&2 2>&1 || { echo "build-sparse: make failed" >&2; exit 2; }
mkdir -p "$DEST"
cp "$DEST.src/sparse" "$BIN"
rm -rf "$DEST.src"
echo "$BIN"
