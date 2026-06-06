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
 * Currently wired: image decode (stb_image).  The rest of stb is vendored and
 * available -- activate another module by adding its *_IMPLEMENTATION define
 * and a wrapper here.
 */

#include <stdlib.h>
#include <string.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO		/* feed bytes from memory; no host file IO */
#define STBI_FAILURE_USERMSG	/* human-readable stbi_failure_reason() */
#include "stb/stb_image.h"

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

void
stbwrap_free(void *p)
{
	stbi_image_free(p);
}
