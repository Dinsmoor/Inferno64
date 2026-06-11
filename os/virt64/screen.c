#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "../port/error.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>

/*
 * Screen glue between devdraw and the ramfb framebuffer.
 *
 * gscreen is a Memimage whose pixels ARE the framebuffer (XRGB32:
 * b,g,r,x byte order, matching ramfb's DRM XRGB8888), so devdraw and
 * the kernel text console draw straight into scanout memory and
 * flushmemscreen is a no-op — qemu rescans the buffer every refresh.
 */

Memimage *gscreen;

static Memdata fbdata;
static Memimage *conscol;
static Memimage *back;
static Memsubfont *memdefont;
static Lock screenlock;
static Point curpos;
static Rectangle window;

static void fbscreenputs(char*, int);

void
screeninit(void)
{
	uchar *fb;
	int w, h;

	fb = ramfbinit(&w, &h);
	if(fb == nil)
		return;

	memimageinit();
	fbdata.bdata = fb;
	fbdata.ref = 1;
	gscreen = allocmemimaged(Rect(0, 0, w, h), XRGB32, &fbdata);
	if(gscreen == nil){
		print("screeninit: allocmemimaged failed\n");
		return;
	}
	gscreen->clipr = gscreen->r;

	memdefont = getmemdefont();
	back = memwhite;
	conscol = memblack;

	memimagedraw(gscreen, gscreen->r, back, ZP, memopaque, ZP, S);
	window = insetrect(gscreen->r, 8);
	curpos = window.min;

	screenputs = fbscreenputs;	/* console output mirrors to the framebuffer */
}

uchar*
attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen)
{
	if(gscreen == nil)
		return nil;
	*r = gscreen->r;
	*chan = gscreen->chan;
	*d = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 0;
	return fbdata.bdata;
}

void
detachscreen(void)
{
}

void
flushmemscreen(Rectangle r)
{
	USED(r);	/* ramfb scans guest RAM; nothing to do */
}

void
getcolor(ulong p, ulong *pr, ulong *pg, ulong *pb)
{
	USED(p);
	*pr = *pg = *pb = 0;
}

int
setcolor(ulong p, ulong r, ulong g, ulong b)
{
	USED(p); USED(r); USED(g); USED(b);
	return 0;	/* no colormap at 32bpp */
}

void
blankscreen(int blank)
{
	USED(blank);
}

void
cursorenable(void)
{
}

void
cursordisable(void)
{
}

void
drawcursor(Drawcursor *c)
{
	USED(c);	/* qemu shows the host cursor */
}

/*
 * kernel console rendered with the built-in subfont.
 * Called from putstrn0 and (via echo) at interrupt time, hence canlock:
 * dropping a line beats deadlocking against an interrupted holder.
 */

static void
scroll(void)
{
	int o;
	Point p;
	Rectangle r;

	o = 8*memdefont->height;
	r = Rpt(window.min, Pt(window.max.x, window.max.y-o));
	p = Pt(window.min.x, window.min.y+o);
	memimagedraw(gscreen, r, gscreen, p, nil, p, S);
	r = Rpt(Pt(window.min.x, window.max.y-o), window.max);
	memimagedraw(gscreen, r, back, ZP, nil, ZP, S);
	curpos.y -= o;
}

static void
screenputc(char *buf)
{
	Point p;
	int w;
	static int *xp;
	static int xbuf[256];

	if(xp < xbuf || xp >= &xbuf[nelem(xbuf)])
		xp = xbuf;

	switch(buf[0]){
	case '\n':
		if(curpos.y+memdefont->height >= window.max.y)
			scroll();
		curpos.y += memdefont->height;
		/* fall through */
	case '\r':
		xp = xbuf;
		curpos.x = window.min.x;
		break;
	case '\t':
		p = memsubfontwidth(memdefont, " ");
		w = p.x;
		*xp++ = curpos.x;
		curpos.x += 8*w - (curpos.x-window.min.x)%(8*w);
		break;
	case '\b':
		if(xp <= xbuf)
			break;
		xp--;
		memimagedraw(gscreen, Rect(*xp, curpos.y, curpos.x, curpos.y+memdefont->height),
			back, ZP, nil, ZP, S);
		curpos.x = *xp;
		break;
	default:
		p = memsubfontwidth(memdefont, buf);
		w = p.x;
		if(curpos.x >= window.max.x-w)
			screenputc("\n");
		*xp++ = curpos.x;
		memimagestring(gscreen, curpos, conscol, ZP, memdefont, buf);
		curpos.x += w;
	}
}

static void
fbscreenputs(char *s, int n)
{
	int i;
	Rune r;
	char buf[4];

	if(!canlock(&screenlock))
		return;
	while(n > 0){
		i = chartorune(&r, s);
		if(i == 0){
			s++;
			--n;
			continue;
		}
		memmove(buf, s, i);
		buf[i] = 0;
		n -= i;
		s += i;
		screenputc(buf);
	}
	unlock(&screenlock);
}
