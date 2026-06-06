# Raster3 - native software triangle rasterizer with a depth buffer and
# perspective-correct texturing.  This is the Phase-3 C kernel of the
# raylib-in-Limbo port: vertex processing stays in Limbo (Raymath), the
# hot per-pixel inner loop is C (libinterp/raster3.c).
#
# Pixel buffers are plain Limbo arrays so the caller owns allocation and can
# blit the result with Draw->Image.writepixels.  Framebuffer and texture are
# 4 bytes/pixel in Draw->XRGB32 order (little-endian B,G,R,X); create the
# destination image with Draw->XRGB32.  Depth is one real per pixel (smaller
# == nearer).

Raster3: module
{
	PATH:	con "$Raster3";

	# shading modes
	FLAT:		con 0;	# whole triangle uses vertex a's colour
	GOURAUD:	con 1;	# interpolate per-vertex colour (screen-linear)
	TEXTURED:	con 2;	# perspective-correct texture, modulated by colour

	# back-face culling (by signed screen area; pick empirically per winding)
	CULLNONE:	con 0;
	CULLNEG:	con 1;	# drop triangles with negative screen area
	CULLPOS:	con 2;	# drop triangles with positive screen area

	# A vertex after projection to screen space (done in Limbo via Raymath).
	Vtx: adt {
		x, y:	real;	# screen pixel coordinates
		z:	real;	# depth (NDC z); smaller is nearer
		iw:	real;	# 1/w_clip, for perspective-correct interpolation
		u, v:	real;	# texture coordinates, 0..1
		r, g, b, a: real;	# colour, 0..1
	};

	# Clear a depth buffer (length w*h) to val (use a large number, e.g. 1e30).
	cleardepth:	fn(zbuf: array of real, val: real);

	# Clear a framebuffer (length w*h*4) to a solid opaque colour (0..255).
	clearcolor:	fn(pix: array of byte, w, h, r, g, b: int);

	# Rasterize a triangle mesh into pix(+zbuf).  verts holds projected
	# vertices; tris holds 3 vertex indices per triangle.  tex may be nil
	# unless mode==TEXTURED (then tw,th are its dimensions).
	drawmesh:	fn(pix: array of byte, zbuf: array of real, w, h: int,
				verts: array of Vtx, tris: array of int,
				tex: array of byte, tw, th: int, mode, cull: int);

	# Transform + project a whole vertex array into out[] in one C call,
	# replacing the pure-Limbo per-vertex loop (the 3D bottleneck: Dis-level
	# mat*vec plus a heap alloc per vertex per frame).  Fills screen x/y,
	# depth z (NDC), iw=1/w_clip, texcoords (from uv, or 0), and Gouraud
	# colour = base*intensity.
	#
	#   pos  - nv*3 reals, model-space xyz per vertex
	#   nrm  - nv*3 reals, model-space normals (nil = no lighting)
	#   uv   - nv*2 reals, texcoords (nil = u=v=0)
	#   mvp  - 16 reals, model*view*proj (Matrix.m layout)
	#   nmat - 16 reals, normal matrix (a rotation; nil = no lighting).
	#          The transformed normal is used directly, not renormalised, so
	#          normals must be unit and nmat orthonormal (matches dot-shading).
	#   w,h  - viewport size in pixels
	#   light    - 3 reals, unit light direction (nil = unlit, intensity 1)
	#   ambient  - ambient term 0..1
	#   base     - 3 reals, base colour (r,g,b) 0..1
	projectmesh:	fn(out: array of Vtx, pos, nrm, uv: array of real, nv: int,
				mvp, nmat: array of real, w, h: real,
				light: array of real, ambient: real,
				base: array of real);
};
