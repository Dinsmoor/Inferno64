implement Acursor;

#
# Build and install full-colour, optionally animated, cursors from userspace.
# The wire format (magic-tagged, big-endian header, ARGB8888 frames) is shared
# with the cursor device and documented in include/cursor.h.
#

include "sys.m";
include "draw.m";
include "acursor.m";

sys: Sys;
draw: Draw;
Image, Point, Rect, Chans, Display: import draw;

Magic:		con 16r41637572;	# "Acur"
Version:	con 1;

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
}

p32(b: array of byte, o, v: int)
{
	b[o+0] = byte (v >> 24);
	b[o+1] = byte (v >> 16);
	b[o+2] = byte (v >> 8);
	b[o+3] = byte v;
}

mkblobraw(hot: Draw->Point, w, h: int, frames: array of array of byte, delays: array of int): (array of byte, string)
{
	if(sys == nil)
		init();
	if(frames == nil || len frames == 0)
		return (nil, "no cursor frames");
	nf := len frames;
	if(nf > MAXFRAME)
		return (nil, "too many cursor frames");
	if(w <= 0 || h <= 0 || w > MAXDIM || h > MAXDIM)
		return (nil, sys->sprint("bad cursor size %dx%d (max %d)", w, h, MAXDIM));

	framebytes := w*h*4;
	blob := array[7*4 + nf*(4 + framebytes)] of byte;
	p32(blob, 0*4, Magic);
	p32(blob, 1*4, Version);
	p32(blob, 2*4, hot.x);
	p32(blob, 3*4, hot.y);
	p32(blob, 4*4, w);
	p32(blob, 5*4, h);
	p32(blob, 6*4, nf);

	o := 7*4;
	for(i := 0; i < nf; i++){
		if(len frames[i] != framebytes)
			return (nil, sys->sprint("frame %d is %d bytes, want %d", i, len frames[i], framebytes));
		ms := DEFMS;
		if(delays != nil && i < len delays)
			ms = delays[i];
		p32(blob, o, ms);
		o += 4;
		blob[o:] = frames[i];
		o += framebytes;
	}
	return (blob, nil);
}

mkblob(hot: Draw->Point, frames: array of ref Draw->Image, delays: array of int): (array of byte, string)
{
	if(draw == nil)
		init();
	if(frames == nil || len frames == 0)
		return (nil, "no cursor frames");
	w := frames[0].r.dx();
	h := frames[0].r.dy();
	if(w <= 0 || h <= 0 || w > MAXDIM || h > MAXDIM)
		return (nil, sys->sprint("bad cursor size %dx%d (max %d)", w, h, MAXDIM));

	abgr := draw->ABGR32;
	framebytes := w*h*4;
	raw := array[len frames] of array of byte;
	pix := array[framebytes] of byte;	# ABGR32 == R,G,B,A bytes in memory
	for(i := 0; i < len frames; i++){
		f := frames[i];
		if(f.r.dx() != w || f.r.dy() != h)
			return (nil, "cursor frames differ in size");
		# normalise to ABGR32 at the origin so readpixels gives R,G,B,A
		if(!f.chans.eq(abgr) || f.r.min.x != 0 || f.r.min.y != 0){
			n := f.display.newimage(((0,0),(w,h)), abgr, 0, draw->Nofill);
			if(n == nil)
				return (nil, "cannot allocate scratch image");
			n.draw(n.r, f, nil, f.r.min);
			f = n;
		}
		if(f.readpixels(f.r, pix) < 0)
			return (nil, sys->sprint("readpixels: %r"));
		# memory order R,G,B,A -> wire order A,R,G,B
		fb := array[framebytes] of byte;
		for(j := 0; j < w*h; j++){
			fb[j*4+0] = pix[j*4+3];	# A
			fb[j*4+1] = pix[j*4+0];	# R
			fb[j*4+2] = pix[j*4+1];	# G
			fb[j*4+3] = pix[j*4+2];	# B
		}
		raw[i] = fb;
	}
	return mkblobraw(hot, w, h, raw, delays);
}

set(fd: ref Sys->FD, hot: Draw->Point, frames: array of ref Draw->Image, delays: array of int): string
{
	(blob, err) := mkblob(hot, frames, delays);
	if(err != nil)
		return err;
	if(sys->write(fd, blob, len blob) != len blob)
		return sys->sprint("write cursor: %r");
	return nil;
}

setraw(fd: ref Sys->FD, hot: Draw->Point, w, h: int, frames: array of array of byte, delays: array of int): string
{
	(blob, err) := mkblobraw(hot, w, h, frames, delays);
	if(err != nil)
		return err;
	if(sys->write(fd, blob, len blob) != len blob)
		return sys->sprint("write cursor: %r");
	return nil;
}

clear(fd: ref Sys->FD): string
{
	if(draw == nil)
		init();
	if(sys->write(fd, array[0] of byte, 0) != 0)
		return sys->sprint("clear cursor: %r");
	return nil;
}
