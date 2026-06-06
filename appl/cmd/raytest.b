implement RayTest;

#
# raytest - headless self-test for the raylib-in-Limbo port: numeric checks
# on Raymath plus a z-buffer/raster check on $Raster3.  Prints "raytest: PASS
# n/n" and exits nonzero on any failure.  Run with:  emu /dis/raytest.dis
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "raymath.m";
	rm: Raymath;
	Vector3, Matrix: import rm;
include "raster3.m";
	raster: Raster3;
	Vtx: import Raster3;

RayTest: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

npass := 0;
nfail := 0;
stderr: ref Sys->FD;

check(cond: int, what: string)
{
	if(cond)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "raytest: FAIL: %s\n", what);
	}
}

feq(a, b: real): int
{
	d := a - b;
	if(d < 0.0)
		d = -d;
	return d < 0.0001;
}

veq(a, b: Vector3): int
{
	return feq(a.x, b.x) && feq(a.y, b.y) && feq(a.z, b.z);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	rm = load Raymath Raymath->PATH;
	if(rm == nil){
		sys->fprint(stderr, "raytest: cannot load Raymath\n");
		raise "fail:load";
	}
	rm->init();
	raster = load Raster3 Raster3->PATH;
	if(raster == nil){
		sys->fprint(stderr, "raytest: cannot load $Raster3\n");
		raise "fail:load";
	}

	testmath();
	testraster();
	testproject();

	sys->print("raytest: PASS %d/%d\n", npass, npass+nfail);
	if(nfail > 0){
		sys->fprint(stderr, "raytest: %d FAILURES\n", nfail);
		raise "fail:tests";
	}
}

testmath()
{
	id := Matrix.identity();
	t := Matrix.translate(1.0, 2.0, 3.0);

	# identity is a multiplicative unit
	check(meq(id.mul(t), t), "I*T == T");
	check(meq(t.mul(id), t), "T*I == T");

	# translation moves the origin
	o := Vector3(0.0, 0.0, 0.0);
	check(veq(o.transform(t), Vector3(1.0, 2.0, 3.0)), "translate origin");

	# inverse of a translation
	check(meq(t.invert(), Matrix.translate(-1.0, -2.0, -3.0)), "invert translate");

	# cross / dot / normalize
	x := Vector3(1.0, 0.0, 0.0);
	y := Vector3(0.0, 1.0, 0.0);
	check(veq(x.cross(y), Vector3(0.0, 0.0, 1.0)), "x cross y == z");
	check(feq(x.dot(y), 0.0), "x dot y == 0");
	check(feq(Vector3(3.0, 4.0, 0.0).length(), 5.0), "length 3,4");
	check(feq(Vector3(0.0, 5.0, 0.0).normalize().length(), 1.0), "normalize unit");

	# rotation preserves length and is invertible
	r := Matrix.rotatey(rm->PI/4.0);
	v := Vector3(1.0, 0.0, 0.0).transform(r);
	check(feq(v.length(), 1.0), "rotate preserves length");
	check(meq(r.mul(r.invert()), Matrix.identity()), "R*R^-1 == I");

	# lookat places the eye at the view-space origin
	eye := Vector3(0.0, 0.0, 5.0);
	view := Matrix.lookat(eye, Vector3(0.0,0.0,0.0), Vector3(0.0,1.0,0.0));
	check(veq(eye.transform(view), Vector3(0.0, 0.0, 0.0)), "lookat eye->origin");
}

meq(a, b: Matrix): int
{
	for(i := 0; i < 16; i++)
		if(!feq(a.m[i], b.m[i]))
			return 0;
	return 1;
}

# a full-screen quad of two triangles, all four corners at depth z, colour rgb
quad(verts: array of Vtx, w, h: int, z, r, g, b: real)
{
	fw := real w;
	fh := real h;
	verts[0] = Vtx(0.0, 0.0, z, 1.0, 0.0,0.0, r,g,b,1.0);
	verts[1] = Vtx(fw,  0.0, z, 1.0, 0.0,0.0, r,g,b,1.0);
	verts[2] = Vtx(fw,  fh,  z, 1.0, 0.0,0.0, r,g,b,1.0);
	verts[3] = Vtx(0.0, fh,  z, 1.0, 0.0,0.0, r,g,b,1.0);
}

