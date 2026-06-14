# Imageanim - play animated images into a Draw image on their own pacing proc.
#
# It decodes through $Imageio (animopen: full-canvas composited frames + per-
# frame delays, held in C with one frame copied into the Dis heap at a time)
# and drives a SINGLE ABGR32 surface, so an animation costs one Draw image plus
# one transient frame array -- not N images.  Animated GIF and animated WebP
# play their frames; any still (PNG/JPEG/static WebP/...) is a one-frame loop,
# so a caller can hand any image to the same player.
#
# A Player runs on its own proc.  It writes each frame into `img` and (if given)
# pulses `updated` with the frame index, so a consumer redraws just that region
# -- e.g. a wm `panel` does `.p dirty ...; update`.  The pixel writes are plain
# Draw ops (safe from the player proc); the consumer issues its own toolkit
# repaint from whichever proc owns the UI.

Imageanim: module
{
	PATH:	con "/dis/lib/imageanim.dis";

	init:	fn();

	Player: adt {
		img:	ref Draw->Image;	# ABGR32 surface holding the current frame
		w:	int;
		h:	int;
		nframes:	int;
		loop:	int;			# 0 = loop forever, else play count
		updated:	chan of int;	# pulsed (frame idx) after each draw; may be nil

		# internal: the decoded animation and the control channel
		anim:	ref Imageio->Anim;
		ctlc:	chan of int;
		running:	int;

		start:	fn(p: self ref Player);	# begin animating on its own proc
		stop:	fn(p: self ref Player);	# stop and let the proc exit
		pause:	fn(p: self ref Player);	# hold on the current frame
		play:	fn(p: self ref Player);	# resume after pause
	};

	# Build a player from encoded image bytes.  `updated`, if non-nil, is pulsed
	# with the just-drawn frame index after every frame so a consumer can
	# repaint; pass nil to ignore.  The first frame is drawn before return, so
	# `img` is valid immediately (call start() to animate).  On success
	# (player, nil); on failure (nil, err).
	open:	fn(display: ref Draw->Display, data: array of byte, updated: chan of int): (ref Player, string);
};
