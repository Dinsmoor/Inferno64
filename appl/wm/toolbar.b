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
include "tkwidgets.m";
	tkwidgets: Tkwidgets;
	Combobox: import tkwidgets;

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
runreq: chan of string;		# "Run..." menu item -> open the run dialog
powerreq: chan of string;	# Power menu item -> open the halt/reboot dialog
cfgreq: chan of string;		# "Customize menu..." item -> open the launcher editor
cfgdone: chan of int;		# launcher editor -> "I have closed" (clears cfgopen)
cfgopen := 0;			# is a launcher editor window already up? (singleton)

# The launcher-menu model: the in-memory source of truth for the Apps start
# menu (.m).  It is populated at boot by the `menu` builtin (run from
# /lib/wmsetup), mutated at run time by writes to /chan/wmmenu and by the
# graphical editor, and serialised back to a script for persistence.  Every
# path -- boot script, control file, GUI -- funnels through addentry/delentry +
# rebuildmenu under menulock, so there is exactly one way the menu is built.
# Entries are kept in display order, head = top of the menu.
Mentry: adt {
	menu:		string;	# top-level title (also the cascade name)
	label:		string;	# submenu item label; "" => top-level item or separator
	command:	string;	# shell command as the `menu` builtin saw it; "" => separator
};
mentries: list of ref Mentry;
menulock: chan of int;		# 1-slot mutex guarding mentries and .m rebuilds
extrasadded := 0;		# have the launcher extras (Run/Power/...) been appended to .m?
shctxt: ref Context;		# the toolbar's shell context (menu/delmenu builtins live here)

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

	shctxt = Context.new(ctxt);
	shctxt.addmodule("wm", myselfbuiltin);
	menulock = chan[1] of int;	# created free (empty buffer)
	cfgdone = chan of int;

	# the launcher control file: any program can register/unregister a menu
	# entry at run time by writing a `menu`/`delmenu` line, and `cat` it to see
	# the current menu as a script.  Same verbs, same parsing as /lib/wmsetup.
	menuIO := sys->file2chan("/chan", "wmmenu");
	if(menuIO == nil)
		fatal(sys->sprint("cannot make /chan/wmmenu: %r"));
	menubuf := "";			# accumulates a partial control-file line
	pendmenu: list of string;	# lines that arrived before setup finished

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
	<-runreq =>
		spawn rundialog(ctxt, exec);
	act := <-powerreq =>
		spawn powerdialog(ctxt, act);
	<-cfgreq =>
		if(!cfgopen){		# one editor at a time
			cfgopen = 1;
			spawn runconfig(ctxt);
		}
	<-cfgdone =>
		cfgopen = 0;
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
	(nil, data, nil, wc) := <-menuIO.write =>
		if(wc == nil)
			break;
		menubuf += string data;
		wc <-= (len data, "");
		for(;;){
			nl := strchr(menubuf, '\n');
			if(nl < 0)
				break;
			line := menubuf[0:nl];
			menubuf = menubuf[nl+1:];
			# a write before setup finished would race the boot script's
			# own use of shctxt; queue it and replay once setup is done.
			if(donesetup)
				runmenuline(line);
			else
				pendmenu = line :: pendmenu;
		}
	(off, nbytes, nil, rc) := <-menuIO.read =>
		if(rc == nil)
			break;
		d := array of byte menudump();
		if(off >= len d){
			rc <-= (nil, "");
			break;
		}
		e := off + nbytes;
		if(e > len d)
			e = len d;
		rc <-= (d[off:e], "");
	donesetup = <-setupfinished =>
		lockmenu();
		extrasadded = 1;
		addlaunchermenu();
		unlockmenu();
		for(pl := revstrlist(pendmenu); pl != nil; pl = tl pl)
			runmenuline(hd pl);
		pendmenu = nil;
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
	cmd(tbtop, ".dm add command -command {send runreq show} -label " + tk->quote("Run..."));
	cmd(tbtop, "menu .dm.pwr");
	cmd(tbtop, ".dm.pwr add command -command {send powerreq reboot} -label Restart");
	cmd(tbtop, ".dm.pwr add command -command {send powerreq halt} -label " + tk->quote("Shut down"));
	cmd(tbtop, ".dm add cascade -menu .dm.pwr -label Power");
	cmd(tbtop, ".dm add separator");
	cmd(tbtop, ".dm add command -command {.m post " + string x + " " + string y + "} -label Apps");
	cmd(tbtop, ".dm post " + string x + " " + string y);
}

