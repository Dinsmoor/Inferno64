#!/usr/bin/env bash
#
# headless_vnc.sh - run the Inferno64 desktop on a headless Linux host over VNC.
#
# Starts a VNC X server (TigerVNC's Xtigervnc, else x11vnc driving Xvfb), launches
# the Inferno window manager (wm/wm) on it with the GUI `emu`, and prints how to
# connect.  Built for hosted Linux; the GUI emu must already be built
# (Linux/<arch>/bin/emu - run `mk` in emu/Linux with CONF=emu if it is missing).
#
# Usage:
#   scripts/headless_vnc.sh [start|stop|status|restart]   (default: start)
#
# Environment knobs:
#   DISP=:N            force a specific X/VNC display (port = 5900 + N).  If unset,
#                      the first free display is chosen automatically.
#   GEOM=1280x800      screen geometry WxH
#   DEPTH=24           colour depth
#   VNC_BIND=local     'local' binds to 127.0.0.1 (use an SSH tunnel - default,
#                      recommended); 'lan' binds to all interfaces and REQUIRES a
#                      VNC password (~/.vnc/passwd, created with `vncpasswd`).
#   FAULTCRASH=1       max-sensitivity fault catching (default ON).  On a wild-
#                      address fault, emu dumps every Dis proc's stack to the emu
#                      log AND re-raises to drop a core at the exact C site, so
#                      "check the logs" after a crash gives a full backtrace plus
#                      a core for gdb.  Set FAULTCRASH=0 for a desktop that
#                      survives a single glitch (fault stays a soft Dis exception).
#                      Ordinary Limbo nil-derefs are unaffected (always soft).
#   WATCHDOG=60        seconds the VM may stall with work queued before emu dumps
#                      all procs (and aborts for a core if FAULTCRASH=1).  0
#                      disables.  An idle desktop never trips it (empty run queue).
#
# Security: this host may have public addresses, and VNC is unencrypted.  The
# default (VNC_BIND=local) is reachable only via localhost; connect through an
# SSH tunnel.  Only use VNC_BIND=lan on a trusted network, with a password set.

set -u

# --- locate the tree and the GUI emu -----------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

case "$(uname -m)" in
	x86_64|amd64)   ARCH=amd64 ;;
	aarch64|arm64)  ARCH=aarch64 ;;
	armv*|arm)      ARCH=arm ;;
	i?86)           ARCH=386 ;;
	*)              ARCH=$(uname -m) ;;
