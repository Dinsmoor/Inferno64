implement Tkwdemo;

#
# tkwdemo - exercises the Tkwidgets megawidget suite: a Notebook whose pages
# show a Paned (Scrolledlist | text), a collapsible Tree, and a Progressbar,
# with a Statusbar along the bottom.  Also a self-test mode (-test) that builds
# everything headless, drives a few operations, prints "tkwdemo: ok", and exits
# - used by the build's smoke check.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "tkwidgets.m";
	tkw: Tkwidgets;
	Scrolledlist, Scrolledtext, Notebook, Paned, Tree, Statusbar, Progressbar: import tkw;

Tkwdemo: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

window: ref Tk->Toplevel;
nb: ref Notebook;
pn: ref Paned;
tr: ref Tree;
sl: ref Scrolledlist;
st: ref Scrolledtext;
sb: ref Statusbar;
pb: ref Progressbar;
prog := 0.0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	tkw = load Tkwidgets Tkwidgets->PATH;
	if(tkw == nil){
		sys->fprint(sys->fildes(2), "tkwdemo: cannot load %s: %r\n", Tkwidgets->PATH);
		raise "fail:load";
	}
	tkclient->init();
	tkw->init();

	# drop argv[0] (the program name) before looking for flags
	if(argv != nil)
		argv = tl argv;
	test := argv != nil && hd argv == "-test";
	# run under the wm when launched from it, else stand alone on our own display
	if(ctxt == nil)
		ctxt = mkdisplayctxt();

	winctl: chan of string;
	(window, winctl) = tkclient->toplevel(ctxt, nil, "Tk Widgets Demo", Tkclient->Appl);

	demo := chan of string;
	tk->namechan(window, demo, "demo");

	build(demo);

	tkclient->onscreen(window, nil);

	# self-test mode: drive a few operations, report, and exit without
	# spawning the input readers (so emu can terminate on return).
	if(test){
		selftest();
		sys->print("tkwdemo: ok\n");
		return;
	}

	tkclient->startinput(window, "kbd" :: "ptr" :: nil);

	for(;;) alt {
	s := <-window.ctxt.kbd =>
		tk->keyboard(window, s);
	s := <-window.ctxt.ptr =>
		tk->pointer(window, *s);
	s := <-window.ctxt.ctl or s = <-winctl =>
		if(s == "exit")
			return;
		tkclient->wmctl(window, s);
	name := <-nb.ev =>
		nb.select(name);
		sb.msg("page: " + name);
	s := <-pn.ev =>
		pn.drag(s);
	s := <-tr.ev =>
		id := tr.click(s);
		if(id != "")
			sb.set("info", "tree: " + id);
	s := <-sl.ev =>
		i := sl.cursel();
		if(i >= 0)
			sb.msg("list row " + string i + ": " + sl.get(i));
	<-st.ev =>		# text-pane click: nothing to do in the demo
		;
	cmd := <-demo =>
		case cmd {
		"step" =>
			prog += 0.1;
			if(prog > 1.0)
				prog = 0.0;
			pb.set(prog);
			sb.set("info", sys->sprint("%d%%", int (prog * 100.0)));
		}
	}
}

build(demo: chan of string)
{
	# notebook on top, status bar on the bottom
	nb = Notebook.new(window, ".nb");
	sb = Statusbar.new(window, ".sb");
	sb.addcell("info");
	tk->cmd(window, "pack .sb -side bottom -fill x");
	tk->cmd(window, "pack .nb -side top -fill both -expand 1");
	tk->cmd(window, ". configure -width 560 -height 380");
	tk->cmd(window, "pack propagate . 0");

	# page 1: a horizontal Paned with a Scrolledlist beside a text panel
	p1 := nb.add("lists", "Lists");
	pn = Paned.new(window, p1 + ".pn", Tkwidgets->Horiz, array[] of {180, 360});
	tk->cmd(window, "pack " + p1 + ".pn -fill both -expand 1");
	sl = Scrolledlist.new(window, pn.pane(0) + ".sl", 0, 0, "-selectmode browse -bg white");
	tk->cmd(window, "pack " + sl.fr + " -fill both -expand 1");
	items := array[20] of string;
	for(i := 0; i < len items; i++)
		items[i] = sys->sprint("item %d", i);
	sl.setitems(items);
	st = Scrolledtext.new(window, pn.pane(1) + ".st", 0, 0, "-wrap word -bg white");
	tk->cmd(window, "pack " + st.fr + " -fill both -expand 1");
	st.insert("Drag the grey sash <-> to resize.  This is a Scrolledtext: a text widget with a scrollbar that honours its size and wraps to its width.\n", "");

	# page 2: a collapsible Tree
	p2 := nb.add("tree", "Tree");
	tr = Tree.new(window, p2 + ".tr", 0, 0);
	tk->cmd(window, "pack " + tr.fr + " -fill both -expand 1");
	tr.add("", "fruit", "Fruit");
	tr.add("fruit", "apple", "Apple");
	tr.add("fruit", "pear", "Pear");
	tr.add("", "veg", "Vegetables");
	tr.add("veg", "carrot", "Carrot");
	tr.add("veg", "pea", "Pea");
	tr.setexpand("fruit", 1);

	# page 3: a Progressbar plus a Step button
	p3 := nb.add("prog", "Progress");
	pb = Progressbar.new(window, p3 + ".pb", 300, 20);
	tk->cmd(window, "pack " + pb.fr + " -side top -padx 10 -pady 20");
	tk->cmd(window, "button " + p3 + ".step -text {Step} -command {send demo step}");
	tk->cmd(window, "pack " + p3 + ".step -side top");

	sb.msg("ready");
}

# headless drive: switch pages, toggle a branch, advance the bar, resize a pane
selftest()
{
	nb.select("tree");
	tr.setexpand("veg", 1);
	tr.sl.select(0);
	pn.setsize(0, 120);
	pb.set(0.5);
	nb.select("prog");
	if(sl.count() != 20)
		sys->fprint(sys->fildes(2), "tkwdemo: bad list count %d\n", sl.count());
	st.clear();
	st.insert("hello", "");
	if(st.get() != "hello")
		sys->fprint(sys->fildes(2), "tkwdemo: scrolledtext get got %q\n", st.get());
}

# build a minimal display context so -test works without a window manager
mkdisplayctxt(): ref Draw->Context
{
	ctxt := tkclient->makedrawcontext();
	return ctxt;
}
