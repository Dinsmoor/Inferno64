#include <lib9.h>
#include <draw.h>
#include <memdraw.h>

/*
 * Software triangle rasterizer with a per-pixel depth buffer, flat / Gouraud /
 * perspective-correct-textured, writing directly into a Memimage's pixel store
 * in that image's own channel order (no XRGB32 assumption).  This is the native
 * primitive behind the Limbo $Raster3 module; it is portable C so it works on
 * every emu host and on native os/ builds.
 *
 * The destination (and any texture) must have 8-bit, byte-aligned colour
 * channels -- i.e. the common cases RGB24, BGR24, XRGB32/RGBX32, RGBA32,
 * ABGR32, GREY8.  Channel byte offsets are derived from the image's chan
 * descriptor (shift[]/nbits[]), so red/green/blue land wherever that format
 * keeps them; byte offset == shift/8 (little-endian pixel order, matching the
 * rest of the draw stack on LE hosts).
 *
 * Vertices arrive already projected to screen space, in image-LOCAL pixel
 * coordinates (0,0 == dst->r.min).  The depth buffer is one double per pixel
 * over dst->r, row-major, Dx(dst->r) wide; smaller depth is nearer.  Callers
 * own all the array storage.
 */

static int
ifloor(double x)
{
	int i = (int)x;
	if(x < (double)i)
		i--;
	return i;
}

static int
iceil(double x)
{
	int i = (int)x;
	if(x > (double)i)
		i++;
	return i;
}

static double
dmin3(double a, double b, double c)
{
	double m = a;
	if(b < m) m = b;
	if(c < m) m = c;
	return m;
}

static double
dmax3(double a, double b, double c)
{
	double m = a;
	if(b > m) m = b;
	if(c > m) m = c;
	return m;
}

/* twice the signed area of triangle (a,b,p) */
static double
edge(double ax, double ay, double bx, double by, double px, double py)
{
	return (bx - ax)*(py - ay) - (by - ay)*(px - ax);
}

static uchar
clampb(double v)
{
	int i;

	i = (int)(v*255.0 + 0.5);
	if(i < 0)
		i = 0;
	if(i > 255)
		i = 255;
	return (uchar)i;
}

/* byte offset of an 8-bit channel within a pixel, or -1 if absent/not 8-bit */
static int
chanoff(Memimage *m, int ctype)
{
	if(m->nbits[ctype] != 8)
		return -1;
	return m->shift[ctype]/8;
}

/*
 * Resolve a Memimage's colour layout into byte offsets the inner loop can use.
 * Returns 0 if the format is unsupported (channels not 8-bit/byte-aligned).
 */
typedef struct Pixfmt Pixfmt;
struct Pixfmt
{
	int	bpp;		/* bytes per pixel */
	int	grey;		/* 1 == single grey channel */
	int	roff, goff, boff;
	int	aoff;		/* alpha byte, or -1 */
	int	xoff;		/* ignore (X) byte to force opaque, or -1 */
};

static int
pixfmt(Memimage *m, Pixfmt *f)
{
	if(m->depth < 8 || (m->depth & 7) != 0)
		return 0;
	f->bpp = m->depth/8;
	f->grey = (m->flags & Fgrey) != 0;
	f->aoff = chanoff(m, CAlpha);
	f->xoff = chanoff(m, CIgnore);
	if(f->grey){
		f->roff = f->goff = f->boff = chanoff(m, CGrey);
		if(f->goff < 0)
			return 0;
		return 1;
	}
	f->roff = chanoff(m, CRed);
	f->goff = chanoff(m, CGreen);
	f->boff = chanoff(m, CBlue);
	if(f->roff < 0 || f->goff < 0 || f->boff < 0)
		return 0;
	return 1;
}

static void
putpix(uchar *d, Pixfmt *f, double cr, double cg, double cb, double ca)
{
	if(f->grey){
		d[f->goff] = clampb(0.299*cr + 0.587*cg + 0.114*cb);
	} else {
		d[f->roff] = clampb(cr);
		d[f->goff] = clampb(cg);
		d[f->boff] = clampb(cb);
	}
	if(f->aoff >= 0)
		d[f->aoff] = clampb(ca);
	else if(f->xoff >= 0)
		d[f->xoff] = 0xff;	/* keep X opaque for the compositor */
}

