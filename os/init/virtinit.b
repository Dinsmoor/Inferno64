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
