#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "tk.h"
#include "ttk.h"

/*
 * ttk::notebook - a tabbed container.  Each pane is an ordinary widget
 * (typically a ttk::frame) created as a child of the notebook and then
 * handed over with `<nb> add <pane>'.  Only the selected pane is shown.
 *
 * Panes are NOT pack/place managed: the notebook owns their geometry and
 * draws the selected one itself, using the embedded-window / parent-link
 * model that the canvas and text widgets use (sub->parent = nb, with the
 * per-instance geom/destroyed callbacks and the relpos/inwindow method
 * hooks routing geometry and events).  This avoids the packer and the
 * notebook fighting over the panes.
 *
 * Parallel to the classic widget set, which is untouched.
 */

#define	O(t, e)		((long)(&((t*)0)->e))

enum
{
	Tabpadx		= 10,	/* tab cell horizontal text padding */
	Tabpady		= 4,	/* tab cell vertical text padding */
	Tabgap		= 1,	/* gap between adjacent tab cells */
	Nbinset		= 2,	/* inset of the content area within the border */
	Nbminw		= 40,	/* minimum natural content width */
	Nbminh		= 30	/* minimum natural content height */
};

typedef struct Tab Tab;
typedef struct TkNotebook TkNotebook;

struct Tab
{
	char*	text;		/* -text */
	ulong	state;		/* S* bits (Sdisabled hides/greys the tab) */
	Tk*	pane;		/* the embedded widget */
	int	x;		/* tab cell left, notebook-local (set by draw) */
	int	w;		/* tab cell width (set by draw) */
};

struct TkNotebook
{
	ulong	state;		/* widget S* bits */
	char*	style;		/* explicit -style, or nil => TNotebook */
	int	sel;		/* selected tab index, -1 if none */
	int	ntab;
	Tab*	tabs;
	int	tabh;		/* tab row height (set by ttknbsize) */
};

/* ---- options ---- */

static TkOption ttknbopts[] =
{
	"style",	OPTtext,	O(TkNotebook, style),	nil,
	nil
};

/* ---- bindings ---- */

static TkEbind ttknbb[] =
{
	{TkButton1P,	"%W tkttknbPress %x %y"},
};

/* ---- helpers ---- */

static char*
nbstylename(Tk *tk)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);

	if(nb->style != nil && nb->style[0] != '\0')
		return nb->style;
	return "TNotebook";
}

static ulong
nbstate(Tk *tk)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	ulong st;

	st = nb->state;
	if(tk->flag & Tkdisabled)
		st |= Sdisabled;
	return st;
}

static Tk*
nbselpane(Tk *tk)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);

	if(nb->sel < 0 || nb->sel >= nb->ntab)
		return nil;
	return nb->tabs[nb->sel].pane;
}

/* width of one tab cell, given its text */
static int
tabwidth(Tk *tk, Tab *tab)
{
	Point ts;
	int w;

	w = 0;
	if(tab->text != nil && tab->text[0] != '\0'){
		ts = tkstringsize(tk, tab->text);
		w = ts.x;
	}
	return w + 2*Tabpadx;
}

/* notebook-local content rectangle (inside the border, below the tab row) */
static Rectangle
nbcontent(Tk *tk)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	Rectangle r;

	r.min.x = Nbinset;
	r.min.y = nb->tabh + Nbinset;
	r.max.x = tk->act.width - Nbinset;
	r.max.y = tk->act.height - Nbinset;
	if(r.max.x < r.min.x)
		r.max.x = r.min.x;
	if(r.max.y < r.min.y)
		r.max.y = r.min.y;
	return r;
}

/* compute the tab-row height and the notebook's natural request size */
static void
ttknbsize(Tk *tk)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	int i, tabsum, panew, paneh, w, h;
	Tk *pane;

	nb->tabh = tk->env->font->height + 2*Tabpady;

	tabsum = Nbinset;
	panew = Nbminw;
	paneh = Nbminh;
	for(i = 0; i < nb->ntab; i++){
		tabsum += tabwidth(tk, &nb->tabs[i]) + Tabgap;
		pane = nb->tabs[i].pane;
		if(pane != nil){
			if(pane->req.width > panew)
				panew = pane->req.width;
			if(pane->req.height > paneh)
				paneh = pane->req.height;
		}
	}

	w = panew + 2*Nbinset;
	if(tabsum > w)
		w = tabsum;
	h = paneh + nb->tabh + 2*Nbinset;

	if((tk->flag & Tksetwidth) == 0)
		tk->req.width = w;
	if((tk->flag & Tksetheight) == 0)
		tk->req.height = h;
}

