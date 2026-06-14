/*
 * webpwrap.c -- Inferno glue for the vendored single-file WebP decoder
 * (libwebp/webpdec.h: libwebp 1.6.0 decode + demux path, amalgamated,
 * BSD-style license; see libwebp/COPYING and libwebp/PATENTS).
 *
 * This is the ONLY translation unit that pulls in the WebP *implementation*.
 * Like stbwrap.c / the libmbedtls vendoring, it is plain ISO C and must NOT
 * include Inferno's lib9.h -- it sees only libc and webpdec.h.  The Inferno
 * side (libinterp/imageio.c) declares the handful of webpwrap_* prototypes
 * itself, so the two header worlds never mix.
 *
 * The decoder is built fully portable: no SIMD, no threads, no host file I/O
 * (see webpdec.h -- HAVE_CONFIG_H forces libwebp's generic-C path).
 */

#include <stdlib.h>
#include <string.h>

#define WEBPDEC_IMPLEMENTATION
#include "webpdec.h"

/*
 * Hard ceilings on decoded geometry.  WebP comes from untrusted sources (the
 * charon browser, fedi images), so cap dimensions before we ever allocate:
 * a malicious 16383x16383 header would otherwise ask for ~1 GB.  16384 is
 * libwebp's own max per side; 64 Mpx (= 256 MB RGBA) is a sane area cap.
 */
#define WEBP_MAX_DIM	16384
#define WEBP_MAX_AREA	(64L * 1024 * 1024)

/* RIFF....WEBP container sniff; len/data may be untrusted. */
int
webpwrap_is_webp(const unsigned char *data, int len)
{
	if(data == 0 || len < 12)
		return 0;
	return data[0]=='R' && data[1]=='I' && data[2]=='F' && data[3]=='F'
	    && data[8]=='W' && data[9]=='E' && data[10]=='B' && data[11]=='P';
}

/*
 * Core decode.  Always decodes to 8-bit RGBA -- 4 channels, top-to-bottom,
 * byte order R,G,B,A per pixel (exactly a Draw ABGR32 image, ready to
 * writepixels with no reordering).  If maxw/maxh > 0 and the source is larger,
 * libwebp downscales *during* decode (preserving aspect), so we never allocate
 * the full-resolution buffer -- this matters because the result lands in the
 * Dis heap (~32 MB arena) and a big fedi photo would overflow it.
 *
 * The output buffer is plain malloc'd (external decode memory), so the single
 * webpwrap_free (= free) covers it; no libwebp allocator detail leaks out.
 * Returns NULL on failure with *err set to a static reason string.
 */
static unsigned char*
decode_common(const unsigned char *data, int len, int maxw, int maxh,
	int *w, int *h, const char **err)
{
	WebPDecoderConfig cfg;
	int sw, sh, dw, dh;
	long outsize;
	unsigned char *out;

	*w = 0;
	*h = 0;
	if(err != 0)
		*err = 0;
	if(data == 0 || len <= 0){
		if(err != 0)
			*err = "no image data";
		return 0;
	}
	if(!WebPInitDecoderConfig(&cfg)){
		if(err != 0)
			*err = "webp ABI mismatch";
		return 0;
	}
	if(WebPGetFeatures(data, len, &cfg.input) != VP8_STATUS_OK){
		if(err != 0)
			*err = "not a webp image";
		return 0;
	}
	sw = cfg.input.width;
	sh = cfg.input.height;
	if(sw <= 0 || sh <= 0 || sw > WEBP_MAX_DIM || sh > WEBP_MAX_DIM
	|| (long)sw * sh > WEBP_MAX_AREA){
		if(err != 0)
			*err = "webp dimensions out of range";
		return 0;
	}

	/* fit into maxw x maxh, preserving aspect; integer down-scale only */
	dw = sw;
	dh = sh;
	if(maxw > 0 && dw > maxw){
		dh = (int)((long)dh * maxw / dw);
		dw = maxw;
	}
	if(maxh > 0 && dh > maxh){
		dw = (int)((long)dw * maxh / dh);
		dh = maxh;
	}
	if(dw < 1)
		dw = 1;
	if(dh < 1)
		dh = 1;
	if(dw != sw || dh != sh){
		cfg.options.use_scaling = 1;
		cfg.options.scaled_width = dw;
		cfg.options.scaled_height = dh;
	}

	outsize = (long)dw * dh * 4;
	out = (unsigned char*)malloc(outsize);
	if(out == 0){
		if(err != 0)
			*err = "out of memory";
		return 0;
	}

	cfg.output.colorspace = MODE_RGBA;	/* R,G,B,A, top-to-bottom */
	cfg.output.is_external_memory = 1;
	cfg.output.u.RGBA.rgba = out;
	cfg.output.u.RGBA.stride = dw * 4;
	cfg.output.u.RGBA.size = outsize;

	if(WebPDecode(data, len, &cfg) != VP8_STATUS_OK){
		WebPFreeDecBuffer(&cfg.output);	/* frees internals, not our buffer */
		free(out);
		if(err != 0)
			*err = "webp decode failed";
		return 0;
	}
	WebPFreeDecBuffer(&cfg.output);		/* releases internal scratch only */

	*w = dw;
	*h = dh;
	return out;
}