# projectmesh (C) must reproduce the pure-Limbo transform/project/shade path
testproject()
{
	W := 320;
	H := 240;
	nv := 3;
	mvp := Matrix.perspective(rm->PI/4.0, real W/real H, 0.1, 100.0);
	rot := Matrix.rotatey(0.5);		# a rotation, as projectmesh requires

	mverts := array[] of {
		Vector3(0.3, -0.2, -2.0),
		Vector3(-0.5, 0.4, -3.0),
		Vector3(0.1, 0.6, -1.5),
	};
	mnorm := array[] of {
		Vector3(1.0, 0.0, 0.0),
		Vector3(0.0, 1.0, 0.0),
		Vector3(0.0, 0.0, 1.0),
	};
	pos := array[nv*3] of real;
	nrm := array[nv*3] of real;
	for(i := 0; i < nv; i++){
		pos[i*3] = mverts[i].x; pos[i*3+1] = mverts[i].y; pos[i*3+2] = mverts[i].z;
		nrm[i*3] = mnorm[i].x; nrm[i*3+1] = mnorm[i].y; nrm[i*3+2] = mnorm[i].z;
	}

	lv := Vector3(0.4, 0.7, 0.6).normalize();
	light := array[] of {lv.x, lv.y, lv.z};
	amb := 0.3;
	base := array[] of {0.9, 0.8, 0.5};

	out := array[nv] of Vtx;
	raster->projectmesh(out, pos, nrm, nil, nv, mvp.m, rot.m,
		real W, real H, light, amb, base);

	ok := 1;
	for(i = 0; i < nv; i++){
		(cv, wv) := mverts[i].transformp(mvp);
		if(wv == 0.0)
			wv = 0.0001;
		iw := 1.0/wv;
		sx := (cv.x*iw*0.5 + 0.5)*real W;
		sy := (1.0 - (cv.y*iw*0.5 + 0.5))*real H;
		nw := mnorm[i].transform(rot);
		d := nw.dot(lv);
		if(d < 0.0)
			d = 0.0;
		inten := amb + (1.0 - amb)*d;
		if(!feq(out[i].x, sx) || !feq(out[i].y, sy) || !feq(out[i].z, cv.z*iw)
		|| !feq(out[i].iw, iw) || !feq(out[i].r, base[0]*inten)
		|| !feq(out[i].g, base[1]*inten) || !feq(out[i].b, base[2]*inten))
			ok = 0;
	}
	check(ok, "projectmesh matches Limbo transformp");
}

testraster()
{
	w := 8;
	h := 8;
	pix := array[w*h*4] of byte;
	zbuf := array[w*h] of real;
	verts := array[4] of Vtx;
	tris := array[] of {0, 1, 2,  0, 2, 3};

	cx := 4;
	cy := 4;
	idx := (cy*w + cx)*4;

	# a single green quad should fill the centre pixel (XRGB32 bytes B,G,R,X)
	raster->clearcolor(pix, w, h, 0, 0, 0);
	raster->cleardepth(zbuf, 1e30);
	quad(verts, w, h, 0.0, 0.0, 1.0, 0.0);
	raster->drawmesh(pix, zbuf, w, h, verts, tris, nil, 0, 0,
		Raster3->GOURAUD, Raster3->CULLNONE);
	check(int pix[idx+1] > 200 && int pix[idx+2] < 50, "raster fills (green)");

	# z-buffer: a NEAR green quad must win over a FAR red one, drawn far-first
	raster->clearcolor(pix, w, h, 0, 0, 0);
	raster->cleardepth(zbuf, 1e30);
	quad(verts, w, h, 0.5, 1.0, 0.0, 0.0);		# far red
	raster->drawmesh(pix, zbuf, w, h, verts, tris, nil, 0, 0, Raster3->GOURAUD, Raster3->CULLNONE);
	quad(verts, w, h, -0.5, 0.0, 1.0, 0.0);		# near green
	raster->drawmesh(pix, zbuf, w, h, verts, tris, nil, 0, 0, Raster3->GOURAUD, Raster3->CULLNONE);
	check(int pix[idx+1] > 200 && int pix[idx+2] < 50, "zbuffer near-over-far");

	# ... and the far red must be REJECTED when drawn after the near green
	raster->clearcolor(pix, w, h, 0, 0, 0);
	raster->cleardepth(zbuf, 1e30);
	quad(verts, w, h, -0.5, 0.0, 1.0, 0.0);		# near green first
	raster->drawmesh(pix, zbuf, w, h, verts, tris, nil, 0, 0, Raster3->GOURAUD, Raster3->CULLNONE);
	quad(verts, w, h, 0.5, 1.0, 0.0, 0.0);		# far red second (must be hidden)
	raster->drawmesh(pix, zbuf, w, h, verts, tris, nil, 0, 0, Raster3->GOURAUD, Raster3->CULLNONE);
	check(int pix[idx+1] > 200 && int pix[idx+2] < 50, "zbuffer rejects far");
}
