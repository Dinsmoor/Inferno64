implement TkFont;

#
# Headless functional test for the `font' command (measurement subset).
# Run under a graphical emu (Xvfb).
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

TkFont: module
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
		sys->fprint(sys->fildes(2), "tkfont: no window context\n");
		raise "fail:no ctxt";
	}
	(top, nil) = tkclient->toplevel(ctxt, "200x150", "tkfont", Tkclient->Appl);

	# measure in the default font (empty spec)
	w0 := int cmd("font measure {} {}");
	ok("empty string measures 0", w0 == 0);

	wa := int cmd("font measure {} a");
	ok("single char has positive width", wa > 0);

	w4 := int cmd("font measure {} aaaa");
	ok("four chars wider than one", w4 > wa);
	ok("width is monotonic", w4 >= 4*wa - 4 && w4 <= 4*wa + 4);

	# metrics
	line := int cmd("font metrics {} -linespace");
	asc := int cmd("font metrics {} -ascent");
	desc := int cmd("font metrics {} -descent");
	ok("linespace positive", line > 0);
	ok("ascent positive", asc > 0);
	ok("descent non-negative", desc >= 0);
	ok("ascent+descent == linespace", asc + desc == line);

	# aggregate metrics line includes the parts
	allm := cmd("font metrics {}");
	ok("metrics dump has -ascent", has(allm, "-ascent"));
	ok("metrics dump has -linespace", has(allm, "-linespace"));

	# families/names exist (empty in this port) without erroring
	ok("font families ok", cmd("font families") == "");
	ok("font names ok", cmd("font names") == "");

	sys->print("1..%d\n", nok+nfail);
	if(nfail == 0)
		sys->print("# all %d font tests passed\n", nok);
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