# Append the launcher extras (Run, Power) to the bottom of the Apps start menu
# once wmsetup has populated it.  wmsetup's `menu` builtin can only wire items to
# `send exec`, so these — which drive the run/power dialogs over their own
# channels — are added here in code rather than from the boot script.
addlaunchermenu()
{
	cmd(tbtop, ".m add separator");
	cmd(tbtop, ".m add command -command {send runreq show} -label " + tk->quote("Run..."));
	cmd(tbtop, "menu .m.pwr");
	cmd(tbtop, ".m.pwr add command -command {send powerreq reboot} -label Restart");
	cmd(tbtop, ".m.pwr add command -command {send powerreq halt} -label " + tk->quote("Shut down"));
	cmd(tbtop, ".m add cascade -menu .m.pwr -label Power");
	cmd(tbtop, ".m add command -command {send cfgreq show} -label " + tk->quote("Customize menu..."));
}

# A one-shot "Run a program" dialog.  Built on the Tkwidgets Combobox: type a
# command and an autocomplete dropdown of matching $path programs / files tracks
# what you type (Up/Down to pick, Tab to fill, click to choose).  On Enter (or
# Run) — if the program resolves against $path — the line is handed to the
# toolbar's shell context as `wmrun <line>` and the dialog closes.  Routing
# through `wmrun` (defined by wmsetup) is the same launch path every desktop app
# uses: the child gets its own process group (`pctl newpgrp`) and a copied shell
# environment, and its stdout/stderr land in the Log window.  A command that does
# not resolve leaves the dialog open with an error, so a typo never silently does
# nothing.
rundialog(ctxt: ref Draw->Context, exec: chan of string)
{
	if(tkwidgets == nil){
		tkwidgets = load Tkwidgets Tkwidgets->PATH;
		if(tkwidgets == nil){
			sys->fprint(stderr(), "wm: Run needs %s: %r\n", Tkwidgets->PATH);
			return;
		}
		tkwidgets->init();
	}

	(top, titlectl) := tkclient->toplevel(ctxt, "", "Run", tkclient->Appl);
	runc := chan of string;
	tk->namechan(top, runc, "runc");
	cmd(top, "frame .f");
	cmd(top, "label .f.l -text {Run: }");
	cmd(top, "pack .f.l -side left");
	cb := Combobox.new(top, ".f.cb", 40);
	cmd(top, "pack .f.cb -side left -fill x -expand 1");
	cmd(top, "label .msg -text {}");
	cmd(top, "frame .bb");
	cmd(top, "button .bb.run -text Run -command {send runc run}");
	cmd(top, "button .bb.cancel -text Cancel -command {send runc cancel}");
	cmd(top, "pack .bb.cancel -side right");
	cmd(top, "pack .bb.run -side right");
	cmd(top, "pack .f -fill x");
	cmd(top, "pack .msg -fill x");
	cmd(top, "pack .bb -fill x");
	cmd(top, "update");
	r := tk->rect(top, ".", Tk->Border|Tk->Required);
	cmd(top, ". configure -x " + string ((top.screenr.dx() - r.dx())/2 + top.screenr.min.x) +
		" -y " + string ((top.screenr.dy() - r.dy())/3 + top.screenr.min.y));
	tkclient->startinput(top, "ptr"::"kbd"::nil);
	tkclient->onscreen(top, "onscreen");
	cb.focus();
	cmd(top, "update");
	for(;;) alt {
	c := <-titlectl or
	c = <-top.wreq or
	c = <-top.ctxt.ctl =>
		if(c == "exit")
			return;
		tkclient->wmctl(top, c);
	k := <-top.ctxt.kbd =>
		tk->keyboard(top, k);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	ce := <-cb.ev =>
		case cb.event(ce) {
		"changed" =>
			(disp, val) := runsuggest(cb.text());
			cb.suggest(disp, val);
		"select" =>
			if(runcommit(top, exec, cb.text()))
				return;
		}
	m := <-runc =>
		case m {
		"cancel" =>
			return;
		"run" =>
			if(runcommit(top, exec, cb.text()))
				return;
		}
	}
}

# Validate `line` and, if it names a runnable program, launch it (return 1 so
# the caller closes the dialog).  Otherwise show the error and return 0 (stay
# open).  The brace makes the shell re-lex the line into wmrun + args (a bare
# word would be taken as one program name).
runcommit(top: ref Tk->Toplevel, exec: chan of string, line: string): int
{
	line = strip(line);
	if(line == "")
		return 0;
	err := badcommand(line);
	if(err != nil){
		cmd(top, ".msg configure -text " + tk->quote(err) + "; update");
		return 0;
	}
	exec <-= "{wmrun " + line + "}";
	return 1;
}

