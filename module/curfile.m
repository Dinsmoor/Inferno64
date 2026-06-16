# Curfile - decode Windows cursor files (.cur and animated .ani) into raw
# cursor frames the cursor device understands.  Pure byte-munging: it needs no
# display, so it can run anywhere (including the native kernel over a serial
# shell).  PNG-embedded entries (Vista-era icons) are handed to $Imageio; the
# common DIB (BMP) entries are decoded in-line for 1/4/8/24/32 bpp with the AND
# transparency mask.
#
# Output pixels are straight-alpha A,R,G,B (row-major, top-down) -- exactly the
# per-frame layout of the Acursor wire format / /dev/cursor.

Curfile: module
{
	PATH:	con "/dis/lib/curfile.dis";

	MAXDIM:		con 64;		# reject frames larger than this
	MAXFRAME:	con 64;		# cap an animation to this many steps

	# A decoded cursor.  hotx,hoty is the hotspot from the top-left.  Each
	# frames[i] is w*h*4 bytes of straight-alpha A,R,G,B; delays[i] is that
	# frame's hold in milliseconds.  A still .cur yields one frame.
	Cursor: adt {
		w, h:		int;
		hotx, hoty:	int;
		frames:		array of array of byte;
		delays:		array of int;
	};

	init:	fn();

	# Decode an auto-detected .cur or .ani held in memory.
	decode:	fn(data: array of byte): (ref Cursor, string);

	# Read a file and decode it.
	readfile:	fn(path: string): (ref Cursor, string);
};
