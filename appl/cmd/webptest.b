implement WebpTest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "imageio.m";
	imageio: Imageio;

WebpTest: module
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
		sys->print("usage: webptest file\n");
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
	(w, h, rgba, err) := imageio->decode(buf[0:off]);
	if(err != nil){
		sys->print("decode error: %s\n", err);
		return;
	}
	sys->print("OK decoded %dx%d  rgba=%d bytes  px0=%d,%d,%d,%d\n",
		w, h, len rgba, int rgba[0], int rgba[1], int rgba[2], int rgba[3]);

	# also exercise decodefit (cap 64x64)
	(fw, fh, frgba, ferr) := imageio->decodefit(buf[0:off], 64, 64);
	if(ferr != nil){
		sys->print("decodefit error: %s\n", ferr);
		return;
	}
	sys->print("OK decodefit(64,64) -> %dx%d  rgba=%d bytes\n", fw, fh, len frgba);
}
