implement Titletex;

#
# Titletex -- procedurally drawn decorative window-titlebar textures.
#
# The system theme (see ON_THEMING.md) themes flat-coloured chrome through the
# "titlebg"/"titlefg"/"titlefocusbg" keys.  This library is the next layer: it
# bakes a whole titlebar -- a tiled stone-block ("ashlar") texture plus the
# window title text -- into a single Draw image, which the titlebar binds to a
# Tk panel with tk->putimage.  That is the only way to get imagery *behind* the
# title text, because a Tk widget background is a flat rectangle and frames can
# not tile a background.
#
# Everything here is deterministic and display-driven: render() allocates a new
# image each call (titlebars regenerate on resize / title change / focus), so it
# keeps no per-window state.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point, Font: import draw;
include "titletex.m";

FONTPATH:	con "/fonts/pelm/unicode.8.font";
NSH:		con 6;			# number of stone shades

disp:	ref Display;
font:	ref Font;

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	disp = d;
	if(d != nil)
		font = Font.open(d, FONTPATH);
}

styleid(name: string): int
{
	case name {
	"castle" =>	return CASTLE;
	"temple" =>	return TEMPLE;
	* =>		return FLAT;
	}
}

clampb(v: int): int
{
	if(v < 0)
		return 0;
	if(v > 255)
		return 255;
	return v;
}

# deterministic per-cell pseudo-random, so a given block is always the same shade
hash2(x, y: int): int
{
	h := (x*73856093) ^ (y*19349663) ^ 16r2f3e1d;
	return h & 16r7fffffff;
}

rgba(r, g, b: int): int
{
	return (clampb(r)<<24) | (clampb(g)<<16) | (clampb(b)<<8) | 16rff;
}

render(style, w, h, focused: int, title: string, fg: int): ref Image
{
	if(disp == nil || style == FLAT)
		return nil;
	if(w < 1)
		w = 1;
	if(h < 1)
		h = 1;

	# base stone rgb + mortar rgb per style
	br, bg, bb, mr, mg, mb: int;
	case style {
	TEMPLE =>				# dark gold ashlar on near-black mortar
		(br, bg, bb) = (120, 96, 28);
		(mr, mg, mb) = (24, 18, 4);
	* =>					# CASTLE: cool grey stone, dark mortar
		(br, bg, bb) = (96, 96, 102);
		(mr, mg, mb) = (40, 40, 46);
	}
	if(focused){
		br = clampb(br+22); bg = clampb(bg+22); bb = clampb(bb+22);
	}

	img := disp.newimage(Rect((0,0),(w,h)), draw->RGB24, 0, rgba(mr, mg, mb));
	if(img == nil)
		return nil;

	# stone-shade source images (replicated solids), light highlight + dark shade
	shades := array[NSH] of ref Image;
	for(i := 0; i < NSH; i++){
		d := (i - NSH/2) * 9;		# -27 .. +18
		shades[i] = disp.rgb(clampb(br+d), clampb(bg+d), clampb(bb+d));
	}
	hi := disp.rgb(clampb(br+44), clampb(bg+44), clampb(bb+48));
	lo := disp.rgb(clampb(br-44), clampb(bg-44), clampb(bb-40));
	edge := disp.rgb(clampb(br-64), clampb(bg-64), clampb(bb-58));

	# lay staggered ashlar blocks; draw clips to the image, so off-edge is fine
	bw := 20; bh := 9; gap := 2;
	rowi := 0;
	for(y := -gap; y < h; y += bh+gap){
		xoff := (rowi & 1) * (bw/2 + gap);
		for(x := -bw; x < w; x += bw+gap){
			sx := x - xoff;
			sh := shades[hash2((sx+bw)/(bw+gap), rowi) % NSH];
			img.draw(Rect((sx, y),(sx+bw, y+bh)), sh, nil, (0,0));
			# bevel: top + left highlight, bottom + right shadow
			img.line((sx, y),       (sx+bw-1, y),      draw->Endsquare, draw->Endsquare, 0, hi, (0,0));
			img.line((sx, y),       (sx, y+bh-1),      draw->Endsquare, draw->Endsquare, 0, hi, (0,0));
			img.line((sx, y+bh-1),  (sx+bw-1, y+bh-1), draw->Endsquare, draw->Endsquare, 0, lo, (0,0));
			img.line((sx+bw-1, y),  (sx+bw-1, y+bh-1), draw->Endsquare, draw->Endsquare, 0, lo, (0,0));
		}
		rowi++;
	}

	# frame the bar top and bottom
	img.line((0,0),   (w-1,0),   draw->Endsquare, draw->Endsquare, 0, edge, (0,0));
	img.line((0,h-1), (w-1,h-1), draw->Endsquare, draw->Endsquare, 0, edge, (0,0));

	# bake the title with a soft drop shadow so it reads over the texture
	if(title != nil && font != nil){
		ty := (h - font.height) / 2;
		if(ty < 0)
			ty = 0;
		tx := 8;
		shadow := disp.color(16r000000c0);
		fgsrc := disp.color(fg);
		if(shadow != nil)
			img.text((tx+1, ty+1), shadow, (0,0), font, title);
		if(fgsrc != nil)
			img.text((tx, ty), fgsrc, (0,0), font, title);
	}

	return img;
}
