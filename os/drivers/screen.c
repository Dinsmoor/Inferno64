#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>

/*
 * Screen glue between devdraw and the framebuffer.
 *
 * gscreen is a Memimage (XRGB32: b,g,r,x byte order, matching DRM
 * XRGB8888) that devdraw and the kernel text console draw into.  Its
 * pixels are a private backing buffer, NOT the scanout framebuffer:
 * flushmemscreen blits the changed rectangle from the backing buffer to
 * the scanout (ramfb / virtio-gpu) and then composites the software mouse
 * cursor on top.  Keeping the cursor out of the backing buffer is what
 * lets it ride above application drawing without the application ever
 * seeing it or a ghost being left behind when it moves.
 *
 * The cursor is generic: any target whose pointer delivers relative
 * motion (PS/2, virtio-mouse) has no host cursor, so we draw one.  A
 * target with an absolute pointer (the virtio tablet) gets a host cursor
 * from qemu; that driver sets hostcursor=1 and we skip the overlay (we
 * still blit, since devdraw always draws into the backing buffer).
 */

Memimage *gscreen;
int	hostcursor;		/* absolute-pointer driver sets 1: no sw cursor */

static Memdata fbdata;		/* the backing buffer behind gscreen */
static uchar *scanout;		/* the actual scanned-out framebuffer */
static int fbw, fbh;		/* scanout size, pixels */
static Memimage *conscol;
static Memimage *back;
static Memsubfont *memdefont;
static Lock screenlock;		/* serialises console state, blits, cursor */
static Point curpos;
static Rectangle window;
static Rectangle cdirty;	/* console area touched since the last blit */

static void fbscreenputs(char*, int);
static void blit(Rectangle);

/* ---- software cursor ---- */

enum {
	Curswid	= 16,		/* max software-cursor size, pixels */
	Curshgt	= 16,
};

static struct {
	int	ena;		/* pointer open: show the cursor */
	int	x, y;		/* hot-point position (screen coords) */
	int	hotx, hoty;
	int	w, h;		/* current cursor size */
	uchar	clr[Curswid/8 * Curshgt];
	uchar	set[Curswid/8 * Curshgt];
} swc;

/* default arrow, used until (and whenever) an app clears its cursor */
static uchar arrowclr[Curswid/8 * Curshgt] = {
	0xFF, 0xFF, 0x80, 0x01, 0x80, 0x02, 0x80, 0x0C,
	0x80, 0x10, 0x80, 0x10, 0x80, 0x08, 0x80, 0x04,
	0x80, 0x02, 0x80, 0x01, 0x80, 0x02, 0x8C, 0x04,
	0x92, 0x08, 0x91, 0x10, 0xA0, 0xA0, 0xC0, 0x40,
};
static uchar arrowset[Curswid/8 * Curshgt] = {
	0x00, 0x00, 0x7F, 0xFE, 0x7F, 0xFC, 0x7F, 0xF0,
	0x7F, 0xE0, 0x7F, 0xE0, 0x7F, 0xF0, 0x7F, 0xF8,
	0x7F, 0xFC, 0x7F, 0xFE, 0x7F, 0xFC, 0x73, 0xF8,
	0x61, 0xF0, 0x60, 0xE0, 0x40, 0x40, 0x00, 0x00,
};

static Rectangle
cursorrect(void)
{
	Rectangle r;

	r.min.x = swc.x - swc.hotx;
	r.min.y = swc.y - swc.hoty;
	r.max.x = r.min.x + swc.w;
	r.max.y = r.min.y + swc.h;
	return r;
}

/*
 * Copy gscreen's backing buffer to the scanout for rect r, then composite
 * the cursor wherever it overlaps r.  Caller holds screenlock.
 */
static void
blit(Rectangle r)
{
	u32int *src, *dst, *drow;
	int y, x, bpl, bx, by, bit, idx, ox, oy, cx0, cy0, cx1, cy1;

	if(gscreen == nil || scanout == nil)
		return;
	if(r.min.x < 0)
		r.min.x = 0;
	if(r.min.y < 0)
		r.min.y = 0;
	if(r.max.x > fbw)
		r.max.x = fbw;
	if(r.max.y > fbh)
		r.max.y = fbh;
	if(r.min.x >= r.max.x || r.min.y >= r.max.y)
		return;

	src = (u32int*)fbdata.bdata;
	dst = (u32int*)scanout;
	for(y = r.min.y; y < r.max.y; y++)
		memmove(dst + y*fbw + r.min.x, src + y*fbw + r.min.x,
			(r.max.x - r.min.x)*sizeof(u32int));

	if(hostcursor || !swc.ena || swc.w == 0)
		return;
	ox = swc.x - swc.hotx;
	oy = swc.y - swc.hoty;
	cx0 = ox < r.min.x ? r.min.x : ox;
	cy0 = oy < r.min.y ? r.min.y : oy;
	cx1 = ox+swc.w > r.max.x ? r.max.x : ox+swc.w;
	cy1 = oy+swc.h > r.max.y ? r.max.y : oy+swc.h;
	if(cx0 >= cx1 || cy0 >= cy1)
		return;
	bpl = swc.w/8;
	for(y = cy0; y < cy1; y++){
		drow = dst + y*fbw;
		by = y - oy;
		for(x = cx0; x < cx1; x++){
			bx = x - ox;
			idx = by*bpl + (bx>>3);
			bit = 0x80 >> (bx&7);
			if(swc.set[idx] & bit)
				drow[x] = 0x000000;		/* black body */
			else if(swc.clr[idx] & bit)
				drow[x] = 0xFFFFFF;		/* white outline */
		}
	}
}

