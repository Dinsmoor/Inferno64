implement RayCube3;

#
# raycube3 - two interpenetrating spinning cubes rendered with the native
# Raster3 software rasterizer (per-pixel z-buffer).  This is the case the
# painter's algorithm in raycube.b CANNOT handle: where two solids
# interpenetrate, occlusion must be decided per pixel by depth.
#
# Vertex processing (transform, project, light) is Limbo via Raymath; the
# inner per-pixel loop is the C kernel $Raster3, which rasterizes straight into
# an off-screen Draw image (back buffer) that is then blitted to the window.
#
# Runs in a managed wm window (tkclient: titlebar, resize, hide) so it can be
# closed normally.  Started straight from emu with no draw context (no wm) it
# makes its own via tkclient->makedrawcontext(), so it still renders headlessly
# under Xvfb for screenshots.
#
#	wm/raycube3 [nframes]   (nframes>0: auto-exit after that many frames)
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "tkclient.m";
	tkclient: Tkclient;
include "raymath.m";
	rm: Raymath;
	Vector3, Matrix: import rm;
include "raster3.m";
	raster: Raster3;
	Vtx: import Raster3;

RayCube3: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# cube corners (half-size 0.8) and faces (4 indices, CCW seen from outside)
cube := array[] of {
	Vector3(-0.8, -0.8, -0.8), Vector3( 0.8, -0.8, -0.8),
	Vector3( 0.8,  0.8, -0.8), Vector3(-0.8,  0.8, -0.8),
	Vector3(-0.8, -0.8,  0.8), Vector3( 0.8, -0.8,  0.8),
	Vector3( 0.8,  0.8,  0.8), Vector3(-0.8,  0.8,  0.8),
};
face := array[] of {
	0,3,2,1,  4,5,6,7,  0,4,7,3,  1,2,6,5,  0,1,5,4,  3,7,6,2,
};

# render state, recreated whenever the window is resized
mainwin: ref Toplevel;
buf: ref Image;		# panel-bound back buffer the rasterizer writes into
bg: ref Image;		# background fill colour
W, H: int;
zbuf: array of real;
view, proj: Matrix;
verts: array of Vtx;	# 2 cubes * 6 faces * 4 verts
tris: array of int;
light: Vector3;

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
	raster = load Raster3 Raster3->PATH;
	if(tk == nil || tkclient == nil || rm == nil || raster == nil){
		sys->fprint(sys->fildes(2), "raycube3: cannot load modules\n");
		return;
	}
	rm->init();
	tkclient->init();

	nframes := 0;				# 0 == run forever
	if(tl argv != nil)
		nframes = int hd tl argv;

	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(win, wmcmd) := tkclient->toplevel(ctxt, "", "Z-buffer cubes", Tkclient->Resize | Tkclient->Hide);
	mainwin = win;
	sys->pctl(Sys->NEWPGRP, nil);

	for(i := 0; i < len win_config; i++)
		tk->cmd(win, win_config[i]);
	tkclient->onscreen(win, nil);
	tkclient->startinput(win, "kbd"::"ptr"::nil);

	bg = win.image.display.rgb(12, 12, 18);
	verts = array[48] of Vtx;
	tris = buildtris();
	light = Vector3(0.3, 0.5, 1.0).normalize();
	view = Matrix.lookat(Vector3(0.0,0.0,6.0), Vector3(0.0,0.0,0.0), Vector3(0.0,1.0,0.0));

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

# (re)allocate the back buffer + depth buffer for the current panel size
setimage(win: ref Toplevel): int
{
	W = int tk->cmd(win, ".pbd.p cget -actwidth");
	H = int tk->cmd(win, ".pbd.p cget -actheight");
	if(W < 3) W = 3;
	if(H < 3) H = 3;
	buf = win.image.display.newimage(Rect((0,0), (W,H)), win.image.chans, 0, draw->Black);
	if(buf == nil){
		sys->fprint(sys->fildes(2), "raycube3: not enough image memory\n");
		return 0;
	}
	tk->putimage(win, ".pbd.p", buf, nil);
	zbuf = array[W*H] of real;
	proj = Matrix.perspective(45.0*rm->DEG2RAD, real W/real H, 0.1, 100.0);
	return 1;
}

