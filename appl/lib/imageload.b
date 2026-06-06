implement Imageload;

#
# imageload - decode encoded image data (PNG/JPEG/BMP/TGA/GIF/...) into a Draw
# image via the native $Imageio decoder (libstb -> stb_image).  $Imageio hands
# back RGBA8 bytes, whose layout matches a Draw ABGR32 image exactly, so the
# image is built with one writepixels.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "imageio.m";
	imageio: Imageio;
include "imageload.m";

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	# Draw must be loaded here: read() calls Draw builtin methods
	# (display.newimage, img.writepixels) which dispatch through this
	# module's own Draw linkage, not the caller's.
	if(draw == nil)
		draw = load Draw Draw->PATH;
	if(imageio == nil)
		imageio = load Imageio Imageio->PATH;
}

read(display: ref Display, data: array of byte): (ref Image, string)
{
	if(imageio == nil)
		init();
	if(imageio == nil)
		return (nil, "cannot load $Imageio");
	if(display == nil)
		return (nil, "nil display");

	(w, h, rgba, err) := imageio->decode(data);
	if(rgba == nil)
		return (nil, err);

	img := display.newimage(Rect((0,0),(w,h)), draw->ABGR32, 0, draw->Black);
	if(img == nil)
		return (nil, "not enough image memory");
	img.writepixels(img.r, rgba);
	return (img, nil);
}

readfile(display: ref Display, path: string): (ref Image, string)
{
	if(sys == nil)
		init();

	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%s: %r", path));

	data := array[0] of byte;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return (nil, sys->sprint("%s: %r", path));
		if(n == 0)
			break;
		nd := array[len data + n] of byte;
		nd[0:] = data;
		nd[len data:] = buf[0:n];
		data = nd;
	}
	return read(display, data);
}
