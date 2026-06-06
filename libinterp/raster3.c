#include <lib9.h>
#include <kernel.h>
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "raster3mod.h"

/*
 * Native software triangle rasterizer for the raylib-in-Limbo port.
 *
 * The Limbo side (Raymath) projects vertices to screen space and fills a
 * Raster3_Vtx array; this kernel does the per-pixel work: edge-function
 * rasterization, a depth (z) buffer, flat/Gouraud shading and
 * perspective-correct texture mapping.  Buffers are caller-owned Limbo
 * arrays (framebuffer + texture are 4 bytes/pixel; depth is one real each).
 *
 * No VM lock juggling: we only read/write caller arrays already on the heap
 * and never allocate or re-enter Dis, so the lock is held throughout (the
 * arrays must not move under us).
 *
 * Framebuffer pixel format is XRGB32 as Inferno draw stores it on a
 * little-endian host: 4 bytes/pixel in memory order B,G,R,X (the word
 * X<<24|R<<16|G<<8|B that win-x11a.c expects).  Create the destination
 * Draw image with Draw->XRGB32 and blit it with Image.writepixels.
 */

void
raster3modinit(void)
{
	builtinmod("$Raster3", Raster3modtab, Raster3modlen);
}

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

void
Raster3_cleardepth(void *fp)
{
	F_Raster3_cleardepth *f = fp;
	double *z;
	int i, n;

	if(f->zbuf == H)
		return;
	z = (double*)f->zbuf->data;
	n = f->zbuf->len;
	for(i = 0; i < n; i++)
		z[i] = f->val;
}

void
Raster3_clearcolor(void *fp)
{
	F_Raster3_clearcolor *f = fp;
	uchar *p, r, g, b;
	int i, n;

	if(f->pix == H)
		return;
	p = f->pix->data;
	n = f->w * f->h;
	if(n*4 > f->pix->len)
		n = f->pix->len/4;
	r = (uchar)f->r;
	g = (uchar)f->g;
	b = (uchar)f->b;
	for(i = 0; i < n; i++){
		p[0] = b;	/* XRGB32 little-endian: B,G,R,X */
		p[1] = g;
		p[2] = r;
		p[3] = 255;
		p += 4;
	}
}

/*
 * Transform + project an entire vertex array in one C call.  This replaces the
 * pure-Limbo per-vertex loop (a Dis-level mat*vec plus a short-lived heap
 * allocation per vertex per frame -- the 3D bottleneck).  Same locking model
 * as drawmesh: we only read/write caller arrays, never re-enter Dis or alloc.
 *
 * Matrix layout matches Raymath (m[i] == raylib mi); the transform below is a
 * faithful port of Raymath's Vector3.transformp / Vector3.transform.  The
 * normal is NOT renormalised (matching rayteapot's shading), so nmat must be a
 * rotation and the input normals unit.
 */
void
Raster3_projectmesh(void *fp)
{
	F_Raster3_projectmesh *f = fp;
	Raster3_Vtx *out;
	double *pos, *nrm, *uv, *m, *nm, *base, *light;
	double w, h, amb, br, bg, bb, lx, ly, lz;
	int nv, i, lit;

	if(f->out == H || f->pos == H || f->mvp == H || f->base == H)
		return;
	out = (Raster3_Vtx*)f->out->data;
	pos = (double*)f->pos->data;
	m = (double*)f->mvp->data;
	base = (double*)f->base->data;
	nrm = (f->nrm != H) ? (double*)f->nrm->data : nil;
	uv  = (f->uv  != H) ? (double*)f->uv->data  : nil;
	nm  = (f->nmat != H) ? (double*)f->nmat->data : nil;

	nv = f->nv;
	if(nv > f->out->len)
		nv = f->out->len;
	if(nv*3 > f->pos->len)
		nv = f->pos->len/3;
	w = f->w;
	h = f->h;
	amb = f->ambient;
	br = base[0];
	bg = base[1];
	bb = base[2];

	lit = (f->light != H && nrm != nil && nm != nil);
	lx = ly = lz = 0.0;
	if(lit){
		light = (double*)f->light->data;
		lx = light[0];
		ly = light[1];
		lz = light[2];
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
			double tx = nm[0]*nx + nm[4]*ny + nm[8]*nz  + nm[12];
			double ty = nm[1]*nx + nm[5]*ny + nm[9]*nz  + nm[13];
			double tz = nm[2]*nx + nm[6]*ny + nm[10]*nz + nm[14];
			double d = tx*lx + ty*ly + tz*lz;
			if(d < 0.0)
				d = 0.0;
			inten = amb + (1.0 - amb)*d;
		}
		out[i].r = br*inten;
		out[i].g = bg*inten;
		out[i].b = bb*inten;
		out[i].a = 1.0;
	}
}

