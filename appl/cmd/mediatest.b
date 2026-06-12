implement Mediatest;

#
# Headless media-pipeline check:  mediatest <url>
# Starts ndb/cs (so dialtls can resolve), GETs the URL via masto->fetchurl,
# decodes it with $Imageio, and prints the byte count + decoded dimensions.
# Exercises everything wm/pleromussy's media viewer does except the Tk paint.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;

include "imageio.m";
	imageio: Imageio;

include "masto.m";
	masto: Masto;

Mediatest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Command: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	imageio = load Imageio Imageio->PATH;
	masto = load Masto Masto->PATH;
	if(masto == nil || imageio == nil){
		sys->fprint(sys->fildes(2), "load failed: %r\n");
		raise "fail:load";
	}
	if((e := masto->init()) != nil){
		sys->fprint(sys->fildes(2), "masto init: %s\n", e);
		raise "fail:init";
	}
	ensurecs();

	argv = tl argv;
	if(argv == nil){
		sys->fprint(sys->fildes(2), "usage: mediatest <url>\n");
		raise "fail:usage";
	}
	url := hd argv;

	sys->print("GET %s\n", url);
	(data, ferr) := masto->fetchurl(url);
	if(ferr != nil){
		sys->fprint(sys->fildes(2), "fetchurl: %s\n", ferr);
		raise "fail:fetch";
	}
	sys->print("got %d bytes\n", len data);

	(w, h, rgba, derr) := imageio->decode(data);
	if(rgba == nil){
		sys->fprint(sys->fildes(2), "decode: %s\n", derr);
		raise "fail:decode";
	}
	sys->print("decoded %dx%d  (%d rgba bytes)\n", w, h, len rgba);
}

ensurecs()
{
	if(csup())
		return;
	cs := load Command "/dis/ndb/cs.dis";
	if(cs == nil)
		return;
	spawn cs->init(nil, "cs" :: nil);
	for(i := 0; i < 50 && !csup(); i++)
		sys->sleep(100);
}

csup(): int
{
	fd := sys->open("/net/cs", Sys->ORDWR);
	return fd != nil;
}
