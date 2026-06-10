#!/bin/sh
# PostToolUse(Bash) hook: after a `git commit` on master (ILP64), remind Claude
# to consider backporting the new commit to the parked `lp64` branch.
#
# Stays SILENT unless: the Bash command actually committed, HEAD is on master,
# and the commit touches something backportable (i.e. not PURELY the
# ABI-divergent C core, which won't apply across the int-width change). The
# nudge is injected via PostToolUse additionalContext; it never blocks.
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

# ABI-divergent files that won't backport cleanly to LP64 (mirror of the warn
# set in tools/backport-to-lp64.sh). A commit touching ONLY these is skipped.
hazard='^(include/(isa|interp|draw|tk)\.h|limbo/|libinterp/(comp-|das-|draw\.c|load\.c|runt\.c|tk\.c|raster3\.c)|libprefab/compound\.c|libtk/(ebind|menus)\.c|emu/port/devdraw\.c|appl/lib/styx\.b)'
total=$(printf '%s\n' "$files" | grep -c .)
core=$(printf '%s\n' "$files" | grep -Ec "$hazard")
[ "$total" -eq "$core" ] && exit 0   # purely ABI-core -> nothing to backport

subj=$(git show -s --format='%h %s' HEAD 2>/dev/null)
msg="Commit [$subj] just landed on master (ILP64). Consider whether its userspace/.dis/doc changes should also go to the parked lp64 branch. To backport: tools/backport-to-lp64.sh HEAD (it warns on ABI-core files and stops on conflicts). Ignore if this commit should not apply to LP64."

printf '%s' "$msg" | jq -Rs '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:.}}'
