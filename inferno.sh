#!/bin/sh
# Launch a graphical Inferno session (emu + the wm window manager).
#
# The tree is relocatable: emu's compiled-in root is mkconfig's ROOT
# (/usr/inferno), but $INFERNO overrides it at run time, so this script points
# emu at whichever directory the script itself lives in.  Nothing needs to be
# installed under /usr/inferno.
#
# Usage:
#   ./inferno.sh                  graphical session at the default size
#   ./inferno.sh -g1920x1080      pick the window size
#   ./inferno.sh -H2              HiDPI: integer-scale the host window 2x
#   ./inferno.sh -c               drop to a plain shell, no window manager
#   ./inferno.sh pleromussy      run a program by bare name (resolved below)
#   ./inferno.sh /dis/sh.dis      run some other Dis program instead of wm
#   ./inferno.sh --build         rebuild the tree first, then start
#   ./inferno.sh --install-desktop add an "Inferno" entry to the desktop menu
#
# Any option not listed above is passed straight through to emu; see the
# "Usage: emu" text in emu/port/main.c for the full set.
#
# To shut the session down: ^\ (Ctrl-\) at the terminal emu was started from,
# or the Power item in the wm start menu.

set -e

# Resolve this script's directory, following symlinks, so the launcher works
# from anywhere (a .desktop file, a $PATH symlink, another working directory).
self=$0
while [ -L "$self" ]; do
	link=$(readlink "$self")
	case $link in
	/*)	self=$link ;;
	*)	self=$(dirname "$self")/$link ;;
	esac
done
ROOT=$(cd "$(dirname "$self")" && pwd)

# emu reads $INFERNO (then $ROOT) to locate the tree it serves as /.
INFERNO=$ROOT
export INFERNO

# Optional: register a freedesktop .desktop entry so the session can be started
# from the host's applications menu instead of a terminal.  Writes to the
# per-user directory only -- nothing is installed system-wide.
if [ "$1" = --install-desktop ]; then
	dir=${XDG_DATA_HOME:-$HOME/.local/share}/applications
	mkdir -p "$dir"

	# Install the Vita Nuova tree (the same glyph the wm toolbar's start button
	# uses) into the hicolor theme, at every size the desktop may ask for.
	icons=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor
	if [ -f "$ROOT/icons/inferno-icon.png" ]; then
		if command -v convert >/dev/null 2>&1; then
			for sz in 16 22 24 32 48 64 128 256; do
				mkdir -p "$icons/${sz}x${sz}/apps"
				convert "$ROOT/icons/inferno-icon.png" -resize ${sz}x${sz} \
					"$icons/${sz}x${sz}/apps/inferno.png" 2>/dev/null
			done
		else
			# No ImageMagick: install the 256px master at its native size only.
			mkdir -p "$icons/256x256/apps"
			cp "$ROOT/icons/inferno-icon.png" "$icons/256x256/apps/inferno.png"
		fi
		# Refreshing the theme cache is best-effort: it fails harmlessly when
		# the theme has no index.theme, and must not abort the install.
		if command -v gtk-update-icon-cache >/dev/null 2>&1; then
			gtk-update-icon-cache -f -t "$icons" >/dev/null 2>&1 || true
		fi
	fi
	cat > "$dir/inferno.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Inferno
Comment=Inferno OS graphical session (emu + wm)
Icon=inferno
Exec=$ROOT/inferno.sh
Path=$ROOT
Terminal=true
Categories=System;Emulator;
EOF
	# Terminal=true keeps a console attached: emu prints its shutdown hint there
	# and ^\ at that console is the documented way to stop the session.
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database "$dir" >/dev/null 2>&1 || true
	fi
	echo "installed $dir/inferno.desktop"
	exit 0
fi

# Host OS and architecture, in the spelling the build tree uses for its
# Linux/<objtype>/bin directories.
sys=$(uname -s)
case $(uname -m) in
x86_64|amd64)		objtype=amd64 ;;
aarch64|arm64)		objtype=aarch64 ;;
armv6l|armv7l)		objtype=arm ;;
i386|i486|i586|i686)	objtype=386 ;;
ppc|powerpc)		objtype=power ;;
*)			objtype=$(uname -m) ;;
esac

emu=$ROOT/$sys/$objtype/bin/emu

# On a fresh clone there is no emu yet (and no .dis tree: both are build output
# and neither is tracked).  Build them.  The root Makefile is the only coherent
# build -- it auto-bootstraps mk with the host gcc when no mk binary exists, and
# builds the C side and the Dis tree together; building just one half leaves a
# stale .dis tree against a freshly built compiler.  See AGENTS.md.
#
# --build forces a rebuild even when emu is already present.
if [ ! -x "$emu" ] || [ -n "${forcebuild:-}" ]; then
	if [ ! -x "$emu" ]; then
		echo "$0: no emu at $emu -- building (first run on a fresh clone)" >&2
	fi
	if ! command -v make >/dev/null 2>&1; then
		echo "$0: need 'make' to build; install it, or see AGENTS.md" >&2
		exit 1
	fi
	# OBJTYPE is passed explicitly: the Makefile derives its own default from
	# uname, and we must land in the same Linux/<objtype>/bin slot we look in.
	if ! (cd "$ROOT" && make OBJTYPE="$objtype" all); then
		echo "$0: build failed; see the output above" >&2
		exit 1
	fi
	if [ ! -x "$emu" ]; then
		echo "$0: build finished but still no emu at $emu" >&2
		exit 1
	fi
fi

# emu maps the host user to an Inferno user of the same name and expects a home
# directory for it; without one, wmsetup's $home is a dangling path and per-user
# config (lib/wmsetup, lib/menu, lib/warmup) silently does nothing.
user=${USER:-$(id -un)}
[ -d "$ROOT/usr/$user" ] || mkdir -p "$ROOT/usr/$user/lib"

# Flags go to emu; a bare name or path picks the program to run.  Defaults are
# only applied when the user did not ask for that option themselves.
geom=-g1024x768
opts=

# Resolve a bare program name ("pleromussy", "charon") to the name wm expects,
# so the whole path need not be typed.  Programs live in several directories:
# the GUI ones under /dis/wm, plain commands at /dis top level, and the rest in
# subdirectories (acme, charon, ndb, ...).  wm is searched first, since a bare
# name given to a graphical launcher almost always means the GUI program --
# wm/sh (a shell in a window) rather than /dis/sh.dis (the raw one).
#
# Echoes the resolved name in wm's own notation ("wm/pleromussy", "charon"),
# which is also what the toolbar's menu entries use.  Returns 1 if not found.
resolve_dis() {
	name=$1
	for dir in wm "" acme charon ndb auth disk fs ip lib svc usb; do
		if [ -n "$dir" ]; then
			if [ -f "$ROOT/dis/$dir/$name.dis" ]; then
				echo "$dir/$name"
				return 0
			fi
		else
			if [ -f "$ROOT/dis/$name.dis" ]; then
				echo "$name"
				return 0
			fi
		fi
	done
	return 1
}

# The program to run, in wm notation; empty means the default desktop (the
# toolbar and its start menu).
client=

for arg do
	case $arg in
	-g*)	geom=$arg ;;
	-c)	bare=1 ;;			# no window manager, just a shell
	--build)	forcebuild=1 ;;		# rebuild before starting
	-*)	opts="$opts $arg" ;;		# any other flag goes to emu
	/*|./*|../*|*.dis)
		# An explicit path is passed through to emu untouched.
		explicit=$arg ;;
	*)
		if client=$(resolve_dis "$arg"); then
			:
		else
			echo "$0: no Dis program named $arg" >&2
			echo "$0: looked for $arg.dis under $ROOT/dis (also dis/wm, dis/acme, ...)" >&2
			exit 1
		fi ;;
	esac
done

# A graphical session needs an X display.  Inferno's emu draws through Xlib, so
# under a pure Wayland session it needs Xwayland (normally already running).
if [ -z "${bare:-}" ] && [ -z "$DISPLAY" ]; then
	echo "$0: no \$DISPLAY set; a graphical session needs X (or Xwayland)" >&2
	echo "$0: for a non-graphical shell, run: $0 -c" >&2
	exit 1
fi

# Dispatch.  A named program runs as a client OF the window manager rather than
# instead of it: wm takes its client as an argument (defaulting to wm/toolbar,
# see appl/wm/wm.b:310), so the program gets a managed, resizable window and the
# usual desktop furniture.  Running it as emu's own top-level Dis file would
# leave it with no window manager to draw into.
if [ -n "${bare:-}" ]; then
	exec "$emu" $opts /dis/sh.dis
elif [ -n "${explicit:-}" ]; then
	exec "$emu" "$geom" $opts "$explicit"
elif [ -n "$client" ]; then
	exec "$emu" "$geom" $opts /dis/wm/wm.dis "$client"
else
	exec "$emu" "$geom" $opts /dis/wm/wm.dis
fi
