implement RayTest;

#
# raytest - self-test for the raylib-in-Limbo port: numeric checks on Raymath
# and the C vertex stage, plus z-buffer/raster checks on $Raster3.  Prints
# "raytest: PASS n/n" and exits nonzero on any failure.  The raster checks now
# rasterize into a real Draw image (the native zero-copy path), so they need a
# display: run under one, e.g.  emu -g320x240 /dis/raytest.dis  (headless they
# are skipped; the Raymath + projectmesh checks still run).
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
include "imageio.m";
	imageio: Imageio;

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
	draw = load Draw Draw->PATH;
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
	imageio = load Imageio Imageio->PATH;
	if(imageio == nil){
		sys->fprint(stderr, "raytest: cannot load $Imageio\n");
		raise "fail:load";
	}

	testmath();
	testimageio();
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

# centre pixel is green: G byte high, R byte low (XRGB32 read order B,G,R,X)
isgreen(pix: array of byte, idx: int): int
{
	return int pix[idx+1] > 200 && int pix[idx+2] < 50;
}

testimageio()
{
	# embedded 2x2 RGBA PNG; pixels top->bottom, left->right:
	#   (0,0) red    (1,0) green
	#   (0,1) blue   (1,1) yellow @ alpha 128
	png := array[] of {
		byte 16r89, byte 16r50, byte 16r4e, byte 16r47, byte 16r0d, byte 16r0a, byte 16r1a, byte 16r0a,
		byte 16r00, byte 16r00, byte 16r00, byte 16r0d, byte 16r49, byte 16r48, byte 16r44, byte 16r52,
		byte 16r00, byte 16r00, byte 16r00, byte 16r02, byte 16r00, byte 16r00, byte 16r00, byte 16r02,
		byte 16r08, byte 16r06, byte 16r00, byte 16r00, byte 16r00, byte 16r72, byte 16rb6, byte 16r0d,
		byte 16r24, byte 16r00, byte 16r00, byte 16r00, byte 16r14, byte 16r49, byte 16r44, byte 16r41,
		byte 16r54, byte 16r78, byte 16rda, byte 16r63, byte 16rf8, byte 16rcf, byte 16rc0, byte 16rf0,
		byte 16r1f, byte 16r0c, byte 16r81, byte 16r34, byte 16r10, byte 16r30, byte 16r34, byte 16r00,
		byte 16r00, byte 16r47, byte 16r4b, byte 16r08, byte 16r79, byte 16rc3, byte 16r25, byte 16r87,
		byte 16reb, byte 16r00, byte 16r00, byte 16r00, byte 16r00, byte 16r49, byte 16r45, byte 16r4e,
		byte 16r44, byte 16rae, byte 16r42, byte 16r60, byte 16r82,
	};
	(w, h, rgba, err) := imageio->decode(png);
	check(rgba != nil && err == nil, "imageio decode ok");
	if(rgba == nil){
		sys->fprint(stderr, "raytest: imageio decode: %s\n", err);
		return;
	}
	check(w == 2 && h == 2, "imageio decode 2x2");
	check(len rgba == 16, "imageio rgba is w*h*4");
	if(len rgba >= 16){
		check(texel(rgba, 0, 255,0,0,255),   "decode texel(0,0) red");
		check(texel(rgba, 1, 0,255,0,255),   "decode texel(1,0) green");
		check(texel(rgba, 2, 0,0,255,255),   "decode texel(0,1) blue");
		check(texel(rgba, 3, 255,255,0,128), "decode texel(1,1) yellow a=128");
	}

	# junk input must fail gracefully (error, no crash, no image)
	(bw, bh, bad, berr) := imageio->decode(array[] of {byte 1, byte 2, byte 3, byte 4});
	check(bad == nil && berr != nil && bw == 0 && bh == 0, "imageio rejects junk");
}

texel(rgba: array of byte, i: int, r, g, b, a: int): int
{
	o := i*4;
	return int rgba[o]==r && int rgba[o+1]==g && int rgba[o+2]==b && int rgba[o+3]==a;
}

