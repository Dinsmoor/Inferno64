/*
 * mouse or stylus
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#include <draw.h>
#include <memdraw.h>
#include <cursor.h>
#include "screen.h"

enum{
	Qdir,
	Qpointer,
	Qcursor,
};

typedef struct Pointer Pointer;

struct Pointer {
	int	x;
	int	y;
	int	b;
	ulong	msec;
};

static struct
{
	Pointer;
	int	modify;
	int	lastb;
	Rendez	r;
	Ref	ref;
	QLock	q;
} mouse;

static
Dirtab pointertab[]={
	".",			{Qdir, 0, QTDIR},	0,	0555,
	"pointer",		{Qpointer},	0,	0666,
	"cursor",		{Qcursor},		0,	0222,
};

enum {
	Nevent = 16	/* enough for some */
};

static struct {
	int	rd;
	int	wr;
	Pointer	clicks[Nevent];
	Rendez r;
	int	full;
	int	put;
	int	get;
} ptrq;

/*
 * called by any source of pointer data
 */
void
mousetrack(int b, int x, int y, int isdelta)
{
	int lastb;
	ulong msec;
	Pointer e;

	if(isdelta){
		x += mouse.x;
		y += mouse.y;
	}
	/*
	 * clamp to the screen.  a relative pointer (PS/2, virtio-mouse)
	 * integrates deltas, so without this a bogus delta — e.g. the byte
	 * desync qemu produces when a GTK menu steals the pointer grab —
	 * walks the position off-screen for good: the software cursor is
	 * erased at its old spot and redrawn into an empty off-screen rect,
	 * and never comes back.  Absolute pointers are already in range.
	 */
	{
		int sw, sh;

		screensize(&sw, &sh);
		if(sw > 0 && sh > 0){
			if(x < 0)
				x = 0;
			else if(x >= sw)
				x = sw - 1;
			if(y < 0)
				y = 0;
			else if(y >= sh)
				y = sh - 1;
		}
	}
	msec = TK2MS(MACHP(0)->ticks);
	if(b && (mouse.b ^ b)&0x1f){
		if(msec - mouse.msec < 300 && mouse.lastb == b
		   && abs(mouse.x - x) < 12 && abs(mouse.y - y) < 12)
			b |= 1<<8;
		mouse.lastb = b & 0x1f;
		mouse.msec = msec;
	}
	if(x == mouse.x && y == mouse.y && mouse.b == b)
		return;
	lastb = mouse.b;
	mouse.x = x;
	mouse.y = y;
	mouse.b = b;
	mouse.msec = msec;
	if(!ptrq.full && lastb != b){
		e = mouse.Pointer;
		ptrq.clicks[ptrq.wr] = e;
		if(++ptrq.wr >= Nevent)
			ptrq.wr = 0;
		if(ptrq.wr == ptrq.rd)
			ptrq.full = 1;
	}
	mouse.modify = 1;
	ptrq.put++;
	wakeup(&ptrq.r);
	drawactive(1);
	cursorupdate(mouse.x, mouse.y);
}

static int
ptrqnotempty(void*)
{
	return ptrq.full || ptrq.put != ptrq.get;
}

static Pointer
mouseconsume(void)
{
	Pointer e;

	sleep(&ptrq.r, ptrqnotempty, 0);
	ptrq.full = 0;
	ptrq.get = ptrq.put;
	if(ptrq.rd != ptrq.wr){
		e = ptrq.clicks[ptrq.rd];
		if(++ptrq.rd >= Nevent)
			ptrq.rd = 0;
	}else
		e = mouse.Pointer;
	return e;
}

Point
mousexy(void)
{
	return Pt(mouse.x, mouse.y);
}


static Chan*
pointerattach(char* spec)
{
	return devattach('m', spec);
}

static Walkqid*
pointerwalk(Chan *c, Chan *nc, char **name, int nname)
{
	Walkqid *wq;

	wq = devwalk(c, nc, name, nname, pointertab, nelem(pointertab), devgen);
	if(wq != nil && wq->clone != c && wq->clone != nil && (ulong)c->qid.path == Qpointer)
		incref(&mouse.ref);	/* can this happen? */
	return wq;
}

static int
pointerstat(Chan* c, uchar *db, int n)
{
	return devstat(c, db, n, pointertab, nelem(pointertab), devgen);
}

static Chan*
pointeropen(Chan* c, int omode)
{
	c = devopen(c, omode, pointertab, nelem(pointertab), devgen);
	if((ulong)c->qid.path == Qpointer){
		if(waserror()){
			c->flag &= ~COPEN;
			nexterror();
		}
		if(!canqlock(&mouse.q))
			error(Einuse);
		if(incref(&mouse.ref) != 1){
			qunlock(&mouse.q);
			error(Einuse);
		}
		cursorenable();
		qunlock(&mouse.q);
		poperror();
	}
	return c;
}

static void
pointerclose(Chan* c)
{
	if((c->flag & COPEN) == 0)
		return;
	switch((ulong)c->qid.path){
	case Qpointer:
		qlock(&mouse.q);
		if(decref(&mouse.ref) == 0)
			cursordisable();
		qunlock(&mouse.q);
		break;
	}
}

