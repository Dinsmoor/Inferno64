# Imageload - convenience wrapper that turns encoded image data (PNG, JPEG,
# BMP, TGA, GIF, ...) into a ready-to-use Draw image, using the native
# $Imageio decoder (libstb).  The decoded pixels are RGBA8, which is exactly
# the byte layout of a Draw ABGR32 image, so the image is built with a single
# writepixels and no per-pixel reordering.
#
# Consumers must `include "draw.m"` before this file (for Draw->Display/Image).

Imageload: module
{
	PATH:	con "/dis/lib/imageload.dis";

	init:	fn();

	# Decode in-memory image data into a new ABGR32 Draw image on display.
	# Returns (image, nil) on success or (nil, error) on failure.
	read:	fn(display: ref Draw->Display, data: array of byte): (ref Draw->Image, string);

	# Read a file and decode it (convenience around read()).
	readfile:	fn(display: ref Draw->Display, path: string): (ref Draw->Image, string);
};