void
screeninit(void)
{
	uchar *fb;
	int w, h;

	fb = vgpuinit(&w, &h);		/* -device virtio-gpu-device */
	if(fb == nil)
		fb = ramfbinit(&w, &h);	/* else -device ramfb */
	if(fb == nil)
		return;

	scanout = fb;
	fbw = w;
	fbh = h;

	memimageinit();
	fbdata.bdata = xspanalloc(w*h*sizeof(u32int), BY2PG, 0);
	if(fbdata.bdata == nil){
		print("screeninit: no memory for backing buffer\n");
		return;
	}
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

	/* default arrow, centred; shown once the pointer is opened */
	memmove(swc.clr, arrowclr, sizeof swc.clr);
	memmove(swc.set, arrowset, sizeof swc.set);
	swc.w = Curswid;
	swc.h = Curshgt;
	swc.x = w/2;
	swc.y = h/2;

	screenputs = fbscreenputs;	/* console output mirrors to the screen */
	blit(gscreen->r);		/* push the initial frame to the scanout */
}

void
screensize(int *w, int *h)
{
	if(gscreen == nil){
		*w = 1024;
		*h = 768;
		return;
	}
	*w = Dx(gscreen->r);
	*h = Dy(gscreen->r);
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
	*softscreen = 1;		/* devdraw draws into the backing buffer */
	return fbdata.bdata;
}

void
detachscreen(void)
{
}

void
flushmemscreen(Rectangle r)
{
	lock(&screenlock);
	blit(r);
	unlock(&screenlock);
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

/* ---- cursor entry points (called from devpointer) ---- */

void
cursorenable(void)
{
	lock(&screenlock);
	swc.ena = 1;
	blit(cursorrect());
	unlock(&screenlock);
}

void
cursordisable(void)
{
	lock(&screenlock);
	swc.ena = 0;
	blit(cursorrect());
	unlock(&screenlock);
}

/* the pointer moved (called from mousetrack, possibly at interrupt time) */
void
cursorupdate(int x, int y)
{
	Rectangle old;

	if(gscreen == nil || hostcursor)
		return;
	if(!canlock(&screenlock))
		return;		/* busy: the next motion event will catch up */
	old = cursorrect();
	swc.x = x;
	swc.y = y;
	blit(old);		/* erase the cursor at its old position */
	blit(cursorrect());	/* draw it at the new one */
	unlock(&screenlock);
}

/*
 * Load a new cursor image (from a /dev/cursor write).  The draw cursor
 * format is a clr (outline) bitmap followed by a set (body) bitmap, each
 * (maxx/8 * maxy/2) bytes, 1 bit/pixel, MSB first.  A nil image reverts
 * to the default arrow.
 */
void
drawcursor(Drawcursor *c)
{
	uchar *clrsrc, *setsrc;
	Rectangle old;
	int i, h, fh, sbpl, dbpl;

	lock(&screenlock);
	old = cursorrect();
	if(c == nil || c->data == nil){
		memmove(swc.clr, arrowclr, sizeof swc.clr);
		memmove(swc.set, arrowset, sizeof swc.set);
		swc.w = Curswid;
		swc.h = Curshgt;
		swc.hotx = swc.hoty = 0;
	}else{
		sbpl = (c->maxx - c->minx)/8;
		fh = (c->maxy - c->miny)/2;
		h = fh > Curshgt ? Curshgt : fh;
		dbpl = sbpl > Curswid/8 ? Curswid/8 : sbpl;
		clrsrc = c->data;
		setsrc = c->data + sbpl*fh;
		memset(swc.clr, 0, sizeof swc.clr);
		memset(swc.set, 0, sizeof swc.set);
		for(i = 0; i < h; i++){
			memmove(swc.clr + i*dbpl, clrsrc + i*sbpl, dbpl);
			memmove(swc.set + i*dbpl, setsrc + i*sbpl, dbpl);
		}
		swc.w = dbpl*8;
		swc.h = h;
		swc.hotx = c->hotx;
		swc.hoty = c->hoty;
	}
	blit(old);		/* erase the old shape */
	blit(cursorrect());	/* draw the new one */
	unlock(&screenlock);
}

/*
 * kernel console rendered with the built-in subfont.
 * Called from putstrn0 and (via echo) at interrupt time, hence canlock:
 * dropping a line beats deadlocking against an interrupted holder.
 */

static void
condirty(Rectangle r)
{
	if(cdirty.min.x >= cdirty.max.x)
		cdirty = r;
	else
		combinerect(&cdirty, r);
}

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
	condirty(window);
}

static void
screenputc(char *buf)
{
	Point p;
	int w, pos;
	Rectangle r;
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
		r = Rect(*xp, curpos.y, curpos.x, curpos.y+memdefont->height);
		memimagedraw(gscreen, r, back, ZP, nil, ZP, S);
		condirty(r);
		curpos.x = *xp;
		break;
	default:
		p = memsubfontwidth(memdefont, buf);
		w = p.x;
		if(curpos.x >= window.max.x-w)
			screenputc("\n");
		*xp++ = curpos.x;
		pos = curpos.x;
		memimagestring(gscreen, curpos, conscol, ZP, memdefont, buf);
		curpos.x += w;
		condirty(Rect(pos, curpos.y, curpos.x, curpos.y+memdefont->height));
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
	cdirty = Rect(0, 0, 0, 0);
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
	blit(cdirty);		/* push the touched console region + cursor */
	unlock(&screenlock);
}
