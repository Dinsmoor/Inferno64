implement RayTeapot;

#
# rayteapot - load a Wavefront .obj mesh and render it spinning, smooth-shaded
# (Gouraud + smooth normals) through the native Raster3 z-buffer rasterizer.
# This exercises the full Phase 1-4 stack: Objloader (Limbo) + Raymath (Limbo)
# + Raster3 (C kernel).
#
#	emu -g640x480 /dis/wm/rayteapot.dis [objpath] [nframes]
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;
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

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	rm = load Raymath Raymath->PATH;
	rm->init();
	raster = load Raster3 Raster3->PATH;
	objloader = load Objloader Objloader->PATH;
	if(raster == nil || objloader == nil){
		sys->fprint(sys->fildes(2), "rayteapot: cannot load modules\n");
		return;
	}
	objloader->init();

	stderr := sys->fildes(2);
	path := "/lib/models/teapot.obj";
	nframes := 0;
	args := tl argv;
	if(args != nil){
		path = hd args;
		args = tl args;
	}
	if(args != nil)
		nframes = int hd args;

	(mesh, err) := objloader->readobj(path);
	if(mesh == nil){
		sys->fprint(stderr, "rayteapot: %s\n", err);
		return;
	}
	nv := len mesh.verts;
	ntri := len mesh.tris / 3;
	sys->fprint(stderr, "rayteapot: loaded %s: %d verts, %d tris\n", path, nv, ntri);

	# centre + uniformly scale the mesh to fit in [-1,1]
	centre := mesh.min.add(mesh.max).scale(0.5);
	ext := mesh.max.sub(mesh.min);
	span := ext.x;
	if(ext.y > span) span = ext.y;
	if(ext.z > span) span = ext.z;
	if(span == 0.0) span = 1.0;
	s := 2.0/span;
	for(i := 0; i < nv; i++)
		mesh.verts[i] = mesh.verts[i].sub(centre).scale(s);

	# pack model-space positions + normals into flat real arrays once; the
	# per-frame transform/projection then happens entirely in C (projectmesh).
	pos := array[nv*3] of real;
	nrm := array[nv*3] of real;
	for(i = 0; i < nv; i++){
		pos[i*3]   = mesh.verts[i].x;
		pos[i*3+1] = mesh.verts[i].y;
		pos[i*3+2] = mesh.verts[i].z;
		nrm[i*3]   = mesh.normals[i].x;
		nrm[i*3+1] = mesh.normals[i].y;
		nrm[i*3+2] = mesh.normals[i].z;
	}

	disp := Display.allocate(nil);
	if(disp == nil){
		sys->fprint(stderr, "rayteapot: cannot open display\n");
		return;
	}
	screen := disp.image;
	W := screen.r.dx();
	H := screen.r.dy();
	fbimg := disp.newimage(screen.r, draw->XRGB32, 0, draw->Black);
	pix := array[W*H*4] of byte;
	zbuf := array[W*H] of real;
	verts := array[nv] of Vtx;

	lv := Vector3(0.4, 0.7, 0.6).normalize();
	light := array[] of {lv.x, lv.y, lv.z};
	amb := 0.32;
	base := array[] of {0.95, 0.78, 0.42};	# warm gold

	view := Matrix.lookat(Vector3(0.0, 0.5, 3.2), Vector3(0.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0));
	proj := Matrix.perspective(45.0*rm->DEG2RAD, real W/real H, 0.1, 100.0);

	ang := 0.0;
	frame := 0;
	for(;;){
		rot := Matrix.rotatexyz(Vector3(0.0, ang, 0.0));
		mvp := rot.mul(view).mul(proj);

		# whole vertex stage in C: transform, project, viewport, shade
		raster->projectmesh(verts, pos, nrm, nil, nv, mvp.m, rot.m,
			real W, real H, light, amb, base);

		raster->clearcolor(pix, W, H, 15, 15, 22);
		raster->cleardepth(zbuf, 1e30);
		raster->drawmesh(pix, zbuf, W, H, verts, mesh.tris, nil, 0, 0,
			Raster3->GOURAUD, Raster3->CULLNONE);

		fbimg.writepixels(fbimg.r, pix);
		screen.draw(screen.r, fbimg, nil, fbimg.r.min);
		screen.flush(draw->Flushnow);

		ang += 0.04;
		frame++;
		if(nframes != 0 && frame >= nframes)
			break;
		sys->sleep(16);
	}
}
