implement Toolbar;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Screen, Display, Image, Rect, Point, Wmcontext, Pointer: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "sh.m";
	shell: Sh;
	Listnode, Context: import shell;
include "string.m";
	str: String;
include "arg.m";
include "daytime.m";
	daytime: Daytime;

myselfbuiltin: Shellbuiltin;

Toolbar: module 
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
	initbuiltin: fn(c: ref Context, sh: Sh): string;
	runbuiltin: fn(c: ref Context, sh: Sh,
			cmd: list of ref Listnode, last: int): string;
	runsbuiltin: fn(c: ref Context, sh: Sh,
			cmd: list of ref Listnode): list of ref Listnode;
	whatis: fn(c: ref Sh->Context, sh: Sh, name: string, wtype: int): string;
	getself: fn(): Shellbuiltin;
};

MAXCONSOLELINES:	con 1024;

# execute this if no menu items have been created
# by the init script.
defaultscript :=
	"{menu shell " +
		"{{autoload=std; load $autoload; pctl newpgrp; wm/sh}&}}";

tbtop: ref Tk->Toplevel;
screenr: Rect;

# command run by the desktop menu's "New shell" entry.
NEWSHELL: con "{autoload=std; load $autoload; pctl newpgrp; wm/sh}&";

Nws: con 4;

# window list mirrored from the wm, for the desktop context menu.
Win: adt {
	id:	int;
	title:	string;
	ws:	int;
};
wins: list of ref Win;
curworkspace := 0;
nworkspaces := Nws;
pagerbuilt := 0;
wmcmd: chan of string;		# desktop/pager menu actions -> wm verbs

badmodule(p: string)
{
	sys->fprint(stderr(), "toolbar: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys  = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil)
		badmodule(Draw->PATH);
	tk   = load Tk Tk->PATH;
	if(tk == nil)
		badmodule(Tk->PATH);

	str = load String String->PATH;
	if(str == nil)
		badmodule(String->PATH);

	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil)
		badmodule(Tkclient->PATH);
	tkclient->init();

	shell = load Sh Sh->PATH;
	if (shell == nil)
		badmodule(Sh->PATH);
	daytime = load Daytime Daytime->PATH;	# optional: clock degrades gracefully
	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmodule(Arg->PATH);

	myselfbuiltin = load Shellbuiltin "$self";
	if (myselfbuiltin == nil)
		badmodule("$self(Shellbuiltin)");

	sys->pctl(Sys->NEWPGRP|Sys->FORKNS, nil);

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#s", "/chan", sys->MBEFORE);

	arg->init(argv);
	arg->setusage("toolbar [-s] [-p]");
	startmenu := 1;
#	ownsnarf := (sys->open("/chan/snarf", Sys->ORDWR) == nil);
	ownsnarf := sys->stat("/chan/snarf").t0 < 0;
	while((c := arg->opt()) != 0){
		case c {
		's' =>
			startmenu = 0;
		'p' =>
			ownsnarf = 1;
		* =>
			arg->usage();
		}
	}
	argv = arg->argv();
	arg = nil;

	if (ctxt == nil){
		sys->fprint(sys->fildes(2), "toolbar: must run under a window manager\n");
		raise "fail:no wm";
	}

	exec := chan of string;
	task := chan of string;

	tbtop = toolbar(ctxt, startmenu, exec, task);
	tkclient->startinput(tbtop, "ptr" :: "control" :: nil);
	layout(tbtop);

	shctxt := Context.new(ctxt);
	shctxt.addmodule("wm", myselfbuiltin);

	snarfIO: ref Sys->FileIO;
	if(ownsnarf){
		snarfIO = sys->file2chan("/chan", "snarf");
		if(snarfIO == nil)
			fatal(sys->sprint("cannot make /chan/snarf: %r"));
	}else
		snarfIO = ref Sys->FileIO(chan of (int, int, int, Sys->Rread), chan of (int, array of byte, int, Sys->Rwrite));
	sync := chan of string;
	spawn consoleproc(ctxt, sync);
	if ((err := <-sync) != nil)
		fatal(err);

	setupfinished := chan of int;
	donesetup := 0;
	spawn setup(shctxt, setupfinished);

	tick := chan of int;
	if (daytime != nil) {
		updateclock();
		spawn clockproc(tick);
	}

	snarf: array of byte;
#	write("/prog/"+string sys->pctl(0, nil)+"/ctl", "restricted"); # for testing
	for(;;) alt{
	<-tick =>
		updateclock();
	dc := <-wmcmd =>
		wmaction(dc);
	k := <-tbtop.ctxt.kbd =>
		tk->keyboard(tbtop, k);
	m := <-tbtop.ctxt.ptr =>
		tk->pointer(tbtop, *m);
	s := <-tbtop.ctxt.ctl or
	s = <-tbtop.wreq =>
		wmctl(tbtop, s);
	s := <-exec =>
		# guard against parallel access to the shctxt environment
		if (donesetup){
			{
 				shctxt.run(ref Listnode(nil, s) :: nil, 0);
			} exception {
			"fail:*" =>	;
			}
		}
	detask := <-task =>
		deiconify(detask);
	(off, data, nil, wc) := <-snarfIO.write =>
		if(wc == nil)
			break;
		if (off == 0)			# write at zero truncates
			snarf = data;
		else {
			if (off + len data > len snarf) {
				nsnarf := array[off + len data] of byte;
				nsnarf[0:] = snarf;
				snarf = nsnarf;
			}
			snarf[off:] = data;
		}
		wc <-= (len data, "");
	(off, nbytes, nil, rc) := <-snarfIO.read =>
		if(rc == nil)
			break;
		if (off >= len snarf) {
			rc <-= (nil, "");		# XXX alt
			break;
		}
		e := off + nbytes;
		if (e > len snarf)
			e = len snarf;
		rc <-= (snarf[off:e], "");	# XXX alt
	donesetup = <-setupfinished =>
		;	
	}
}

