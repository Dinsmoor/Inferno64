implement RayTeapot;

#
# rayteapot - load a Wavefront .obj mesh and render it spinning, smooth-shaded
# (Gouraud + smooth normals) through the native Raster3 z-buffer rasterizer,
# in a normal managed wm window (tkclient: titlebar, resize, hide).
# Exercises the full Phase 1-4 stack: Objloader + Raymath (Limbo) + Raster3 (C).
#
#	wm/rayteapot [objpath]
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
include "objloader.m";
	objloader: Objloader;
	Mesh: import Objloader;

RayTeapot: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# render state, recreated whenever the window is resized
mainwin: ref Toplevel;
disp: ref Image;	# panel-bound image; the rasterizer writes into it directly
bg: ref Image;		# background fill colour
W, H: int;
zbuf: array of real;
proj: Matrix;

# geometry (loaded once)
tris: array of int;
pos, nrm: array of real;
verts: array of Vtx;
nv: int;
view: Matrix;
light, base: array of real;
amb: real;

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
	objloader = load Objloader Objloader->PATH;
	if(tk == nil || tkclient == nil || rm == nil || raster == nil || objloader == nil){
		sys->fprint(sys->fildes(2), "rayteapot: cannot load modules\n");
		return;
	}
	rm->init();
	objloader->init();
	tkclient->init();

	stderr := sys->fildes(2);
	path := "/lib/models/teapot.obj";
	args := tl argv;
	if(args != nil)
		path = hd args;

	(mesh, err) := objloader->readobj(path);
	if(mesh == nil){
		sys->fprint(stderr, "rayteapot: %s\n", err);
		return;
	}
	nv = len mesh.verts;
	tris = mesh.tris;
	sys->fprint(stderr, "rayteapot: loaded %s: %d verts, %d tris\n", path, nv, len tris / 3);

	# centre + uniformly scale the mesh to fit in [-1,1]
	centre := mesh.min.add(mesh.max).scale(0.5);
	ext := mesh.max.sub(mesh.min);
	span := ext.x;
	if(ext.y > span) span = ext.y;
	if(ext.z > span) span = ext.z;
	if(span == 0.0) span = 1.0;
	sc := 2.0/span;

	# pack model-space positions + normals into flat real arrays once; the
	# per-frame transform/projection then happens entirely in C (projectmesh).
	pos = array[nv*3] of real;
	nrm = array[nv*3] of real;
	for(i := 0; i < nv; i++){
		v := mesh.verts[i].sub(centre).scale(sc);
		pos[i*3] = v.x; pos[i*3+1] = v.y; pos[i*3+2] = v.z;
		nrm[i*3] = mesh.normals[i].x;
		nrm[i*3+1] = mesh.normals[i].y;
		nrm[i*3+2] = mesh.normals[i].z;
	}
	verts = array[nv] of Vtx;

	lv := Vector3(0.4, 0.7, 0.6).normalize();
	light = array[] of {lv.x, lv.y, lv.z};
	amb = 0.32;
	base = array[] of {0.95, 0.78, 0.42};	# warm gold
	view = Matrix.lookat(Vector3(0.0, 0.5, 3.2), Vector3(0.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0));

	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(win, wmcmd) := tkclient->toplevel(ctxt, "", "Teapot", Tkclient->Resize | Tkclient->Hide);
	mainwin = win;
	sys->pctl(Sys->NEWPGRP, nil);

	for(i = 0; i < len win_config; i++)
		tk->cmd(win, win_config[i]);
	tkclient->onscreen(win, nil);
	tkclient->startinput(win, "kbd"::"ptr"::nil);
	if(setimage(win) <= 0)
		return;

	tick := chan of int;
	tpidc := chan of int;
	spawn ticker(tick, tpidc);
	tpid := <-tpidc;

	ang := 0.0;
	for(;;) alt {
	<-tick =>
		render(ang);
		ang += 0.04;
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
				setimage(win);	# reshaped: rebuild buffers
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
	r := Rect((0,0), (W,H));
	disp = win.image.display.newimage(r, win.image.chans, 0, draw->Black);
	if(disp == nil){
		sys->fprint(sys->fildes(2), "rayteapot: not enough image memory\n");
		return 0;
	}
	tk->putimage(win, ".pbd.p", disp, nil);
	bg = win.image.display.rgb(15, 15, 22);
	zbuf = array[W*H] of real;
	proj = Matrix.perspective(45.0*rm->DEG2RAD, real W/real H, 0.1, 100.0);
	return 1;
}

render(ang: real)
{
	rot := Matrix.rotatexyz(Vector3(0.0, ang, 0.0));
	mvp := rot.mul(view).mul(proj);

	# whole vertex stage in C: transform, project, viewport, shade
	raster->projectmesh(verts, pos, nrm, nil, nv, mvp.m, rot.m,
		real W, real H, light, amb, base);

	# clear, then rasterize straight into the panel image (no scratch buffer)
	disp.draw(disp.r, bg, nil, (0,0));
	raster->cleardepth(zbuf, 1e30);
	raster->drawmesh(disp, zbuf, verts, tris, nil,
		Raster3->GOURAUD, Raster3->CULLNONE);

	tk->cmd(mainwin, sys->sprint(".pbd.p dirty 0 0 %d %d", W, H));
	tk->cmd(mainwin, "update");
}
