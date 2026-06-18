#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "tk.h"
#include "ttk.h"

/*
 * ttk::panedwindow - a container that tiles its panes along one axis with a
 * draggable sash between each adjacent pair.  Like the notebook, the panes
 * are ordinary widgets handed over with `<pw> add <pane>' and managed by the
 * embedded-window / parent-link model (NOT pack/place): the panedwindow owns
 * pane geometry and draws them itself.  Unlike the notebook, every pane is
 * visible at once, side by side.
 *
 * The container infrastructure is shared in spirit with ttknb.c (parent-link,
 * the relpos/inwindow/dirtychild/geom TkMethod hooks, the tkimageof case).
 */

#define	O(t, e)		((long)(&((t*)0)->e))

enum
{
	Sashw		= 6,	/* sash thickness, px */
	Panemin		= 16,	/* minimum pane extent along the major axis */
	Pwinset		= 1	/* inset of the pane band within the border */
};

typedef struct Pane Pane;
typedef struct TkPaned TkPaned;

struct Pane
{
	Tk*	sub;		/* the embedded widget */
	int	weight;		/* -weight, for distributing extra space */
	int	size;		/* current extent along the major axis */
	int	off;		/* current offset along the major axis (set by layout) */
};

struct TkPaned
{
	ulong	state;		/* widget S* bits */
	char*	style;		/* explicit -style, or nil => TPanedwindow */
	int	orient;		/* Tkhorizontal / Tkvertical */
	int	npane;
	Pane*	panes;
	int	drag;		/* sash index being dragged, -1 if none */
	int	userpos;	/* a sash has been positioned: freeze sizes */
};

extern TkStab tkorient[];

/* ---- options ---- */

static TkOption ttkpwopts[] =
{
	"style",	OPTtext,	O(TkPaned, style),	nil,
	"orient",	OPTstab,	O(TkPaned, orient),	tkorient,
	nil
};

/* ---- bindings ---- */

static TkEbind ttkpwb[] =
{
	{TkButton1P,		"%W tkttkpwPress %x %y"},
	{TkButton1P|TkMotion,	"%W tkttkpwDrag %x %y"},
	{TkButton1R,		"%W tkttkpwRelease"},
};

/* ---- helpers ---- */

static char*
pwstylename(Tk *tk)
{
	TkPaned *pw = TKobj(TkPaned, tk);

	if(pw->style != nil && pw->style[0] != '\0')
		return pw->style;
	return "TPanedwindow";
}

static ulong
pwstate(Tk *tk)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	ulong st;

	st = pw->state;
	if(tk->flag & Tkdisabled)
		st |= Sdisabled;
	return st;
}

static int
ishoriz(Tk *tk)
{
	return TKobj(TkPaned, tk)->orient != Tkvertical;
}

/* major-axis extent of the content band (inside the border) */
static int
pwmajor(Tk *tk)
{
	if(ishoriz(tk))
		return tk->act.width - 2*Pwinset;
	return tk->act.height - 2*Pwinset;
}

/* minor-axis extent of the content band */
static int
pwminor(Tk *tk)
{
	if(ishoriz(tk))
		return tk->act.height - 2*Pwinset;
	return tk->act.width - 2*Pwinset;
}

static int
panereqmajor(Tk *tk, Tk *sub)
{
	if(ishoriz(tk))
		return sub->req.width;
	return sub->req.height;
}

/* lay out pane offsets/sizes and position+repack each pane to its slot */
static void
ttkpwlayout(Tk *tk)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	int i, avail, off, minor;
	Tk *sub;
	TkGeom old;

	if(pw->npane == 0)
		return;

	minor = pwminor(tk);
	if(minor < 0)
		minor = 0;
	avail = pwmajor(tk) - (pw->npane-1)*Sashw;
	if(avail < pw->npane*Panemin)
		avail = pw->npane*Panemin;

	if(!pw->userpos){
		/*
		 * No sash has been positioned yet: derive each pane's size from
		 * its natural request (refreshing any stale req picked up after
		 * `add'), scaled down proportionally if they don't all fit.
		 */
		int total = 0, nat;
		for(i = 0; i < pw->npane; i++){
			sub = pw->panes[i].sub;
			nat = (sub != nil) ? panereqmajor(tk, sub) : Panemin;
			if(nat < Panemin)
				nat = Panemin;
			pw->panes[i].size = nat;
			total += nat;
		}
		if(total < 1)
			total = 1;
		if(total > avail)
			for(i = 0; i < pw->npane; i++)
				pw->panes[i].size = pw->panes[i].size * avail / total;
	}

	/* clamp current sizes, then hand any slack/deficit to the last pane */
	{
		int sum = 0;
		for(i = 0; i < pw->npane; i++){
			if(pw->panes[i].size < Panemin)
				pw->panes[i].size = Panemin;
			sum += pw->panes[i].size;
		}
		pw->panes[pw->npane-1].size += avail - sum;
		if(pw->panes[pw->npane-1].size < Panemin)
			pw->panes[pw->npane-1].size = Panemin;
	}

	off = Pwinset;
	for(i = 0; i < pw->npane; i++){
		pw->panes[i].off = off;
		sub = pw->panes[i].sub;
		off += pw->panes[i].size + Sashw;
		if(sub == nil)
			continue;
		old = sub->act;
		sub->act.x = 0;
		sub->act.y = 0;
		if(ishoriz(tk)){
			sub->act.width = pw->panes[i].size;
			sub->act.height = minor;
		}else{
			sub->act.width = minor;
			sub->act.height = pw->panes[i].size;
		}
		if(memcmp(&old, &sub->act, sizeof(TkGeom)) != 0){
			if(sub->slave){
				tkpackqit(sub);
				tkrunpack(sub->env->top);
			}
			tkdeliver(sub, TkConfigure, &old);
		}
	}
}