wmctl(top: ref Tk->Toplevel, c: string)
{
	args := str->unquoted(c);
	if(args == nil)
		return;
	n := len args;

	case hd args{
	"request" =>
		# request clientid args...
		if(n < 3)
			return;
		args = tl args;
		clientid := hd args;
		args = tl args;
		err := handlerequest(clientid, args);
		if(err != nil)
			sys->fprint(sys->fildes(2), "toolbar: bad wmctl request %#q: %s\n", c, err);
	"newclient" =>
		# newclient id
		if(n >= 2)
			addwin(int hd tl args);
	"delclient" =>
		# delclient id
		if(n >= 2){
			delwin(int hd tl args);
			deiconify(hd tl args);
		}
	"wtitle" =>
		# wtitle id {title}
		if(n >= 3)
			setwintitle(int hd tl args, hd tl tl args);
	"wworkspace" =>
		# wworkspace id ws
		if(n >= 3)
			setwinws(int hd tl args, int hd tl tl args);
	"curworkspace" =>
		# curworkspace cur nworkspaces
		if(n >= 3){
			curworkspace = int hd tl args;
			nworkspaces = int hd tl tl args;
			updatepager();
		}
	"popup" =>
		# popup x y -- open the desktop context menu
		if(n >= 3)
			postdesktopmenu(int hd tl args, int hd tl tl args);
	"rect" =>
		tkclient->wmctl(top, c);
		layout(top);
	* =>
		tkclient->wmctl(top, c);
	}
}

handlerequest(clientid: string, args: list of string): string
{
	n := len args;
	case hd args {
	"task" =>
		# task name
		if(n != 2)
			return "no task label given";
		iconify(clientid, hd tl args);
	"untask" or
	"unhide" =>
		deiconify(clientid);
	* =>
		return "unknown request";
	}
	return nil;
}

iconify(id, label: string)
{
	label = condenselabel(label);
	e := tk->cmd(tbtop, "button .toolbar." +id+" -command {send task "+id+"} -takefocus 0");
	cmd(tbtop, ".toolbar." +id+" configure -text '" + label);
	if(e[0] != '!')
		cmd(tbtop, "pack .toolbar."+id+" -side left -fill y");
	cmd(tbtop, "update");
}

deiconify(id: string)
{
	e := tk->cmd(tbtop, "destroy .toolbar."+id);
	if(e == nil){
		tkclient->wmctl(tbtop, sys->sprint("ctl %q untask", id));
		tkclient->wmctl(tbtop, sys->sprint("ctl %q kbdfocus 1", id));
	}
	cmd(tbtop, "update");
}

clockproc(tick: chan of int)
{
	for(;;){
		sys->sleep(1000);
		tick <-= 1;
	}
}

updateclock()
{
	if (daytime == nil)
		return;
	tm := daytime->local(daytime->now());
	cmd(tbtop, sys->sprint(".toolbar.clk configure -text {%02d:%02d:%02d}", tm.hour, tm.min, tm.sec));
	cmd(tbtop, "update");
}

# --- window list mirrored from the wm (for the desktop context menu) ---

findwin(id: int): ref Win
{
	for(wl := wins; wl != nil; wl = tl wl)
		if((hd wl).id == id)
			return hd wl;
	return nil;
}

addwin(id: int)
{
	if(findwin(id) == nil)
		wins = ref Win(id, nil, curworkspace) :: wins;
}

delwin(id: int)
{
	nw: list of ref Win;
	for(wl := wins; wl != nil; wl = tl wl)
		if((hd wl).id != id)
			nw = hd wl :: nw;
	wins = nw;
}

setwintitle(id: int, t: string)
{
	addwin(id);
	findwin(id).title = t;
}

setwinws(id, ws: int)
{
	addwin(id);
	findwin(id).ws = ws;
}