esac
EMU="$ROOT/Linux/$ARCH/bin/emu"
[ -x "$EMU" ] || EMU=$(ls "$ROOT"/Linux/*/bin/emu 2>/dev/null | head -n1)

# --- config -------------------------------------------------------------------
GEOM=${GEOM:-1280x800}
DEPTH=${DEPTH:-24}
VNC_BIND=${VNC_BIND:-local}
FAULTCRASH=${FAULTCRASH:-1}
WATCHDOG=${WATCHDOG:-60}
CMD=${1:-start}

# Where the kernel writes cores (from core_pattern), so we can surface them after
# a crash.  A leading '|' means cores are piped to a handler (eg systemd-coredump)
# -> use coredumpctl; an absolute pattern -> that directory; else emu's cwd.
COREDIR=""
core_info() {
	local pat
	pat=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)
	case "$pat" in
	'|'*) COREDIR="" ;;                                  # piped to a handler
	/*)   COREDIR=$(dirname "$pat"); mkdir -p "$COREDIR" 2>/dev/null ;;
	*)    COREDIR="emu working dir ($ROOT)" ;;
	esac
}

# Was a display explicitly requested?
if [ -n "${DISP:-}" ]; then DISP_EXPLICIT=1; else DISP_EXPLICIT=0; fi

RUNDIR="${TMPDIR:-/tmp}/inferno-vnc.$(id -un)"
mkdir -p "$RUNDIR"
STATEF="$RUNDIR/current"           # remembers the most recently started display N

say()   { printf '%s\n' "$*"; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }
alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
catf()  { [ -f "$1" ] && cat "$1" 2>/dev/null; }

# emu runs each kproc as a pthread (one TGID, many threads).  A plain SIGTERM to
# the leader pid can leave the leader a zombie while its sibling threads keep
# running -- which keeps the emu binary ETXTBSY (so a rebuild can't reinstall it)
# and leaves the desktop half-up.  emu_threads_alive/kill_emu reap the WHOLE
# thread group: TERM, wait, then escalate to SIGKILL on the TGID until /proc shows
# no surviving task threads.
emu_threads_alive() {  # $1 = tgid (== emu leader pid); true if any thread remains
	[ -n "${1:-}" ] && [ -d "/proc/$1/task" ] && [ -n "$(ls "/proc/$1/task" 2>/dev/null)" ]
}

kill_emu() {  # $1 = emu leader pid; returns 0 once every thread is gone
	local p=$1 i
	[ -n "$p" ] || return 0
	kill "$p" 2>/dev/null
	for i in $(seq 1 15); do emu_threads_alive "$p" || return 0; sleep 0.2; done
	kill -9 "$p" 2>/dev/null                       # leader (or a live sibling) gets SIGKILL
	for i in $(seq 1 15); do emu_threads_alive "$p" || return 0; sleep 0.2; done
	# last resort: signal each surviving thread id directly
	local t
	for t in $(ls "/proc/$p/task" 2>/dev/null); do kill -9 "$t" 2>/dev/null; done
	for i in $(seq 1 10); do emu_threads_alive "$p" || return 0; sleep 0.2; done
	return 1
}

sock_exists() { [ -S "/tmp/.X11-unix/X$1" ]; }

# Compute all per-display paths/vars from a display number.
set_disp() {
	N=$1
	DISP=":$N"
	PORT=$((5900 + N))
	XLOG="$RUNDIR/x$N.log"
	EMULOG="$RUNDIR/emu$N.log"
	XPIDF="$RUNDIR/x$N.pid"
	EMUPIDF="$RUNDIR/emu$N.pid"
	XVFBPIDF="$RUNDIR/xvfb$N.pid"
	XSOCK="/tmp/.X11-unix/X$N"
}

free_port() {  # $1 = N ; true if VNC port is free
	command -v ss >/dev/null 2>&1 || return 0
	! ss -ltn 2>/dev/null | grep -q ":$((5900 + $1)) "
}

# Choose the display: honour an explicit DISP, else first free :1..:20.
choose_display() {
	if [ "$DISP_EXPLICIT" = 1 ]; then
		local n=${DISP#:}
		set_disp "$n"
		return 0
	fi
	local n
	for n in $(seq 1 20); do
		if ! sock_exists "$n" && free_port "$n"; then set_disp "$n"; return 0; fi
	done
	die "no free X display in :1..:20 (set DISP=:N explicitly)"
}

# --- dependency check ---------------------------------------------------------
need_install() {
	cat >&2 <<EOF
error: no usable VNC server found.

Install x11vnc (needs sudo), then re-run this script:

    sudo apt-get install -y x11vnc xvfb

(x11vnc + Xvfb is the path that works with emu.  TigerVNC's own X server
makes emu fail with BadMatch, so it is only a last-resort fallback here.)

EOF
	exit 1
}

have_tiger()  { command -v Xtigervnc >/dev/null 2>&1; }
have_x11vnc() { command -v x11vnc >/dev/null 2>&1 && command -v Xvfb >/dev/null 2>&1; }

wait_for_x() {  # $1 = server pid to watch
	local i
	for i in $(seq 1 50); do
		[ -S "$XSOCK" ] && return 0
		alive "$1" || return 1
		sleep 0.2
	done
	return 1
}

# --- start the VNC X server ---------------------------------------------------
start_xserver() {
	have_tiger || have_x11vnc || need_install

	local bindlocal=1
	[ "$VNC_BIND" = lan ] && bindlocal=0

	local pwfile="$HOME/.vnc/passwd"
	if [ "$bindlocal" -eq 0 ] && [ ! -f "$pwfile" ]; then
		die "VNC_BIND=lan needs a VNC password. Run 'vncpasswd' to create $pwfile, then retry."
	fi

	# Preferred: Xvfb + x11vnc.  emu's X11 backend renders cleanly on Xvfb;
	# x11vnc just scrapes that framebuffer over VNC, so there is no visual/
	# colormap negotiation to trip over.  (emu's older win-x11a.c picks a
	# visual that TigerVNC's own X server rejects with BadMatch, so the direct
	# Xtigervnc path below is a last resort and may not display.)
	if have_x11vnc; then
		Xvfb "$DISP" -screen 0 "${GEOM}x${DEPTH}" >"$XLOG" 2>&1 &
		echo $! >"$XVFBPIDF"
		wait_for_x "$(catf "$XVFBPIDF")" || { tail -n 20 "$XLOG" >&2; die "Xvfb failed to start (see $XLOG)"; }
		local auth bindopt
		if [ "$bindlocal" -eq 1 ]; then auth="-nopw"; bindopt="-localhost"; else auth="-rfbauth $pwfile"; bindopt=""; fi
		# shellcheck disable=SC2086
		# emu blits to the Xvfb framebuffer with XPutImage; use XDAMAGE plus
		# tight polling/defer timing so menus and window updates are pushed to
		# the VNC client promptly (the old -noxdamage build never refreshed past
		# the first frame for some clients).
		x11vnc -display "$DISP" -rfbport "$PORT" -forever -shared \
			-wait 10 -defer 10 \
			$bindopt $auth -bg -o "$RUNDIR/x11vnc$N.log" >/dev/null 2>&1 \
			|| die "x11vnc failed to start (see $RUNDIR/x11vnc$N.log)"
	elif have_tiger; then
		say "warning: only TigerVNC found; emu may fail with BadMatch on it." >&2
		say "         if the screen stays black, install x11vnc: sudo apt-get install -y x11vnc" >&2
		local sec localhostopt
		if [ "$bindlocal" -eq 1 ]; then
			sec="-SecurityTypes None"; localhostopt="-localhost"
		else
			sec="-SecurityTypes VncAuth -rfbauth $pwfile"; localhostopt=""
		fi
		# shellcheck disable=SC2086
		Xtigervnc "$DISP" -geometry "$GEOM" -depth "$DEPTH" -rfbport "$PORT" \
			-desktop "Inferno64" $localhostopt $sec >"$XLOG" 2>&1 &
		echo $! >"$XPIDF"
		wait_for_x "$(catf "$XPIDF")" || { tail -n 20 "$XLOG" >&2; die "Xtigervnc failed to start (see $XLOG)"; }
	else
		need_install
	fi
}

# --- start the Inferno desktop ------------------------------------------------
start_emu() {
	[ -n "$EMU" ] && [ -x "$EMU" ] || die "GUI emu not found under $ROOT/Linux/*/bin/emu (build: cd emu/Linux && mk install)"
	core_info
	# Let the faulting emu actually write a core (subshell ulimit propagates to
	# the backgrounded child).  Harmless if cores are piped to a handler.
	ulimit -c unlimited 2>/dev/null || true
	if [ "$FAULTCRASH" = 1 ]; then
		DISPLAY="$DISP" EMUCRASH=1 EMUWATCHDOG="$WATCHDOG" \
			"$EMU" -r"$ROOT" -g"$GEOM" wm/wm >"$EMULOG" 2>&1 &
	else
		DISPLAY="$DISP" EMUWATCHDOG="$WATCHDOG" \
			"$EMU" -r"$ROOT" -g"$GEOM" wm/wm >"$EMULOG" 2>&1 &
	fi
	echo $! >"$EMUPIDF"
	sleep 1
	alive "$(catf "$EMUPIDF")" || { tail -n 20 "$EMULOG" >&2; die "emu exited immediately (see $EMULOG)"; }
}

