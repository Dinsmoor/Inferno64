#!/bin/sh
# libcache.sh -- content-signature cache for the heavy *vendored* C libraries
# (libfreetype, libmbedtls, libstb).  These are third-party trees that only
# change when their source is manually updated, yet they dominate the C build
# time.  The top-level Makefile uses this to skip rebuilding one when nothing
# that could affect its output has changed -- WITHOUT the stale-object risk that
# made us distrust mk's incremental tracking.
#
# Safety model: the signature is a CONTENT hash (not mtime, which is unreliable
# across checkouts/worktrees) folding in EVERY input that can change the .a:
#   1. every source file under the lib dir, BY PATH (so add/remove/rename/edit
#      of any vendored file -- i.e. a dependency UPDATE -- changes the sig);
#   2. the Inferno headers the thin wrapper files include ($ROOT/include and the
#      per-ABI $ROOT/$SYSTARG/$OBJTYPE/include);
#   3. the arch mkfile (CFLAGS / OLEVEL / MTUNE / DBGFLAGS);
#   4. the profile / ABI / CONF;
#   5. the compiler identity (gcc --version).
# Any difference -> a different signature -> a different cache slot.
#
# Multi-slot cache: each distinct signature gets its OWN slot directory under
# $ROOT/$SYSTARG/$OBJTYPE/libcache/<lib>-<sig>/ holding the lib's compiled
# objects (*.o).  The Makefile restores those objects into the lib's build dir
# on a hit (so mk re-archives the right ones without recompiling) and stores
# them after a build.  Objects -- not the .a -- because the emu link re-archives
# each vendored lib from its build-dir objects as a prerequisite, and mk can't
# see a debug<->release flip (the flags are CLI overrides, not a file change),
# so the .a alone would be regenerated from whatever objects are lying around.
# Because slots are keyed by signature, the debug and release objects of a lib
# coexist, so a `make check` that flips debug->release->debug restores the debug
# objects on the way back instead of recompiling them a third time.  Objects are
# copied into a slot only AFTER a successful build (see the Makefile), so an
# interrupted build can never leave a "valid" slot over half-built objects.
#
# Usage:
#   libcache.sh sig <libdir>    print the current signature (hex)
#   libcache.sh slot <libdir>   print the cache-slot directory path for it
# Requires env: ROOT, SYSTARG, OBJTYPE; optional: PROFILE, CONF, CC.

set -eu

cmd=${1:-}
dir=${2:-}

: "${ROOT:?libcache.sh: ROOT not set}"
: "${SYSTARG:?libcache.sh: SYSTARG not set}"
: "${OBJTYPE:?libcache.sh: OBJTYPE not set}"

incdirs="include $SYSTARG/$OBJTYPE/include"
archmk="mkfiles/mkfile-$SYSTARG-$OBJTYPE"
# Compiler identity: prefer the CC named in the arch mkfile, else gcc.
cc=$(sed -n 's/^CC=[ 	]*//p' "$ROOT/$archmk" 2>/dev/null | awk '{print $1}')
[ -n "${cc:-}" ] || cc=gcc

compute_sig() {  # <libdir> -> hex signature on stdout
	cd "$ROOT"
	{
		# 1. the lib's own source, hashed with paths (rename/add/remove sensitive).
		#    Exclude build outputs (*.o/*.a) so only INPUTS feed the signature.
		find "$1" -type f \
			\( -name '*.c' -o -name '*.h' -o -name '*.s' -o -name '*.S' \
			   -o -name '*.cpp' -o -name '*.cc' -o -name 'mkfile' \) \
			| LC_ALL=C sort | xargs -r sha256sum
		# 2. Inferno headers (the wrapper files include lib9.h etc).
		for inc in $incdirs; do
			[ -d "$inc" ] && find "$inc" -type f -name '*.h' \
				| LC_ALL=C sort | xargs -r sha256sum
		done
		# 3. build flags.
		[ -f "$archmk" ] && cat "$archmk"
		# 4. profile / ABI / conf.
		printf 'PROFILE=%s OBJTYPE=%s CONF=%s\n' "${PROFILE:-}" "$OBJTYPE" "${CONF:-}"
		# 5. compiler identity.
		"$cc" --version 2>/dev/null | head -1 || true
	} | sha256sum | awk '{print $1}'
}

case "$cmd" in
sig)
	[ -n "$dir" ] || { echo "libcache.sh sig: need a libdir" >&2; exit 2; }
	compute_sig "$dir"
	;;
slot)
	[ -n "$dir" ] || { echo "libcache.sh slot: need a libdir" >&2; exit 2; }
	sig=$(compute_sig "$dir")
	printf '%s/%s/%s/libcache/%s-%s\n' "$ROOT" "$SYSTARG" "$OBJTYPE" "$(basename "$dir")" "$sig"
	;;
*)
	echo "usage: libcache.sh {sig|slot} <libdir>" >&2
	exit 2
	;;
esac
