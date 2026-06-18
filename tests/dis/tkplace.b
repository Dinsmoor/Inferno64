implement TkPlace;

#
# Headless functional test for the Tk `place' geometry manager (and the
# winfo geometry queries it leans on).  Run under a graphical emu (Xvfb).
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

TkPlace: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

top: ref Tk->Toplevel;
mypid := 0;
nok := 0;
nfail := 0;

ok(desc: string, cond: int)
{
	if(cond){
		nok++;
		sys->print("ok - %s\n", desc);
	} else {
		nfail++;
		sys->print("not ok - %s\n", desc);
	}
}

cmd(s: string): string
{
	return tk->cmd(top, s);
}

wint(s: string): int
{
	return int cmd("winfo " + s);
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
		sys->fprint(sys->fildes(2), "tkplace: no window context\n");
		raise "fail:no ctxt";
	}
	(top, nil) = tkclient->toplevel(ctxt, "300x300", "tkplace", Tkclient->Appl);

	# a fixed-size master that does not shrink to its (placed-only) contents
	cmd("frame .f -width 200 -height 200 -borderwidth 0");
	cmd("pack propagate .f 0");
	cmd("pack .f");
	cmd("update");

	fw := wint("width .f");
	fh := wint("height .f");
	ok("master keeps requested size", fw == 200 && fh == 200);

	# 1. absolute placement, default anchor nw
	cmd("label .f.a -text A -borderwidth 0");
	cmd("place .f.a -x 10 -y 20");
	cmd("update");
	ok("absolute -x", wint("x .f.a") == 10);
	ok("absolute -y", wint("y .f.a") == 20);

	# 2. relative placement, centred, explicit size
	cmd("label .f.b -text B -borderwidth 0");
	cmd("place .f.b -relx 0.5 -rely 0.5 -width 40 -height 20 -anchor center");
	cmd("update");
	ok("centred relx x", wint("x .f.b") == fw/2 - 20);
	ok("centred rely y", wint("y .f.b") == fh/2 - 10);
	ok("explicit -width", wint("width .f.b") == 40);
	ok("explicit -height", wint("height .f.b") == 20);

	# 3. relwidth/relheight fill the master
	cmd("label .f.c -text C -borderwidth 0");
	cmd("place .f.c -relwidth 1.0 -relheight 1.0");
	cmd("update");
	ok("relwidth fills", wint("width .f.c") == fw);
	ok("relheight fills", wint("height .f.c") == fh);
	ok("fill origin x", wint("x .f.c") == 0);

	# 4. place info / slaves
	info := cmd("place info .f.a");
	ok("place info reports -x", has(info, "-x 10"));
	slaves := cmd("place slaves .f");
	ok("place slaves lists placed children", has(slaves, ".f.a") && has(slaves, ".f.b") && has(slaves, ".f.c"));

	# 5. forget unmaps and de-lists
	cmd("place forget .f.a");
	cmd("update");
	ok("forget unmaps", wint("ismapped .f.a") == 0);
	ok("forget de-lists", !has(cmd("place slaves .f"), ".f.a"));

	# 6. place must not disturb a packed sibling tree (compat): pack a label in .f too
	#    (mixing pack-managed and placed children in the same master)
	cmd("frame .g -borderwidth 0");
	cmd("label .g.p -text packed -borderwidth 0");
	cmd("pack .g.p");
	cmd("label .g.o -text over -borderwidth 0");
	cmd("place .g.o -x 5 -y 5");
	cmd("pack .g");
	cmd("update");
	ok("packed sibling still mapped under place", wint("ismapped .g.p") == 1);
	ok("placed overlay positioned", wint("x .g.o") == 5);

	# 7. winfo basics that ttk will rely on
	ok("winfo exists yes", cmd("winfo exists .f") == "1");
	ok("winfo exists no", cmd("winfo exists .nope") == "0");
	ok("winfo class", cmd("winfo class .f") == "frame");
	ok("winfo children", has(cmd("winfo children .f"), ".f.b"));

	sys->print("1..%d\n", nok+nfail);
	if(nfail == 0)
		sys->print("# all %d place/winfo tests passed\n", nok);
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