/* position and size the selected pane to fill the content area, repack it */
static void
ttknblayout(Tk *tk)
{
	Rectangle c;
	Tk *pane;
	TkGeom old;

	pane = nbselpane(tk);
	if(pane == nil)
		return;
	c = nbcontent(tk);

	old = pane->act;
	pane->act.x = 0;
	pane->act.y = 0;
	pane->act.width = Dx(c);
	pane->act.height = Dy(c);
	if(memcmp(&old, &pane->act, sizeof(TkGeom)) != 0){
		if(pane->slave){
			tkpackqit(pane);
			tkrunpack(pane->env->top);
		}
		tkdeliver(pane, TkConfigure, &old);
	}
}

/* ---- embedded-window callbacks (parent-link model) ---- */

/* a pane's intrinsic size changed: re-size the notebook and relayout */
static void
ttknbpanegeom(Tk *sub, int x, int y, int w, int h)
{
	Tk *nb;
	TkGeom g;
	int bd;

	USED(x);
	USED(y);
	nb = sub->parent;
	if(nb == nil)
		return;
	sub->req.width = w;
	sub->req.height = h;
	g = nb->req;
	bd = nb->borderwidth;
	ttknbsize(nb);
	ttknblayout(nb);
	tkgeomchg(nb, &g, bd);
	nb->dirty = tkrect(nb, 1);
	tkdirty(nb);
}

/* a pane widget was destroyed out from under us */
static void
ttknbsubdestroy(Tk *sub)
{
	Tk *nb;
	TkNotebook *d;
	int i;

	nb = sub->parent;
	if(nb == nil)
		return;
	d = TKobj(TkNotebook, nb);
	for(i = 0; i < d->ntab; i++)
		if(d->tabs[i].pane == sub)
			break;
	if(i >= d->ntab)
		return;

	free(d->tabs[i].text);
	memmove(&d->tabs[i], &d->tabs[i+1], (d->ntab-i-1)*sizeof(Tab));
	d->ntab--;
	if(d->sel >= d->ntab)
		d->sel = d->ntab-1;

	sub->parent = nil;
	sub->geom = nil;
	sub->destroyed = nil;

	ttknbsize(nb);
	ttknblayout(nb);
	nb->dirty = tkrect(nb, 1);
	tkdirty(nb);
}

/* offset of a pane's content origin within the notebook's inner frame */
static Point
ttknbrelpos(Tk *sub)
{
	Tk *nb;
	Rectangle c;

	nb = sub->parent;
	if(nb == nil)
		return ZP;
	c = nbcontent(nb);
	return c.min;
}

/* route a point (notebook-local) into the selected pane, else stay on nb */
static Tk*
ttknbinwindow(Tk *tk, Point *p)
{
	Tk *pane;
	Rectangle c;

	pane = nbselpane(tk);
	if(pane == nil)
		return tk;
	c = nbcontent(tk);
	if(!ptinrect(*p, c))
		return tk;
	p->x -= c.min.x;
	p->y -= c.min.y;
	return pane;
}

/* a pane (or its descendant) went dirty: repaint the notebook region */
static void
ttknbdirtychild(Tk *sub)
{
	Tk *tk, *nb;

	for(tk = sub; tk != nil; tk = tk->master)
		if(tk->parent != nil)
			break;
	if(tk == nil)
		return;
	nb = tk->parent;
	nb->dirty = tkrect(nb, 1);
	tkdirty(nb);
}

static void
ttknbfocusorder(Tk *tk)
{
	Tk *pane;

	pane = nbselpane(tk);
	if(pane != nil)
		tkappendfocusorder(pane);
}

/* the notebook itself was resized: relayout the selected pane */
static void
ttknbgeom(Tk *tk)
{
	ttknblayout(tk);
	tk->dirty = tkrect(tk, 1);
}

/* ---- attach / detach a pane ---- */

static char*
nbattach(Tk *tk, Tk *sub)
{
	if(sub->flag & Tkwindow)
		return TkIstop;
	if(sub->master != nil || sub->parent != nil)
		return TkWpack;
	sub->parent = tk;
	tksetbits(sub, Tksubsub);
	sub->geom = ttknbpanegeom;
	sub->destroyed = ttknbsubdestroy;
	return nil;
}

static void
nbdetach(Tk *sub)
{
	if(sub == nil)
		return;
	sub->parent = nil;
	sub->geom = nil;
	sub->destroyed = nil;
}