/* natural request size: panes summed along major, max along minor */
static void
ttkpwsize(Tk *tk)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	int i, major, minor, m;
	Tk *sub;

	major = 0;
	minor = Panemin;
	for(i = 0; i < pw->npane; i++){
		sub = pw->panes[i].sub;
		if(sub == nil)
			continue;
		major += panereqmajor(tk, sub);
		m = ishoriz(tk) ? sub->req.height : sub->req.width;
		if(m > minor)
			minor = m;
	}
	if(pw->npane > 1)
		major += (pw->npane-1)*Sashw;
	major += 2*Pwinset;
	minor += 2*Pwinset;

	if(ishoriz(tk)){
		if((tk->flag & Tksetwidth) == 0)
			tk->req.width = major;
		if((tk->flag & Tksetheight) == 0)
			tk->req.height = minor;
	}else{
		if((tk->flag & Tksetwidth) == 0)
			tk->req.width = minor;
		if((tk->flag & Tksetheight) == 0)
			tk->req.height = major;
	}
}

/* ---- embedded-window callbacks (parent-link model) ---- */

static int
paneindex(TkPaned *pw, Tk *sub)
{
	int i;

	for(i = 0; i < pw->npane; i++)
		if(pw->panes[i].sub == sub)
			return i;
	return -1;
}

static void
ttkpwpanegeom(Tk *sub, int x, int y, int w, int h)
{
	Tk *pw;
	TkGeom g;
	int bd;

	USED(x);
	USED(y);
	pw = sub->parent;
	if(pw == nil)
		return;
	sub->req.width = w;
	sub->req.height = h;
	g = pw->req;
	bd = pw->borderwidth;
	ttkpwsize(pw);
	ttkpwlayout(pw);
	tkgeomchg(pw, &g, bd);
	pw->dirty = tkrect(pw, 1);
	tkdirty(pw);
}

static void
ttkpwsubdestroy(Tk *sub)
{
	Tk *pw;
	TkPaned *d;
	int i;

	pw = sub->parent;
	if(pw == nil)
		return;
	d = TKobj(TkPaned, pw);
	i = paneindex(d, sub);
	if(i < 0)
		return;

	memmove(&d->panes[i], &d->panes[i+1], (d->npane-i-1)*sizeof(Pane));
	d->npane--;

	sub->parent = nil;
	sub->geom = nil;
	sub->destroyed = nil;

	ttkpwsize(pw);
	ttkpwlayout(pw);
	pw->dirty = tkrect(pw, 1);
	tkdirty(pw);
}

static Point
ttkpwrelpos(Tk *sub)
{
	Tk *pw;
	TkPaned *d;
	int i;
	Point p;

	pw = sub->parent;
	if(pw == nil)
		return ZP;
	d = TKobj(TkPaned, pw);
	i = paneindex(d, sub);
	if(i < 0)
		return ZP;
	if(ishoriz(pw)){
		p.x = d->panes[i].off;
		p.y = Pwinset;
	}else{
		p.x = Pwinset;
		p.y = d->panes[i].off;
	}
	return p;
}

