#include <lib9.h>
#include <kernel.h>
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include <draw.h>
#include <drawif.h>
#include <memdraw.h>
#include "raster3mod.h"

/*
 * Limbo face of the native 3D rasterizer.  The actual per-pixel and per-vertex
 * work lives in the portable libmemdraw primitives memmesh()/memmeshproject();
 * this file only marshals Limbo arguments.  drawmesh resolves the Draw image to
 * its server-side Memimage (via devdraw's drawmesh3) and rasterizes straight
 * into its pixel store -- no intermediate framebuffer, any 8-bit channel order.
 *
 * The VM lock is held throughout (we hold raw pointers into caller-owned Limbo
 * arrays, so they must not move); drawmesh3 additionally takes the draw qlock.
 */

void
raster3modinit(void)
{
	builtinmod("$Raster3", Raster3modtab, Raster3modlen);
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
Raster3_drawmesh(void *fp)
{
	F_Raster3_drawmesh *f = fp;
	Image *dst, *tex;
	ulong qidpath;
	int dstid, texid, nv, ntri, locked, i, nidx;
	double *zbuf;
	int *tris;
	WORD *wtris;
	void *verts;

	if(f->dst == H || f->verts == H || f->tris == H)
		return;

	dst = checkimage(f->dst);		/* libdraw Image* (raises if nil) */
	qidpath = dst->display->dataqid;
	dstid = dst->id;

	texid = 0;
	if(f->tex != H){
		tex = checkimage(f->tex);
		texid = tex->id;
	}

	/*
	 * Limbo Draw ops are buffered and flushed lazily; memmesh writes the
	 * Memimage immediately.  Flush any pending ops (e.g. a background clear
	 * queued just before this call) so they apply BEFORE we rasterize, not
	 * after.
	 */
	locked = lockdisplay(dst->display);
	flushimage(dst->display, 0);

	zbuf = nil;
	if(f->zbuf != H)
		zbuf = (double*)f->zbuf->data;
	verts = f->verts->data;
	nv = f->verts->len;
	/*
	 * tris is a Limbo 'array of int'.  Under ILP64 a Limbo int is a WORD
	 * (8 bytes), so it can no longer be cast straight to a C int*; copy the
	 * indices down into a C int array for drawmesh3.
	 */
	ntri = f->tris->len / 3;
	nidx = ntri * 3;
	wtris = (WORD*)f->tris->data;
	tris = malloc(nidx * sizeof(int));
	if(tris == nil){
		if(locked)
			unlockdisplay(dst->display);
		return;
	}
	for(i = 0; i < nidx; i++)
		tris[i] = (int)wtris[i];

	drawmesh3(qidpath, dstid, texid, zbuf, verts, nv, tris, ntri,
		f->mode, f->cull);

	free(tris);
	if(locked)
		unlockdisplay(dst->display);
}

void
Raster3_projectmesh(void *fp)
{
	F_Raster3_projectmesh *f = fp;
	double *nrm, *uv, *nmat, *light;
	int nv;

	if(f->out == H || f->pos == H || f->mvp == H || f->base == H)
		return;

	nrm   = (f->nrm   != H) ? (double*)f->nrm->data   : nil;
	uv    = (f->uv    != H) ? (double*)f->uv->data    : nil;
	nmat  = (f->nmat  != H) ? (double*)f->nmat->data  : nil;
	light = (f->light != H) ? (double*)f->light->data : nil;

	nv = f->nv;
	if(nv > f->out->len)
		nv = f->out->len;
	if(nv*3 > f->pos->len)
		nv = f->pos->len/3;

	memmeshproject((Memvtx*)f->out->data, (double*)f->pos->data, nrm, uv, nv,
		(double*)f->mvp->data, nmat, f->w, f->h,
		light, f->ambient, (double*)f->base->data);
}
