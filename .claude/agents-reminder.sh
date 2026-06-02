#!/bin/sh
# SessionStart hook: surface the repo's durable-knowledge topic map ONCE per
# session so Claude consults the right AGENTS_*.md before deep work, without
# force-reading every file every turn.  (Lesson: reached for gdb/C-level
# instrumentation when AGENTS_DEBUGGING.md already documented /prog stack
# traces.)
cd /home/tyler/inferno-os 2>/dev/null || exit 0
[ -f ref/AGENTS_INPRO.md ] || exit 0
echo "Durable project knowledge lives in ref/AGENTS_*.md. Before deep debugging/building/graphics/etc., consult the relevant file (start: ref/AGENTS_INPRO.md). Do NOT read them all every turn — just the one that fits the task. Topic map:"
for f in ref/AGENTS_*.md; do
	[ -f "$f" ] || continue
	h=$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# *//')
	printf '  - %s — %s\n' "$f" "$h"
done
