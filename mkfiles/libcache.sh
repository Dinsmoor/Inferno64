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
# Any difference -> the Makefile nukes and rebuilds the lib, then re-stamps.
# The stamp is written only AFTER a successful build (see the Makefile), so an
# interrupted build can never leave a "valid" stamp over a half-built archive.
#
# Usage:
#   libcache.sh sig <libdir>     print the current signature (hex)
#   libcache.sh stampfile <lib>  print the stamp path for a lib dir
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

case "$cmd" in
sig)
	[ -n "$dir" ] || { echo "libcache.sh sig: need a libdir" >&2; exit 2; }
	cd "$ROOT"
	{
		# 1. the lib's own source, hashed with paths (rename/add/remove sensitive).
		#    Exclude build outputs (*.o/*.a) so only INPUTS feed the signature.
		find "$dir" -type f \
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
	;;
stampfile)
	[ -n "$dir" ] || { echo "libcache.sh stampfile: need a libdir" >&2; exit 2; }
	printf '%s/%s/%s/lib/.sig-%s\n' "$ROOT" "$SYSTARG" "$OBJTYPE" "$(basename "$dir")"
	;;
*)
	echo "usage: libcache.sh {sig|stampfile} <libdir>" >&2
	exit 2
	;;
esac
