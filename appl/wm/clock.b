implement Clock;

#
# Subject to the Lucent Public License 1.02
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "daytime.m";
	daytime: Daytime;
	Tm: import daytime;

Clock: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

hrhand: ref Image;
minhand: ref Image;
dots: ref Image;
back: ref Image;

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	daytime = load Daytime Daytime->PATH;
	wmclient = load Wmclient Wmclient->PATH;

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();

	w := wmclient->window(ctxt, "clock", Wmclient->Appl);	# Plain?
	setcolours(w);

	w.reshape(Rect((0, 0), (100, 100)));
	w.startinput("ptr" :: nil);

	now := daytime->now();
	w.onscreen(nil);
	drawclock(w.image, now);

	ticks := chan of int;
	spawn timer(ticks, 30*1000);
	for(;;) alt{
	ctl := <-w.ctl or
	ctl = <-w.ctxt.ctl =>
		w.wmctl(ctl);
		if(len ctl >= 5 && ctl[0:5] == "theme"){
			setcolours(w);
			drawclock(w.image, now);
		}else if(ctl != nil && ctl[0] == '!')
			drawclock(w.image, now);
	p := <-w.ctxt.ptr =>
		w.pointer(*p);
	<-ticks =>
		t := daytime->now();
		if(t != now){
			now = t;
			drawclock(w.image, now);
		}
	}
}

ZP := Point(0, 0);

# Build the clock-face colours from the live theme (bg = face, fg = hour hand /
# dots, select = minute hand), falling back to the classic blue-on-pale look
# when no theme is set.  Re-run on a theme push.
setcolours(w: ref Window)
{
	display := w.display;
	bg := w.themecolour("bg");
	fg := w.themecolour("fg");
	ac := w.themecolour("select");
	if(bg != nil)
		back = display.color(parsecol(bg));
	else
		back = display.colormix(Draw->Palebluegreen, Draw->White);
	if(fg != nil){
		dots = display.color(parsecol(fg));
		hrhand = display.color(parsecol(fg));
	}else{
		dots = display.newimage(Rect((0,0),(1,1)), Draw->CMAP8, 1, Draw->Blue);
		hrhand = display.newimage(Rect((0,0),(1,1)), Draw->CMAP8, 1, Draw->Darkblue);
	}
	if(ac != nil)
		minhand = display.color(parsecol(ac));
	else
		minhand = display.newimage(Rect((0,0),(1,1)), Draw->CMAP8, 1, Draw->Paleblue);
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

# parse a theme colour string (#rgb #rrggbb #rrggbbaa) to a Draw RGBA int
parsecol(s: string): int
{
	if(s == nil || s[0] != '#')
		return Draw->White;
	v := 0;
	ndig := 0;
	for(i := 1; i < len s; i++){
		d := hexval(s[i]);
		if(d < 0)
			break;
		v = (v << 4) | d;
		ndig++;
	}
	if(ndig <= 6)
		v = (v << 8) | 16rff;		# #rrggbb -> opaque
	return v;
}

drawclock(screen: ref Image, t: int)
{
	if(screen == nil)
		return;
	tms := daytime->local(t);
	anghr := 90-(tms.hour*5 + tms.min/10)*6;
	angmin := 90-tms.min*6;
	r := screen.r;
	c := r.min.add(r.max).div(2);
	if(r.dx() < r.dy())
		rad := r.dx();
	else
		rad = r.dy();
	rad /= 2;
	rad -= 8;

	screen.draw(screen.r, back, nil, ZP);
	for(i:=0; i<12; i++)
		screen.fillellipse(circlept(c, rad, i*(360/12)), 2, 2, dots, ZP);

	screen.line(c, circlept(c, (rad*3)/4, angmin), 0, 0, 1, minhand, ZP);
	screen.line(c, circlept(c, rad/2, anghr), 0, 0, 1, hrhand, ZP);

	screen.flush(Draw->Flushnow);
}

circlept(c: Point, r: int, degrees: int): Point
{
	rad := real degrees * Math->Pi/180.0;
	c.x += int (math->cos(rad)*real r);
	c.y -= int (math->sin(rad)*real r);
	return c;
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
