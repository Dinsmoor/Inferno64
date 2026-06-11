implement Init;

#
# qemu -M virt (aarch64) init: bind the core devices, run the shell.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

Init: module
{
	init:	fn();
};

init()
{
	sys = load Sys Sys->PATH;

	sys->print("**\n** Inferno native aarch64 (qemu -M virt)\n**\n");

	sys->bind("#c", "/dev", Sys->MREPL);
	sys->bind("#e", "/env", Sys->MREPL|Sys->MCREATE);
	sys->bind("#p", "/prog", Sys->MREPL);
	sys->bind("#d", "/fd", Sys->MREPL);
	if(sys->bind("#i", "/dev", Sys->MAFTER) < 0)		# draw
		sys->print("init: bind #i: %r\n");
	if(sys->bind("#m", "/dev", Sys->MAFTER) < 0)		# pointer
		sys->print("init: bind #m: %r\n");
	if(sys->bind("#s", "/chan", Sys->MREPL|Sys->MCREATE) < 0)	# file2chan (wm makes /chan/wmrect)
		sys->print("init: bind #s: %r\n");

	# the baked root (devroot) is read-only; give the system writable
	# space where applications expect it (acme temp files, $home state)
	memfsmount("/tmp");
	memfsmount("/usr/inferno");

	# graphical session if there's a display; dies harmlessly if not
	spawn wmstart();
	# let wm's /dev/keyboard reader get in BEFORE the console sh
	# blocks reading /dev/cons: a console read pending from before
	# the keyboard opens steals the first GUI keystroke (the queue
	# wakes the senior sleeper first)
	sys->sleep(8000);

	sh := load Sh "/dis/sh.dis";
	if(sh == nil){
		sys->print("init: load /dis/sh.dis: %r\n");
		echoloop();
		return;
	}
	for(;;){
		sh->init(nil, "sh" :: nil);
		sys->print("init: sh exited; restarting\n");
	}
}

# heap-backed writable fs over mntpt (capped so a runaway writer
# can't eat the heap pool); memfs mounts itself and returns
memfsmount(mntpt: string)
{
	memfs := load Command "/dis/memfs.dis";
	if(memfs == nil){
		sys->print("init: load memfs: %r\n");
		return;
	}
	{
		memfs->init(nil, "memfs" :: "-m" :: "67108864" :: mntpt :: nil);
	} exception {
	"*" =>
		sys->print("init: memfs %s failed\n", mntpt);
	}
}

wmstart()
{
	# run wm under its own sh, like a user would
	sys->sleep(300);	# let the console sh reach its prompt first
	sh := load Sh "/dis/sh.dis";
	if(sh == nil){
		sys->print("init: wmstart: load sh: %r\n");
		return;
	}
	sh->init(nil, "sh" :: "-c" :: "wm/wm" :: nil);
}

echoloop()
{
	cons := sys->open("/dev/cons", Sys->ORDWR);
	if(cons == nil)
		return;
	buf := array[256] of byte;
	for(;;){
		n := sys->read(cons, buf, len buf);
		if(n <= 0)
			break;
		sys->fprint(cons, "you said: %s", string buf[0:n]);
	}
}
