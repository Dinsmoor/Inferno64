implement TkEvent;

#
# Headless functional test for `event generate' and virtual events
# (bind .w <<Name>> ...).  Run under a graphical emu (Xvfb).
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

TkEvent: module
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
		sys->fprint(sys->fildes(2), "tkevent: no window context\n");
		raise "fail:no ctxt";
	}
	(top, nil) = tkclient->toplevel(ctxt, "300x200", "tkevent", Tkclient->Appl);

	# a button + two result labels the bound scripts will mutate
	cmd("button .b -text hit");
	cmd("label .r1 -text -");
	cmd("label .r2 -text -");
	cmd("pack .b .r1 .r2");
	cmd("update");

	# 1. concrete event: a bind fires when generated
	cmd("bind .b <Button-1> {.r1 configure -text pressed}");
	cmd("event generate .b <Button-1>");
	cmd("update");
	ok("concrete <Button-1> binding fired", cmd(".r1 cget -text") == "pressed");

	# 2. coordinates are substituted from -x/-y
	cmd("bind .b <Button-3> {.r1 configure -text %x}");
	cmd("event generate .b <Button-3> -x 7 -y 9");
	cmd("update");
	ok("event -x coord substituted", cmd(".r1 cget -text") == "7");

	# 3. virtual event: register, fire, observe
	cmd("bind .b <<Custom>> {.r1 configure -text virt1}");
	cmd("event generate .b <<Custom>>");
	cmd("update");
	ok("virtual event fired", cmd(".r1 cget -text") == "virt1");

	# 4. a second (additive) virtual binding also fires
	cmd("bind .b <<Custom>> +{.r2 configure -text virt2}");
	cmd(".r1 configure -text -");
	cmd(".r2 configure -text -");
	cmd("event generate .b <<Custom>>");
	cmd("update");
	ok("first virtual binding still fires", cmd(".r1 cget -text") == "virt1");
	ok("added virtual binding fires too", cmd(".r2 cget -text") == "virt2");

	# 5. an empty script removes the virtual bindings
	cmd("bind .b <<Custom>> {}");
	cmd(".r1 configure -text none");
	cmd(".r2 configure -text none");
	cmd("event generate .b <<Custom>>");
	cmd("update");
	ok("removed virtual binding does not fire", cmd(".r1 cget -text") == "none" && cmd(".r2 cget -text") == "none");

	# 6. an unrelated virtual name does not fire Custom's old binding
	cmd("bind .b <<Other>> {.r2 configure -text other}");
	cmd("event generate .b <<Custom>>");
	cmd("update");
	ok("unrelated virtual name is independent", cmd(".r2 cget -text") == "none");
	cmd("event generate .b <<Other>>");
	cmd("update");
	ok("named virtual event fires its own binding", cmd(".r2 cget -text") == "other");

	sys->print("1..%d\n", nok+nfail);
	if(nfail == 0)
		sys->print("# all %d event tests passed\n", nok);
	else
		sys->print("# %d FAILED\n", nfail);
	shutdown();
	exit;
}

shutdown()
{
	fd := sys->open("#p/" + string mypid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}
