#!/dis/sh
#
# demo.sh - self-contained fault-isolation demo for sqlitefs.
# Run it inside Inferno (emu):  sh /path/to/demo.sh
#
# It (1) inserts rows into sqlite and reads them back, (2) CRASHES the host
# sqlite server with SIGSEGV - via the `os` cmd device - and keeps ticking a
# heartbeat to show emu stays alive while the queries fail, then restarts the
# server and (3) shows the rows survived the crash. The whole crash/recovery is
# driven from the script itself, so a plain `sh demo.sh` reproduces it with no
# external timing. See docs/ON_C_AT_RUNTIME.md.
#
# Prereqs: a sqlitefs server already running on the host (tcp 6701), and the
# Limbo client `sql` in /dis. The restart line below uses the host build path
# Linux/aarch64/bin/sqlitefs (relative to where emu was started) - adjust the
# OBJTYPE if your host is not aarch64.

load std

echo '=== sqlite over styx  (sqlite = a SEPARATE host C process) ==='
echo
echo '[1] insert rows, read them back:'
sql /tmp/demo.db 'drop table if exists t'                  >/dev/null >[2] /dev/null
sql /tmp/demo.db 'create table t(id integer, name text)'   >/dev/null >[2] /dev/null
sql /tmp/demo.db 'insert into t values(1,''hello''),(2,''world''),(3,''inferno'')' >/dev/null >[2] /dev/null
sql /tmp/demo.db 'select * from t order by id'
echo
echo '[2] crash the C server (os kill); emu keeps ticking, query just fails:'
os pkill -SEGV sqlitefs
for i in 1 2 3 4 5 6 {
	if {sql /tmp/demo.db 'select count(*) from t' >/dev/null >[2] /dev/null} {
		echo '   tick' $i '  emu ALIVE   sqlite ok'
	} {
		echo '   tick' $i '  emu ALIVE   sqlite DOWN (C crashed)'
	}
	if {~ $i 3} {
		echo '   ... restarting the C server (os) ...'
		os sh -c 'setsid Linux/aarch64/bin/sqlitefs -p 6701 >>/tmp/sqlitefs.log 2>&1 &'
		sleep 1
	}
	sleep 1
}
echo
echo '[3] rows survived the crash - add one and re-read:'
sql /tmp/demo.db 'insert into t values(4,''survived the crash'')' >/dev/null >[2] /dev/null
sql /tmp/demo.db 'select * from t order by id'