int
memmesh(Memimage *dst, double *zbuf, Memvtx *V, int nv, int *T, int ntri,
	Memimage *tex, int mode, int cull)
{
	Memvtx *a, *b, *c;
	Pixfmt df, tf;
	uchar *rowbase, *d, *tp;
	int w, h, t, i0, i1, i2, x, y;
	int minx, maxx, miny, maxy, clx0, cly0, clx1, cly1;
	int rminx, rminy, tw, th, hastex;
	double area, inv, px, py, w0, w1, w2, l0, l1, l2, z;
	double cr, cg, cb, ca, iw, uu, vv;

	if(dst == nil || V == nil || T == nil)
		return 0;
	if(!pixfmt(dst, &df))
		return 0;

	w = Dx(dst->r);
	h = Dy(dst->r);
	rminx = dst->r.min.x;
	rminy = dst->r.min.y;

	/* clip box in image-local coords, intersected with clipr */
	clx0 = dst->clipr.min.x - rminx;  if(clx0 < 0) clx0 = 0;
	cly0 = dst->clipr.min.y - rminy;  if(cly0 < 0) cly0 = 0;
	clx1 = dst->clipr.max.x - rminx;  if(clx1 > w) clx1 = w;
	cly1 = dst->clipr.max.y - rminy;  if(cly1 > h) cly1 = h;
	if(clx0 >= clx1 || cly0 >= cly1)
		return 1;

	hastex = (mode == MEMmeshTEXTURED && tex != nil && pixfmt(tex, &tf));
	tw = th = 0;
	if(hastex){
		tw = Dx(tex->r);
		th = Dy(tex->r);
	}

	for(t = 0; t < ntri; t++){
		i0 = T[t*3];
		i1 = T[t*3 + 1];
		i2 = T[t*3 + 2];
		if(i0 < 0 || i1 < 0 || i2 < 0 || i0 >= nv || i1 >= nv || i2 >= nv)
			continue;
		a = &V[i0];
		b = &V[i1];
		c = &V[i2];

		area = edge(a->x, a->y, b->x, b->y, c->x, c->y);
		if(area == 0.0)
			continue;
		if(cull == MEMmeshCULLNEG && area < 0.0)
			continue;
		if(cull == MEMmeshCULLPOS && area > 0.0)
			continue;

		minx = ifloor(dmin3(a->x, b->x, c->x));
		maxx = iceil (dmax3(a->x, b->x, c->x));
		miny = ifloor(dmin3(a->y, b->y, c->y));
		maxy = iceil (dmax3(a->y, b->y, c->y));
		if(minx < clx0) minx = clx0;
		if(miny < cly0) miny = cly0;
		if(maxx > clx1-1) maxx = clx1-1;
		if(maxy > cly1-1) maxy = cly1-1;

		inv = 1.0/area;
		for(y = miny; y <= maxy; y++){
			rowbase = byteaddr(dst, Pt(rminx, rminy + y));
			for(x = minx; x <= maxx; x++){
				px = x + 0.5;
				py = y + 0.5;
				w0 = edge(b->x, b->y, c->x, c->y, px, py);
				w1 = edge(c->x, c->y, a->x, a->y, px, py);
				w2 = edge(a->x, a->y, b->x, b->y, px, py);
				if(area > 0.0){
					if(w0 < 0.0 || w1 < 0.0 || w2 < 0.0)
						continue;
				} else {
					if(w0 > 0.0 || w1 > 0.0 || w2 > 0.0)
						continue;
				}
				l0 = w0*inv;
				l1 = w1*inv;
				l2 = w2*inv;

				z = l0*a->z + l1*b->z + l2*c->z;
				if(zbuf != nil){
					if(z >= zbuf[y*w + x])
						continue;
				}

				if(mode == MEMmeshFLAT){
					cr = a->r; cg = a->g; cb = a->b; ca = a->a;
				} else {
					cr = l0*a->r + l1*b->r + l2*c->r;
					cg = l0*a->g + l1*b->g + l2*c->g;
					cb = l0*a->b + l1*b->b + l2*c->b;
					ca = l0*a->a + l1*b->a + l2*c->a;
				}

				if(hastex){
					iw = l0*a->iw + l1*b->iw + l2*c->iw;
					if(iw == 0.0)
						iw = 1e-9;
					uu = (l0*a->u*a->iw + l1*b->u*b->iw + l2*c->u*c->iw)/iw;
					vv = (l0*a->v*a->iw + l1*b->v*b->iw + l2*c->v*c->iw)/iw;
					uu -= (double)ifloor(uu);	/* wrap 0..1 */
					vv -= (double)ifloor(vv);
					{
						int sx = (int)(uu*tw);
						int sy = (int)(vv*th);
						if(sx < 0) sx = 0;
						if(sx >= tw) sx = tw-1;
						if(sy < 0) sy = 0;
						if(sy >= th) sy = th-1;
						tp = byteaddr(tex, Pt(tex->r.min.x+sx, tex->r.min.y+sy));
						cr *= tp[tf.roff]/255.0;
						cg *= tp[tf.goff]/255.0;
						cb *= tp[tf.boff]/255.0;
					}
				}

				if(zbuf != nil)
					zbuf[y*w + x] = z;
				d = rowbase + x*df.bpp;
				putpix(d, &df, cr, cg, cb, ca);
			}
		}
	}
	return 1;
}

