# Imageio - native image decoding, layered on the vendored stb libraries
# (libstb).  The actual codec work is C (libstb/stb/stb_image.h, wrapped by
# libstb/stbwrap.c); this builtin only marshals Limbo arguments.
#
# decode() turns an in-memory image of any stb-supported format (PNG, JPEG,
# BMP, TGA, GIF, PSD, HDR, PIC, PNM) into 8-bit RGBA bytes: 4 channels,
# top-to-bottom, byte order R,G,B,A per pixel.  That is exactly the pixel
# layout of a Draw ABGR32 image, so the bytes can be written straight into one
# with writepixels and no reordering -- which is what the Imageload library
# (/dis/lib/imageload.dis) does to hand you a ready ref Draw->Image.
#
# encode() is the inverse: 8-bit RGBA bytes (same layout) -> an in-memory PNG.

Imageio: module
{
	PATH:	con "$Imageio";

	# Decode image data to 8-bit RGBA.  On success returns (w, h, rgba, nil)
	# where rgba has w*h*4 bytes (R,G,B,A order); on failure (0, 0, nil, err).
	decode:	fn(data: array of byte): (int, int, array of byte, string);

	# Like decode(), but cap the result to maxw x maxh, downscaling a larger
	# source (preserving aspect) in C before it ever reaches the Dis heap --
	# so a huge image can't overflow the (~32 MB) main arena.  maxw/maxh <= 0
	# means no cap.  Returns the RETURNED (possibly reduced) w, h.
	decodefit:	fn(data: array of byte, maxw, maxh: int): (int, int, array of byte, string);

	# Encode 8-bit RGBA pixels (w*h*4 bytes, R,G,B,A order, top-to-bottom --
	# the layout decode() produces) to an in-memory PNG.  On success returns
	# (png, nil); on failure (nil, err).
	encode:	fn(w, h: int, rgba: array of byte): (array of byte, string);
};
