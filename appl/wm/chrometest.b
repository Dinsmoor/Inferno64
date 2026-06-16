implement Chrometest;

#
# chrometest -- visual check for the Titletex decorative-titlebar renderer.
# Shows the flat / castle / temple bars stacked, each in focused and unfocused
# tint, so the procedural stone texture + baked title can be eyeballed (and
# screenshotted) without wiring it into the live window chrome.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "titletex.m";
	titletex: Titletex;

Chrometest: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

W:	con 460;
H:	con 22;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	titletex = load Titletex Titletex->PATH;
	if(tkclient == nil || titletex == nil){
		sys->fprint(sys->fildes(2), "chrometest: cannot load modules: %r\n");
		raise "fail:bad module";
	}
	tkclient->init();
	sys->pctl(Sys->NEWPGRP, nil);
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	titletex->init(ctxt.display);

	(win, wmctl) := tkclient->toplevel(ctxt, nil, "Chrome test", 0);

	rows := array[] of {
		("flat",          "flat",   Titletex->FLAT,   0),
		("castle focus",  "castle", Titletex->CASTLE, 1),
		("castle blur",   "castle", Titletex->CASTLE, 0),
		("temple focus",  "temple", Titletex->TEMPLE, 1),
		("temple blur",   "temple", Titletex->TEMPLE, 0),
	};

	cmd(win, "frame .f");
	for(i := 0; i < len rows; i++){
		p := ".f.p" + string i;
		cmd(win, "panel " + p + " -bd 0 -width " + string W + " -height " + string H);
		cmd(win, "pack " + p + " -side top");
	}
	cmd(win, "pack .f -fill both -expand 1");
	cmd(win, "pack propagate . 0");

	tkclient->onscreen(win, nil);
	tkclient->startinput(win, "kbd"::"ptr"::nil);

	for(i = 0; i < len rows; i++){
		(label, sname, style, focus) := rows[i];
		p := ".f.p" + string i;
		img: ref Image;
		if(style == Titletex->FLAT)
			img = ctxt.display.newimage(Rect((0,0),(W,H)), draw->RGB24, 0, int 16raaaaaaff);
		else
			img = titletex->render(style, W, H, focus,
				sname + ": Welcome to Hell", draw->White);
		if(img == nil){
			sys->fprint(sys->fildes(2), "chrometest: render %s failed\n", label);
			continue;
		}
		tk->putimage(win, p, img, nil);
		cmd(win, p + " dirty");
	}
	cmd(win, "update");

	for(;;) alt {
	s := <-win.ctxt.kbd =>
		tk->keyboard(win, s);
	s := <-win.ctxt.ptr =>
		tk->pointer(win, *s);
	s := <-win.ctxt.ctl or
	s = <-win.wreq or
	s = <-wmctl =>
		if(s == "exit")
			return;
		tkclient->wmctl(win, s);
	}
}

cmd(top: ref Tk->Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if(e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "chrometest: tk error %s on '%s'\n", e, s);
	return e;
}
