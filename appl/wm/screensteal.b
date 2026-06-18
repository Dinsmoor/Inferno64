implement ScreenSteal;

#
# screensteal - a deliberately antisocial demo.  It opens /dev/draw directly via
# Display.allocate(nil), so under wm it gets the whole screen, paints over every
# window, reads no keyboard or mouse, and never exits.  There is no close box and
# no way to quit it from inside: it exists to exercise the wm panic key
# (triple-F12, or `echo kill > /chan/wmpanic`) and the launch-time draw warning.
#
# HARMLESS: it only draws; it touches nothing else.  It optionally takes a number
# of seconds after which it exits on its own, so automated tests do not hang:
#
#	wm/screensteal [seconds]
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Font: import draw;

ScreenSteal: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;

	deadline := 0;				# 0 == run forever (the point of the demo)
	if(tl argv != nil)
		deadline = sys->millisec() + 1000*int hd tl argv;

	# Display.allocate connects straight to /dev/draw and hands back the whole
	# screen image -- bypassing the wm's window layers entirely.
	disp := Display.allocate(nil);
	if(disp == nil){
		sys->fprint(sys->fildes(2), "screensteal: cannot open display\n");
		return;
	}
	screen := disp.image;
	r := screen.r;

	cols := array[] of {
		disp.color(draw->Red), disp.color(draw->Green),
		disp.color(draw->Blue), disp.color(draw->Magenta),
	};
	white := disp.color(draw->White);
	font := Font.open(disp, "*default*");

	msg := "SCREEN STEALER -- nothing here closes me; triple-F12 to kill";
	i := 0;
	for(;;){
		screen.draw(r, cols[i % len cols], nil, (0,0));
		if(font != nil)
			screen.text(Point(r.min.x + 24, r.min.y + r.dy()/2), white, (0,0), font, msg);
		screen.flush(draw->Flushnow);
		i++;
		if(deadline != 0 && sys->millisec() >= deadline)
			break;
		sys->sleep(150);
	}
}
