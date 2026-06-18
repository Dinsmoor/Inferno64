implement RayCube;

#
# raycube - a spinning 3D cube, rendered with the Raymath Limbo port over
# Inferno's native Draw.  A cube is convex, so the painter's algorithm
# (draw faces back-to-front by view-space depth) gives correct occlusion
# with no z-buffer; faces are filled with native fillpoly.
#
# Runs in a managed wm window (tkclient: titlebar, resize, hide) so it can be
# closed normally.  Started straight from emu with no draw context (no wm) it
# makes its own via tkclient->makedrawcontext(), so it still renders headlessly
# under Xvfb for screenshots.
#
#	wm/raycube [nframes]   (nframes>0: auto-exit after that many frames)
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "tkclient.m";
	tkclient: Tkclient;
include "raymath.m";
	rm: Raymath;
	Vector3, Matrix: import rm;

RayCube: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# 8 cube corners
verts := array[] of {
	Vector3(-1.0, -1.0, -1.0),
	Vector3( 1.0, -1.0, -1.0),
	Vector3( 1.0,  1.0, -1.0),
	Vector3(-1.0,  1.0, -1.0),
	Vector3(-1.0, -1.0,  1.0),
	Vector3( 1.0, -1.0,  1.0),
	Vector3( 1.0,  1.0,  1.0),
	Vector3(-1.0,  1.0,  1.0),
};

# 6 faces, each 4 corner indices wound CCW seen from outside
Face: adt {
	a, b, c, d: int;
	col: int;		# Draw colour constant
};

faces := array[] of {
	Face(0, 3, 2, 1, draw->Red),		# back  (-z)
	Face(4, 5, 6, 7, draw->Green),		# front (+z)
	Face(0, 4, 7, 3, draw->Blue),		# left  (-x)
	Face(1, 2, 6, 5, draw->Yellow),		# right (+x)
	Face(0, 1, 5, 4, draw->Cyan),		# bottom(-y)
	Face(3, 7, 6, 2, draw->Magenta),	# top   (+y)
};

# render state, recreated whenever the window is resized
mainwin: ref Toplevel;
buf: ref Image;			# panel-bound off-screen image (drawn into, then blitted)
black, white: ref Image;
cols: array of ref Image;	# one colour image per face
W, H: int;
view, proj: Matrix;
scr: array of Point;		# projected screen points
vz: array of real;		# view-space depth per vertex

win_config := array[] of {
	"frame .pbd -bd 2",
	"panel .pbd.p -width 512 -height 384",
	"pack .pbd.p -fill both -expand 1",
	"pack .pbd -side top -fill both -expand 1",
	"update",
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	rm = load Raymath Raymath->PATH;
	if(tk == nil || tkclient == nil || rm == nil){
		sys->fprint(sys->fildes(2), "raycube: cannot load modules\n");
		return;
	}
	rm->init();
	tkclient->init();

	nframes := 0;				# 0 == run forever
	if(tl argv != nil)
		nframes = int hd tl argv;

	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(win, wmcmd) := tkclient->toplevel(ctxt, "", "Cube", Tkclient->Resize | Tkclient->Hide);
	mainwin = win;
	sys->pctl(Sys->NEWPGRP, nil);

	for(i := 0; i < len win_config; i++)
		tk->cmd(win, win_config[i]);
	tkclient->onscreen(win, nil);
	tkclient->startinput(win, "kbd"::"ptr"::nil);

	display := win.image.display;
	black = display.color(draw->Black);
	white = display.color(draw->White);
	cols = array[len faces] of ref Image;
	for(i = 0; i < len faces; i++)
		cols[i] = display.color(faces[i].col);

	# camera: eye back along +z, looking at the origin (proj depends on the
	# panel aspect, so it is (re)built in setimage)
	view = Matrix.lookat(Vector3(0.0, 0.0, 5.0), Vector3(0.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0));
	scr = array[len verts] of Point;
	vz = array[len verts] of real;

	if(setimage(win) <= 0)
		return;

	tick := chan of int;
	tpidc := chan of int;
	spawn ticker(tick, tpidc);
	tpid := <-tpidc;

	ang := 0.0;
	frame := 0;
	for(;;) alt {
	<-tick =>
		render(ang);
		ang += 0.03;
		frame++;
		if(nframes != 0 && frame >= nframes){
			killproc(tpid);
			return;
		}
	k := <-win.ctxt.kbd =>
		tk->keyboard(win, k);
	p := <-win.ctxt.ptr =>
		tk->pointer(win, *p);
	c := <-win.ctxt.ctl or
	c = <-win.wreq =>
		tkclient->wmctl(win, c);
	c := <-wmcmd =>
		case c {
		"exit" =>
			killproc(tpid);
			return;
		* =>
			tkclient->wmctl(win, c);
			if(c != nil && c[0] == '!')
				setimage(win);		# reshaped: rebuild buffers
		}
	}
}

