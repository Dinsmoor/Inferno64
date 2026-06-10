#!/bin/sh
# PostToolUse(Bash) hook: after a `git commit` on master (ILP64), prompt Claude to
# judge whether the new commit can be backported to the parked `lp64` branch
# WITHOUT breaking LP64 semantics (the question is ABI/semantic compatibility, not
# "is it userspace"). The decision is Claude's; the hook only raises the question.
#
# Stays SILENT unless: the Bash command actually committed, HEAD is on master, and
# the commit touches at least one file that is NOT known to encode ILP64 semantics
# (a commit that is PURELY ABI-core can't apply across the int-width change, so
# there's nothing to weigh). Injected via PostToolUse additionalContext; never blocks.
set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Only react to commands that actually commit.
case "$cmd" in
	*"git commit"*) ;;
	*) exit 0 ;;
esac

# Only on master (the ILP64 trunk). Runs in whatever worktree the command used.
br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
[ "$br" = "master" ] || exit 0

files=$(git show --name-only --format= HEAD 2>/dev/null | sed '/^$/d')
[ -n "$files" ] || exit 0

# Files that encode ILP64 semantics and so can't be backported to LP64 as-is
# (mirror of the warn set in tools/backport-to-lp64.sh). A commit touching ONLY
# these has nothing to weigh -> stay silent. This is a coarse pre-filter, NOT the
# decision: a file outside this set can still carry ILP64-specific semantics, which
# is exactly what the prompt below asks Claude to judge.
hazard='^(include/(isa|interp|draw|tk)\.h|limbo/|libinterp/(comp-|das-|draw\.c|load\.c|runt\.c|tk\.c|raster3\.c)|libprefab/compound\.c|libtk/(ebind|menus)\.c|emu/port/devdraw\.c|appl/lib/styx\.b)'
total=$(printf '%s\n' "$files" | grep -c .)
core=$(printf '%s\n' "$files" | grep -Ec "$hazard")
[ "$total" -eq "$core" ] && exit 0   # purely ILP64-semantic -> nothing to weigh

subj=$(git show -s --format='%h %s' HEAD 2>/dev/null)
msg="Commit [$subj] landed on master (ILP64). Can it be backported to the parked lp64 branch WITHOUT breaking LP64 semantics? Safe when it does NOT depend on the ILP64 model (int == pointer == 64-bit) -- bug fixes, .dis/userspace, docs, and ABI-neutral C usually are; anything that assumes 64-bit int width, or the C<->Limbo struct layout that follows from it, is NOT. If it's compatible: tools/backport-to-lp64.sh HEAD (warns on ABI-core files, stops on conflicts). Skip if it's ILP64-specific."

printf '%s' "$msg" | jq -Rs '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}'
