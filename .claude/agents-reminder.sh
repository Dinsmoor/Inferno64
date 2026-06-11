#!/bin/sh
# SessionStart hook: surface the repo's durable-knowledge topic map ONCE per
# session so Claude consults the right docs/ON_*.md before deep work, without
# force-reading every file every turn.  (Lesson: reached for gdb/C-level
# instrumentation when docs/ON_DEBUGGING.md already documented /prog stack
# traces.)
cd /home/tyler/inferno-os 2>/dev/null || exit 0
[ -f docs/DEV_INPRO.md ] || exit 0
echo "Durable project knowledge lives in docs/ON_*.md (\"so you want to X\" topic references). Before deep debugging/building/graphics/etc., consult the relevant file (start: docs/DEV_INPRO.md — the live in-progress checklist; docs/ON_C_IN_DIS.md is the durable dual-ABI/LP64 reference). Do NOT read them all every turn — just the one that fits the task. Topic map:"
for f in docs/ON_*.md; do
	[ -f "$f" ] || continue
	h=$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# *//')
	printf '  - %s — %s\n' "$f" "$h"
done
