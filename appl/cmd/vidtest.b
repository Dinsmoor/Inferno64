implement VidTest;

#
# vidtest -- exercise the $Ffmpeg native video decoder from Limbo.
#
# Reads a video through the Inferno namespace and decodes it with openbytes
# (the portable path: FFmpeg never touches the host filesystem, it decodes the
# bytes we hand it).  Reports geometry, walks every frame printing pts/size, then
# seeks back to the start and decodes one more frame to exercise seek().
#
#	vidtest /path/in/namespace.mp4 [maxframes]
#
# Each frame comes back as w*h*4 RGBA (R,G,B,A per pixel, top-to-bottom) -- the
# byte layout of a Draw ABGR32 image, so it can be written straight into one.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "ffmpeg.m";
	ffmpeg: Ffmpeg;
	Vid: import ffmpeg;

VidTest: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	ffmpeg = load Ffmpeg Ffmpeg->PATH;
	if(ffmpeg == nil){
		sys->print("load Ffmpeg failed: %r\n");
		return;
	}
	if(tl argv == nil){
		sys->print("usage: vidtest file [maxframes]\n");
		return;
	}
	file := hd tl argv;
	max := 0;			# 0 == decode the whole stream
	if(tl tl argv != nil)
		max = int hd tl tl argv;

	buf := readfile(file);
	if(buf == nil){
		sys->print("read %s: %r\n", file);
		return;
	}

	(v, err) := ffmpeg->openbytes(buf);
	if(err != nil){
		sys->print("openbytes %s: %s\n", file, err);
		return;
	}
	sys->print("opened %s: %dx%d  duration=%dms  fps=%d.%03d\n",
		file, v.w, v.h, v.durationms, v.fpsmilli/1000, v.fpsmilli%1000);

	n := 0;
	for(;;){
		(pts, rgba, ferr) := v.frame();
		if(ferr != nil){
			sys->print("frame %d: error: %s\n", n, ferr);
			return;
		}
		if(rgba == nil){		# clean end of stream
			sys->print("end of stream after %d frames\n", n);
			break;
		}
		want := v.w * v.h * 4;
		if(len rgba != want)
			sys->print("frame %d: WARNING got %d bytes, expected %d\n",
				n, len rgba, want);
		sys->print("frame %d  pts=%dms  rgba=%d bytes  px0=%d,%d,%d,%d\n",
			n, pts, len rgba,
			int rgba[0], int rgba[1], int rgba[2], int rgba[3]);
		if(++n == max){
			sys->print("stopping after %d frames\n", n);
			break;
		}
	}

	# exercise seek back to the start, then one more frame
	serr := v.seek(0);
	if(serr != nil){
		sys->print("seek(0): %s\n", serr);
		return;
	}
	(pts2, rgba2, ferr2) := v.frame();
	if(ferr2 != nil)
		sys->print("post-seek frame: error: %s\n", ferr2);
	else if(rgba2 == nil)
		sys->print("post-seek frame: end of stream\n");
	else
		sys->print("post-seek frame  pts=%dms  rgba=%d bytes\n", pts2, len rgba2);

	v.close();
	sys->print("OK\n");
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	n := int d.length;
	buf := array[n] of byte;
	off := 0;
	while(off < n){
		m := sys->read(fd, buf[off:], n - off);
		if(m <= 0)
			break;
		off += m;
	}
	return buf[0:off];
}