void
Raster3_drawmesh(void *fp)
{
	F_Raster3_drawmesh *f = fp;
	uchar *fb, *tex;
	double *zb;
	Raster3_Vtx *V, *a, *b, *c;
	WORD *T;
	int w, h, ntri, nv, tw, th, mode, cull, t;
	int i0, i1, i2, minx, maxx, miny, maxy, x, y, idx;
	double area, inv, px, py, w0, w1, w2, l0, l1, l2, z;
	double cr, cg, cb, iw, uu, vv;
	uchar *d, *tp;

	if(f->pix == H || f->zbuf == H || f->verts == H || f->tris == H)
		return;

	w = f->w;
	h = f->h;
	fb = f->pix->data;
	zb = (double*)f->zbuf->data;
	V = (Raster3_Vtx*)f->verts->data;
	nv = f->verts->len;
	T = (WORD*)f->tris->data;
	ntri = f->tris->len / 3;
	mode = f->mode;
	cull = f->cull;

	tex = nil;
	tw = th = 0;
	if(f->tex != H){
		tex = f->tex->data;
		tw = f->tw;
		th = f->th;
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
		if(cull == 1 && area < 0.0)
			continue;
		if(cull == 2 && area > 0.0)
			continue;

		minx = ifloor(dmin3(a->x, b->x, c->x));
		maxx = iceil (dmax3(a->x, b->x, c->x));
		miny = ifloor(dmin3(a->y, b->y, c->y));
		maxy = iceil (dmax3(a->y, b->y, c->y));
		if(minx < 0) minx = 0;
		if(miny < 0) miny = 0;
		if(maxx > w-1) maxx = w-1;
		if(maxy > h-1) maxy = h-1;

		inv = 1.0/area;
		for(y = miny; y <= maxy; y++){
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
				idx = y*w + x;
				if(z >= zb[idx])
					continue;

				if(mode == 0){		/* FLAT */
					cr = a->r;
					cg = a->g;
					cb = a->b;
				} else {		/* GOURAUD / TEXTURED base */
					cr = l0*a->r + l1*b->r + l2*c->r;
					cg = l0*a->g + l1*b->g + l2*c->g;
					cb = l0*a->b + l1*b->b + l2*c->b;
				}

				if(mode == 2 && tex != nil){
					iw = l0*a->iw + l1*b->iw + l2*c->iw;
					if(iw == 0.0)
						iw = 1e-9;
					uu = (l0*a->u*a->iw + l1*b->u*b->iw + l2*c->u*c->iw)/iw;
					vv = (l0*a->v*a->iw + l1*b->v*b->iw + l2*c->v*c->iw)/iw;
					uu -= (double)ifloor(uu);	/* wrap to 0..1 */
					vv -= (double)ifloor(vv);
					{
						int sx = (int)(uu*tw);
						int sy = (int)(vv*th);
						if(sx < 0) sx = 0;
						if(sx >= tw) sx = tw-1;
						if(sy < 0) sy = 0;
						if(sy >= th) sy = th-1;
						tp = tex + (sy*tw + sx)*4;
						cr *= tp[0]/255.0;
						cg *= tp[1]/255.0;
						cb *= tp[2]/255.0;
					}
				}

				zb[idx] = z;
				d = fb + idx*4;
				d[0] = clampb(cb);	/* XRGB32 LE: B,G,R,X */
				d[1] = clampb(cg);
				d[2] = clampb(cr);
				d[3] = 255;
			}
		}
	}
}