# Suggestions for the Run combobox: complete the final word of `line` against
# $path (when it is the command word) or the filesystem (an argument).  Returns
# (display, value): display = bare candidate names for the dropdown, value = the
# whole line with the final word replaced, ready to drop into the entry.
runsuggest(line: string): (array of string, array of string)
{
	i := len line;
	while(i > 0 && !iswhite(line[i-1]))
		i--;
	tok := line[i:];
	if(tok == "")			# nothing typed in this word: don't dump all of /dis
		return (nil, nil);

	cmdpos := 1;
	for(j := 0; j < i; j++)
		if(!iswhite(line[j])){
			cmdpos = 0;
			break;
		}
	(dir, base) := splitp(tok);
	m := listdir(dir, base);
	# the command word: also complete program names along $path
	if(cmdpos && !isabsolute(tok))
		for(pl := pathdirs(); pl != nil; pl = tl pl){
			pd := hd pl;
			if(dir != ".")
				pd = pd + "/" + dir;
			m = concatarr(m, listdir(pd, base));
		}
	m = dedup(m);
	if(len m == 0)
		return (nil, nil);

	pre := tok[0:len tok - len base];
	disp := array[len m] of string;
	val := array[len m] of string;
	for(k := 0; k < len m; k++){
		disp[k] = m[k];
		repl := m[k];
		if(len repl == 0 || repl[len repl-1] != '/')
			repl += " ";		# a file/program: leave room for args
		val[k] = line[0:i] + pre + repl;
	}
	# present the dropdown in name order
	for(a := 1; a < len disp; a++){
		db := disp[a];
		vb := val[a];
		b := a - 1;
		while(b >= 0 && disp[b] > db){
			disp[b+1] = disp[b];
			val[b+1] = val[b];
			b--;
		}
		disp[b+1] = db;
		val[b+1] = vb;
	}
	return (disp, val);
}

dedup(m: array of string): array of string
{
	seen: list of string;
	n := 0;
	for(i := 0; i < len m; i++)
		if(!inlist(m[i], seen)){
			seen = m[i] :: seen;
			n++;
		}
	r := array[n] of string;
	seen = nil;
	k := 0;
	for(i = 0; i < len m; i++)
		if(!inlist(m[i], seen)){
			seen = m[i] :: seen;
			r[k++] = m[i];
		}
	return r;
}

# Return an error string if `line` does not name a runnable program, else nil.
# A brace block or other shell construct is passed straight to the shell.
badcommand(line: string): string
{
	if(line[0] == '{')
		return nil;
	(n, toks) := sys->tokenize(line, " \t");
	if(n == 0)
		return nil;
	prog := hd toks;
	if(resolveprog(prog) == nil)
		return "not found: " + prog;
	return nil;
}

# Resolve `prog` the way the shell's runexternal does: an absolute name is
# taken as-is; any other name (even one with an interior '/', e.g. wm/clock) is
# searched along $path.  `.dis` is appended if absent.
resolveprog(prog: string): string
{
	pathlist: list of string;
	if(isabsolute(prog))
		pathlist = "" :: nil;
	else
		pathlist = pathdirs();
	for(; pathlist != nil; pathlist = tl pathlist){
		cand := prog;
		if(hd pathlist != "")
			cand = hd pathlist + "/" + prog;
		if(existsfile(cand))
			return cand;
		if(!hassuffix(prog, ".dis") && existsfile(cand + ".dis"))
			return cand + ".dis";
	}
	return nil;
}

# mirrors sh's absolute(): rooted at /, # (a device), ./ or ../
isabsolute(p: string): int
{
	if(len p >= 1 && (p[0] == '/' || p[0] == '#'))
		return 1;
	if(len p >= 2 && p[0] == '.' && p[1] == '/')
		return 1;
	if(len p >= 3 && p[0] == '.' && p[1] == '.' && p[2] == '/')
		return 1;
	return 0;
}

existsfile(path: string): int
{
	(ok, d) := sys->stat(path);
	return ok >= 0 && (d.mode & Sys->DMDIR) == 0;
}

hassuffix(s, suf: string): int
{
	return len s >= len suf && s[len s - len suf:] == suf;
}

# the command search path ($path), defaulting to the shell's ("/dis" ".").
pathdirs(): list of string
{
	s := getenvval("path");
	if(s == nil)
		return "/dis" :: "." :: nil;
	# $path is exported shell-quoted and space-separated (quoted(val,1)).
	toks := str->unquoted(s);
	if(toks == nil)
		return "/dis" :: "." :: nil;
	return toks;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

iswhite(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

splitp(tok: string): (string, string)
{
	k := -1;
	for(j := 0; j < len tok; j++)
		if(tok[j] == '/')
			k = j;
	if(k < 0)
		return (".", tok);
	return (tok[0:k+1], tok[k+1:]);
}

listdir(dir, base: string): array of string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return nil;
	res: list of string;
	nres := 0;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(j := 0; j < n; j++){
			nm := d[j].name;
			if(len nm >= len base && nm[0:len base] == base){
				if(d[j].mode & Sys->DMDIR)
					nm += "/";
				res = nm :: res;
				nres++;
			}
		}
	}
	a := array[nres] of string;
	k := 0;
	for(; res != nil; res = tl res)
		a[k++] = hd res;
	return a;
}