# build and post the rio-style desktop menu at (x, y).
postdesktopmenu(x, y: int)
{
	tk->cmd(tbtop, "destroy .dm");	# may not exist yet; ignore "bad window path"
	cmd(tbtop, "menu .dm");
	cmd(tbtop, ".dm add command -command {send exec " + NEWSHELL + "} -label " + tk->quote("New shell"));
	if(wins != nil){
		cmd(tbtop, "menu .dm.win");
		for(wl := wins; wl != nil; wl = tl wl){
			w := hd wl;
			ids := string w.id;
			m := ".dm.win.w" + ids;
			cmd(tbtop, "menu " + m);
			cmd(tbtop, m + " add command -command {send wmcmd raise " + ids + "} -label Raise");
			cmd(tbtop, m + " add command -command {send wmcmd hide " + ids + "} -label Hide");
			cmd(tbtop, m + " add command -command {send wmcmd close " + ids + "} -label Close");
			cmd(tbtop, "menu " + m + ".to");
			for(i := 0; i < nworkspaces; i++)
				cmd(tbtop, m + ".to add command -command {send wmcmd sendto " + ids + " " + string i +
					"} -label " + tk->quote("Workspace " + string (i+1)));
			cmd(tbtop, m + " add cascade -menu " + m + ".to -label " + tk->quote("Send to"));
			label := w.title;
			if(label == nil)
				label = "window " + ids;
			cmd(tbtop, ".dm.win add cascade -menu " + m + " -label " + tk->quote(label));
		}
		cmd(tbtop, ".dm add cascade -menu .dm.win -label Windows");
	}
	cmd(tbtop, ".dm add command -command {send wmcmd cascade} -label Cascade");
	cmd(tbtop, ".dm add command -command {send wmcmd minall} -label " + tk->quote("Minimize all"));
	cmd(tbtop, "menu .dm.ws");
	for(i := 0; i < nworkspaces; i++)
		cmd(tbtop, ".dm.ws add command -command {send wmcmd workspace " + string i +
			"} -label " + tk->quote("Workspace " + string (i+1)));
	cmd(tbtop, ".dm add cascade -menu .dm.ws -label Workspace");
	cmd(tbtop, ".dm add separator");
	cmd(tbtop, ".dm add command -command {.m post " + string x + " " + string y + "} -label Apps");
	cmd(tbtop, ".dm post " + string x + " " + string y);
}

# turn a desktop/pager menu action into a wm control request.
wmaction(s: string)
{
	args := str->unquoted(s);
	if(args == nil)
		return;
	n := len args;
	case hd args {
	"raise" =>
		if(n >= 2)
			raisewin(hd tl args);
	"hide" =>
		if(n >= 2)
			tkclient->wmctl(tbtop, "ctl " + hd tl args + " task");
	"close" =>
		if(n >= 2)
			tkclient->wmctl(tbtop, "ctl " + hd tl args + " exit");
	"cascade" =>
		tkclient->wmctl(tbtop, "cascade");
	"minall" =>
		tkclient->wmctl(tbtop, "minall");
	"workspace" =>
		if(n >= 2)
			tkclient->wmctl(tbtop, "workspace " + hd tl args);
	"sendto" =>
		if(n >= 3)
			tkclient->wmctl(tbtop, "sendto " + hd tl args + " " + hd tl tl args);
	}
}

# raise+focus a window, restoring it from the taskbar first if minimized.
raisewin(id: string)
{
	if(tk->cmd(tbtop, "destroy .toolbar." + id) == nil)
		tkclient->wmctl(tbtop, "ctl " + id + " untask");
	tkclient->wmctl(tbtop, "ctl " + id + " kbdfocus 1");
}

# --- workspace pager ---

buildpager()
{
	if(pagerbuilt)
		return;
	cmd(tbtop, "frame .toolbar.pager");
	for(i := 0; i < nworkspaces; i++){
		b := ".toolbar.pager.b" + string i;
		cmd(tbtop, "button " + b + " -text " + string (i+1) +
			" -command {send wmcmd workspace " + string i + "} -takefocus 0 -bd 1");
		cmd(tbtop, "pack " + b + " -side left");
	}
	cmd(tbtop, "pack .toolbar.pager -side left -padx 4");
	pagerbuilt = 1;
}

updatepager()
{
	buildpager();
	for(i := 0; i < nworkspaces; i++){
		rel := "raised";
		if(i == curworkspace)
			rel = "sunken";
		cmd(tbtop, ".toolbar.pager.b" + string i + " configure -relief " + rel);
	}
	cmd(tbtop, "update");
}

layout(top: ref Tk->Toplevel)
{
	r := top.screenr;
	h := 32;
	if(r.dy() < 480)
		h = tk->rect(top, ".b", Tk->Border|Tk->Required).dy();
	cmd(top, ". configure -x " + string r.min.x +
			" -y " + string (r.max.y - h) +
			" -width " + string r.dx() +
			" -height " + string h);
	cmd(top, "update");
	tkclient->onscreen(tbtop, "exact");
}

toolbar(ctxt: ref Draw->Context, startmenu: int,
		exec, task: chan of string): ref Tk->Toplevel
{
	(tbtop, nil) = tkclient->toplevel(ctxt, nil, nil, Tkclient->Plain);
	screenr = tbtop.screenr;

	cmd(tbtop, "button .b -text {XXX}");
	cmd(tbtop, "pack propagate . 0");

	tk->namechan(tbtop, exec, "exec");
	tk->namechan(tbtop, task, "task");
	wmcmd = chan of string;
	tk->namechan(tbtop, wmcmd, "wmcmd");
	cmd(tbtop, "frame .toolbar");
	if (startmenu) {
		cmd(tbtop, "menubutton .toolbar.start -menu .m -borderwidth 0 -bitmap vitasmall.bit");
		cmd(tbtop, "pack .toolbar.start -side left");
	}
	if (daytime != nil) {
		cmd(tbtop, "label .toolbar.clk -text {--:--:--} -bd 1");
		cmd(tbtop, "pack .toolbar.clk -side right");
	}
	cmd(tbtop, "pack .toolbar -fill x");
	cmd(tbtop, "menu .m");
	return tbtop;
}

