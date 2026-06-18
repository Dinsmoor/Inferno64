implement TkTtk;

#
# Headless functional test for the ttk parallel widget set and the
# ttk::style engine.  Run under a graphical emu (Xvfb).
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "wmclient.m";
	wmclient: Wmclient;

TkTtk: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

top: ref Tk->Toplevel;
mypid := 0;
nok := 0;
nfail := 0;

ok(desc: string, cond: int)
{
	if(cond){ nok++; sys->print("ok - %s\n", desc); }
	else { nfail++; sys->print("not ok - %s\n", desc); }
}

cmd(s: string): string
{
	return tk->cmd(top, s);
}

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	mypid = sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	tkclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	if(ctxt == nil){
		sys->fprint(sys->fildes(2), "tkttk: no window context\n");
		raise "fail:no ctxt";
	}
	(top, nil) = tkclient->toplevel(ctxt, "320x260", "tkttk", Tkclient->Appl);

	# build the widget set inside a ttk frame
	cmd("ttk::frame .f");
	cmd("ttk::label .f.l -text Hello");
	cmd("ttk::button .f.b -text Go -command {.f.l configure -text clicked}");
	cmd("ttk::checkbutton .f.c -text Check -variable cv -onvalue on -offvalue off");
	cmd("ttk::radiobutton .f.r1 -text A -variable rv -value a");
	cmd("ttk::radiobutton .f.r2 -text B -variable rv -value b");
	cmd("ttk::separator .f.s -orient horizontal");
	cmd("ttk::label .f.out -text -");
	cmd("pack .f.l .f.b .f.c .f.r1 .f.r2 .f.s .f.out");
	cmd("pack .f");
	cmd("update");

	# 1. classes
	ok("frame class TFrame", cmd("winfo class .f") == "TFrame");
	ok("label class TLabel", cmd("winfo class .f.l") == "TLabel");
	ok("button class TButton", cmd("winfo class .f.b") == "TButton");
	ok("check class TCheckbutton", cmd("winfo class .f.c") == "TCheckbutton");
	ok("radio class TRadiobutton", cmd("winfo class .f.r1") == "TRadiobutton");
	ok("separator class TSeparator", cmd("winfo class .f.s") == "TSeparator");

	# 2. button invoke runs -command
	cmd(".f.b invoke");
	cmd("update");
	ok("button invoke fired command", cmd(".f.l cget -text") == "clicked");

	# 3. state machine
	ok("starts in empty state", cmd(".f.b state") == "");
	cmd(".f.b state disabled");
	ok("instate disabled true", cmd(".f.b instate disabled") == "1");
	ok("instate !disabled false", cmd(".f.b instate {!disabled}") == "0");
	ok("state lists disabled", cmd(".f.b state") == "disabled");
	# disabled button does not invoke
	cmd(".f.l configure -text reset");
	cmd(".f.b invoke");
	ok("disabled button ignores invoke", cmd(".f.l cget -text") == "reset");
	cmd(".f.b state {!disabled}");
	ok("re-enabled", cmd(".f.b instate disabled") == "0");

	# 4. instate with a script
	cmd(".f.out configure -text no");
	cmd(".f.b instate {!disabled} {.f.out configure -text yes}");
	ok("instate runs script when matching", cmd(".f.out cget -text") == "yes");

	# 5. checkbutton toggles variable + selected state
	ok("check starts unselected", cmd(".f.c instate selected") == "0");
	cmd(".f.c invoke");
	cmd("update");
	ok("check variable set on", cmd("variable cv") == "on");
	ok("check now selected", cmd(".f.c instate selected") == "1");
	cmd(".f.c invoke");
	ok("check variable set off", cmd("variable cv") == "off");
	ok("check now unselected", cmd(".f.c instate selected") == "0");

	# 6. radiobutton sets shared variable
	cmd(".f.r2 invoke");
	ok("radio sets variable", cmd("variable rv") == "b");
	cmd(".f.r1 invoke");
	ok("radio re-sets variable", cmd("variable rv") == "a");

	# 7. ttk::style configure + lookup
	cmd("ttk::style configure TButton -foreground #ff0000");
	ok("style lookup returns configured value", cmd("ttk::style lookup TButton -foreground") == "#ff0000");

	# 8. ttk::style map (state-specific value)
	cmd("ttk::style map TButton -foreground {disabled #808080 active #00ff00}");
	ok("style map disabled", cmd("ttk::style lookup TButton -foreground disabled") == "#808080");
	ok("style map active", cmd("ttk::style lookup TButton -foreground active") == "#00ff00");
	ok("style map falls back to configure", cmd("ttk::style lookup TButton -foreground {}") == "#ff0000");

	# 9. style inheritance via dotted prefix
	cmd("ttk::style configure Danger.TButton -background #aa0000");
	ok("dotted style own option", cmd("ttk::style lookup Danger.TButton -background") == "#aa0000");
	ok("dotted style inherits parent", cmd("ttk::style lookup Danger.TButton -foreground") == "#ff0000");

	# 10. progressbar
	cmd("ttk::progressbar .f.p -maximum 100 -value 0 -length 120");
	cmd("pack .f.p");
	cmd("update");
	ok("progressbar class", cmd("winfo class .f.p") == "TProgressbar");
	cmd(".f.p configure -value 25");
	ok("progressbar value set", int cmd(".f.p cget -value") == 25);
	cmd(".f.p step 10");
	ok("progressbar step", int cmd(".f.p cget -value") == 35);
	cmd(".f.p configure -value 90");
	cmd(".f.p step 20");	# wraps modulo maximum (110 -> 10)
	ok("progressbar step wraps", int cmd(".f.p cget -value") == 10);

	# progressbar driven by a variable
	cmd("ttk::progressbar .f.p2 -variable pv -maximum 50");
	cmd("variable pv 20");
	cmd("update");
	ok("progressbar follows variable", int cmd(".f.p2 cget -value") == 20);

	# 11. labelframe
	cmd("ttk::labelframe .f.lf -text Group");
	cmd("ttk::label .f.lf.inner -text inside");
	cmd("pack .f.lf.inner");
	cmd("pack .f.lf");
	cmd("update");
	ok("labelframe class", cmd("winfo class .f.lf") == "TLabelframe");
	ok("labelframe title", cmd(".f.lf cget -text") == "Group");
	ok("labelframe holds child", has(cmd("winfo children .f.lf"), ".f.lf.inner"));

	# 12. ttk::entry - shares the classic editing core, themed chrome + state
	cmd("ttk::entry .f.e");
	cmd("pack .f.e");
	cmd("update");
	ok("entry class TEntry", cmd("winfo class .f.e") == "TEntry");
	cmd(".f.e insert 0 hello");
	ok("entry insert+get", cmd(".f.e get") == "hello");
	cmd(".f.e delete 0 1");
	ok("entry delete", cmd(".f.e get") == "ello");
	ok("entry style default TEntry", cmd(".f.e style") == "TEntry");
	cmd(".f.e configure -style Search.TEntry");
	ok("entry -style honoured", cmd(".f.e style") == "Search.TEntry");
	ok("entry starts !disabled", cmd(".f.e instate disabled") == "0");
	cmd(".f.e state readonly");
	cmd(".f.e insert 0 X");
	ok("readonly entry ignores insert", cmd(".f.e get") == "ello");
	cmd(".f.e state {!readonly}");
	cmd(".f.e insert 0 Y");
	ok("writable entry accepts insert", cmd(".f.e get") == "Yello");
	cmd(".f.e state disabled");
	ok("entry instate disabled", cmd(".f.e instate disabled") == "1");
	cmd(".f.e state {!disabled}");

	# 13. ttk::scrollbar - shares the classic core, flat themed chrome + state
	cmd("ttk::scrollbar .f.sb -orient vertical -command {.f.e xview}");
	cmd("pack .f.sb");
	cmd("update");
	ok("scrollbar class TScrollbar", cmd("winfo class .f.sb") == "TScrollbar");
	cmd(".f.sb set 0.0 0.5");
	ok("scrollbar set+get", cmd(".f.sb get") == "0 0.5");
	ok("scrollbar style default TScrollbar", cmd(".f.sb style") == "TScrollbar");
	cmd(".f.sb configure -style Vertical.TScrollbar");
	ok("scrollbar -style honoured", cmd(".f.sb style") == "Vertical.TScrollbar");
	ok("scrollbar starts !disabled", cmd(".f.sb instate disabled") == "0");
	cmd(".f.sb state disabled");
	ok("scrollbar instate disabled", cmd(".f.sb instate disabled") == "1");
	cmd(".f.sb state {!disabled}");
	ok("scrollbar instate !disabled", cmd(".f.sb instate disabled") == "0");

	# 14. ttk::scale - shares the classic core, flat themed trough/thumb + state
	cmd("ttk::scale .f.sc -orient horizontal -from 0 -to 100 -value 25");
	cmd("pack .f.sc");
	cmd("update");
	ok("scale class TScale", cmd("winfo class .f.sc") == "TScale");
	ok("scale -value initial", cmd(".f.sc get") == "25");
	cmd(".f.sc set 60");
	ok("scale set+get", cmd(".f.sc get") == "60");
	ok("scale style default TScale", cmd(".f.sc style") == "TScale");
	cmd(".f.sc configure -style Horizontal.TScale");
	ok("scale -style honoured", cmd(".f.sc style") == "Horizontal.TScale");
	ok("scale starts !disabled", cmd(".f.sc instate disabled") == "0");
	cmd(".f.sc state disabled");
	ok("scale instate disabled", cmd(".f.sc instate disabled") == "1");
	cmd(".f.sc state {!disabled}");

	# 15. ttk::sizegrip - a themed resize-handle decoration
	cmd("ttk::sizegrip .f.sg");
	cmd("pack .f.sg");
	cmd("update");
	ok("sizegrip class TSizegrip", cmd("winfo class .f.sg") == "TSizegrip");
	ok("sizegrip style default TSizegrip", cmd(".f.sg style") == "TSizegrip");
	cmd(".f.sg configure -style Custom.TSizegrip");
	ok("sizegrip -style honoured", cmd(".f.sg style") == "Custom.TSizegrip");
	ok("sizegrip instate !disabled", cmd(".f.sg instate disabled") == "0");

	# 16. ttk::notebook - a tabbed container (embedded-window panes)
	cmd("ttk::notebook .nb");
	cmd("ttk::frame .nb.p1");
	cmd("ttk::label .nb.p1.l -text {page one}");
	cmd("pack .nb.p1.l");
	cmd("ttk::frame .nb.p2");
	cmd("ttk::label .nb.p2.l -text {page two}");
	cmd("pack .nb.p2.l");
	cmd("ttk::frame .nb.p3");
	cmd("pack .nb");
	cmd("update");
	ok("notebook class TNotebook", cmd("winfo class .nb") == "TNotebook");
	ok("notebook style default TNotebook", cmd(".nb style") == "TNotebook");
	cmd(".nb add .nb.p1 -text One");
	cmd(".nb add .nb.p2 -text Two");
	cmd(".nb add .nb.p3 -text Three");
	cmd("update");
	ok("notebook lists three tabs", cmd(".nb tabs") == ".nb.p1 .nb.p2 .nb.p3");
	ok("notebook first add auto-selects", cmd(".nb select") == ".nb.p1");
	ok("notebook index by path", cmd(".nb index .nb.p2") == "1");
	ok("notebook index end counts tabs", cmd(".nb index end") == "3");
	ok("notebook tab -text get", cmd(".nb tab .nb.p2 -text") == "Two");
	cmd(".nb select .nb.p3");
	ok("notebook select by path", cmd(".nb select") == ".nb.p3");
	cmd(".nb select 1");
	ok("notebook select by index", cmd(".nb select") == ".nb.p2");
	cmd(".nb tab .nb.p1 -text Uno");
	ok("notebook tab -text set", cmd(".nb tab .nb.p1 -text") == "Uno");
	cmd(".nb tab .nb.p3 -state disabled");
	cmd(".nb select .nb.p3");
	ok("notebook skips disabled tab on select", cmd(".nb select") == ".nb.p2");
	cmd(".nb forget .nb.p2");
	cmd("update");
	ok("notebook forget drops a tab", cmd(".nb tabs") == ".nb.p1 .nb.p3");
	cmd(".nb configure -style Custom.TNotebook");
	ok("notebook style honoured", cmd(".nb style") == "Custom.TNotebook");
	cmd(".nb state disabled");
	ok("notebook instate disabled", cmd(".nb instate disabled") == "1");
	cmd(".nb state {!disabled}");

	# 17. ttk::panedwindow - a tiled container with draggable sashes
	cmd("ttk::panedwindow .pw -orient horizontal -width 260 -height 120");
	cmd("ttk::frame .pw.a");
	cmd("ttk::label .pw.a.l -text left");
	cmd("pack .pw.a.l");
	cmd("ttk::frame .pw.b");
	cmd("ttk::label .pw.b.l -text right");
	cmd("pack .pw.b.l");
	cmd("ttk::frame .pw.c");
	cmd("pack .pw");
	cmd("update");
	ok("panedwindow class TPanedwindow", cmd("winfo class .pw") == "TPanedwindow");
	ok("panedwindow style default", cmd(".pw style") == "TPanedwindow");
	ok("panedwindow orient honoured", cmd(".pw cget -orient") == "horizontal");
	# two wide panes: sash 0 has room to move to 80
	cmd(".pw add .pw.a");
	cmd(".pw add .pw.b");
	cmd("update");
	ok("panedwindow lists panes", cmd(".pw panes") == ".pw.a .pw.b");
	cmd(".pw sashpos 0 80");
	cmd("update");
	ok("panedwindow sashpos set+get", cmd(".pw sashpos 0") == "80");
	cmd(".pw add .pw.c");
	cmd("update");
	ok("panedwindow add a third pane", cmd(".pw panes") == ".pw.a .pw.b .pw.c");
	cmd(".pw forget .pw.b");
	cmd("update");
	ok("panedwindow forget drops a pane", cmd(".pw panes") == ".pw.a .pw.c");
	cmd(".pw configure -style Custom.TPanedwindow");
	ok("panedwindow style honoured", cmd(".pw style") == "Custom.TPanedwindow");
	cmd(".pw state disabled");
	ok("panedwindow instate disabled", cmd(".pw instate disabled") == "1");
	cmd(".pw state {!disabled}");

	sys->print("1..%d\n", nok+nfail);
	if(nfail == 0)
		sys->print("# all %d ttk tests passed\n", nok);
	else
		sys->print("# %d FAILED\n", nfail);
	shutdown();
	exit;
}

has(s: string, sub: string): int
{
	n := len sub;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

shutdown()
{
	fd := sys->open("#p/" + string mypid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}