/* resolve a tab spec: a widget path (.foo), a number, or "end"/"current" */
static int
nbindexof(Tk *tk, char *spec)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	Tk *w;
	int i;

	if(spec == nil || spec[0] == '\0')
		return -1;
	if(strcmp(spec, "current") == 0)
		return nb->sel;
	if(strcmp(spec, "end") == 0)
		return nb->ntab;
	if(spec[0] == '.'){
		w = tklook(tk->env->top, spec, 0);
		if(w == nil)
			return -1;
		for(i = 0; i < nb->ntab; i++)
			if(nb->tabs[i].pane == w)
				return i;
		return -1;
	}
	if(spec[0] >= '0' && spec[0] <= '9')
		return atoi(spec);
	return -1;
}

/* ---- tab option parsing (-text, -state) ---- */

static char*
nbparsetabopts(Tk *tk, Tab *tab, char *arg)
{
	TkTop *t = tk->env->top;
	char *opt, *val;
	ulong on, off;

	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(opt == nil || val == nil){
		free(opt); free(val);
		return TkNomem;
	}
	for(;;){
		arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
		if(opt[0] == '\0')
			break;
		arg = tkword(t, arg, val, val+Tkmaxitem, nil);
		if(strcmp(opt, "-text") == 0){
			free(tab->text);
			tab->text = strdup(val);
		}else if(strcmp(opt, "-state") == 0){
			if(ttkstateparse(val, &on, &off) == 0)
				tab->state = (tab->state | on) & ~off;
		}
	}
	free(opt);
	free(val);
	return nil;
}

/* ---- subcommands ---- */