# --- connection instructions --------------------------------------------------
print_instructions() {
	local user host lan
	user=$(id -un)
	host=$(hostname 2>/dev/null || echo localhost)
	lan=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01]))' | head -n1)

	echo
	echo "=================================================================="
	echo " Inferno64 desktop is up on display $DISP  (VNC port $PORT)"
	echo "=================================================================="
	echo " geometry : ${GEOM}x${DEPTH}     bind: $VNC_BIND"
	echo " emu      : $EMU"
	echo " logs     : $XLOG"
	echo "            $EMULOG"
	[ -z "$COREDIR" ] && core_info
	if [ "$FAULTCRASH" = 1 ]; then
		echo " faults   : EMUCRASH on, watchdog ${WATCHDOG}s -- on a crash, the emu log"
		echo "            holds a full Dis backtrace; a core lands in $COREDIR"
	else
		echo " faults   : EMUCRASH off (soft Dis exceptions), watchdog ${WATCHDOG}s"
	fi
	echo
	if [ "$VNC_BIND" = lan ]; then
		echo " Connect a VNC client (password required) to:"
		echo "     ${lan:-<this-host-LAN-IP>}:$PORT       (display ${lan:-HOST}:$N)"
		echo
		echo " WARNING: bound to all interfaces and unencrypted - trusted LANs only."
	else
		echo " Bound to localhost only. From your machine, open an SSH tunnel:"
		echo
		echo "     ssh -L $PORT:localhost:$PORT $user@${lan:-$host}"
		echo
		echo " then point your VNC client at:"
		echo "     localhost:$PORT       (display localhost:$N)"
	fi
	echo
	echo " Status:  $0 status        Stop:  $0 stop"
	echo "=================================================================="
}