ticker(c: chan of int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		sys->sleep(16);
		c <-= 1;
	}
}

killproc(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# (re)allocate the panel image and per-frame buffers for the current panel size
setimage(win: ref Toplevel): int
{
	W = int tk->cmd(win, ".pbd.p cget -actwidth");
	H = int tk->cmd(win, ".pbd.p cget -actheight");
	if(W < 3) W = 3;
	if(H < 3) H = 3;
	buf = win.image.display.newimage(Rect((0,0), (W,H)), win.image.chans, 0, draw->Black);
	if(buf == nil){
		sys->fprint(sys->fildes(2), "raycube: not enough image memory\n");
		return 0;
	}
	tk->putimage(win, ".pbd.p", buf, nil);
	proj = Matrix.perspective(45.0*rm->DEG2RAD, real W/real H, 0.1, 100.0);
	return 1;
}

render(ang: real)
{
	# spin about a tilted axis
	model := Matrix.rotatexyz(Vector3(ang*0.6, ang, ang*0.3));
	mv := model.mul(view);		# view-space transform
	mvp := mv.mul(proj);		# full clip transform

	for(i := 0; i < len verts; i++){
		vp := verts[i].transform(mv);
		vz[i] = vp.z;
		(c, cw) := verts[i].transformp(mvp);
		if(cw == 0.0)
			cw = 0.0001;
		ndcx := c.x/cw;
		ndcy := c.y/cw;
		sx := int ((ndcx*0.5 + 0.5) * real W);
		sy := int ((1.0 - (ndcy*0.5 + 0.5)) * real H);
		scr[i] = (sx, sy);
	}

	# painter's algorithm: order faces far -> near.
	# camera looks down -z, so "farther" == more negative view z.
	order := array[len faces] of int;
	for(i = 0; i < len faces; i++)
		order[i] = i;
	for(i = 0; i < len faces; i++){
		for(j := i+1; j < len faces; j++){
			if(facedepth(faces[order[j]], vz) < facedepth(faces[order[i]], vz))
				(order[i], order[j]) = (order[j], order[i]);
		}
	}

	# clear and draw straight into the panel image, then blit with one update
	buf.draw(buf.r, black, nil, (0,0));
	for(k := 0; k < len faces; k++){
		fi := order[k];
		f := faces[fi];
		poly := array[] of { scr[f.a], scr[f.b], scr[f.c], scr[f.d] };
		buf.fillpoly(poly, 0, cols[fi], (0,0));
		# edge outline for definition
		buf.poly(poly, 0, 0, 0, white, (0,0));
		buf.line(poly[3], poly[0], 0, 0, 0, white, (0,0));
	}

	tk->cmd(mainwin, sys->sprint(".pbd.p dirty 0 0 %d %d", W, H));
	tk->cmd(mainwin, "update");
}

facedepth(f: Face, vz: array of real): real
{
	return (vz[f.a] + vz[f.b] + vz[f.c] + vz[f.d]) / 4.0;
}
