#!/bin/sh
# PreToolUse(Bash) hook: before a `make`, warn if stale emu thread-groups are
# lingering. A 'Z' emu (Zsl/Zl in ps) is a MULTITHREADED ZOMBIE -- the group
# LEADER thread is defunct but its kproc sibling pthreads are still alive and
# keep the emu binary mapped, so `cp o.emu bin/emu` fails with ETXTBSY and the
# build aborts at the install step (cost a whole wasted build once).
#
# Fix: kill each lingering emu BY PID (kill -9 <pid>) -- that reaps the live
# siblings. Do NOT `pkill -x emu`: it also kills the live shared :3 desktop.
#
# Silent unless the command runs make AND emu processes are present.
set -u

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# Only react when make is in COMMAND POSITION -- at the start or after a shell
# separator (;, &, |, (, `), optionally behind nohup/time/env VAR=... . This
# avoids firing when "make" merely appears in prose (e.g. a commit message arg).
printf '%s' "$cmd" | grep -Eq '(^|[;&|(`])[[:space:]]*(nohup[[:space:]]+|time[[:space:]]+|env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*)?make([[:space:]]|$)' || exit 0

# Any emu processes around (zombie or live) that could hold the binary?
procs=$(ps -eo pid,stat,comm 2>/dev/null | awk '$3 ~ /^emu/ {print $1" ("$2")"}')
[ -n "$procs" ] || exit 0

list=$(printf '%s' "$procs" | tr '\n' ' ')
pids=$(printf '%s' "$procs" | awk '{print $1}' | tr '\n' ' ')
msg="Before this make: stale emu thread-group(s) present: ${list}. A 'Z' emu is a MULTITHREADED ZOMBIE -- the group leader is defunct but its kproc sibling threads still map the emu binary, so 'cp o.emu bin/emu' fails ETXTBSY and the build aborts at install. Kill them BY PID first: kill -9 ${pids}. Do NOT 'pkill -x emu' (kills the live shared :3 desktop). Then run make."

printf '%s' "$msg" | jq -Rs '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:.}}'
