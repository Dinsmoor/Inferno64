implement Init;

#
# qemu -M virt (aarch64) first-boot init: bind the core devices,
# then echo the console until there is a shell to run.
#

include "sys.m";
	sys: Sys;

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

	cons := sys->open("/dev/cons", Sys->ORDWR);
	if(cons == nil){
		sys->print("init: open /dev/cons: %r\n");
		return;
	}
	sys->fprint(cons, "console echo ready (no shell yet); type:\n");
	buf := array[256] of byte;
	for(;;){
		n := sys->read(cons, buf, len buf);
		if(n <= 0)
			break;
		sys->fprint(cons, "you said: %s", string buf[0:n]);
	}
}