setup(shctxt: ref Context, finished: chan of int)
{
	ctxt := shctxt.copy(0);
	ctxt.run(shell->stringlist2list("run"::"/lib/wmsetup"::nil), 0);
	# if no items in menu, then create some.
	if (tk->cmd(tbtop, ".m type 0")[0] == '!')
		ctxt.run(shell->stringlist2list(defaultscript::nil), 0);
	cmd(tbtop, "update");
	finished <-= 1;
}

condenselabel(label: string): string
{
	if(len label > 15){
		new := "";
		l := 0;
		while(len label > 15 && l < 3) {
			new += label[0:15]+"\n";
			label = label[15:];
			for(v := 0; v < len label; v++)
				if(label[v] != ' ')
					break;
			label = label[v:];
			l++;
		}
		label = new + label;
	}
	return label;
}

initbuiltin(ctxt: ref Context, nil: Sh): string
{
	if (tbtop == nil) {
		sys = load Sys Sys->PATH;
		sys->fprint(sys->fildes(2), "wm: cannot load wm as a builtin\n");
		raise "fail:usage";
	}
	ctxt.addbuiltin("menu", myselfbuiltin);
	ctxt.addbuiltin("delmenu", myselfbuiltin);
	ctxt.addbuiltin("error", myselfbuiltin);
	return nil;
}

whatis(nil: ref Sh->Context, nil: Sh, nil: string, nil: int): string
{
	return nil;
}

runbuiltin(c: ref Context, sh: Sh,
			cmd: list of ref Listnode, nil: int): string
{
	case (hd cmd).word {
	"menu" =>	return builtin_menu(c, sh, cmd);
	"delmenu" =>	return builtin_delmenu(c, sh, cmd);
	}
	return nil;
}

runsbuiltin(nil: ref Context, nil: Sh,
			nil: list of ref Listnode): list of ref Listnode
{
	return nil;
}

stderr(): ref Sys->FD
{
	return sys->fildes(2);
}

word(ln: ref Listnode): string
{
	if (ln.word != nil)
		return ln.word;
	if (ln.cmd != nil)
		return shell->cmd2string(ln.cmd);
	return nil;
}

menupath(title: string): string
{
	mpath := ".m."+title;
	for(j := 0; j < len mpath; j++)
		if(mpath[j] == ' ')
			mpath[j] = '_';
	return mpath;
}

builtin_menu(nil: ref Context, nil: Sh, argv: list of ref Listnode): string
{
	n := len argv;
	if (n < 3 || n > 4) {
		sys->fprint(stderr(), "usage: menu topmenu [ secondmenu ] command\n");
		raise "fail:usage";
	}
	primary := (hd tl argv).word;
	argv = tl tl argv;

	if (n == 3) {
		w := word(hd argv);
		if (len w == 0)
			cmd(tbtop, ".m insert 0 separator");
		else
			cmd(tbtop, ".m insert 0 command -label " + tk->quote(primary) +
				" -command {send exec " + w + "}");
	} else {
		secondary := (hd argv).word;
		argv = tl argv;

		mpath := menupath(primary);
		e := tk->cmd(tbtop, mpath+" cget -width");
		if(e[0] == '!') {
			cmd(tbtop, "menu "+mpath);
			cmd(tbtop, ".m insert 0 cascade -label "+tk->quote(primary)+" -menu "+mpath);
		}
		w := word(hd argv);
		if (len w == 0)
			cmd(tbtop, mpath + " insert 0 separator");
		else
			cmd(tbtop, mpath+" insert 0 command -label "+tk->quote(secondary)+
				" -command {send exec "+w+"}");
	}
	return nil;
}

builtin_delmenu(nil: ref Context, nil: Sh, nil: list of ref Listnode): string
{
	delmenu(".m");
	cmd(tbtop, "menu .m");
	return nil;
}

delmenu(m: string)
{
	for (i := int cmd(tbtop, m + " index end"); i >= 0; i--)
		if (cmd(tbtop, m + " type " + string i) == "cascade")
			delmenu(cmd(tbtop, m + " entrycget " + string i + " -menu"));
	cmd(tbtop, "destroy " + m);
}

getself(): Shellbuiltin
{
	return myselfbuiltin;
}

cmd(top: ref Tk->Toplevel, c: string): string
{
	s := tk->cmd(top, c);
	if (s != nil && s[0] == '!')
		sys->fprint(stderr(), "tk error on %#q: %s\n", c, s);
	return s;
}

kill(pid: int, note: string): int
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", note) < 0)
		return -1;
	return 0;
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "wm: %s\n", s);
	kill(sys->pctl(0, nil), "killgrp");
	raise "fail:error";
}

bufferproc(in, out: chan of string)
{
	h, t: list of string;
	dummyout := chan of string;
	for(;;){
		outc := dummyout;
		s: string;
		if(h != nil || t != nil){
			outc = out;
			if(h == nil)
				for(; t != nil; t = tl t)
					h = hd t :: h;
			s = hd h;
		}
		alt{
		x := <-in =>
			t = x :: t;
		outc <-= s =>
			h = tl h;
		}
	}
}

