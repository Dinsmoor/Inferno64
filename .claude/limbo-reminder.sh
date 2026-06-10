#!/bin/sh
# UserPromptSubmit hook: every turn, before writing/editing Limbo, point at the
# language reference and surface the reserved-word list.  Lesson (2026-06-06):
# fn / load / tl / hd were used as identifiers and cost several compile
# iterations -- they are KEYWORDS and cannot be variable or function names.
dir=$(CDPATH= cd "$(dirname "$0")/.." 2>/dev/null && pwd) || exit 0
ref="$dir/docs/ref/ON_LIMBO.md"
[ -f "$ref" ] || exit 0
cat <<EOF
[limbo-reminder] Writing or editing Limbo (.b/.m) this turn? Read $ref first.
Reserved words that CANNOT be identifiers (the recurring slip): fn load tl hd
len list to do or of self type pick array chan ref con alt case spawn tagof.
Don't read the whole ref every turn -- only when the task touches Limbo.
EOF