static char*
nbadd(Tk *tk, char *arg, char **ret)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	TkTop *t = tk->env->top;
	char *e, *buf, *leaf;
	Tk *sub;
	Tab *nt;
	int n;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);
	if(buf[0] != '.'){
		free(buf);
		return TkBadwp;
	}
	sub = tklook(t, buf, 0);
	if(sub == nil){
		tkerr(t, buf);
		free(buf);
		return TkBadwp;
	}

	/* already a tab?  treat add as a reconfigure + select */
	for(n = 0; n < nb->ntab; n++)
		if(nb->tabs[n].pane == sub)
			break;
	if(n < nb->ntab){
		e = nbparsetabopts(tk, &nb->tabs[n], arg);
		free(buf);
		if(e != nil)
			return e;
		nb->sel = n;
		ttknbsize(tk);
		ttknblayout(tk);
		tk->dirty = tkrect(tk, 1);
		tkdirty(tk);
		return nil;
	}

	e = nbattach(tk, sub);
	if(e != nil){
		free(buf);
		return e;
	}

	nt = realloc(nb->tabs, (nb->ntab+1)*sizeof(Tab));
	if(nt == nil){
		nbdetach(sub);
		free(buf);
		return TkNomem;
	}
	nb->tabs = nt;
	memset(&nb->tabs[nb->ntab], 0, sizeof(Tab));
	nb->tabs[nb->ntab].pane = sub;

	leaf = strrchr(buf, '.');
	nb->tabs[nb->ntab].text = strdup(leaf ? leaf+1 : buf);
	free(buf);

	e = nbparsetabopts(tk, &nb->tabs[nb->ntab], arg);
	if(e != nil)
		return e;

	if(nb->ntab == 0 || nb->sel < 0)
		nb->sel = nb->ntab;
	nb->ntab++;

	ttknbsize(tk);
	ttknblayout(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static char*
nbforget(Tk *tk, char *arg, char **ret)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	TkTop *t = tk->env->top;
	char *buf;
	int i;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(t, arg, buf, buf+Tkmaxitem, nil);
	i = nbindexof(tk, buf);
	free(buf);
	if(i < 0 || i >= nb->ntab)
		return TkBadix;

	nbdetach(nb->tabs[i].pane);
	free(nb->tabs[i].text);
	memmove(&nb->tabs[i], &nb->tabs[i+1], (nb->ntab-i-1)*sizeof(Tab));
	nb->ntab--;
	if(nb->sel >= nb->ntab)
		nb->sel = nb->ntab-1;

	ttknbsize(tk);
	ttknblayout(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static char*
nbselect(Tk *tk, char *arg, char **ret)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	TkTop *t = tk->env->top;
	char *buf;
	int i;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(t, arg, buf, buf+Tkmaxitem, nil);
	if(buf[0] == '\0'){
		free(buf);
		if(nb->sel < 0 || nb->sel >= nb->ntab)
			return nil;
		return tkvalue(ret, "%s", tkname(nb->tabs[nb->sel].pane));
	}
	i = nbindexof(tk, buf);
	free(buf);
	if(i < 0 || i >= nb->ntab)
		return TkBadix;
	if(nb->tabs[i].state & Sdisabled)
		return nil;
	nb->sel = i;
	ttknblayout(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static char*
nbindex(Tk *tk, char *arg, char **ret)
{
	TkTop *t = tk->env->top;
	char *buf;
	int i;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(t, arg, buf, buf+Tkmaxitem, nil);
	i = nbindexof(tk, buf);
	free(buf);
	return tkvalue(ret, "%d", i);
}

static char*
nbtabs(Tk *tk, char *arg, char **ret)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	char *e;
	int i;

	USED(arg);
	for(i = 0; i < nb->ntab; i++){
		e = tkvalue(ret, "%s%s", i ? " " : "", tkname(nb->tabs[i].pane));
		if(e != nil)
			return e;
	}
	return nil;
}

static char*
nbtab(Tk *tk, char *arg, char **ret)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	TkTop *t = tk->env->top;
	char *buf, *opt, *val, *rest, *e;
	int i;

	buf = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(buf == nil || opt == nil || val == nil){
		free(buf); free(opt); free(val);
		return TkNomem;
	}
	arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);
	i = nbindexof(tk, buf);
	if(i < 0 || i >= nb->ntab){
		free(buf); free(opt); free(val);
		return TkBadix;
	}

	/* `tab IDX' or `tab IDX -opt' with no value is a query */
	rest = tkword(t, arg, opt, opt+Tkmaxitem, nil);
	tkword(t, rest, val, val+Tkmaxitem, nil);
	if(opt[0] == '\0' || (val[0] == '\0' && strcmp(opt, "-text") == 0)){
		e = tkvalue(ret, "%s", nb->tabs[i].text ? nb->tabs[i].text : "");
		free(buf); free(opt); free(val);
		return e;
	}
	free(buf); free(opt); free(val);

	e = nbparsetabopts(tk, &nb->tabs[i], arg);
	if(e != nil)
		return e;
	ttknbsize(tk);
	ttknblayout(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

/* click on the tab row selects a tab */
static char*
nbpress(Tk *tk, char *arg, char **ret)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	char *e;
	Point p;
	int i;

	USED(ret);
	e = tkxyparse(tk, &arg, &p);
	if(e != nil)
		return e;
	if(p.y < 0 || p.y >= nb->tabh)
		return nil;
	for(i = 0; i < nb->ntab; i++){
		if(p.x >= nb->tabs[i].x && p.x < nb->tabs[i].x + nb->tabs[i].w){
			if(nb->tabs[i].state & Sdisabled)
				return nil;
			nb->sel = i;
			ttknblayout(tk);
			tk->dirty = tkrect(tk, 1);
			tkdirty(tk);
			return nil;
		}
	}
	return nil;
}

/* ---- state / instate / style ---- */

static char*
nbstatecmd(Tk *tk, char *arg, char **ret)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	return ttkstateop(tk, &nb->state, arg, ret);
}

static char*
nbinstatecmd(Tk *tk, char *arg, char **ret)
{
	return ttkinstateop(tk, nbstate(tk), arg, ret);
}

static char*
nbstylecmd(Tk *tk, char *arg, char **ret)
{
	USED(arg);
	return tkvalue(ret, "%s", nbstylename(tk));
}

static char*
nbidentcmd(Tk *tk, char *arg, char **ret)
{
	USED(tk); USED(arg);
	return tkvalue(ret, "");
}

/* ---- cget / configure ---- */

static char*
nbcget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[3];

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkNotebook, tk);
	tko[1].optab = ttknbopts;
	tko[2].ptr = nil;
	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
nbconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[3];

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkNotebook, tk);
	tko[1].optab = ttknbopts;
	tko[2].ptr = nil;

	if(*arg == '\0')
		return tkconflist(tko, val);
	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	ttknbsize(tk);
	ttknblayout(tk);
	tkgeomchg(tk, &g, bd);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return e;
}

/* ---- draw ---- */