#
# The Log window is a multi-source console.  Every source contributes a
# stream of text lines tagged with a short name (the "out"/"err" app streams,
# the kernel #c/kprint buffer, named logfile(4) buffers under a watched
# directory, or any extra /chan endpoint).  All sources funnel their text
# through the single channel `logc` to the one proc that owns the Tk widgets;
# dynamic sources cannot be added to a static `alt`, so each source runs its
# own forwarding proc instead.  The window keeps a bounded in-memory transcript
# so a filter (the search bar at the top, or a click on a source's tag button)
# can be applied by re-rendering only the matching lines.
#
con_cfg := array[] of
{
	"frame .ctl",
	"menubutton .ctl.src -text Sources -menu .srcm -bd 1 -relief raised",
	"menu .srcm",
	".srcm add command -text {Tail file...} -command {send logcmd asktail}",
	".srcm add command -text {Watch directory...} -command {send logcmd askdir}",
	".srcm add command -text {New /chan endpoint...} -command {send logcmd askchan}",
	".srcm add command -text {Kernel log (#c/kprint)} -command {send logcmd addkprint}",
	".srcm add separator",
	".srcm add command -text {Dump all procs to host file} -command {send logcmd dumpprocs}",
	".srcm add command -text {Clear transcript} -command {send logcmd clearlog}",
	"label .ctl.fl -text { Filter:}",
	"entry .ctl.f -width 20 -bg white",
	"button .ctl.fc -text Clear -command {send logcmd clearfilter} -bd 1",
	"pack .ctl.src -side left",
	"pack .ctl.fl -side left",
	"pack .ctl.f -side left -fill x -expand 1",
	"pack .ctl.fc -side left",
	"bind .ctl.f <Key> +{send logcmd filter}",
	"frame .ask",
	"label .ask.l",
	"entry .ask.e -width 40 -bg white",
	"button .ask.c -text Cancel -command {send logcmd cancel} -bd 1",
	"pack .ask.l -side left",
	"pack .ask.e -side left -fill x -expand 1",
	"pack .ask.c -side left",
	"bind .ask.e <Key-\n> {send logcmd submit}",
	"frame .tags",
	"frame .cons",
	"scrollbar .cons.scroll -command {.cons.t yview}",
	"text .cons.t -width 60w -height 15w -bg white "+
		"-fg black -font /fonts/misc/latin1.6x13.font "+
		"-yscrollcommand {.cons.scroll set}",
	"pack .cons.scroll -side left -fill y",
	"pack .cons.t -fill both -expand 1",
	"pack .ctl -fill x",
	"pack .tags -fill x",
	"pack .cons -expand 1 -fill both",
	"pack propagate . 0",
	"update"
};

# distinct foreground colours handed out to sources in arrival order
palette := array[] of {
	"#1a4ba0", "#107010", "#a02020", "#806000",
	"#7020a0", "#008080", "#a0307a", "#404040",
};

Src: adt {
	tag:		string;		# source key (display + filter)
	ttag:		string;		# Tk text-tag carrying the colour
	button:	string;		# tag button widget path
	pending:	string;		# partial (newline-incomplete) line buffer
};

Logline: adt {
	ttag:	string;
	tag:	string;
	text:	string;
};

sources: array of ref Src;
nsrc := 0;

logbuf: array of ref Logline;	# bounded transcript ring
loghead := 0;			# index of oldest entry
logcount := 0;
shownlines := 0;		# lines currently in the text widget
filter := "";			# current search-bar contents (case-insensitive)
askmode := "";			# pending prompt action, "" when idle
logc: chan of (string, string);	# (tag, text-chunk) from every source

consoleproc(ctxt: ref Draw->Context, sync: chan of string)
{
	iostdout := sys->file2chan("/chan", "wmstdout");
	if(iostdout == nil){
		sync <-= sys->sprint("cannot make /chan/wmstdout: %r");
		return;
	}
	iostderr := sys->file2chan("/chan", "wmstderr");
	if(iostderr == nil){
		sync <-= sys->sprint("cannot make /chan/wmstderr: %r");
		return;
	}

	sync <-= nil;

	(top, titlectl) := tkclient->toplevel(ctxt, "", "Log", tkclient->Appl);
	for(i := 0; i < len con_cfg; i++)
		cmd(top, con_cfg[i]);

	logcmd := chan of string;
	tk->namechan(top, logcmd, "logcmd");

	sources = array[8] of ref Src;
	logbuf = array[MAXCONSOLELINES] of ref Logline;
	logc = chan[256] of (string, string);

	r := tk->rect(top, ".", Tk->Border|Tk->Required);
	cmd(top, ". configure -x " + string ((top.screenr.dx() - r.dx()) / 2 + top.screenr.min.x) +
				" -y " + string (r.dy() / 3 + top.screenr.min.y));

	tkclient->startinput(top, "ptr"::"kbd"::nil);
	tkclient->onscreen(top, "onscreen");
	tkclient->wmctl(top, "task");

	# the two app streams that wmsetup's wmrun redirects here
	ensuresrc(top, "out");
	ensuresrc(top, "err");
	spawn fchanproc(iostdout, "out", logc);
	spawn fchanproc(iostderr, "err", logc);

	# general-purpose ad-hoc log sink: any program can `echo ... >/chan/log`
	# and have it appear tagged `log`, separate from its stdout/stderr.
	# (#c/kprint is not opened by default: in hosted emu it is mostly empty,
	# it is exclusive, and opening it diverts kernel print() from the console;
	# add it on demand via the Sources menu.)
	iolog := sys->file2chan("/chan", "log");
	if(iolog != nil){
		ensuresrc(top, "log");
		spawn fchanproc(iolog, "log", logc);
	}

	# proc-failure stream, tagged `proc`: real breaks (uncaught exceptions)
	# never reach a shell, so procmon watches /prog for them; `fail:` exits do
	# reach the launching shell, so wmsetup's wmrun reports those to /chan/proc.
	ioproc := sys->file2chan("/chan", "proc");
	if(ioproc != nil){
		ensuresrc(top, "proc");
		spawn fchanproc(ioproc, "proc", logc);
	}
	spawn procmon(logc);
	spawn vmtailer(logc);

	for(;;) alt {
	c := <-titlectl or
	c = <-top.wreq or
	c = <-top.ctxt.ctl =>
		if(c == "exit")
			c = "task";
		tkclient->wmctl(top, c);
	c := <-top.ctxt.kbd =>
		tk->keyboard(top, c);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	(tag, chunk) := <-logc =>
		ingest(top, tag, chunk);
		if(tag == "err")		# stderr raises the window, as before
			tkclient->wmctl(top, "untask");
	m := <-logcmd =>
		docmd(top, m);
	}
}