concatarr(a, b: array of string): array of string
{
	c := array[len a + len b] of string;
	k := 0;
	for(i := 0; i < len a; i++)
		c[k++] = a[i];
	for(j := 0; j < len b; j++)
		c[k++] = b[j];
	return c;
}

# A confirm dialog for halt/reboot; on confirm it writes the verb to
# /dev/sysctl (the #c console control), which the kernel turns into a clean
# emu/OS shutdown ("halt" -> cleanexit) or restart ("reboot" -> re-exec).
powerdialog(ctxt: ref Draw->Context, action: string)
{
	verb := "Shut down";
	if(action == "reboot")
		verb = "Restart";
	(top, titlectl) := tkclient->toplevel(ctxt, "", verb, tkclient->Appl);
	pc := chan of string;
	tk->namechan(top, pc, "pc");
	cmd(top, "label .l -text " + tk->quote(verb + " Inferno?"));
	cmd(top, "frame .b");
	cmd(top, "button .b.ok -text " + tk->quote(verb) + " -command {send pc ok}");
	cmd(top, "button .b.cancel -text Cancel -command {send pc cancel}");
	cmd(top, "pack .b.cancel -side right");
	cmd(top, "pack .b.ok -side right");
	cmd(top, "pack .l -fill x -padx 8 -pady 6");
	cmd(top, "pack .b -fill x");
	cmd(top, "update");
	r := tk->rect(top, ".", Tk->Border|Tk->Required);
	cmd(top, ". configure -x " + string ((top.screenr.dx() - r.dx())/2 + top.screenr.min.x) +
		" -y " + string ((top.screenr.dy() - r.dy())/3 + top.screenr.min.y));
	tkclient->startinput(top, "ptr"::"kbd"::nil);
	tkclient->onscreen(top, "onscreen");
	for(;;) alt {
	c := <-titlectl or
	c = <-top.wreq or
	c = <-top.ctxt.ctl =>
		if(c == "exit")
			return;
		tkclient->wmctl(top, c);
	k := <-top.ctxt.kbd =>
		tk->keyboard(top, k);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	m := <-pc =>
		case m {
		"cancel" =>
			return;
		"ok" =>
			powerctl(action);
			return;
		}
	}
}

powerctl(action: string)
{
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	if(fd == nil){
		sys->fprint(stderr(), "wm: cannot open /dev/sysctl: %r\n");
		return;
	}
	sys->fprint(fd, "%s", action);
}

# --- the graphical launcher editor ---
#
# A live view of the launcher model.  Every operation mutates the shared model
# under menulock and rebuilds .m at once, so the menu it edits is the menu you
# see.  "Save" serialises the model to $home/lib/menu, which /lib/wmsetup
# replays at the next login (it does a `delmenu` first, so it fully defines the
# menu when present).  The launcher extras (Run/Power/Customize) are added in
# code after the model is built, so they are neither shown here nor persisted.
mcfg := array[] of {
	"frame .top",
	"frame .top.lf",
	"scrollbar .top.lf.s -command {.top.lf.l yview}",
	"listbox .top.lf.l -width 40w -height 12w -yscrollcommand {.top.lf.s set}",
	"bind .top.lf.l <ButtonRelease-1> {send mc sel}",
	"pack .top.lf.s -side left -fill y",
	"pack .top.lf.l -side left -fill both -expand 1",
	"frame .top.rf",
	"button .top.rf.up -text {Move Up} -command {send mc up} -width 10w",
	"button .top.rf.dn -text {Move Down} -command {send mc down} -width 10w",
	"button .top.rf.rm -text {Remove} -command {send mc remove} -width 10w",
	"pack .top.rf.up .top.rf.dn .top.rf.rm -side top -fill x -pady 1",
	"pack .top.lf -side left -fill both -expand 1",
	"pack .top.rf -side left -fill y -padx 4",
	"frame .f0",
	"label .f0.l -text {Menu:} -width 9w -anchor w",
	"entry .f0.e -width 32",
	"pack .f0.l -side left",
	"pack .f0.e -side left -fill x -expand 1",
	"frame .f1",
	"label .f1.l -text {Submenu:} -width 9w -anchor w",
	"entry .f1.e -width 32",
	"pack .f1.l -side left",
	"pack .f1.e -side left -fill x -expand 1",
	"frame .f2",
	"label .f2.l -text {Command:} -width 9w -anchor w",
	"entry .f2.e -width 32",
	"pack .f2.l -side left",
	"pack .f2.e -side left -fill x -expand 1",
	"frame .ab",
	"button .ab.add -text {Add} -command {send mc add}",
	"button .ab.upd -text {Update} -command {send mc update}",
	"button .ab.sep -text {Add Separator} -command {send mc addsep}",
	"pack .ab.add .ab.upd .ab.sep -side left -padx 2",
	"label .status -text {} -anchor w",
	"frame .bb",
	"button .bb.save -text {Save} -command {send mc save}",
	"button .bb.close -text {Close} -command {send mc close}",
	"pack .bb.close -side right -padx 2",
	"pack .bb.save -side left -padx 2",
	"pack .top -fill both -expand 1 -padx 4 -pady 2",
	"pack .f0 -fill x -padx 4",
	"pack .f1 -fill x -padx 4",
	"pack .f2 -fill x -padx 4 -pady 1",
	"pack .ab -fill x -padx 4 -pady 2",
	"pack .status -fill x -padx 4",
	"pack .bb -fill x -padx 4 -pady 2",
	"pack propagate . 0",
	"update",
};

