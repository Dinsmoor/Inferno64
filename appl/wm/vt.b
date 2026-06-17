implement WmVt;

#
# wm/vt -- a terminal window.  This is now a thin embedder: all the VT100/ANSI
# emulation lives in the reusable Term widget (module/term.m, appl/lib/term.b);
# this file just opens a window, drops a Term in it, and wires it to a shell.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "tkclient.m";
	tkclient: Tkclient;
include "term.m";
	terminal: Terminal;
	Term, Termio: import terminal;

WmVt: module {
	init:   fn(ctxt: ref Draw->Context, argv: list of string);
};

COLS: con 80;
ROWS: con 24;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	if(ctxt == nil){
		sys->fprint(sys->fildes(2), "vt: no window context\n");
		raise "fail:bad context";
	}
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	terminal = load Terminal Terminal->PATH;
	if(terminal == nil){
		sys->fprint(sys->fildes(2), "vt: cannot load %s: %r\n", Terminal->PATH);
		raise "fail:load";
	}
	terminal->init();

	sys->pctl(Sys->FORKNS, nil);
	sys->pctl(Sys->NEWPGRP, nil);

	tkclient->init();
	(t, menubut) := tkclient->toplevel(ctxt, "", "VT", Tkclient->Appl);

	term := Term.new(t, ctxt.display, ".t", COLS, ROWS, "");
	tk->cmd(t, "pack .t");
	tk->cmd(t, "update");

	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd" :: "ptr" :: nil);
	term.show();

	tio := terminal->attach(ctxt, "sh" :: "-n" :: nil);
	if(tio == nil){
		sys->fprint(sys->fildes(2), "vt: cannot start shell: %r\n");
		return;
	}

	for(;;) alt {
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);
	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);
	s := <-t.ctxt.ctl or
	s = <-t.wreq =>
		tkclient->wmctl(t, s);
	menu := <-menubut =>
		if(menu == "exit"){
			kill(tio.pid);
			return;
		}
		tkclient->wmctl(t, menu);
		tk->cmd(t, "focus .t");
	key := <-term.ev =>
		tio.send(term.onkey(key));
	out := <-tio.out =>
		reply := term.output(out);
		if(reply != "")
			tio.send(reply);
	}
}

kill(pid: int)
{
	fd := sys->open("#p/"+string pid+"/ctl", sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}