# dispatch a control message from a menu item, the filter entry, or a tag button
docmd(top: ref Tk->Toplevel, m: string)
{
	if(len m > 3 && m[0:3] == "tag"){	# tag<n> button: filter to that source
		i := int m[3:];
		if(i >= 0 && i < nsrc){
			ftext := "[" + sources[i].tag + "]";
			cmd(top, ".ctl.f delete 0 end");
			cmd(top, ".ctl.f insert 0 " + tk->quote(ftext));
			applyfilter(top, ftext);
		}
		return;
	}
	case m {
	"filter" =>
		applyfilter(top, cmd(top, ".ctl.f get"));
	"clearfilter" =>
		cmd(top, ".ctl.f delete 0 end");
		applyfilter(top, "");
	"clearlog" =>
		loghead = logcount = shownlines = 0;
		cmd(top, ".cons.t delete 1.0 end; update");
	"addkprint" =>
		addfilereader(top, "#c/kprint", "kprint");
	"dumpprocs" =>
		spawn dumpprocs();
	"asktail" =>
		ask(top, "tailfile", "File to tail:");
	"askdir" =>
		ask(top, "watchdir", "Directory to watch:");
	"askchan" =>
		ask(top, "addchan", "New /chan name:");
	"cancel" =>
		endask(top);
	"submit" =>
		v := cmd(top, ".ask.e get");
		mode := askmode;
		endask(top);
		case mode {
		"tailfile" =>
			if(v != nil)
				addfilereader(top, v, basename(v));
		"watchdir" =>
			if(v != nil)
				spawn dirwatcher(v, logc);
		"addchan" =>
			if(v != nil)
				addchanep(top, v);
		}
	}
}

# show the inline prompt row for an action needing a path/name
ask(top: ref Tk->Toplevel, mode, prompt: string)
{
	askmode = mode;
	cmd(top, ".ask.l configure -text " + tk->quote(prompt));
	cmd(top, ".ask.e delete 0 end");
	cmd(top, "pack .ask -after .ctl -fill x");
	cmd(top, "focus .ask.e; update");
}

endask(top: ref Tk->Toplevel)
{
	askmode = "";
	cmd(top, "pack forget .ask; update");
}

# create the source for `tag` if it does not exist; return its index
ensuresrc(top: ref Tk->Toplevel, tag: string): int
{
	for(i := 0; i < nsrc; i++)
		if(sources[i].tag == tag)
			return i;
	if(nsrc >= len sources){
		ns := array[2 * len sources] of ref Src;
		ns[0:] = sources;
		sources = ns;
	}
	n := nsrc++;
	col := palette[n % len palette];
	s := ref Src(tag, "c" + string n, ".tags.b" + string n, "");
	sources[n] = s;
	cmd(top, ".cons.t tag configure " + s.ttag + " -foreground " + col);
	cmd(top, "button " + s.button + " -text " + tk->quote(tag) +
		" -command {send logcmd tag" + string n + "} -foreground " + col + " -bd 1");
	cmd(top, "pack " + s.button + " -side left");
	cmd(top, "update");
	return n;
}

addfilereader(top: ref Tk->Toplevel, path, tag: string)
{
	ensuresrc(top, tag);
	spawn filereader(path, tag, logc);
}

addchanep(top: ref Tk->Toplevel, name: string)
{
	io := sys->file2chan("/chan", name);
	if(io == nil){
		ingest(top, "err", sys->sprint("cannot make /chan/%s: %r\n", name));
		return;
	}
	ensuresrc(top, name);
	spawn fchanproc(io, name, logc);
}

# accumulate a chunk for `tag`, emitting each completed line into the transcript
ingest(top: ref Tk->Toplevel, tag, chunk: string)
{
	si := ensuresrc(top, tag);
	s := sources[si];
	s.pending += chunk;
	for(;;){
		nl := strchr(s.pending, '\n');
		if(nl < 0)
			break;
		emit(top, si, s.pending[0:nl]);
		s.pending = s.pending[nl+1:];
	}
	if(len s.pending > Sys->ATOMICIO){	# flush a source that never sends newlines
		emit(top, si, s.pending);
		s.pending = "";
	}
}