# Run the editor and report when it closes, so init can keep at most one open.
runconfig(ctxt: ref Draw->Context)
{
	menuconfig(ctxt);
	cfgdone <-= 1;
}

menuconfig(ctxt: ref Draw->Context)
{
	(top, titlectl) := tkclient->toplevel(ctxt, "", "Customize Menu", tkclient->Appl);
	mc := chan of string;
	tk->namechan(top, mc, "mc");
	for(i := 0; i < len mcfg; i++)
		cmd(top, mcfg[i]);
	refreshlist(top);
	r := tk->rect(top, ".", Tk->Border|Tk->Required);
	cmd(top, ". configure -x " + string ((top.screenr.dx() - r.dx())/2 + top.screenr.min.x) +
		" -y " + string ((top.screenr.dy() - r.dy())/3 + top.screenr.min.y));
	tkclient->startinput(top, "ptr"::"kbd"::nil);
	tkclient->onscreen(top, "onscreen");
	cmd(top, "update");
	for(;;) alt {
	c := <-titlectl or
	c = <-top.wreq or
	c = <-top.ctxt.ctl =>
		if(c == "exit")
			return;
		tkclient->wmctl(top, c);
	k := <-top.ctxt.kbd =>
		tk->keyboard(top, k);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	m := <-mc =>
		if(m == "close")
			return;
		domenucmd(top, m);
	}
}

domenucmd(top: ref Tk->Toplevel, m: string)
{
	case m {
	"sel" =>
		i := selindex(top);
		if(i < 0)
			return;
		lockmenu();
		e := nthentry(i);
		unlockmenu();
		if(e != nil){
			setentry(top, ".f0.e", e.menu);
			setentry(top, ".f1.e", e.label);
			setentry(top, ".f2.e", unbrace(e.command));
		}
	"add" or
	"addsep" =>
		pri := strip(cmd(top, ".f0.e get"));
		lab := strip(cmd(top, ".f1.e get"));
		command := "";
		if(m == "add"){
			command = bracecmd(cmd(top, ".f2.e get"));
			if(command == ""){
				setstatus(top, "Command is empty (use Add Separator for a divider)");
				return;
			}
		}
		e := ref Mentry(pri, lab, command);
		lockmenu();
		a := modelarray();
		a = insertat(a, e, selindex(top) + 1);	# after the selection, else at end
		modelset(a);
		canonicalize();
		rebuildmenu();
		unlockmenu();
		refreshlist(top);
	"update" =>
		i := selindex(top);
		if(i < 0){
			setstatus(top, "Select an entry to update");
			return;
		}
		pri := strip(cmd(top, ".f0.e get"));
		lab := strip(cmd(top, ".f1.e get"));
		command := bracecmd(cmd(top, ".f2.e get"));
		lockmenu();
		a := modelarray();
		if(i < len a)
			a[i] = ref Mentry(pri, lab, command);
		modelset(a);
		canonicalize();
		rebuildmenu();
		unlockmenu();
		refreshlist(top);
		selectrow(top, i);
	"remove" =>
		i := selindex(top);
		if(i < 0)
			return;
		lockmenu();
		a := modelarray();
		if(i < len a)
			a = removeat(a, i);
		modelset(a);
		canonicalize();
		rebuildmenu();
		unlockmenu();
		refreshlist(top);
	"up" or
	"down" =>
		i := selindex(top);
		if(i < 0)
			return;
		j := i - 1;
		if(m == "down")
			j = i + 1;
		lockmenu();
		a := modelarray();
		if(j >= 0 && j < len a){
			t := a[i]; a[i] = a[j]; a[j] = t;
			modelset(a);
			canonicalize();
			rebuildmenu();
		}
		unlockmenu();
		if(j >= 0 && j < len a){
			refreshlist(top);
			selectrow(top, j);
		}
	"save" =>
		lockmenu();
		canonicalize();
		rebuildmenu();
		txt := menudump();
		unlockmenu();
		refreshlist(top);
		err := writemenufile(txt);
		if(err != nil)
			setstatus(top, err);
		else
			setstatus(top, "Saved to " + menufilepath());
	}
}

