# Term: a reusable VT100/ANSI terminal emulator widget.
#
# The emulator core (screen model + escape/CSI parser) is extracted from the
# old wm/vt and made embeddable: Term renders program output into an offscreen
# image shown in a Tk panel, and encodes keystrokes into terminal input.  It
# knows nothing about what is on the other end (a shell, a telnet/ssh session,
# a serial line) -- the embedder pumps bytes in via output() and reads encoded
# keys back through onkey().
#
# Contract (as for Tkwidgets): the widget does NOT spawn its own proc.  It owns
# a `chan of string` named `ev` that fires with each raw Tk key (%A); add it to
# your application's alt and, in the same proc, feed the result of onkey() to
# the process.  new() builds a frame at `path` but does not geometry-manage it.
#
# A convenience layer, Termio, wires a Term to a spawned command over a private
# /dev/cons (file2chan), so "put a shell in my window" is a few lines.

Terminal: module
{
	PATH:	con "/dis/lib/term.dis";

	FONT:	con "/fonts/pelm/unicode.9.font";	# default fixed-width font

	init:	fn();

	# A terminal widget.  Public use is via the methods; the fields are the
	# emulator state (Limbo exposes all adt fields) and should be treated as
	# private.
	Term: adt {
		top:	ref Tk->Toplevel;
		disp:	ref Draw->Display;
		path:	string;			# container frame path
		ppath:	string;			# panel path (path + ".p")
		ev:	chan of string;		# raw Tk key strings (%A) from the panel

		cols, rows:	int;		# screen size in cells
		font:	ref Draw->Font;
		cw, chh:	int;		# cell width / height in pixels
		img:	ref Draw->Image;	# offscreen render target
		pal:	array of ref Draw->Image;	# 16-colour solid tiles

		# cursor / cell state
		x, y:		int;
		y1, y2:		int;		# scroll region (top/bottom rows)
		mode, qmode:	int;		# DEC modes
		attr, fg, bg, ccc: int;		# current attributes + packed cell colour
		dx, dy, nlcr:	int;
		ox, oy:		int;		# last drawn cursor (for clean move)

		# saved cursor state (DECSC/DECRC, ESC 7/8)
		save_x, save_y, save_attr, save_fg, save_bg, save_mode, save_qmode: int;

		# escape parser state
		esc, pcount, etype, ptype, value: int;
		param:	array of int;

		# screen contents: one string of runes per row, one string of packed
		# colour bytes per row, plus a per-row dirty flag
		scr:	array of string;
		cc:	array of string;
		dirty:	array of int;
		pad:	string;

		# build a terminal of cols x rows at frame `path`; font "" uses FONT
		new:	fn(top: ref Tk->Toplevel, disp: ref Draw->Display,
				path: string, cols, rows: int, font: string): ref Term;
		# bind the offscreen image to the panel and paint.  Call ONCE after
		# tkclient->onscreen() -- the window image a panel needs is not valid
		# before then.
		show:	fn(t: self ref Term);
		# force a full repaint (e.g. on a Configure/expose event)
		redraw:	fn(t: self ref Term);
		# feed program output (escape sequences and text) and repaint;
		# returns any device reply the program asked for (usually ""),
		# which the caller should send back to the process
		output:	fn(t: self ref Term, s: string): string;
		# encode a Tk key string (%A, incl. the View/KF private-use runes)
		# into the bytes a terminal would send to the process
		onkey:	fn(t: self ref Term, key: string): string;
		# clear the screen and home the cursor
		clear:	fn(t: self ref Term);
		# pixel size the container frame wants (cols*cw, rows*chh)
		sizereq: fn(t: self ref Term): (int, int);
	};

	# Termio: a command (default: an interactive sh) wired to a Term over a
	# private /dev/cons.  `out` carries bytes to display (program output plus
	# cooked-mode echo); call send() to deliver a keystroke to the process.
	Termio: adt {
		out:	chan of string;
		inp:	chan of string;		# private: keystrokes to the process
		pid:	int;
		raw:	int;			# 1 while the process holds consctl raw

		send:	fn(tio: self ref Termio, s: string);
	};

	# spawn `cmd` (e.g. "sh"::"-n"::nil) attached to a fresh /dev/cons and
	# return its Termio, or nil on failure.
	attach:	fn(ctxt: ref Draw->Context, cmd: list of string): ref Termio;
};