static Tk*
ttkpwinwindow(Tk *tk, Point *p)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	int i, m, n, lo, hi;
	Tk *sub;

	if(ishoriz(tk)){ m = p->x; n = p->y; }
	else { m = p->y; n = p->x; }
	if(n < Pwinset || n >= Pwinset + pwminor(tk))
		return tk;

	for(i = 0; i < pw->npane; i++){
		sub = pw->panes[i].sub;
		lo = pw->panes[i].off;
		hi = lo + pw->panes[i].size;
		if(sub != nil && m >= lo && m < hi){
			if(ishoriz(tk)){
				p->x -= lo;
				p->y -= Pwinset;
			}else{
				p->x -= Pwinset;
				p->y -= lo;
			}
			return sub;
		}
	}
	return tk;
}

static void
ttkpwdirtychild(Tk *sub)
{
	Tk *tk, *pw;

	for(tk = sub; tk != nil; tk = tk->master)
		if(tk->parent != nil)
			break;
	if(tk == nil)
		return;
	pw = tk->parent;
	pw->dirty = tkrect(pw, 1);
	tkdirty(pw);
}

static void
ttkpwfocusorder(Tk *tk)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	int i;

	for(i = 0; i < pw->npane; i++)
		if(pw->panes[i].sub != nil)
			tkappendfocusorder(pw->panes[i].sub);
}

static void
ttkpwgeom(Tk *tk)
{
	ttkpwlayout(tk);
	tk->dirty = tkrect(tk, 1);
}

/* ---- attach / detach ---- */

static char*
pwattach(Tk *tk, Tk *sub)
{
	if(sub->flag & Tkwindow)
		return TkIstop;
	if(sub->master != nil || sub->parent != nil)
		return TkWpack;
	sub->parent = tk;
	tksetbits(sub, Tksubsub);
	sub->geom = ttkpwpanegeom;
	sub->destroyed = ttkpwsubdestroy;
	return nil;
}

static void
pwdetach(Tk *sub)
{
	if(sub == nil)
		return;
	sub->parent = nil;
	sub->geom = nil;
	sub->destroyed = nil;
}

/* ---- subcommands ---- */

static char*
pwadd(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	TkTop *t = tk->env->top;
	char *e, *buf, *opt, *val;
	Tk *sub;
	Pane *np;
	int weight;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(buf == nil || opt == nil || val == nil){
		free(buf); free(opt); free(val);
		return TkNomem;
	}
	arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);
	if(buf[0] != '.'){
		free(buf); free(opt); free(val);
		return TkBadwp;
	}
	sub = tklook(t, buf, 0);
	if(sub == nil){
		tkerr(t, buf);
		free(buf); free(opt); free(val);
		return TkBadwp;
	}
	if(paneindex(pw, sub) >= 0){
		free(buf); free(opt); free(val);
		return nil;
	}

	weight = 0;
	for(;;){
		arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
		if(opt[0] == '\0')
			break;
		arg = tkword(t, arg, val, val+Tkmaxitem, nil);
		if(strcmp(opt, "-weight") == 0)
			weight = atoi(val);
	}
	free(buf); free(opt); free(val);

	e = pwattach(tk, sub);
	if(e != nil)
		return e;

	np = realloc(pw->panes, (pw->npane+1)*sizeof(Pane));
	if(np == nil){
		pwdetach(sub);
		return TkNomem;
	}
	pw->panes = np;
	memset(&pw->panes[pw->npane], 0, sizeof(Pane));
	pw->panes[pw->npane].sub = sub;
	pw->panes[pw->npane].weight = weight;
	pw->panes[pw->npane].size = panereqmajor(tk, sub);
	if(pw->panes[pw->npane].size < Panemin)
		pw->panes[pw->npane].size = Panemin;
	pw->npane++;

	ttkpwsize(tk);
	ttkpwlayout(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static int
pwindexof(Tk *tk, char *spec)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	Tk *w;

	if(spec == nil || spec[0] == '\0')
		return -1;
	if(strcmp(spec, "end") == 0)
		return pw->npane;
	if(spec[0] == '.'){
		w = tklook(tk->env->top, spec, 0);
		if(w == nil)
			return -1;
		return paneindex(pw, w);
	}
	if(spec[0] >= '0' && spec[0] <= '9')
		return atoi(spec);
	return -1;
}

