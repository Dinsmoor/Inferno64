# Imageio - native image decoding, layered on the vendored stb libraries
# (libstb) plus the vendored WebP decoder (libwebp).  The actual codec work is
# C (libstb/stb/stb_image.h wrapped by libstb/stbwrap.c; libwebp/webp.h wrapped
# by libwebp/webpwrap.c); this builtin only marshals Limbo arguments and sniffs
# the RIFF/WEBP magic to pick the decoder.
#
# decode() turns an in-memory image of any supported format -- PNG, JPEG, BMP,
# TGA, GIF, PSD, HDR, PIC, PNM (stb) and WebP: lossy VP8, lossless VP8L, the
# VP8X extended container and the ALPH alpha chunk (libwebp) -- into 8-bit RGBA
# bytes: 4 channels, top-to-bottom, byte order R,G,B,A per pixel.  That is exactly the pixel
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

	# A decoded animation -- or any still image as a one-frame animation.
	# The frames are decoded and composited (full-canvas, top-to-bottom RGBA)
	# in C and held off the back of this handle; frame() copies one into the
	# Dis heap on demand, so an animation costs ONE frame of Dis heap at a
	# time, not all of them.  Held by the GC: the C frame store is released
	# when the Anim is collected, or explicitly by close().
	Anim: adt {
		w:	int;		# canvas width
		h:	int;		# canvas height
		nframes:	int;	# number of frames (>= 1)
		loop:	int;		# 0 = loop forever, else play count

		# Copy frame i (0 <= i < nframes) into a fresh w*h*4 RGBA array.
		# Returns (delayms, rgba, nil) or (0, nil, err); delayms is how
		# long to show this frame (0 for a still).
		frame:	fn(a: self ref Anim, i: int): (int, array of byte, string);

		# Release the C frame store now (optional; the GC also does it).
		# After close(), frame() errors and nframes reads 0.
		close:	fn(a: self ref Anim);
	};

	# Decode an animation from image data.  Animated GIF and animated WebP
	# yield all their frames (full-canvas composited, with per-frame delays);
	# every other format -- PNG, JPEG, static WebP, ... -- comes back as a
	# single-frame Anim, so a caller can treat any image uniformly.  On
	# success (anim, nil); on failure (nil, err).
	animopen:	fn(data: array of byte): (ref Anim, string);
};
