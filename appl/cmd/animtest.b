implement AnimTest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "imageio.m";
	imageio: Imageio;
	Anim: import imageio;	# bind Anim methods to the loaded instance

AnimTest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	imageio = load Imageio Imageio->PATH;
	if(imageio == nil){
		sys->print("load Imageio failed: %r\n");
		return;
	}
	if(tl argv == nil){
		sys->print("usage: animtest file\n");
		return;
	}
	file := hd tl argv;
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil){
		sys->print("open %s: %r\n", file);
		return;
	}
	(ok, d) := sys->fstat(fd);
	if(ok < 0){
		sys->print("fstat: %r\n");
		return;
	}
	n := int d.length;
	buf := array[n] of byte;
	off := 0;
	while(off < n){
		m := sys->read(fd, buf[off:], n - off);
		if(m <= 0)
			break;
		off += m;
	}

	(anim, err) := imageio->animopen(buf[0:off]);
	if(err != nil){
		sys->print("animopen error: %s\n", err);
		return;
	}
	sys->print("OK %s: %dx%d  nframes=%d  loop=%d\n",
		file, anim.w, anim.h, anim.nframes, anim.loop);
	total := 0;
	for(i := 0; i < anim.nframes; i++){
		(delay, rgba, ferr) := anim.frame(i);
		if(ferr != nil){
			sys->print("frame %d error: %s\n", i, ferr);
			return;
		}
		px := "";
		if(len rgba >= 4)
			px = sys->sprint("px0=%d,%d,%d,%d",
				int rgba[0], int rgba[1], int rgba[2], int rgba[3]);
		sys->print("  frame %d: delay=%dms  rgba=%d bytes  %s\n",
			i, delay, len rgba, px);
		total += delay;
	}
	sys->print("OK total duration %dms\n", total);

	# out-of-range guard
	(nil, nil, oob) := anim.frame(anim.nframes);
	if(oob == nil)
		sys->print("BUG: out-of-range frame did not error\n");
	else
		sys->print("OK out-of-range frame rejected: %s\n", oob);

	anim.close();
	(nil, nil, closed) := anim.frame(0);
	if(closed == nil)
		sys->print("BUG: frame after close did not error\n");
	else
		sys->print("OK frame after close rejected: %s\n", closed);
}
