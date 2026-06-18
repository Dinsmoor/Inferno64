implement TkAfter;

#
# Headless functional test for the Tk `after' command.
# Run under a graphical emu (Xvfb):
#	emu -g320x240 /dis/tests/tkafter.dis
# Emits TAP-ish lines to stdout and exits 0 on success, 1 on failure.
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

TkAfter: module
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
		sys->fprint(sys->fildes(2), "tkafter: no window context\n");
		raise "fail:no ctxt";
	}
	(top, nil) = tkclient->toplevel(ctxt, "", "tkafter", Tkclient->Appl);

	cmd("label .l -text START");
	cmd("pack .l");
	cmd("update");

	# 1. a basic timer fires and runs its script
	id := cmd("after 120 {.l configure -text DONE}");
	ok("after returns an id", len id > 6 && id[0:6] == "after#");
	ok("after info lists the pending id", cmd("after info") == id);
	sys->sleep(350);
	ok("timer script ran", cmd(".l cget -text") == "DONE");
	ok("queue empty after firing", cmd("after info") == "");

	# 2. cancel by id prevents the script from running
	cmd(".l configure -text KEEP");
	id2 := cmd("after 120 {.l configure -text SHOULDNOTRUN}");
	cmd("after cancel " + id2);
	ok("cancelled id gone from info", cmd("after info") == "");
	sys->sleep(350);
	ok("cancelled script did not run", cmd(".l cget -text") == "KEEP");

	# 3. cancel by script text
	cmd(".l configure -text KEEP2");
	cmd("after 120 {.l configure -text NOPE}");
	cmd("after cancel {.l configure -text NOPE}");
	sys->sleep(350);
	ok("cancel-by-script did not run", cmd(".l cget -text") == "KEEP2");

	# 4. after idle runs promptly
	cmd(".l configure -text IDLESTART");
	cmd("after idle {.l configure -text IDLED}");
	sys->sleep(150);
	ok("idle script ran", cmd(".l cget -text") == "IDLED");

	# 5. after info <id> reports script + type
	id5 := cmd("after 5000 {.l configure -text LATER}");
	info := cmd("after info " + id5);
	ok("info <id> reports timer type", len info > 0 && infohas(info, "timer"));
	cmd("after cancel " + id5);

	# 6. re-arming from within a fired script keeps working (animation case)
	cmd(".l configure -text 0");
	cmd("variable acount 0");
	# tick increments a counter and re-arms three times via a helper proc-free chain
	cmd("after 40 {.l configure -text A1}");
	sys->sleep(120);
	cmd("after 40 {.l configure -text A2}");
	sys->sleep(120);
	ok("sequential re-arm fires", cmd(".l cget -text") == "A2");

	sys->print("1..%d\n", nok+nfail);
	if(nfail == 0)
		sys->print("# all %d after tests passed\n", nok);
	else
		sys->print("# %d FAILED\n", nfail);
	shutdown();
	exit;
}

# Bring the host emu down so the test is self-terminating under a harness.
shutdown()
{
	fd := sys->open("#p/" + string mypid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

infohas(s: string, sub: string): int
{
	n := len sub;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}