ours_running() {  # is our emu for display N alive?
	alive "$(catf "$EMUPIDF")"
}

# --- commands -----------------------------------------------------------------
do_start() {
	# Reuse our own existing session if one is recorded and still alive.
	if [ "$DISP_EXPLICIT" = 0 ] && [ -f "$STATEF" ]; then
		set_disp "$(catf "$STATEF")"
		if ours_running; then say "Inferno64 already running on $DISP; reusing."; print_instructions; return; fi
	fi

	choose_display

	if sock_exists "$N" && ! ours_running; then
		die "display $DISP is already in use by another X server. Choose a free one, e.g. DISP=:7 $0 start"
	fi

	start_xserver
	start_emu
	echo "$N" >"$STATEF"
	print_instructions
}

resolve_target() {  # for stop/status: explicit DISP, else recorded current, else :1
	if [ "$DISP_EXPLICIT" = 1 ]; then set_disp "${DISP#:}";
	elif [ -f "$STATEF" ]; then set_disp "$(catf "$STATEF")";
	else set_disp 1; fi
}

do_stop() {
	resolve_target
	local p
	p=$(catf "$EMUPIDF")
	if alive "$p" || emu_threads_alive "$p"; then
		if kill_emu "$p"; then say "stopped emu ($p)"
		else say "warning: emu ($p) has threads that would not die (see ps -L $p)" >&2; fi
	fi
	command -v x11vnc >/dev/null 2>&1 && pkill -f "x11vnc -display $DISP " 2>/dev/null && say "stopped x11vnc on $DISP"
	p=$(catf "$XPIDF");    alive "$p" && { kill "$p" 2>/dev/null; say "stopped Xtigervnc ($p)"; }
	p=$(catf "$XVFBPIDF"); alive "$p" && { kill "$p" 2>/dev/null; say "stopped Xvfb ($p)"; }
	rm -f "$EMUPIDF" "$XPIDF" "$XVFBPIDF"
	[ -f "$STATEF" ] && [ "$(catf "$STATEF")" = "$N" ] && rm -f "$STATEF"
	say "display $DISP torn down"
}

do_status() {
	resolve_target
	say "target display: $DISP  (VNC port $PORT)"
	if sock_exists "$N"; then say "  X server : UP (socket $XSOCK)"; else say "  X server : down"; fi
	if ours_running; then say "  emu/wm   : running (pid $(catf "$EMUPIDF"))"; else say "  emu/wm   : not running"; fi
	if command -v ss >/dev/null 2>&1; then
		ss -ltn 2>/dev/null | grep -q ":$PORT " && say "  VNC port : $PORT listening" || say "  VNC port : $PORT not listening"
	fi
	core_info
	if [ -d "$COREDIR" ]; then
		local c
		c=$(ls -t "$COREDIR"/core.* 2>/dev/null | head -n1)
		[ -n "$c" ] && say "  last core: $c  (gdb $EMU $c)"
	fi
}

case "$CMD" in
	start)   do_start ;;
	stop)    do_stop ;;
	restart) do_stop; sleep 1; DISP_EXPLICIT=$DISP_EXPLICIT do_start ;;
	status)  do_status ;;
	*)       die "usage: $0 [start|stop|status|restart]" ;;
esac