# the listbox row is index-for-index with the model, so a row number is a model
# index directly.
selindex(top: ref Tk->Toplevel): int
{
	s := cmd(top, ".top.lf.l curselection");
	if(s == "" || s[0] == '!')
		return -1;
	return int s;
}

selectrow(top: ref Tk->Toplevel, i: int)
{
	cmd(top, ".top.lf.l selection clear 0 end");
	cmd(top, ".top.lf.l selection set " + string i);
	cmd(top, ".top.lf.l see " + string i);
	cmd(top, "update");
}

setentry(top: ref Tk->Toplevel, w, s: string)
{
	cmd(top, w + " delete 0 end");
	if(s != "")
		cmd(top, w + " insert 0 " + tk->quote(s));
}

setstatus(top: ref Tk->Toplevel, s: string)
{
	cmd(top, ".status configure -text " + tk->quote(s) + "; update");
}

refreshlist(top: ref Tk->Toplevel)
{
	cmd(top, ".top.lf.l delete 0 end");
	lockmenu();
	for(l := mentries; l != nil; l = tl l)
		cmd(top, ".top.lf.l insert end " + tk->quote(rowtext(hd l)));
	unlockmenu();
	cmd(top, "update");
}

rowtext(e: ref Mentry): string
{
	if(e.command == ""){
		if(e.label == "")
			return "--------";
		return "    --------";
	}
	if(e.label == "")
		return e.menu;
	return "    " + e.menu + " > " + e.label;
}

nthentry(i: int): ref Mentry
{
	for(l := mentries; l != nil && i > 0; l = tl l)
		i--;
	if(l == nil)
		return nil;
	return hd l;
}