static char*
pwforget(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	TkTop *t = tk->env->top;
	char *buf;
	int i;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(t, arg, buf, buf+Tkmaxitem, nil);
	i = pwindexof(tk, buf);
	free(buf);
	if(i < 0 || i >= pw->npane)
		return TkBadix;

	pwdetach(pw->panes[i].sub);
	memmove(&pw->panes[i], &pw->panes[i+1], (pw->npane-i-1)*sizeof(Pane));
	pw->npane--;

	ttkpwsize(tk);
	ttkpwlayout(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static char*
pwpanes(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	char *e;
	int i;

	USED(arg);
	for(i = 0; i < pw->npane; i++){
		e = tkvalue(ret, "%s%s", i ? " " : "", tkname(pw->panes[i].sub));
		if(e != nil)
			return e;
	}
	return nil;
}

static char*
pwidentcmd(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	char *e;
	Point p;
	int i, m;

	e = tkxyparse(tk, &arg, &p);
	if(e != nil)
		return e;
	m = ishoriz(tk) ? p.x : p.y;
	for(i = 0; i+1 < pw->npane; i++){
		int s = pw->panes[i].off + pw->panes[i].size;
		if(m >= s && m < s + Sashw)
			return tkvalue(ret, "sash %d", i);
	}
	return tkvalue(ret, "");
}

/* sashpos i ?newpos? - the major-axis coord of sash i (end of pane i) */
static char*
pwsashpos(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	TkTop *t = tk->env->top;
	char *buf;
	int i, pos, cur, lo, hi;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);
	i = atoi(buf);
	if(i < 0 || i+1 >= pw->npane){
		free(buf);
		return TkBadix;
	}
	cur = pw->panes[i].off + pw->panes[i].size;

	tkword(t, arg, buf, buf+Tkmaxitem, nil);
	if(buf[0] == '\0'){
		free(buf);
		return tkvalue(ret, "%d", cur);
	}
	pos = atoi(buf);
	free(buf);

	/* clamp between the prior sash (or band start) and the next */
	lo = pw->panes[i].off + Panemin;
	hi = pw->panes[i+1].off + pw->panes[i+1].size - Panemin;
	if(pos < lo) pos = lo;
	if(pos > hi) pos = hi;

	pw->panes[i].size += pos - cur;
	pw->panes[i+1].size -= pos - cur;
	pw->panes[i+1].off = pos + Sashw;
	pw->userpos = 1;

	ttkpwlayout(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

/* ---- sash drag (bindings) ---- */

static int
sashat(Tk *tk, Point p)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	int i, m, s;

	m = ishoriz(tk) ? p.x : p.y;
	for(i = 0; i+1 < pw->npane; i++){
		s = pw->panes[i].off + pw->panes[i].size;
		if(m >= s && m < s + Sashw)
			return i;
	}
	return -1;
}

static char*
pwpress(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	char *e;
	Point p;

	USED(ret);
	e = tkxyparse(tk, &arg, &p);
	if(e != nil)
		return e;
	pw->drag = sashat(tk, p);
	return nil;
}

static char*
pwdrag(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	char *e;
	Point p;
	int i, pos, cur, lo, hi, m;

	USED(ret);
	if(pw->drag < 0)
		return nil;
	e = tkxyparse(tk, &arg, &p);
	if(e != nil)
		return e;
	i = pw->drag;
	if(i+1 >= pw->npane)
		return nil;
	m = ishoriz(tk) ? p.x : p.y;
	cur = pw->panes[i].off + pw->panes[i].size;
	pos = m;
	lo = pw->panes[i].off + Panemin;
	hi = pw->panes[i+1].off + pw->panes[i+1].size - Panemin;
	if(pos < lo) pos = lo;
	if(pos > hi) pos = hi;

	pw->panes[i].size += pos - cur;
	pw->panes[i+1].size -= pos - cur;
	pw->userpos = 1;

	ttkpwlayout(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static char*
pwrelease(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	USED(arg); USED(ret);
	pw->drag = -1;
	return nil;
}

/* ---- state / instate / style ---- */

static char*
pwstatecmd(Tk *tk, char *arg, char **ret)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	return ttkstateop(tk, &pw->state, arg, ret);
}

static char*
pwinstatecmd(Tk *tk, char *arg, char **ret)
{
	return ttkinstateop(tk, pwstate(tk), arg, ret);
}

static char*
pwstylecmd(Tk *tk, char *arg, char **ret)
{
	USED(arg);
	return tkvalue(ret, "%s", pwstylename(tk));
}

/* ---- cget / configure ---- */

static char*
pwcget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[3];

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkPaned, tk);
	tko[1].optab = ttkpwopts;
	tko[2].ptr = nil;
	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
pwconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[3];

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkPaned, tk);
	tko[1].optab = ttkpwopts;
	tko[2].ptr = nil;

	if(*arg == '\0')
		return tkconflist(tko, val);
	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	ttkpwsize(tk);
	ttkpwlayout(tk);
	tkgeomchg(tk, &g, bd);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return e;
}

/* ---- draw ---- */

