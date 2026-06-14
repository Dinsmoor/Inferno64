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
extern uchar*	stbwrap_decode_fit(const uchar *data, int len, int maxw, int maxh, int *w, int *h, const char **err);
extern uchar*	stbwrap_encode_png(const uchar *rgba, int w, int h, int *outlen, const char **err);
extern void	stbwrap_free(void *p);

/*
 * WebP is not handled by stb; it lives in the separate libwebp vendoring
 * (webpwrap.c wrapping the amalgamated libwebp decoder).  We sniff the RIFF
 * container here and route accordingly.  Both decoders honour the same
 * contract -- malloc'd 8-bit RGBA, top-to-bottom, R,G,B,A -- but each frees its
 * own buffers, so the chosen decoder's *_free must match its *_decode.
 */
extern int	webpwrap_is_webp(const uchar *data, int len);
extern uchar*	webpwrap_decode(const uchar *data, int len, int *w, int *h, const char **err);
extern uchar*	webpwrap_decode_fit(const uchar *data, int len, int maxw, int maxh, int *w, int *h, const char **err);
extern void	webpwrap_free(void *p);

/*
 * Animated decode (GIF via stb, animated WebP via libwebp's WebPAnimDecoder;
 * any other format comes back as a single frame).  Both return the frames as
 * one malloc'd, contiguous, full-canvas RGBA buffer (frame i at i*w*h*4) plus a
 * malloc'd per-frame delays array in ms; *loop is the animation loop count
 * (0 = forever).  Same R,G,B,A == Draw ABGR32 contract as the still decoders.
 */
extern uchar*	stbwrap_decode_anim(const uchar *data, int len, int *w, int *h, int *nframes, int **delays, int *loop, const char **err);
extern uchar*	webpwrap_decode_anim(const uchar *data, int len, int *w, int *h, int *nframes, int **delays, int *loop, const char **err);

/*
 * An open animation.  The Limbo-visible part (Imageio_Anim: w,h,nframes,loop --
 * all ints, so the GC map is empty) sits at the front; the frame store and the
 * per-frame delays hang off the back in C memory, kept out of the small Dis
 * heap.  frame() copies one frame into the Dis heap on demand; freeanim (the
 * dtype finalizer) and close() release the C buffers.  iswebp selects the
 * matching *_free so the allocator that produced a buffer also frees it.
 */
typedef struct Anim Anim;
struct Anim {
	Imageio_Anim	x;	/* limbo-visible part */
	uchar*		pix;	/* nframes * w*h*4 RGBA bytes (C memory) */
	int*		delays;	/* nframes ms values (C memory) */
	int		iswebp;	/* picks stbwrap_free vs webpwrap_free */
};

Type*	TAnim;
static uchar	Animmap[] = Imageio_Anim_map;

static void	freeanim(Heap*, int);
static Anim*	ckanim(Imageio_Anim*);

static void
animfree(Anim *a)
{
	if(a->iswebp){
		if(a->pix != nil)
			webpwrap_free(a->pix);
		if(a->delays != nil)
			webpwrap_free(a->delays);
	}else{
		if(a->pix != nil)
			stbwrap_free(a->pix);
		if(a->delays != nil)
			stbwrap_free(a->delays);
	}
	a->pix = nil;
	a->delays = nil;
}

/*
 * dtype finalizer.  The Limbo part holds no Dis references, so there is nothing
 * to freeptrs; the C frame store, however, must be released whether the heap is
 * being swept or refcount-collected, since it lives outside the Dis heap.
 */
static void
freeanim(Heap *h, int swept)
{
	Anim *a = H2D(Anim*, h);

	USED(swept);
	animfree(a);
}

static Anim*
ckanim(Imageio_Anim *la)
{
	if(la == nil || la == H)
		error("nil Anim");
	if(D2H(la)->t != TAnim)
		error(exType);
	return (Anim*)la;
}

void
imageiomodinit(void)
{
	builtinmod("$Imageio", Imageiomodtab, Imageiomodlen);
	TAnim = dtype(freeanim, sizeof(Anim), Animmap, sizeof(Animmap));
}