modelarray(): array of ref Mentry
{
	a := array[len mentries] of ref Mentry;
	i := 0;
	for(l := mentries; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

modelset(a: array of ref Mentry)
{
	l: list of ref Mentry;
	for(i := len a - 1; i >= 0; i--)
		l = a[i] :: l;
	mentries = l;
}

insertat(a: array of ref Mentry, e: ref Mentry, p: int): array of ref Mentry
{
	if(p < 0)
		p = 0;
	if(p > len a)
		p = len a;
	na := array[len a + 1] of ref Mentry;
	na[0:] = a[0:p];
	na[p] = e;
	na[p+1:] = a[p:];
	return na;
}

removeat(a: array of ref Mentry, p: int): array of ref Mentry
{
	na := array[len a - 1] of ref Mentry;
	na[0:] = a[0:p];
	na[p:] = a[p+1:];
	return na;
}

bracecmd(s: string): string
{
	s = strip(s);
	if(s == "")
		return "";
	if(s[0] == '{')
		return s;
	return "{" + s + "}";
}

unbrace(s: string): string
{
	if(len s >= 2 && s[0] == '{' && s[len s - 1] == '}')
		return s[1:len s - 1];
	return s;
}

menufilepath(): string
{
	home := gethome();
	if(home == nil)
		return nil;
	return home + "/lib/menu";
}

gethome(): string
{
	h := getenvval("home");
	if(h != nil)
		return h;
	u := getuser();
	if(u != nil)
		return "/usr/" + u;
	return nil;
}

getuser(): string
{
	u := readfilesmall("/dev/user");
	while(u != nil && (u[len u-1] == '\n' || u[len u-1] == ' ' || u[len u-1] == '\0'))
		u = u[0:len u-1];
	return u;
}

writemenufile(txt: string): string
{
	path := menufilepath();
	if(path == nil)
		return "cannot determine home directory";
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	b := array of byte txt;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("cannot write %s: %r", path);
	return nil;
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
	runreq = chan of string;
	tk->namechan(tbtop, runreq, "runreq");
	powerreq = chan of string;
	tk->namechan(tbtop, powerreq, "powerreq");
	cfgreq = chan of string;
	tk->namechan(tbtop, cfgreq, "cfgreq");
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
	secondary := "";
	if (n == 4) {
		secondary = (hd argv).word;
		argv = tl argv;
	}
	command := word(hd argv);
	lockmenu();
	addentry(primary, secondary, command);
	rebuildmenu();
	unlockmenu();
	return nil;
}

# delmenu                   -> forget every menu item
# delmenu primary           -> drop a top-level item or an entire cascade
# delmenu primary secondary -> drop a single submenu item
builtin_delmenu(nil: ref Context, nil: Sh, argv: list of ref Listnode): string
{
	args := tl argv;	# skip the "delmenu" word
	lockmenu();
	if (args == nil)
		mentries = nil;
	else {
		primary := (hd args).word;
		secondary := "";
		if (tl args != nil)
			secondary = (hd tl args).word;
		delentry(primary, secondary);
	}
	rebuildmenu();
	unlockmenu();
	return nil;
}

# --- the launcher-menu model ---

lockmenu()	{ menulock <-= 0; }
unlockmenu()	{ <-menulock; }

cascadeexists(menu: string): int
{
	for (l := mentries; l != nil; l = tl l)
		if ((hd l).label != "" && (hd l).menu == menu)
			return 1;
	return 0;
}

# Insert an entry exactly as the legacy `menu` builtin did: a top-level item
# goes to the very top of the menu; a submenu item goes to the top of its
# cascade, creating the cascade at the top of the menu if it does not exist yet.
# Caller holds menulock.
addentry(menu, label, command: string)
{
	e := ref Mentry(menu, label, command);
	if (label == "" || !cascadeexists(menu)) {
		mentries = e :: mentries;
		return;
	}
	res: list of ref Mentry;
	inserted := 0;
	for (l := mentries; l != nil; l = tl l) {
		h := hd l;
		if (!inserted && h.label != "" && h.menu == menu) {
			res = e :: res;
			inserted = 1;
		}
		res = h :: res;
	}
	mentries = revmentries(res);
}

# delentry(menu, "")    drops the whole top-level slot named `menu`;
# delentry(menu, label) drops one submenu item.  Caller holds menulock.
delentry(menu, label: string)
{
	res: list of ref Mentry;
	for (l := mentries; l != nil; l = tl l) {
		h := hd l;
		drop := 0;
		if (label == "")
			drop = h.menu == menu;
		else
			drop = h.label != "" && h.menu == menu && h.label == label;
		if (!drop)
			res = h :: res;
	}
	mentries = revmentries(res);
}

revmentries(l: list of ref Mentry): list of ref Mentry
{
	r: list of ref Mentry;
	for (; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# Gather each cascade's items at the cascade's first appearance, leaving
# top-level items where they sit.  Keeps the model contiguous per cascade so a
# free reorder in the editor can't scatter a submenu, and so the serialised
# script round-trips.  Caller holds menulock.
canonicalize()
{
	res: list of ref Mentry;	# built reversed
	placed: list of string;
	for (l := mentries; l != nil; l = tl l) {
		e := hd l;
		if (e.label == "") {
			res = e :: res;
			continue;
		}
		if (inlist(e.menu, placed))
			continue;
		placed = e.menu :: placed;
		for (m := mentries; m != nil; m = tl m) {
			f := hd m;
			if (f.label != "" && f.menu == e.menu)
				res = f :: res;
		}
	}
	mentries = revmentries(res);
}

# Tear down the Apps menu and rebuild it from the model.  A full rebuild (rather
# than incremental Tk insert/delete) is simpler and immune to index drift; the
# menu is small and this only runs on edits, not in any hot path.  Caller holds
# menulock.
rebuildmenu()
{
	delmenu(".m");
	cmd(tbtop, "menu .m");
	built: list of string;
	for (l := mentries; l != nil; l = tl l) {
		e := hd l;
		if (e.label == "") {
			if (e.command == "")
				cmd(tbtop, ".m add separator");
			else
				cmd(tbtop, ".m add command -label " + tk->quote(e.menu) +
					" -command {send exec " + e.command + "}");
		} else {
			mpath := menupath(e.menu);
			if (!inlist(e.menu, built)) {
				cmd(tbtop, "menu " + mpath);
				cmd(tbtop, ".m add cascade -label " + tk->quote(e.menu) +
					" -menu " + mpath);
				built = e.menu :: built;
			}
			if (e.command == "")
				cmd(tbtop, mpath + " add separator");
			else
				cmd(tbtop, mpath + " add command -label " + tk->quote(e.label) +
					" -command {send exec " + e.command + "}");
		}
	}
	if (extrasadded)
		addlaunchermenu();
	cmd(tbtop, "update");
}

# Serialise the model as a script that recreates it: a leading `delmenu` to
# clear whatever defaults preceded it, then one `menu` line per entry.  Because
# the `menu` builtin inserts at the top, lines are emitted in reverse display
# order so replaying them reproduces the on-screen order.  This is what the
# editor writes to $home/lib/menu and what `cat /chan/wmmenu` returns.
menudump(): string
{
	s := "delmenu\n";
	for (l := revmentries(mentries); l != nil; l = tl l) {
		e := hd l;
		c := e.command;
		if (c == "")
			c = "''";		# an empty word: a separator
		if (e.label == "")
			s += "menu " + shquote(e.menu) + " " + c + "\n";
		else
			s += "menu " + shquote(e.menu) + " " + shquote(e.label) + " " + c + "\n";
	}
	return s;
}

# Only the `menu`/`delmenu` verbs are honoured from the control file, and the
# whole line is handed to the toolbar's shell wrapped in a block so its
# arguments (quoting, the {..} command) parse exactly as they do in
# /lib/wmsetup.  Rejecting other verbs keeps /chan/wmmenu from being a way to
# run arbitrary shell.
runmenuline(line: string)
{
	(n, toks) := sys->tokenize(line, " \t");
	if (n == 0)
		return;
	case hd toks {
	"menu" or
	"delmenu" =>
		{
			shctxt.run(ref Listnode(nil, "{" + line + "}") :: nil, 0);
		} exception {
		"fail:*" =>	;
		}
	}
}

revstrlist(l: list of string): list of string
{
	r: list of string;
	for (; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# Shell single-quote a word for the persisted script: wrap and double interior
# quotes only when the word holds characters the shell would otherwise act on.
shquote(s: string): string
{
	if (s == "")
		return "''";
	q := 0;
	for (i := 0; i < len s; i++) {
		c := s[i];
		if (c==' '||c=='\t'||c=='\n'||c=='\''||c=='"'||c=='{'||c=='}'||
		   c=='('||c==')'||c=='$'||c=='`'||c==';'||c=='&'||c=='|'||
		   c=='^'||c=='#'||c=='='||c=='<'||c=='>') {
			q = 1;
			break;
		}
	}
	if (!q)
		return s;
	r := "'";
	for (i = 0; i < len s; i++) {
		if (s[i] == '\'')
			r += "''";
		else
			r[len r] = s[i];
	}
	return r + "'";
}

# Tear down a menu and its cascades.  Probes with raw tk->cmd rather than the
# error-printing cmd() wrapper: rebuildmenu calls this on a freshly created,
# still-empty .m, where `type 0` legitimately reports a bad index — not an error
# worth logging.
delmenu(m: string)
{
	for (i := int tk->cmd(tbtop, m + " index end"); i >= 0; i--)
		if (tk->cmd(tbtop, m + " type " + string i) == "cascade")
			delmenu(tk->cmd(tbtop, m + " entrycget " + string i + " -menu"));
	tk->cmd(tbtop, "destroy " + m);
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
	"entry .ctl.f -width 20",
	"button .ctl.fc -text Clear -command {send logcmd clearfilter} -bd 1",
	"pack .ctl.src -side left",
	"pack .ctl.fl -side left",
	"pack .ctl.f -side left -fill x -expand 1",
	"pack .ctl.fc -side left",
	"bind .ctl.f <Key> +{send logcmd filter}",
	"frame .ask",
	"label .ask.l",
	"entry .ask.e -width 40",
	"button .ask.c -text Cancel -command {send logcmd cancel} -bd 1",
	"pack .ask.l -side left",
	"pack .ask.e -side left -fill x -expand 1",
	"pack .ask.c -side left",
	"bind .ask.e <Key-\n> {send logcmd submit}",
	"frame .tags",
	"frame .cons",
	"scrollbar .cons.scroll -command {.cons.t yview}",
	# no -bg/-fg: inherits the system theme palette and re-themes live
	"text .cons.t -width 60w -height 15w -font /fonts/misc/latin1.6x13.font "+
		"-yscrollcommand {.cons.scroll set}",
	"pack .cons.scroll -side left -fill y",
	"pack .cons.t -fill both -expand 1",
	"pack .ctl -fill x",
	"pack .tags -fill x",
	"pack .cons -expand 1 -fill both",
	"pack propagate . 0",
	"update"
};

# distinct foreground colours handed out to sources in arrival order.  These
# are the per-source tag/button colours and sit over the themed (possibly dark)
# console background, so they are mid-luminance hues that stay legible on both a
# light and a dark palette rather than the darker originals.
palette := array[] of {
	"#5a8de0", "#46b446", "#e06464", "#c8a020",
	"#b48cf0", "#3cc0c0", "#e070b4", "#a8a8a8",
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