render(ang: real)
{
	rotA := Matrix.rotatexyz(Vector3(ang*0.5, ang, 0.0));
	modelA := rotA.mul(Matrix.translate(-0.7, 0.0, 0.0));
	mvpA := modelA.mul(view).mul(proj);

	rotB := Matrix.rotatexyz(Vector3(ang, ang*0.4, ang*0.7));
	modelB := rotB.mul(Matrix.translate(0.7, 0.0, 0.0));
	mvpB := modelB.mul(view).mul(proj);

	buildcube(verts, 0, modelA, mvpA, Vector3(0.95, 0.30, 0.30));
	buildcube(verts, 24, modelB, mvpB, Vector3(0.30, 0.55, 0.95));

	# clear, then rasterize straight into the panel image, then blit
	buf.draw(buf.r, bg, nil, (0,0));
	raster->cleardepth(zbuf, 1e30);
	raster->drawmesh(buf, zbuf, verts, tris, nil,
		Raster3->FLAT, Raster3->CULLNONE);

	tk->cmd(mainwin, sys->sprint(".pbd.p dirty 0 0 %d %d", W, H));
	tk->cmd(mainwin, "update");
}

# project a local-space point through mvp to a screen-space Vtx with colour
projvtx(p: Vector3, mvp: Matrix, r, g, b: real): Vtx
{
	(cv, wv) := p.transformp(mvp);
	if(wv == 0.0)
		wv = 0.0001;
	iw := 1.0/wv;
	ndcx := cv.x*iw;
	ndcy := cv.y*iw;
	ndcz := cv.z*iw;
	sx := (ndcx*0.5 + 0.5)*real W;
	sy := (1.0 - (ndcy*0.5 + 0.5))*real H;
	return Vtx(sx, sy, ndcz, iw, 0.0, 0.0, r, g, b, 1.0);
}

# emit one cube's 6 lit faces (24 verts) starting at verts[vbase]
buildcube(verts: array of Vtx, vbase: int, model, mvp: Matrix, base: Vector3)
{
	amb := 0.30;
	vi := vbase;
	for(fi := 0; fi < 6; fi++){
		i0 := face[fi*4];
		i1 := face[fi*4 + 1];
		i2 := face[fi*4 + 2];
		i3 := face[fi*4 + 3];

		# flat lighting from the world-space face normal
		w0 := cube[i0].transform(model);
		w1 := cube[i1].transform(model);
		w3 := cube[i3].transform(model);
		n := (w1.sub(w0)).cross(w3.sub(w0)).normalize();
		d := n.dot(light);
		if(d < 0.0)
			d = 0.0;
		inten := amb + (1.0 - amb)*d;
		r := base.x*inten;
		g := base.y*inten;
		b := base.z*inten;

		verts[vi]     = projvtx(cube[i0], mvp, r, g, b);
		verts[vi + 1] = projvtx(cube[i1], mvp, r, g, b);
		verts[vi + 2] = projvtx(cube[i2], mvp, r, g, b);
		verts[vi + 3] = projvtx(cube[i3], mvp, r, g, b);
		vi += 4;
	}
}

# two triangles per quad face, 12 faces total
buildtris(): array of int
{
	t := array[12*2*3] of int;
	ti := 0;
	for(f := 0; f < 12; f++){
		base := f*4;
		t[ti++] = base;
		t[ti++] = base + 1;
		t[ti++] = base + 2;
		t[ti++] = base;
		t[ti++] = base + 2;
		t[ti++] = base + 3;
	}
	return t;
}
