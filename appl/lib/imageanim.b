implement Imageanim;

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;	# bind methods/types to the loaded draw
include "imageio.m";
	imageio: Imageio;
	Anim: import imageio;	# bind Anim methods to the loaded instance
include "imageanim.m";

# control codes sent on Player.ctlc
Cstop, Cpause, Cplay: con iota;

# frame-timing floors/defaults (ms): 0-delay frames get DEFDELAY; everything is
# clamped up to MINDELAY so a pathological tiny delay can't peg a CPU.
MINDELAY:	con 20;
DEFDELAY:	con 100;

init()
{
	# A library that calls Draw *methods* (newimage/writepixels) must load Draw
	# itself -- the handle dispatches through this module's own linkage.
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	imageio = load Imageio Imageio->PATH;
}

open(display: ref Draw->Display, data: array of byte, updated: chan of int): (ref Player, string)
{
	if(imageio == nil)
		return (nil, "imageanim not initialised");
	(anim, err) := imageio->animopen(data);
	if(err != nil)
		return (nil, err);

	img := display.newimage(Rect((0,0),(anim.w,anim.h)), Draw->ABGR32, 0, Draw->Black);
	if(img == nil)
		return (nil, "newimage failed");

	p := ref Player(
		img, anim.w, anim.h, anim.nframes, anim.loop, updated,
		anim, chan[1] of int, 0);

	# draw frame 0 now, so img is valid before start()
	(nil, rgba, ferr) := anim.frame(0);
	if(ferr == nil && rgba != nil)
		img.writepixels(img.r, rgba);

	return (p, nil);
}

Player.start(p: self ref Player)
{
	if(p.running)
		return;
	p.running = 1;
	spawn run(p);
}

Player.stop(p: self ref Player)
{
	if(!p.running)
		return;
	p.running = 0;
	p.ctlc <-= Cstop;
}

Player.pause(p: self ref Player)
{
	if(p.running)
		p.ctlc <-= Cpause;
}

Player.play(p: self ref Player)
{
	if(p.running)
		p.ctlc <-= Cplay;
}

run(p: ref Player)
{
	i := 0;
	plays := 0;
	for(;;){
		(delay, rgba, err) := p.anim.frame(i);
		if(err == nil && rgba != nil)
			p.img.writepixels(p.img.r, rgba);
		if(p.updated != nil)
			alt {
			p.updated <-= i =>
				;
			* =>
				;	# consumer not ready; drop the pulse
			}

		if(delay <= 0)
			delay = DEFDELAY;
		else if(delay < MINDELAY)
			delay = MINDELAY;

		if(!waitnext(p, delay))
			return;			# stopped

		if(++i >= p.nframes){
			i = 0;
			if(p.loop != 0 && ++plays >= p.loop){
				p.running = 0;	# finished; leave the last frame shown
				return;
			}
		}
	}
}

# Wait `delay` ms before the next frame, staying responsive to control.
# Returns 1 to advance, 0 if stopped.  A buffered one-shot sleeper proc supplies
# the tick: the buffer means a leftover sleeper completes its send and exits even
# if we stopped first, so it never leaks.
waitnext(p: ref Player, delay: int): int
{
	tick := chan[1] of int;
	spawn sleeper(delay, tick);
	for(;;) alt {
	c := <-p.ctlc =>
		case c {
		Cstop =>
			return 0;
		Cpause =>
			# hold here until play or stop; the pending tick stays buffered
			for(;;){
				c2 := <-p.ctlc;
				if(c2 == Cplay)
					break;
				if(c2 == Cstop)
					return 0;
			}
		Cplay =>
			;	# already running
		}
	<-tick =>
		return 1;
	}
}

sleeper(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}
