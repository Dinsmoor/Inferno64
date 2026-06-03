/*
 * libmemdraw in-memory imaging (no display needed): channel descriptor
 * conversions and a memimage allocate / fill / read-back round-trip.
 */
#include "lib9.h"
#include "draw.h"
#include "memdraw.h"
#include "cunit.h"

static void
test_fill_readback(void)
{
	Memimage *m;
	uchar buf[4*4*4];
	int n, i;

	memimageinit();
	m = allocmemimage(Rect(0, 0, 4, 4), strtochan("r8g8b8a8"));
	CK(m != nil);
	if(m == nil) return;
	CKEQ(Dx(m->r), 4);
	CKEQ(Dy(m->r), 4);

	memfillcolor(m, 0x11223344);         /* uniform fill */
	n = unloadmemimage(m, m->r, buf, sizeof buf);
	CKEQ(n, 4*4*4);                      /* 16 px * 4 bytes */

	/* every pixel identical (4-byte stride) and non-zero */
	CK(buf[0] || buf[1] || buf[2] || buf[3]);
	for(i = 4; i < n; i++)
		if(buf[i] != buf[i % 4]) break;
	CKEQ(i, n);                          /* loop ran to completion: uniform */

	freememimage(m);
}

CUNIT_MAIN("libmemdraw/mem", test_fill_readback)