# a full-image quad with uv spanning 0..1 and a white base (so the texture
# shows unmodulated)
texquad(verts: array of Vtx, w, h: int, z: real)
{
	fw := real w;
	fh := real h;
	verts[0] = Vtx(0.0, 0.0, z, 1.0, 0.0,0.0, 1.0,1.0,1.0,1.0);
	verts[1] = Vtx(fw,  0.0, z, 1.0, 1.0,0.0, 1.0,1.0,1.0,1.0);
	verts[2] = Vtx(fw,  fh,  z, 1.0, 1.0,1.0, 1.0,1.0,1.0,1.0);
	verts[3] = Vtx(0.0, fh,  z, 1.0, 0.0,1.0, 1.0,1.0,1.0,1.0);
}

testraster()
{
	w := 8;
	h := 8;
	disp := Display.allocate(nil);
	if(disp == nil){
		sys->fprint(stderr, "raytest: no display; skipping raster tests\n");
		return;
	}
	img := disp.newimage(Rect((0,0),(w,h)), draw->XRGB32, 0, draw->Black);
	if(img == nil){
		sys->fprint(stderr, "raytest: cannot allocate image; skipping raster tests\n");
		return;
	}
	black := disp.black;
	zbuf := array[w*h] of real;
	verts := array[4] of Vtx;
	tris := array[] of {0, 1, 2,  0, 2, 3};
	pix := array[w*h*4] of byte;

	idx := (4*w + 4)*4;	# centre pixel byte offset

	# a single green quad should fill the centre pixel
	img.draw(img.r, black, nil, (0,0));
	raster->cleardepth(zbuf, 1e30);
	quad(verts, w, h, 0.0, 0.0, 1.0, 0.0);
	raster->drawmesh(img, zbuf, verts, tris, nil, Raster3->GOURAUD, Raster3->CULLNONE);
	img.readpixels(img.r, pix);
	check(isgreen(pix, idx), "raster fills (green)");

	# z-buffer: a NEAR green quad must win over a FAR red one, drawn far-first
	img.draw(img.r, black, nil, (0,0));
	raster->cleardepth(zbuf, 1e30);
	quad(verts, w, h, 0.5, 1.0, 0.0, 0.0);		# far red
	raster->drawmesh(img, zbuf, verts, tris, nil, Raster3->GOURAUD, Raster3->CULLNONE);
	quad(verts, w, h, -0.5, 0.0, 1.0, 0.0);		# near green
	raster->drawmesh(img, zbuf, verts, tris, nil, Raster3->GOURAUD, Raster3->CULLNONE);
	img.readpixels(img.r, pix);
	check(isgreen(pix, idx), "zbuffer near-over-far");

	# ... and the far red must be REJECTED when drawn after the near green
	img.draw(img.r, black, nil, (0,0));
	raster->cleardepth(zbuf, 1e30);
	quad(verts, w, h, -0.5, 0.0, 1.0, 0.0);		# near green first
	raster->drawmesh(img, zbuf, verts, tris, nil, Raster3->GOURAUD, Raster3->CULLNONE);
	quad(verts, w, h, 0.5, 1.0, 0.0, 0.0);		# far red second (must be hidden)
	raster->drawmesh(img, zbuf, verts, tris, nil, Raster3->GOURAUD, Raster3->CULLNONE);
	img.readpixels(img.r, pix);
	check(isgreen(pix, idx), "zbuffer rejects far");

	# TEXTURED: sample a solid-green texture through the perspective-correct
	# path.  Building the texture via writepixels into an ABGR32 image and then
	# having memmesh read green back also validates the ABGR32 (R,G,B,A) byte
	# order -- the exact layout $Imageio/stb_image hands back.
	tex := disp.newimage(Rect((0,0),(1,1)), draw->ABGR32, 0, draw->Black);
	if(tex != nil){
		tex.writepixels(tex.r, array[] of {byte 0, byte 255, byte 0, byte 255});
		img.draw(img.r, black, nil, (0,0));
		raster->cleardepth(zbuf, 1e30);
		texquad(verts, w, h, 0.0);
		raster->drawmesh(img, zbuf, verts, tris, tex, Raster3->TEXTURED, Raster3->CULLNONE);
		img.readpixels(img.r, pix);
		check(isgreen(pix, idx), "textured quad samples texture (ABGR32)");
	}
}
