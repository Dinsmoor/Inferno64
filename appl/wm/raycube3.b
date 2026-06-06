implement RayCube3;

#
# raycube3 - two interpenetrating spinning cubes rendered with the native
# Raster3 software rasterizer (per-pixel z-buffer).  This is the case the
# painter's algorithm in raycube.b CANNOT handle: where two solids
# interpenetrate, occlusion must be decided per pixel by depth.
#
# Vertex processing (transform, project, light) is Limbo via Raymath; the
# inner per-pixel loop is the C kernel $Raster3, which rasterizes straight into
# an off-screen Draw image (back buffer) that is then blitted to the screen.
#
#	emu -g640x480 /dis/wm/raycube3.dis [nframes]
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

W, H: int;
light: Vector3;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	rm = load Raymath Raymath->PATH;
	rm->init();
	raster = load Raster3 Raster3->PATH;
	if(raster == nil){
		sys->fprint(sys->fildes(2), "raycube3: cannot load $Raster3\n");
		return;
	}

	nframes := 0;
	if(tl argv != nil)
		nframes = int hd tl argv;

	disp := Display.allocate(nil);
	if(disp == nil){
		sys->fprint(sys->fildes(2), "raycube3: cannot open display\n");
		return;
	}
	screen := disp.image;
	W = screen.r.dx();
	H = screen.r.dy();

	back := disp.newimage(screen.r, screen.chans, 0, draw->Black);
	bg := disp.rgb(12, 12, 18);
	zbuf := array[W*H] of real;
	verts := array[48] of Vtx;	# 2 cubes * 6 faces * 4 verts
	tris := buildtris();

	light = Vector3(0.3, 0.5, 1.0).normalize();
	view := Matrix.lookat(Vector3(0.0,0.0,6.0), Vector3(0.0,0.0,0.0), Vector3(0.0,1.0,0.0));
	proj := Matrix.perspective(45.0*rm->DEG2RAD, real W/real H, 0.1, 100.0);

	ang := 0.0;
	frame := 0;
	for(;;){
		rotA := Matrix.rotatexyz(Vector3(ang*0.5, ang, 0.0));
		modelA := rotA.mul(Matrix.translate(-0.7, 0.0, 0.0));
		mvpA := modelA.mul(view).mul(proj);

		rotB := Matrix.rotatexyz(Vector3(ang, ang*0.4, ang*0.7));
		modelB := rotB.mul(Matrix.translate(0.7, 0.0, 0.0));
		mvpB := modelB.mul(view).mul(proj);

		buildcube(verts, 0, modelA, mvpA, Vector3(0.95, 0.30, 0.30));
		buildcube(verts, 24, modelB, mvpB, Vector3(0.30, 0.55, 0.95));

		back.draw(back.r, bg, nil, (0,0));
		raster->cleardepth(zbuf, 1e30);
		raster->drawmesh(back, zbuf, verts, tris, nil,
			Raster3->FLAT, Raster3->CULLNONE);

		screen.draw(screen.r, back, nil, back.r.min);
		screen.flush(draw->Flushnow);

		ang += 0.03;
		frame++;
		if(nframes != 0 && frame >= nframes)
			break;
		sys->sleep(16);
	}
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
