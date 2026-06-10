#!/bin/sh
# backport-to-lp64.sh -- cherry-pick master (ILP64) commits onto the parked
# `lp64` branch.
#
# master is ILP64 (Limbo int == pointer == Dis word == 8); `lp64` is the parked
# LP64 trunk (int stays 32-bit, only pointers widen). We keep lp64 alive only so
# userspace / .dis-tree / doc work can be carried back to it in case we ever
# switch ABIs again. Anything touching the width-sensitive C core or the
# C<->Limbo struct glue will NOT apply cleanly (or will be semantically wrong)
# across the two ABIs -- this script warns before each such commit.
#
# Usage:
#   tools/backport-to-lp64.sh <commit> [<commit> ...]
#   tools/backport-to-lp64.sh HEAD          # backport the commit you just made
#
# Run it from anywhere inside the master worktree. It cherry-picks (with -x, so
# the lp64 commit records the source SHA) into the lp64 worktree. On a conflict
# it stops; resolve in the lp64 worktree, then `git cherry-pick --continue`
# there (or `--abort`).
set -eu

if [ $# -eq 0 ]; then
	echo "usage: $0 <commit> [<commit> ...]" >&2
	exit 2
fi

# Locate the lp64 worktree from the shared repo's worktree list.
lp64dir=$(git worktree list --porcelain \
	| awk '/^worktree /{wt=$2} /^branch refs\/heads\/lp64$/{print wt}')
if [ -z "${lp64dir:-}" ] || [ ! -d "$lp64dir" ]; then
	echo "error: no worktree is on the 'lp64' branch." >&2
	echo "       create one:  git worktree add ../inferno-lp64 lp64" >&2
	exit 1
fi

# Refuse to start on a dirty lp64 worktree -- cherry-pick would be a mess.
if [ -n "$(git -C "$lp64dir" status --porcelain)" ]; then
	echo "error: lp64 worktree ($lp64dir) is dirty; commit/stash there first." >&2
	exit 1
fi

# Files that diverge for ABI reasons -- a cherry-pick touching these will
# conflict or be semantically wrong on LP64. Coarse but covers the ILP64 set.
hazard='^(include/(isa|interp|draw|tk)\.h|limbo/|libinterp/(comp-|das-|draw\.c|load\.c|runt\.c|tk\.c|raster3\.c)|libprefab/compound\.c|libtk/(ebind|menus)\.c|emu/port/devdraw\.c|appl/lib/styx\.b)'

for c in "$@"; do
	# resolve to a concrete SHA in THIS (source) repo -- a symbolic ref like
	# HEAD would otherwise resolve against the lp64 worktree in cherry-pick.
	csha=$(git rev-parse --verify "$c^{commit}" 2>/dev/null) || { echo "bad commit: $c" >&2; exit 1; }
	sha=$(git rev-parse --short "$csha")
	subj=$(git log -1 --format='%s' "$csha")
	echo "=== $sha  $subj"
	hits=$(git show --name-only --format= "$csha" | grep -E "$hazard" || true)
	if [ -n "$hits" ]; then
		echo "  !! ABI-sensitive files in this commit -- expect conflicts / wrong semantics on LP64:" >&2
		echo "$hits" | sed 's/^/       /' >&2
		printf '  Continue cherry-picking %s onto lp64 anyway? [y/N] ' "$sha" >&2
		read ans </dev/tty || ans=n
		case "$ans" in
		y|Y) ;;
		*) echo "  skipped $sha"; continue ;;
		esac
	fi
	if git -C "$lp64dir" cherry-pick -x "$csha"; then
		echo "  ok -> lp64"
	else
		echo "error: cherry-pick of $sha hit a conflict in $lp64dir." >&2
		echo "       resolve there, then: git -C $lp64dir cherry-pick --continue" >&2
		echo "       (or abort:           git -C $lp64dir cherry-pick --abort)" >&2
		exit 1
	fi
done

echo "done. lp64 is at $(git -C "$lp64dir" rev-parse --short HEAD); push with: git -C $lp64dir push"