void
Imageio_decode(void *fp)
{
	F_Imageio_decode *f = fp;
	uchar *pix;
	const char *err;
	int w, h, n, iswebp;
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
	iswebp = webpwrap_is_webp(f->data->data, f->data->len);
	if(iswebp)
		pix = webpwrap_decode(f->data->data, f->data->len, &w, &h, &err);
	else
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
		if(iswebp) webpwrap_free(pix); else stbwrap_free(pix);
		f->ret->t3 = c2string(exNomem, strlen(exNomem));
		return;
	}
	a = H2D(Array*, hp);
	memmove(a->data, pix, n);
	if(iswebp) webpwrap_free(pix); else stbwrap_free(pix);

	f->ret->t0 = w;
	f->ret->t1 = h;
	f->ret->t2 = a;
}

void
Imageio_decodefit(void *fp)
{
	F_Imageio_decodefit *f = fp;
	uchar *pix;
	const char *err;
	int w, h, n, iswebp;
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
	iswebp = webpwrap_is_webp(f->data->data, f->data->len);
	if(iswebp)
		pix = webpwrap_decode_fit(f->data->data, f->data->len, f->maxw, f->maxh, &w, &h, &err);
	else
		pix = stbwrap_decode_fit(f->data->data, f->data->len, f->maxw, f->maxh, &w, &h, &err);
	if(pix == nil){
		if(err == nil)
			err = "image decode failed";
		f->ret->t3 = c2string((char*)err, strlen((char*)err));
		return;
	}

	n = w * h * 4;
	hp = heaparray(&Tbyte, n);
	if(hp == H){
		if(iswebp) webpwrap_free(pix); else stbwrap_free(pix);
		f->ret->t3 = c2string(exNomem, strlen(exNomem));
		return;
	}
	a = H2D(Array*, hp);
	memmove(a->data, pix, n);
	if(iswebp) webpwrap_free(pix); else stbwrap_free(pix);

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

void
Imageio_animopen(void *fp)
{
	F_Imageio_animopen *f = fp;
	Heap *h;
	Anim *a;
	uchar *pix;
	int *delays;
	int w, ht, nframes, loop, iswebp;
	const char *err;

	/* default return: (nil, nil) */
	f->ret->t0 = H;
	f->ret->t1 = H;

	if(f->data == H){
		f->ret->t1 = c2string("no image data", 13);
		return;
	}

	err = nil;
	delays = nil;
	nframes = 0;
	loop = 0;
	iswebp = webpwrap_is_webp(f->data->data, f->data->len);
	if(iswebp)
		pix = webpwrap_decode_anim(f->data->data, f->data->len, &w, &ht, &nframes, &delays, &loop, &err);
	else
		pix = stbwrap_decode_anim(f->data->data, f->data->len, &w, &ht, &nframes, &delays, &loop, &err);
	if(pix == nil){
		if(err == nil)
			err = "image decode failed";
		f->ret->t1 = c2string((char*)err, strlen((char*)err));
		return;
	}

	h = heapz(TAnim);
	if(h == H){
		if(iswebp){
			webpwrap_free(pix);
			if(delays != nil)
				webpwrap_free(delays);
		}else{
			stbwrap_free(pix);
			if(delays != nil)
				stbwrap_free(delays);
		}
		f->ret->t1 = c2string(exNomem, strlen(exNomem));
		return;
	}
	a = H2D(Anim*, h);
	a->x.w = w;
	a->x.h = ht;
	a->x.nframes = nframes;
	a->x.loop = loop;
	a->pix = pix;
	a->delays = delays;
	a->iswebp = iswebp;

	f->ret->t0 = (Imageio_Anim*)a;
}

void
Anim_frame(void *fp)
{
	F_Anim_frame *f = fp;
	Anim *a;
	Heap *hp;
	Array *arr;
	int i, n;

	/* default return: (0, nil, nil) */
	f->ret->t0 = 0;
	f->ret->t1 = H;
	f->ret->t2 = H;

	a = ckanim(f->a);
	i = f->i;
	if(a->pix == nil || i < 0 || i >= a->x.nframes){
		f->ret->t2 = c2string("frame index out of range", 24);
		return;
	}
	n = a->x.w * a->x.h * 4;
	hp = heaparray(&Tbyte, n);
	if(hp == H){
		f->ret->t2 = c2string(exNomem, strlen(exNomem));
		return;
	}
	arr = H2D(Array*, hp);
	memmove(arr->data, a->pix + (long)i * n, n);
	f->ret->t0 = a->delays != nil ? a->delays[i] : 0;
	f->ret->t1 = arr;
}

void
Anim_close(void *fp)
{
	F_Anim_close *f = fp;
	Anim *a;

	a = ckanim(f->a);
	animfree(a);
	a->x.nframes = 0;
}