emit(top: ref Tk->Toplevel, si: int, line: string)
{
	s := sources[si];
	ll := ref Logline(s.ttag, s.tag, line);
	if(logcount < len logbuf){
		logbuf[(loghead + logcount) % len logbuf] = ll;
		logcount++;
	}else{
		logbuf[loghead] = ll;
		loghead = (loghead + 1) % len logbuf;
	}
	if(matchfilter(ll))
		renderline(top, ll);
}

renderline(top: ref Tk->Toplevel, ll: ref Logline)
{
	cmd(top, ".cons.t insert end " + tk->quote("[" + ll.tag + "] " + ll.text + "\n") + " " + ll.ttag);
	if(++shownlines > MAXCONSOLELINES){
		cmd(top, ".cons.t delete 1.0 " + string (shownlines / 4) + ".0");
		shownlines -= shownlines / 4;
	}
	if(scrolling)
		cmd(top, ".cons.t see end");
	cmd(top, "update");
}

matchfilter(ll: ref Logline): int
{
	if(filter == "")
		return 1;
	return hasstr(lc("[" + ll.tag + "] " + ll.text), lc(filter));
}

# rebuild the text widget from the transcript under a new filter
applyfilter(top: ref Tk->Toplevel, f: string)
{
	filter = f;
	cmd(top, ".cons.t delete 1.0 end");
	shownlines = 0;
	for(i := 0; i < logcount; i++){
		ll := logbuf[(loghead + i) % len logbuf];
		if(matchfilter(ll)){
			cmd(top, ".cons.t insert end " +
				tk->quote("[" + ll.tag + "] " + ll.text + "\n") + " " + ll.ttag);
			shownlines++;
		}
	}
	cmd(top, ".cons.t see end; update");
}

scrolling := 1;

# forward a file2chan endpoint's writes into the transcript as tagged text
fchanproc(io: ref Sys->FileIO, tag: string, c: chan of (string, string))
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-io.read =>
		if(rc != nil)
			rc <-= (nil, "inappropriate use of file");
	(nil, data, nil, wc) := <-io.write =>
		if(wc == nil)
			continue;
		wc <-= (len data, nil);
		c <-= (tag, string data);
	}
}

# tail a file (a logfile(4) buffer or #c/kprint block until more data; a plain
# file is read once to EOF), forwarding its bytes as tagged text
filereader(path, tag: string, c: chan of (string, string))
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		c <-= (tag, sys->sprint("cannot open %s: %r\n", path));
		return;
	}
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		c <-= (tag, string buf[0:n]);
}

EXITSTUCKMS: con 4000;		# in `exiting` this long => kill not reaping it

Watch: adt {
	pid:	int;
	state:	string;		# the flagged state we're tracking it in
	since:	int;		# millisec first seen in that state
	rpt:	int;		# already reported
};

# Watch /prog for two failure shapes and report each once into the `proc`
# stream:
#   broken  - an uncaught exception (nil deref, bounds, type error, or a raise
#             not starting with "fail:").  Kept (keepbroken) for post-mortem but
#             otherwise only announced on the kernel console.  The reason isn't
#             in /prog for an uncaught break, so the stack frame locates it.
#   exiting - a proc that a killgrp told to die but that stays in `exiting` for
#             EXITSTUCKMS.  This is the "hung on close" shape the wm childminder
#             can't see: an app accepts the close, issues killgrp, then a group
#             member won't reap (e.g. a fetch proc blocked uninterruptibly).
procmon(c: chan of (string, string))
{
	watch: list of ref Watch;
	for(;;){
		now := sys->millisec();
		nwatch: list of ref Watch;
		fd := sys->open("/prog", Sys->OREAD);
		if(fd != nil){
			for(;;){
				(n, d) := sys->dirread(fd);
				if(n <= 0)
					break;
				for(i := 0; i < n; i++){
					pid := int d[i].name;
					(state, mod) := progstate(pid);
					if(state != "broken" && state != "exiting")
						continue;
					w := findwatch(watch, pid);
					if(w == nil || w.state != state)
						w = ref Watch(pid, state, now, 0);
					nwatch = w :: nwatch;
					case state {
					"broken" =>
						if(!w.rpt){
							w.rpt = 1;
							reportbroken(c, pid, mod);
						}
					"exiting" =>
						if(!w.rpt && now - w.since > EXITSTUCKMS){
							w.rpt = 1;
							c <-= ("proc", sys->sprint(
								"*** stuck exiting: pid %d [%s] — killgrp not reaping (%ds)\n",
								pid, mod, (now - w.since) / 1000));
						}
					}
				}
			}
		}
		watch = nwatch;
		sys->sleep(500);
	}
}

findwatch(l: list of ref Watch, pid: int): ref Watch
{
	for(; l != nil; l = tl l)
		if((hd l).pid == pid)
			return hd l;
	return nil;
}