/*
 * Transform + project a whole vertex array into out[] (the vertex stage of the
 * pipeline, in C).  Faithful port of the Limbo Raymath transformp/transform:
 * matrices are raylib-layout (m[i]==mi); the normal is used un-renormalised, so
 * nmat must be a rotation and the input normals unit.  pos/nrm are 3 doubles
 * per vertex, uv 2 doubles (or nil), mvp/nmat 16 doubles, light 3 (or nil),
 * base 3 (colour).  Screen size w,h maps NDC to image-local pixels.
 */
void
memmeshproject(Memvtx *out, double *pos, double *nrm, double *uv, int nv,
	double *mvp, double *nmat, double w, double h,
	double *light, double ambient, double *base)
{
	double *m, br, bg, bb, lx, ly, lz;
	int i, lit;

	if(out == nil || pos == nil || mvp == nil || base == nil)
		return;
	m = mvp;
	br = base[0]; bg = base[1]; bb = base[2];
	lit = (light != nil && nrm != nil && nmat != nil);
	lx = ly = lz = 0.0;
	if(lit){
		lx = light[0]; ly = light[1]; lz = light[2];
	}

	for(i = 0; i < nv; i++){
		double x = pos[i*3], y = pos[i*3+1], z = pos[i*3+2];
		double cx = m[0]*x + m[4]*y + m[8]*z  + m[12];
		double cy = m[1]*x + m[5]*y + m[9]*z  + m[13];
		double cz = m[2]*x + m[6]*y + m[10]*z + m[14];
		double cw = m[3]*x + m[7]*y + m[11]*z + m[15];
		double iw, inten = 1.0;

		if(cw == 0.0)
			cw = 0.0001;
		iw = 1.0/cw;
		out[i].x = (cx*iw*0.5 + 0.5)*w;
		out[i].y = (1.0 - (cy*iw*0.5 + 0.5))*h;
		out[i].z = cz*iw;
		out[i].iw = iw;
		if(uv != nil){
			out[i].u = uv[i*2];
			out[i].v = uv[i*2+1];
		} else {
			out[i].u = 0.0;
			out[i].v = 0.0;
		}
		if(lit){
			double nx = nrm[i*3], ny = nrm[i*3+1], nz = nrm[i*3+2];
			double tx = nmat[0]*nx + nmat[4]*ny + nmat[8]*nz  + nmat[12];
			double ty = nmat[1]*nx + nmat[5]*ny + nmat[9]*nz  + nmat[13];
			double tz = nmat[2]*nx + nmat[6]*ny + nmat[10]*nz + nmat[14];
			double dd = tx*lx + ty*ly + tz*lz;
			if(dd < 0.0)
				dd = 0.0;
			inten = ambient + (1.0 - ambient)*dd;
		}
		out[i].r = br*inten;
		out[i].g = bg*inten;
		out[i].b = bb*inten;
		out[i].a = 1.0;
	}
}
