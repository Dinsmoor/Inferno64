# Ffmpeg - native video decoding, layered on the vendored FFmpeg libraries
# (libffmpeg).  The codec work is C (libffmpeg/ffmpeg-<ver> unpacked and built
# by buildffmpeg.sh, wrapped by libffmpeg/ffwrap.c); this builtin only marshals
# Limbo arguments and holds the open decoder off the back of a GC handle.
#
# A lean DECODE-only build is vendored: video H.264, H.265/HEVC, VP8, VP9, AV1,
# MPEG-2/4, H.263, MJPEG; audio AAC, MP3, FLAC; containers mov/mp4, Matroska/
# WebM, MPEG-TS/PS, AVI, FLV, MP3, FLAC, WAV, Ogg (+ raw h264/hevc).  Pure C, no
# SIMD/asm, no network -- the decoders read from a host file or an in-memory
# buffer we feed them, never the host directly.
#
# Each decoded frame is delivered as 8-bit RGBA: 4 channels, top-to-bottom, byte
# order R,G,B,A per pixel -- exactly the pixel layout of a Draw ABGR32 image, so
# a frame can be written straight into one with writepixels and no reordering
# (the same contract Imageio uses for still images).

Ffmpeg: module
{
	PATH:	con "$Ffmpeg";

	# An open video.  The decoder, an AVFrame, and one RGBA frame buffer live
	# in C memory off the back of this handle, so an open video costs ONE
	# frame of Dis heap at a time (the Dis arena is only ~32 MB), not the
	# whole stream.  Held by the GC: the C decoder is released when the Vid is
	# collected, or explicitly by close().
	Vid: adt {
		w:	int;		# frame width  (pixels)
		h:	int;		# frame height (pixels)
		durationms:	int;	# stream duration in ms (0 if unknown)
		fpsmilli:	int;	# avg frame rate * 1000 (29970 = 29.97), 0 if unknown

		# Decode the next video frame to a fresh w*h*4 RGBA array.  Returns
		# (ptsms, rgba, nil) for a frame (ptsms = its presentation time in
		# ms), (-1, nil, nil) at clean end of stream, or (-1, nil, err) on
		# error.  After close(), errors.
		frame:	fn(v: self ref Vid): (int, array of byte, string);

		# Seek to the keyframe at or before tms and flush the decoder, so
		# the next frame() decodes from there.  Best-effort: the first frame
		# after a seek may precede tms.  Returns nil or an error string.
		seek:	fn(v: self ref Vid, tms: int): string;

		# Release the C decoder now (optional; the GC also does it).  After
		# close(), frame()/seek() error and w/h read 0.
		close:	fn(v: self ref Vid);
	};

	# Open a video file by host path (the file:// protocol).  On success
	# (vid, nil); on failure (nil, err).
	open:	fn(path: string): (ref Vid, string);

	# Open a video held entirely in memory.  The bytes are pinned on the
	# returned handle (kept alive until close()/GC), so the source array need
	# not be retained by the caller.  On success (vid, nil); on failure
	# (nil, err).
	openbytes:	fn(data: array of byte): (ref Vid, string);

	# Like open/openbytes, but decode each frame scaled to fit within
	# maxw x maxh (preserving aspect ratio, never upscaling) -- the downscale
	# happens in C, so v.w/v.h and every frame() array come back at the fitted
	# size and the native-resolution RGBA never enters the Dis heap.  Pass a
	# box of 0 in either dimension for no limit.  Use this for playback so a
	# high-resolution source can't overflow the ~32 MB Dis arena.
	openfit:	fn(path: string, maxw, maxh: int): (ref Vid, string);
	openbytesfit:	fn(data: array of byte, maxw, maxh: int): (ref Vid, string);

	# Open a video at a path in the INFERNO NAMESPACE (not the host fs),
	# streaming it on demand through the kernel file ops -- the encoded stream
	# is never held in memory, so an arbitrarily large video costs only one
	# fitted frame of Dis heap.  maxw/maxh fit as for openfit (0 = no limit).
	# This is the path to use for real-world video: download to a namespace
	# file (e.g. under /tmp), then openstream it.  Works unchanged on the
	# native kernel, since it uses the kernel's own file I/O.
	openstream:	fn(path: string, maxw, maxh: int): (ref Vid, string);
};