# (state, module) from /prog/<pid>/status; mirrors wm/task's trailing-token
# parse (the time field has embedded spaces, but the line always ends
# STATE SIZE MODULE with MODULE a single whitespace-free token)
progstate(pid: int): (string, string)
{
	s := readfilesmall("/prog/" + string pid + "/status");
	if(s == nil)
		return ("", "");
	(nt, toks) := sys->tokenize(s, " \t\n");
	if(nt < 3)
		return ("", "");
	a := array[nt] of string;
	for(i := 0; i < nt; i++){
		a[i] = hd toks;
		toks = tl toks;
	}
	return (a[nt-3], a[nt-1]);
}

# Snapshot every Dis proc's status + full stack to a host file under $emuroot,
# reachable from the host without any copy/paste out of the GUI.  One menu click
# (Sources -> Dump all procs to host file) captures the whole picture of a hang
# -- the stuck proc, its state, and where its stack is parked.  Runs in its own
# proc (it may read many stacks) and reports only via logc, never touching Tk.
dumpprocs()
{
	out := "#U/tmp/proghang.txt";		# #U is rooted at $emuroot -> repo/tmp
	fd := sys->create(out, Sys->OWRITE, 8r644);
	if(fd == nil){
		logc <-= ("proc", sys->sprint("dumpprocs: cannot create %s: %r\n", out));
		return;
	}
	dir := sys->open("/prog", Sys->OREAD);
	if(dir == nil){
		logc <-= ("proc", "dumpprocs: cannot open /prog\n");
		return;
	}
	count := 0;
	for(;;){
		(n, d) := sys->dirread(dir);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			pid := d[i].name;
			sys->fprint(fd, "== prog %s ==\n", pid);
			st := readfilesmall("/prog/" + pid + "/status");
			if(st != nil)
				sys->fprint(fd, "%s", st);
			stk := readwhole("/prog/" + pid + "/stack");
			if(stk != nil)
				sys->fprint(fd, "%s", stk);
			sys->fprint(fd, "\n");
			count++;
		}
	}
	hostpath := "tmp/proghang.txt";
	root := getenvval("emuroot");
	if(root != nil)
		hostpath = root + "/tmp/proghang.txt";
	logc <-= ("proc", sys->sprint("dumpprocs: wrote %d procs to %s (host)\n", count, hostpath));
}

readwhole(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

reportbroken(c: chan of (string, string), pid: int, mod: string)
{
	c <-= ("proc", sys->sprint("*** broken: pid %d [%s]\n", pid, mod));
	where := readfirstline("/prog/" + string pid + "/stack");
	if(where != "")
		c <-= ("proc", "        at " + where + "\n");
	exc := readfirstline("/prog/" + string pid + "/exception");
	if(exc != "")
		c <-= ("proc", "        exception: " + exc + "\n");
}

readfilesmall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

readfirstline(path: string): string
{
	s := readfilesmall(path);
	i := strchr(s, '\n');
	if(i >= 0)
		return s[0:i];
	return s;
}


# Bridge VM-level fault/hang dumps into the `vm` stream.  The emu writes them
# async-safely to the host file named by $emuhanglog (the EMUHANGLOG env var):
# such reports fire when the VM itself can't be trusted, so they can't be routed
# through Dis channels live -- but once the VM recovers (a lost-wakeup dump, an
# on-demand SIGUSR2 dump) we can tail the host file and republish them.
#
# The host file is reachable only through #U, which is rooted at the emu root
# ($emuroot), so the dump file must live under $emuroot and we strip that prefix
# to form the #U path.  (A file set outside $emuroot is still captured on the
# host -- the durable record -- it just can't be mirrored into the GUI.)
# Seek to the end first so a file accumulated across sessions (opened append)
# doesn't replay its whole history.
vmtailer(c: chan of (string, string))
{
	path := getenvval("emuhanglog");
	if(path == nil || path[0] != '/')		# disabled, or not an absolute host path
		return;
	root := getenvval("emuroot");
	if(root == nil || len path <= len root || path[0:len root] != root)
		return;				# dump file is not under the emu root: unreachable
	fd := sys->open("#U" + path[len root:], Sys->OREAD);
	if(fd == nil)
		return;
	sys->seek(fd, big 0, Sys->SEEKEND);
	buf := array[Sys->ATOMICIO] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			c <-= ("vm", string buf[0:n]);
		else
			sys->sleep(1000);		# at EOF: poll for the next dump
	}
}

getenvval(name: string): string
{
	s := readfilesmall("/env/" + name);
	while(s != nil && (s[len s - 1] == '\0' || s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

# poll a directory for new entries, tailing each as a source named by basename
dirwatcher(dir: string, c: chan of (string, string))
{
	seen: list of string;
	for(;;){
		fd := sys->open(dir, Sys->OREAD);
		if(fd != nil){
			for(;;){
				(n, d) := sys->dirread(fd);
				if(n <= 0)
					break;
				for(i := 0; i < n; i++){
					name := d[i].name;
					if(!inlist(name, seen)){
						seen = name :: seen;
						spawn filereader(dir + "/" + name, name, c);
					}
				}
			}
		}
		sys->sleep(1000);
	}
}

inlist(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

basename(p: string): string
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return p[i+1:];
	return p;
}

strchr(s: string, ch: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == ch)
			return i;
	return -1;
}

lc(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] = s[i] + ('a' - 'A');
	return s;
}

hasstr(h, n: string): int
{
	ln := len n;
	if(ln == 0)
		return 1;
	for(i := 0; i + ln <= len h; i++)
		if(h[i:i+ln] == n)
			return 1;
	return 0;
}