static char*
ttkdrawnb(Tk *tk, Point orig)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	TkEnv *e = tk->env;
	Image *i, *fill, *line;
	Point po, pane0, tp;
	Rectangle r, cell, cr;
	char *style;
	ulong st;
	int k, tx, dirty;
	Tk *pane;

	i = tkimageof(tk);
	if(i == nil)
		return nil;
	style = nbstylename(tk);
	st = nbstate(tk);

	po.x = orig.x + tk->act.x + tk->borderwidth;
	po.y = orig.y + tk->act.y + tk->borderwidth;

	/* background over the dirty region */
	draw(i, rectaddpt(tk->dirty, po),
		ttkcolorx(tk, style, st, "-background", TkCbackgnd), nil, ZP);

	line = ttkcolorx(tk, style, st, "-bordercolor", TkCbackgnddark);

	/* content border box, leaving the tab row above it */
	r = rectaddpt(tkrect(tk, 0), po);
	r.min.y += nb->tabh;
	tkbox(i, r, 1, line);

	/* tab cells */
	tx = Nbinset;
	for(k = 0; k < nb->ntab; k++){
		Tab *tab = &nb->tabs[k];
		int selected = (k == nb->sel);
		int slot;

		tab->x = tx;
		tab->w = tabwidth(tk, tab);

		cell.min.x = po.x + tx;
		cell.min.y = po.y + (selected ? 0 : 2);
		cell.max.x = cell.min.x + tab->w;
		cell.max.y = po.y + nb->tabh + (selected ? 1 : 0);

		slot = selected ? TkCbackgndlght : TkCbackgnd;
		if(tab->state & Sdisabled)
			slot = TkCbackgnd;
		fill = tkgc(e, slot);
		draw(i, cell, fill, nil, ZP);
		tkbox(i, cell, 1, line);

		if(tab->text != nil && tab->text[0] != '\0'){
			Point ts = tkstringsize(tk, tab->text);
			Image *ct = tkgc(e, (tab->state & Sdisabled) ?
				TkCdisablefgnd : TkCforegnd);
			tp.x = cell.min.x + (tab->w - ts.x)/2;
			tp.y = cell.min.y + (Dy(cell) - ts.y)/2;
			tkdrawstring(tk, i, tp, tab->text, -1, ct, Tkleft);
		}
		tx += tab->w + Tabgap;
	}

	/* the selected pane */
	pane = nbselpane(tk);
	if(pane != nil){
		cr = nbcontent(tk);
		pane0.x = po.x + cr.min.x - pane->borderwidth;
		pane0.y = po.y + cr.min.y - pane->borderwidth;
		pane->flag |= Tkrefresh;
		pane->dirty = tkrect(pane, 1);
		tkdrawslaves(pane, pane0, &dirty);
	}
	return nil;
}

/* ---- free ---- */

static void
nbfree(Tk *tk)
{
	TkNotebook *nb = TKobj(TkNotebook, tk);
	int i;

	for(i = 0; i < nb->ntab; i++){
		nbdetach(nb->tabs[i].pane);
		free(nb->tabs[i].text);
	}
	free(nb->tabs);
	free(nb->style);
	nb->tabs = nil;
	nb->ntab = 0;
}

/* ---- constructor ---- */

char*
tkttknotebook(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkNotebook *nb;
	TkName *names;
	TkOptab tko[3];

	tk = tknewobj(t, TKttknotebook, sizeof(Tk)+sizeof(TkNotebook));
	if(tk == nil)
		return TkNomem;
	nb = TKobj(TkNotebook, tk);
	nb->state = 0;
	nb->style = nil;
	nb->sel = -1;
	nb->ntab = 0;
	nb->tabs = nil;
	nb->tabh = 0;

	e = tkbindings(t, tk, ttknbb, nelem(ttknbb));
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = nb;
	tko[1].optab = ttknbopts;
	tko[2].ptr = nil;
	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	ttknbsize(tk);
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

static TkCmdtab ttknbcmd[] =
{
	"add",		nbadd,
	"cget",		nbcget,
	"configure",	nbconf,
	"forget",	nbforget,
	"identify",	nbidentcmd,
	"index",	nbindex,
	"instate",	nbinstatecmd,
	"select",	nbselect,
	"state",	nbstatecmd,
	"style",	nbstylecmd,
	"tab",		nbtab,
	"tabs",		nbtabs,
	"tkttknbPress",	nbpress,
	nil
};

TkMethod ttknotebookmethod = {
	"TNotebook",
	ttknbcmd,
	nbfree,
	ttkdrawnb,
	ttknbgeom,
	nil,
	ttknbfocusorder,
	ttknbdirtychild,
	ttknbrelpos,
	nil,
	nil,
	ttknbinwindow,
	nil,
	nil,
};
