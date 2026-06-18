implement Drawcheck;

#
# drawcheck - launch-time guard run by wmrun.  Given the program wmrun is about
# to start, statically inspect its Dis object: if its OWN code imports the raw
# display grabbers Display.allocate / Screen.allocate, it can paint over the
# whole screen with no managed window and no close box.  Warn the user (who may
# then need the wm panic key) and let them cancel.
#
#	drawcheck prog [args...]	# GUI: dialog; exit 0 = run, fail = cancel
#	drawcheck -q prog		# quiet: print CLEAN / GRAB <name>, never blocks
#
# Advisory only.  It sees capability, not behaviour, and a program can hide the
# call behind a helper module or a path built at run time.  A polite wm app does
# NOT trip this: it reaches the display through the window context or through
# tkclient->makedrawcontext, so the allocate lives in tkclient, not the app.
# See ON_GRAPHICS.md.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "dis.m";
	dis: Dis;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "dialog.m";
	dialog: Dialog;

Drawcheck: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

grabbers := array[] of { "Display.allocate", "Screen.allocate" };

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	argv = tl argv;				# drop "drawcheck"
	quiet := 0;
	if(argv != nil && hd argv == "-q"){
		quiet = 1;
		argv = tl argv;
	}
	if(argv == nil)
		exit;				# nothing to check -> allow
	prog := hd argv;

	dis = load Dis Dis->PATH;
	if(dis == nil)
		exit;				# can't inspect -> don't block the launch
	dis->init();

	path := dispath(prog);
	if(path == nil)
		exit;				# unresolved -> let the loader report it

	(m, nil) := dis->loadobj(path);
	if(m == nil)
		exit;				# unreadable -> allow

	hit := scan(m);
	if(hit == nil){
		if(quiet)
			sys->print("CLEAN\n");
		exit;				# clean -> allow silently
	}
	if(quiet){
		sys->print("GRAB %s\n", hit);
		exit;
	}

	# flagged: warn (needs a draw context for the dialog).
	draw = load Draw Draw->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	dialog = load Dialog Dialog->PATH;
	if(draw == nil || tkclient == nil || dialog == nil)
		exit;				# no UI -> allow rather than silently block
	tkclient->init();
	dialog->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	msg := prog + " can draw over the entire screen (it uses " + hit + ").\n\n" +
		"A program like this has no window and no close box.  If it misbehaves, " +
		"the wm panic key — press F12 three times, or write \"kill\" to " +
		"/chan/wmpanic — should kill it.  If the panic key fails too, you may be " +
		"left with an unrecoverable desktop.\n\nRun it anyway?";
	# labs index: 0 = Cancel, 1 = Run; default Cancel (the safe choice).
	if(dialog->prompt(ctxt, nil, "warning", "Full-screen program", msg, 0,
			"Cancel" :: "Run" :: nil) == 1)
		exit;				# Run -> status 0
	raise "fail:cancelled";			# Cancel -> nonzero status
}

scan(m: ref Dis->Mod): string
{
	for(i := 0; i < len m.imports; i++)
		for(j := 0; j < len m.imports[i]; j++)
			for(k := 0; k < len grabbers; k++)
				if(m.imports[i][j].name == grabbers[k])
					return grabbers[k];
	return nil;
}

dispath(prog: string): string
{
	p := prog;
	if(len p < 4 || p[len p-4:] != ".dis")
		p += ".dis";
	if(exists(p))
		return p;
	if(p[0] != '/'){
		q := "/dis/" + p;
		if(exists(q))
			return q;
	}
	return nil;
}

exists(p: string): int
{
	(ok, nil) := sys->stat(p);
	return ok == 0;
}
