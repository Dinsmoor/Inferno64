#include <lib9.h>
#include <kernel.h>
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "imageiomod.h"

/*
 * Limbo face of the native image decoder.  The codec work lives in libstb
 * (stbwrap.c wrapping the vendored stb single-header libraries); this file only
 * marshals Limbo arguments and has no Draw/Memimage dependency at all -- it
 * hands back raw RGBA bytes and lets the Imageload library build the image.
 *
 * The stbwrap_* prototypes are declared here (not via a header) so the stb
 * world and the Inferno (lib9.h) world never share a translation unit.
 */
extern uchar*	stbwrap_decode(const uchar *data, int len, int *w, int *h, const char **err);
extern uchar*	stbwrap_encode_png(const uchar *rgba, int w, int h, int *outlen, const char **err);
extern void	stbwrap_free(void *p);

void
imageiomodinit(void)
{
	builtinmod("$Imageio", Imageiomodtab, Imageiomodlen);
}

void
Imageio_decode(void *fp)
{
	F_Imageio_decode *f = fp;
	uchar *pix;
	const char *err;
	int w, h, n;
	Heap *hp;
	Array *a;

	/* default return: (0, 0, nil, nil) */
	f->ret->t0 = 0;
	f->ret->t1 = 0;
	f->ret->t2 = H;
	f->ret->t3 = H;

	if(f->data == H){
		f->ret->t3 = c2string("no image data", 13);
		return;
	}

	err = nil;
	pix = stbwrap_decode(f->data->data, f->data->len, &w, &h, &err);
	if(pix == nil){
		if(err == nil)
			err = "image decode failed";
		f->ret->t3 = c2string((char*)err, strlen((char*)err));
		return;
	}

	n = w * h * 4;
	hp = heaparray(&Tbyte, n);
	if(hp == H){
		stbwrap_free(pix);
		f->ret->t3 = c2string(exNomem, strlen(exNomem));
		return;
	}
	a = H2D(Array*, hp);
	memmove(a->data, pix, n);
	stbwrap_free(pix);

	f->ret->t0 = w;
	f->ret->t1 = h;
	f->ret->t2 = a;
}

void
Imageio_encode(void *fp)
{
	F_Imageio_encode *f = fp;
	uchar *png;
	const char *err;
	int w, h, need, outlen;
	Heap *hp;
	Array *a;

	/* default return: (nil, nil) */
	f->ret->t0 = H;
	f->ret->t1 = H;

	w = f->w;
	h = f->h;
	if(f->rgba == H){
		f->ret->t1 = c2string("no pixel data", 13);
		return;
	}
	need = w * h * 4;
	if(w <= 0 || h <= 0 || f->rgba->len < need){
		f->ret->t1 = c2string("bad image dimensions", 20);
		return;
	}

	err = nil;
	png = stbwrap_encode_png(f->rgba->data, w, h, &outlen, &err);
	if(png == nil){
		if(err == nil)
			err = "png encode failed";
		f->ret->t1 = c2string((char*)err, strlen((char*)err));
		return;
	}

	hp = heaparray(&Tbyte, outlen);
	if(hp == H){
		stbwrap_free(png);
		f->ret->t1 = c2string(exNomem, strlen(exNomem));
		return;
	}
	a = H2D(Array*, hp);
	memmove(a->data, png, outlen);
	stbwrap_free(png);

	f->ret->t0 = a;
}
