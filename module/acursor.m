Acursor: module
{
	PATH:	con "/dis/lib/acursor.dis";

	# Defaults and limits (mirrors include/cursor.h).
	DEFMS:		con 100;	# per-frame hold when delays unspecified
	MAXDIM:		con 64;		# max cursor width/height in pixels
	MAXFRAME:	con 64;		# max frame count

	init:	fn();

	# Serialise a colour (optionally animated) cursor into the magic-tagged
	# blob the cursor file expects, from raw pixel data.  hot is the hotspot
	# pixel measured from the top-left.  Each frames[i] is w*h*4 bytes of
	# straight-alpha A,R,G,B (row-major, top-down).  delays gives each frame's
	# hold in milliseconds; nil or short defaults to DEFMS.  Needs no display.
	# Returns (blob, nil) or (nil, error).
	mkblobraw:	fn(hot: Draw->Point, w, h: int,
			frames: array of array of byte, delays: array of int): (array of byte, string);

	# As mkblobraw, but taking Draw images (any channel; normalised to ABGR32
	# via readpixels).  Requires a display to allocate scratch images.
	mkblob:	fn(hot: Draw->Point, frames: array of ref Draw->Image,
			delays: array of int): (array of byte, string);

	# Build the blob and write it to fd (an open cursor file, e.g.
	# /dev/cursor).  Returns nil on success, or an error string.
	set:	fn(fd: ref Sys->FD, hot: Draw->Point,
			frames: array of ref Draw->Image, delays: array of int): string;
	setraw:	fn(fd: ref Sys->FD, hot: Draw->Point, w, h: int,
			frames: array of array of byte, delays: array of int): string;

	# Revert fd's cursor to the system default.
	clear:	fn(fd: ref Sys->FD): string;
};