unsigned char*
webpwrap_decode(const unsigned char *data, int len, int *w, int *h, const char **err)
{
	return decode_common(data, len, 0, 0, w, h, err);
}

unsigned char*
webpwrap_decode_fit(const unsigned char *data, int len, int maxw, int maxh,
	int *w, int *h, const char **err)
{
	return decode_common(data, len, maxw, maxh, w, h, err);
}

void
webpwrap_free(void *p)
{
	free(p);
}

/* aggregate frame-store ceiling (256 MB) and a hard frame-count cap */
#define WEBP_MAX_TOTAL		(256L * 1024 * 1024)
#define WEBP_MAX_FRAMES		4096

/*
 * Decode an animated (or static) WebP to N frames of 8-bit RGBA -- same
 * contract as stbwrap_decode_anim.  Returns a malloc'd nframes*w*h*4 buffer
 * (frame i at i*w*h*4, full-canvas composited, top-to-bottom R,G,B,A), *delays
 * a malloc'd nframes ms array, *loop the animation loop count (0 = forever).
 * Uses WebPAnimDecoder, which composites and yields full canvases; a static
 * webp comes back as a single frame.  Free the buffer and delays with
 * webpwrap_free.  Returns NULL on failure with *err set.
 */
unsigned char*
webpwrap_decode_anim(const unsigned char *data, int len, int *w, int *h,
	int *nframes, int **delays, int *loop, const char **err)
{
	WebPData wd;
	WebPAnimDecoder *dec;
	WebPAnimInfo info;
	WebPAnimDecoderOptions opt;
	unsigned char *out, *frame;
	int *del;
	long canvas, total;
	int i, n, prevts, ts;

	*w = 0;
	*h = 0;
	*nframes = 0;
	if(delays != 0)
		*delays = 0;
	if(loop != 0)
		*loop = 0;
	if(err != 0)
		*err = 0;
	if(data == 0 || len < 12){
		if(err != 0)
			*err = "no image data";
		return 0;
	}

	wd.bytes = data;
	wd.size = (size_t)len;

	if(!WebPAnimDecoderOptionsInit(&opt)){
		if(err != 0)
			*err = "webp ABI mismatch";
		return 0;
	}
	opt.color_mode = MODE_RGBA;	/* non-premultiplied R,G,B,A */
	opt.use_threads = 0;

	dec = WebPAnimDecoderNew(&wd, &opt);
	if(dec == 0){
		if(err != 0)
			*err = "not a webp animation";
		return 0;
	}
	if(!WebPAnimDecoderGetInfo(dec, &info)){
		WebPAnimDecoderDelete(dec);
		if(err != 0)
			*err = "webp anim info failed";
		return 0;
	}

	*w = (int)info.canvas_width;
	*h = (int)info.canvas_height;
	n = (int)info.frame_count;
	if(*w <= 0 || *h <= 0 || *w > WEBP_MAX_DIM || *h > WEBP_MAX_DIM
	|| (long)*w * *h > WEBP_MAX_AREA){
		WebPAnimDecoderDelete(dec);
		*w = 0;
		*h = 0;
		if(err != 0)
			*err = "webp dimensions out of range";
		return 0;
	}
	if(n <= 0 || n > WEBP_MAX_FRAMES){
		WebPAnimDecoderDelete(dec);
		*w = 0;
		*h = 0;
		if(err != 0)
			*err = "webp frame count out of range";
		return 0;
	}
	canvas = (long)*w * *h * 4;
	total = canvas * n;
	if(total > WEBP_MAX_TOTAL){
		WebPAnimDecoderDelete(dec);
		*w = 0;
		*h = 0;
		if(err != 0)
			*err = "webp animation too large";
		return 0;
	}

	out = (unsigned char*)malloc(total);
	del = (int*)malloc(sizeof(int) * n);
	if(out == 0 || del == 0){
		free(out);
		free(del);
		WebPAnimDecoderDelete(dec);
		*w = 0;
		*h = 0;
		if(err != 0)
			*err = "out of memory";
		return 0;
	}

	i = 0;
	prevts = 0;
	while(i < n && WebPAnimDecoderHasMoreFrames(dec)){
		if(!WebPAnimDecoderGetNext(dec, &frame, &ts)){
			free(out);
			free(del);
			WebPAnimDecoderDelete(dec);
			*w = 0;
			*h = 0;
			if(err != 0)
				*err = "webp frame decode failed";
			return 0;
		}
		/* frame is owned by dec (valid until next call); copy it out */
		memcpy(out + (long)i * canvas, frame, canvas);
		del[i] = ts - prevts;	/* ts is the cumulative end time in ms */
		if(del[i] < 0)
			del[i] = 0;
		prevts = ts;
		i++;
	}
	WebPAnimDecoderDelete(dec);

	if(i == 0){
		free(out);
		free(del);
		*w = 0;
		*h = 0;
		if(err != 0)
			*err = "webp has no frames";
		return 0;
	}
	*nframes = i;
	if(delays != 0)
		*delays = del;
	else
		free(del);
	if(loop != 0)
		*loop = (int)info.loop_count;
	return out;
}