static long
pointerread(Chan* c, void* a, long n, vlong)
{
	Pointer mt;
	char tmp[128];
	int l;

	switch((ulong)c->qid.path){
	case Qdir:
		return devdirread(c, a, n, pointertab, nelem(pointertab), devgen);
	case Qpointer:
		qlock(&mouse.q);
		if(waserror()) {
			qunlock(&mouse.q);
			nexterror();
		}
		mt = mouseconsume();
		poperror();
		qunlock(&mouse.q);
		l = sprint(tmp, "m%11d %11d %11d %11lud ", mt.x, mt.y, mt.b, mt.msec);
		if(l < n)
			n = l;
		memmove(a, tmp, n);
		break;
	case Qcursor:
		/* TO DO: interpret data written as Image; give to drawcursor() */
		break;
	default:
		n=0;
		break;
	}
	return n;
}

/* plain big-endian 32-bit fetch (the rich cursor format; not draw's BGLONG) */
static int
becl(uchar *p)
{
	return (p[0]<<24) | (p[1]<<16) | (p[2]<<8) | p[3];
}

/*
 * Parse a magic-tagged rich (colour/animated) cursor blob and install it.
 * Format documented in include/cursor.h.  Validate fully before allocating,
 * de-interleave the per-frame (delay,argb) records into the contiguous arrays
 * richcursor() expects, install, then free: the backend copies synchronously.
 */
static void
writerichcursor(uchar *p, long n)
{
	Richcursor rc;
	int i, framebytes;
	long need;
	uchar *q;

	if(n < 7*4)
		error(Eshort);
	if(becl(p+1*4) != Crversion)
		error(Ebadarg);
	rc.hotx = becl(p+2*4);
	rc.hoty = becl(p+3*4);
	rc.w = becl(p+4*4);
	rc.h = becl(p+5*4);
	rc.nframe = becl(p+6*4);
	if(rc.w <= 0 || rc.w > Crmaxdim || rc.h <= 0 || rc.h > Crmaxdim)
		error(Ebadarg);
	if(rc.nframe <= 0 || rc.nframe > Crmaxframe)
		error(Ebadarg);
	framebytes = rc.w * rc.h * 4;
	need = 7*4 + (vlong)rc.nframe * (4 + framebytes);
	if(n != need)
		error(Ebadarg);

	rc.delay = malloc(rc.nframe * sizeof(int));
	rc.argb = malloc(rc.nframe * framebytes);
	if(rc.delay == nil || rc.argb == nil){
		free(rc.delay);
		free(rc.argb);
		error(Enomem);
	}
	q = p + 7*4;
	for(i = 0; i < rc.nframe; i++){
		rc.delay[i] = becl(q);
		q += 4;
		memmove(rc.argb + i*framebytes, q, framebytes);
		q += framebytes;
	}
	if(waserror()){
		free(rc.delay);
		free(rc.argb);
		nexterror();
	}
	richcursor(&rc);
	poperror();
	free(rc.delay);
	free(rc.argb);
}

static long
pointerwrite(Chan* c, void* va, long n, vlong)
{
	char *a = va;
	char buf[128];
	int b, x, y;
	Drawcursor cur;

	switch((ulong)c->qid.path){
	case Qpointer:
		if(n > sizeof buf-1)
			n = sizeof buf -1;
		memmove(buf, va, n);
		buf[n] = 0;
		x = strtoul(buf+1, &a, 0);
		if(*a == 0)
			error(Eshort);
		y = strtoul(a, &a, 0);
		if(*a != 0)
			b = strtoul(a, 0, 0);
		else
			b = mouse.b;
		mousetrack(b, x, y, 0);
		break;
	case Qcursor:
		/*
		 *  hotx[4] hoty[4] dx[4] dy[4] clr[dx/8 * dy/2] set[dx/8 * dy/2]
		 *  big-endian longs; dx a multiple of 8, dy a multiple of 2.
		 *  An empty write reverts to the default cursor.
		 */
		if(n == 0){
			cur.data = nil;
			drawcursor(&cur);
			break;
		}
		if(n >= 4 && becl((uchar*)va) == Crmagic){
			writerichcursor((uchar*)va, n);
			break;
		}
		if(n < 4*4)
			error(Eshort);
		cur.hotx = BGLONG((uchar*)va+0*4);
		cur.hoty = BGLONG((uchar*)va+1*4);
		cur.minx = 0;
		cur.miny = 0;
		cur.maxx = BGLONG((uchar*)va+2*4);
		cur.maxy = BGLONG((uchar*)va+3*4);
		if(cur.maxx%8 != 0 || cur.maxy%2 != 0 || n-4*4 != (cur.maxx/8 * cur.maxy))
			error(Ebadarg);
		cur.data = (uchar*)va + 4*4;
		drawcursor(&cur);
		break;
	default:
		error(Ebadusefd);
	}
	return n;
}

Dev pointerdevtab = {
	'm',
	"pointer",

	devreset,
	devinit,
	devshutdown,
	pointerattach,
	pointerwalk,
	pointerstat,
	pointeropen,
	devcreate,
	pointerclose,
	pointerread,
	devbread,
	pointerwrite,
	devbwrite,
	devremove,
	devwstat,
};
