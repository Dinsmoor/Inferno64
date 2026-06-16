/*
 * This is a separate file because image.h cannot be
 * included in many of the graphics drivers due to
 * name conflicts
 */

typedef struct Drawcursor Drawcursor;
struct Drawcursor
{
	int	hotx;
	int	hoty;
	int	minx;
	int	miny;
	int	maxx;
	int	maxy;
	uchar*	data;
};

void	drawcursor(Drawcursor*);

/*
 * Rich cursor: a full-colour, optionally animated cursor, as opposed to the
 * legacy 1-bit two-plane Drawcursor above.  Userspace writes a magic-tagged
 * blob to the cursor file; the device parses it into a Richcursor and hands
 * it to richcursor() (a nil pointer, or nframe==0, reverts to the default).
 *
 * Wire format on the cursor file (plain big-endian 32-bit words; note this
 * is NOT the draw protocol's mixed-endian BGLONG), distinguished from the
 * legacy blob by the leading magic (a legacy hotx can never be ~1.1e9 px):
 *
 *	magic[4]    "Acur" (Crmagic)
 *	version[4]  Crversion
 *	hotx[4] hoty[4]
 *	w[4] h[4]                          size in pixels
 *	nframe[4]                          >= 1
 *	repeat nframe times:
 *		delay[4]                   per-frame hold, milliseconds
 *		argb[w*h*4]                ARGB8888, straight alpha, row-major,
 *		                           top-down; one byte each A,R,G,B
 */
enum {
	Crmagic		= 0x41637572,	/* "Acur" */
	Crversion	= 1,
	Crmaxdim	= 64,		/* cap on w and h (pixels) */
	Crmaxframe	= 64,		/* cap on frame count */
};

typedef struct Richcursor Richcursor;
struct Richcursor
{
	int	hotx;
	int	hoty;
	int	w;
	int	h;
	int	nframe;
	int*	delay;		/* nframe entries, milliseconds */
	uchar*	argb;		/* nframe*w*h*4 bytes, ARGB8888 straight alpha */
};

void	richcursor(Richcursor*);
