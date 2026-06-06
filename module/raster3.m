# Raster3 - native software triangle rasterizer with a depth buffer and
# perspective-correct texturing, layered on the native Draw system.  The hot
# per-pixel and per-vertex loops are C (libmemdraw/mesh.c, the reusable
# `memmesh`/`memmeshproject` primitives); this module is the Limbo face of them.
#
# drawmesh rasterizes DIRECTLY into a Draw image's pixel store (any 8-bit-channel
# format: RGB24, XRGB32, RGBA32, ...), so there is no intermediate framebuffer
# and no manual blit/convert -- allocate an off-screen Draw image, draw the mesh
# into it, then blit it to your window (or hand the image to <canvas>).  Clear it
# with ordinary Draw (e.g. img.draw(img.r, colour, nil, ...)).
#
# The depth buffer is a caller-owned `array of real`, one per pixel over the
# destination image's rectangle (Dx*Dy), smaller == nearer.
#
# Consumers must `include "draw.m"` before this file (for Draw->Image).

Raster3: module
{
	PATH:	con "$Raster3";

	# shading modes (must match libmemdraw MEMmesh* enums)
	FLAT:		con 0;	# whole triangle uses vertex a's colour
	GOURAUD:	con 1;	# interpolate per-vertex colour (screen-linear)
	TEXTURED:	con 2;	# perspective-correct texture, modulated by colour

	# back-face culling (by signed screen area; pick empirically per winding)
	CULLNONE:	con 0;
	CULLNEG:	con 1;	# drop triangles with negative screen area
	CULLPOS:	con 2;	# drop triangles with positive screen area

	# A vertex after projection to screen space (image-local pixels).
	Vtx: adt {
		x, y:	real;	# screen pixel coordinates (0,0 == image min)
		z:	real;	# depth (NDC z); smaller is nearer
		iw:	real;	# 1/w_clip, for perspective-correct interpolation
		u, v:	real;	# texture coordinates, 0..1
		r, g, b, a: real;	# colour, 0..1
	};

	# Clear a depth buffer (length Dx*Dy of the target) to val (e.g. 1e30).
	cleardepth:	fn(zbuf: array of real, val: real);

	# Rasterize a triangle mesh straight into dst's pixel store, z-buffered.
	# verts holds projected vertices; tris holds 3 vertex indices per triangle.
	# zbuf must have one real per pixel of dst.r (or be nil for no depth test).
	# tex is a Draw image (nil unless mode==TEXTURED).  dst should be an
	# off-screen image (not a live window/layer).
	drawmesh:	fn(dst: ref Draw->Image, zbuf: array of real,
				verts: array of Vtx, tris: array of int,
				tex: ref Draw->Image, mode, cull: int);

	# Transform + project a whole vertex array into out[] in one C call (the
	# vertex stage: model->clip transform, perspective divide, viewport map,
	# optional directional Gouraud shading).  Pre-pack model-space pos/nrm into
	# flat real arrays (3 each per vertex); uv is 2 per vertex or nil; mvp/nmat
	# are 16 reals (Matrix.m layout); nmat must be a rotation (normals are not
	# renormalised); light is 3 reals (nil = unlit); base is the rgb colour.
	# w,h are the destination size in pixels (dst.r.dx()/dy()).
	projectmesh:	fn(out: array of Vtx, pos, nrm, uv: array of real, nv: int,
				mvp, nmat: array of real, w, h: real,
				light: array of real, ambient: real,
				base: array of real);
};
