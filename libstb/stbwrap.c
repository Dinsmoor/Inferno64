/*
 * stbwrap.c -- Inferno glue for the vendored stb single-header libraries
 * (libstb/stb/, public domain / MIT; see libstb/stb/LICENSE).
 *
 * This is the ONLY translation unit that pulls in the stb *_IMPLEMENTATION
 * blocks, behind a tiny, Inferno-free C API.  It is plain ISO C and must NOT
 * include Inferno's lib9.h -- like the libmbedtls vendoring, it sees only libc
 * and its own headers.  The Inferno side (libinterp/imageio.c) declares the
 * handful of stbwrap_* prototypes itself, so the two header worlds never mix.
 *
 * Currently wired: image decode (stb_image) and PNG encode (stb_image_write).
 * The rest of stb is vendored and available -- activate another module by
 * adding its *_IMPLEMENTATION define and a wrapper here.
 */

#include <stdlib.h>
#include <string.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO		/* feed bytes from memory; no host file IO */
#define STBI_FAILURE_USERMSG	/* human-readable stbi_failure_reason() */
#include "stb/stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO	/* encode to memory; no host file IO */
#include "stb/stb_image_write.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb/stb_image_resize2.h"

/*
 * Decode an in-memory image of any stb-supported format (PNG, JPEG, BMP, TGA,
 * GIF, PSD, HDR, PIC, PNM) to 8-bit RGBA: 4 channels, top-to-bottom, byte
 * order R,G,B,A per pixel -- i.e. exactly the pixel layout of a Draw ABGR32
 * image, ready to writepixels with no reordering.
 *
 * Returns a malloc'd buffer of *w * *h * 4 bytes, or NULL on failure (with
 * *err pointing at a static reason string).  Free it with stbwrap_free.
 */
unsigned char*
stbwrap_decode(const unsigned char *data, int len, int *w, int *h, const char **err)
{
	unsigned char *p;
	int comp;

	*w = 0;
	*h = 0;
	if(err != 0)
		*err = 0;
	if(data == 0 || len <= 0){
		if(err != 0)
			*err = "no image data";
		return 0;
	}
	p = stbi_load_from_memory(data, len, w, h, &comp, 4);	/* force RGBA */
	if(p == 0){
		*w = 0;
		*h = 0;
		if(err != 0)
			*err = stbi_failure_reason();
	}
	return p;
}

/*
 * Decode like stbwrap_decode, but cap the result to maxw x maxh: if the source
 * is larger, downscale it (preserving aspect) in C with stb_image_resize, so
 * the caller never has to allocate the full-resolution buffer.  This matters
 * because the decoded RGBA lands in the Dis heap, whose main arena is small
 * (~32 MB) -- a big fedi photo (e.g. 4000x3000 = 48 MB) overflows it.  Doing the
 * downscale here keeps the large buffer in C's malloc and returns only the
 * small image.  maxw/maxh <= 0 means "no cap".  *w,*h receive the RETURNED size.
 * Free the result with stbwrap_free.
 */
unsigned char*
stbwrap_decode_fit(const unsigned char *data, int len, int maxw, int maxh,
	int *w, int *h, const char **err)
{
	unsigned char *p, *q;
	int sw, sh, comp, dw, dh;
	double s, sv;

	*w = 0;
	*h = 0;
	if(err != 0)
		*err = 0;
	if(data == 0 || len <= 0){
		if(err != 0)
			*err = "no image data";
		return 0;
	}
	p = stbi_load_from_memory(data, len, &sw, &sh, &comp, 4);	/* force RGBA */
	if(p == 0){
		if(err != 0)
			*err = stbi_failure_reason();
		return 0;
	}
	if(maxw <= 0 || maxh <= 0 || (sw <= maxw && sh <= maxh)){
		*w = sw;
		*h = sh;
		return p;
	}
	s = (double)maxw / sw;
	sv = (double)maxh / sh;
	if(sv < s)
		s = sv;
	dw = (int)(sw * s);
	dh = (int)(sh * s);
	if(dw < 1)
		dw = 1;
	if(dh < 1)
		dh = 1;
	/* output NULL => stb allocates and returns the buffer (free with free) */
	q = stbir_resize_uint8_srgb(p, sw, sh, 0, 0, dw, dh, 0, STBIR_RGBA);
	stbi_image_free(p);
	if(q == 0){
		if(err != 0)
			*err = "image resize failed";
		return 0;
	}
	*w = dw;
	*h = dh;
	return q;
}

void
stbwrap_free(void *p)
{
	stbi_image_free(p);
}

/*
 * Growable byte buffer for the stb_image_write memory callback.  `failed` is
 * sticky so a mid-encode realloc failure can't make a later callback deref a
 * freed/NULL pointer (stb keeps calling the writer until the image is done).
 */
struct membuf {
	unsigned char	*p;
	int		len;
	int		cap;
	int		failed;
};

static void
memwrite(void *ctx, void *data, int size)
{
	struct membuf *m = ctx;
	unsigned char *np;
	int ncap;

	if(m->failed || size <= 0)
		return;
	if(m->len + size > m->cap){
		ncap = m->cap ? m->cap * 2 : 4096;
		while(ncap < m->len + size)
			ncap *= 2;
		np = realloc(m->p, ncap);
		if(np == 0){
			free(m->p);
			m->p = 0;
			m->failed = 1;
			return;
		}
		m->p = np;
		m->cap = ncap;
	}
	memcpy(m->p + m->len, data, size);
	m->len += size;
}

/*
 * Encode 8-bit RGBA pixels (w*h*4 bytes, R,G,B,A order, top-to-bottom -- the
 * layout stbwrap_decode produces and a Draw ABGR32 image holds) to an
 * in-memory PNG.  Returns a malloc'd buffer of *outlen bytes, or NULL on
 * failure (with *err pointing at a static reason string).  Free it with
 * stbwrap_free.
 */
unsigned char*
stbwrap_encode_png(const unsigned char *rgba, int w, int h, int *outlen, const char **err)
{
	struct membuf m;

	*outlen = 0;
	if(err != 0)
		*err = 0;
	if(rgba == 0 || w <= 0 || h <= 0){
		if(err != 0)
			*err = "no image data";
		return 0;
	}
	m.p = 0;
	m.len = 0;
	m.cap = 0;
	m.failed = 0;
	if(stbi_write_png_to_func(memwrite, &m, w, h, 4, rgba, w * 4) == 0 || m.failed || m.p == 0){
		free(m.p);
		if(err != 0)
			*err = "png encode failed";
		return 0;
	}
	*outlen = m.len;
	return m.p;
}