static char*
ttkdrawpw(Tk *tk, Point orig)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	TkEnv *e = tk->env;
	Image *i, *sash, *light, *dark;
	Point po, paneo;
	Rectangle r, sr;
	char *style;
	ulong st;
	int k, s, dirty;
	Tk *sub;

	i = tkimageof(tk);
	if(i == nil)
		return nil;
	style = pwstylename(tk);
	st = pwstate(tk);

	po.x = orig.x + tk->act.x + tk->borderwidth;
	po.y = orig.y + tk->act.y + tk->borderwidth;

	draw(i, rectaddpt(tk->dirty, po),
		ttkcolorx(tk, style, st, "-background", TkCbackgnd), nil, ZP);

	sash = tkgc(e, TkCbackgnd);
	light = tkgc(e, TkCbackgndlght);
	dark = tkgc(e, TkCbackgnddark);

	/* sashes, with a thin bevel for grip */
	for(k = 0; k+1 < pw->npane; k++){
		s = pw->panes[k].off + pw->panes[k].size;
		if(ishoriz(tk)){
			sr.min.x = po.x + s;
			sr.min.y = po.y + Pwinset;
			sr.max.x = sr.min.x + Sashw;
			sr.max.y = sr.min.y + pwminor(tk);
		}else{
			sr.min.x = po.x + Pwinset;
			sr.min.y = po.y + s;
			sr.max.x = sr.min.x + pwminor(tk);
			sr.max.y = sr.min.y + Sashw;
		}
		draw(i, sr, sash, nil, ZP);
		tkbox(i, sr, 1, dark);
		/* highlight one inner edge for a raised look */
		r = sr;
		if(ishoriz(tk)){
			r.min.x++; r.max.x = r.min.x+1;
		}else{
			r.min.y++; r.max.y = r.min.y+1;
		}
		draw(i, r, light, nil, ZP);
	}

	/* the panes */
	for(k = 0; k < pw->npane; k++){
		sub = pw->panes[k].sub;
		if(sub == nil)
			continue;
		if(ishoriz(tk)){
			paneo.x = po.x + pw->panes[k].off - sub->borderwidth;
			paneo.y = po.y + Pwinset - sub->borderwidth;
		}else{
			paneo.x = po.x + Pwinset - sub->borderwidth;
			paneo.y = po.y + pw->panes[k].off - sub->borderwidth;
		}
		sub->flag |= Tkrefresh;
		sub->dirty = tkrect(sub, 1);
		tkdrawslaves(sub, paneo, &dirty);
	}
	return nil;
}

/* ---- free ---- */

static void
pwfree(Tk *tk)
{
	TkPaned *pw = TKobj(TkPaned, tk);
	int i;

	for(i = 0; i < pw->npane; i++)
		pwdetach(pw->panes[i].sub);
	free(pw->panes);
	free(pw->style);
	pw->panes = nil;
	pw->npane = 0;
}

/* ---- constructor ---- */

char*
tkttkpanedwindow(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkPaned *pw;
	TkName *names;
	TkOptab tko[3];

	tk = tknewobj(t, TKttkpanedwindow, sizeof(Tk)+sizeof(TkPaned));
	if(tk == nil)
		return TkNomem;
	pw = TKobj(TkPaned, tk);
	pw->state = 0;
	pw->style = nil;
	pw->orient = Tkvertical;	/* Tk default: vertical => stacked panes */
	pw->npane = 0;
	pw->panes = nil;
	pw->drag = -1;

	e = tkbindings(t, tk, ttkpwb, nelem(ttkpwb));
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = pw;
	tko[1].optab = ttkpwopts;
	tko[2].ptr = nil;
	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	ttkpwsize(tk);
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));

	e = tkaddchild(t, tk, &names);
	tkfreename(names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;
	return tkvalue(ret, "%s", tk->name->name);
}

/* ---- command + method tables ---- */

static TkCmdtab ttkpwcmd[] =
{
	"add",		pwadd,
	"cget",		pwcget,
	"configure",	pwconf,
	"forget",	pwforget,
	"identify",	pwidentcmd,
	"instate",	pwinstatecmd,
	"panes",	pwpanes,
	"sashpos",	pwsashpos,
	"state",	pwstatecmd,
	"style",	pwstylecmd,
	"tkttkpwDrag",	pwdrag,
	"tkttkpwPress",	pwpress,
	"tkttkpwRelease", pwrelease,
	nil
};

TkMethod ttkpanedwindowmethod = {
	"TPanedwindow",
	ttkpwcmd,
	pwfree,
	ttkdrawpw,
	ttkpwgeom,
	nil,
	ttkpwfocusorder,
	ttkpwdirtychild,
	ttkpwrelpos,
	nil,
	nil,
	ttkpwinwindow,
	nil,
	nil,
};
