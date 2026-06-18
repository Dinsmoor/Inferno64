#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "tk.h"
#include "ttk.h"

/*
 * ttk::progressbar and ttk::labelframe.
 *
 * progressbar absorbs the Limbo `Progressbar' megawidget: determinate
 * (-value/-maximum/-variable, step) and indeterminate (start/stop, animated
 * over the shared rptproc timer).  labelframe is a titled container.
 */

#define	O(t, e)		((long)(&((t*)0)->e))

enum
{
	Pthick		= 18,	/* progressbar cross thickness */
	Lfpad		= 8	/* labelframe title inset */
};

extern TkStab tkorient[];
extern TkStab tkanchor[];

static TkStab ttkpmode[] =
{
	"determinate",		0,
	"indeterminate",	1,
	nil
};

static TkOption ttkprogopts[] =
{
	"style",	OPTtext,	O(TkTtk, style),	nil,
	"orient",	OPTstab,	O(TkTtk, orient),	tkorient,
	"length",	OPTnndist,	O(TkTtk, length),	nil,
	"mode",		OPTstab,	O(TkTtk, pmode),	ttkpmode,
	"value",	OPTfrac,	O(TkTtk, pvalue),	nil,
	"maximum",	OPTnnfrac,	O(TkTtk, pmaximum),	nil,
	"variable",	OPTtext,	O(TkTtk, variable),	nil,
	nil
};

static TkOption ttklfopts[] =
{
	"style",	OPTtext,	O(TkTtk, style),	nil,
	"text",		OPTtext,	O(TkTtk, text),		nil,
	"labelanchor",	OPTflag,	O(TkTtk, anchor),	tkanchor,
	nil
};

/* ---- progressbar ---- */

static void
ttkprogsize(Tk *tk)
{
	TkTtk *d = TKobj(TkTtk, tk);
	int along, cross;

	along = d->length;
	cross = Pthick;
	if(d->orient == Tkvertical){
		if((tk->flag & Tksetwidth) == 0)
			tk->req.width = cross;
		if((tk->flag & Tksetheight) == 0)
			tk->req.height = along;
	}else{
		if((tk->flag & Tksetwidth) == 0)
			tk->req.width = along;
		if((tk->flag & Tksetheight) == 0)
			tk->req.height = cross;
	}
}

static char*
ttkprogdraw(Tk *tk, Point orig)
{
	TkTtk *d = TKobj(TkTtk, tk);
	TkEnv *e = tk->env;
	Image *i, *dst, *bar;
	Rectangle r, tr, br;
	Point sz;
	int along, lo, hi, span;
	double frac;

	dst = tkimageof(tk);
	if(dst == nil)
		return nil;
	sz.x = tk->act.width + 2*tk->borderwidth;
	sz.y = tk->act.height + 2*tk->borderwidth;
	r.min = ZP;
	r.max = sz;

	i = tkitmp(e, sz, TkCbackgnd);
	if(i == nil)
		return nil;

	/* trough */
	tr = r;
	draw(i, tr, tkgc(e, TkCbackgnddark), nil, ZP);
	tkbox(i, tr, 1, tkgc(e, TkCbackgnddark));
	tr = insetrect(tr, 1);

	along = (d->orient == Tkvertical) ? Dy(tr) : Dx(tr);
	bar = ttkcolor(tk, "-background", TkCselectbgnd);

	lo = 0;
	hi = 0;
	if(d->pmode == 0){	/* determinate */
		frac = 0.0;
		if(d->pmaximum > 0)
			frac = (double)d->pvalue / (double)d->pmaximum;
		if(frac < 0.0) frac = 0.0;
		if(frac > 1.0) frac = 1.0;
		lo = 0;
		hi = (int)(frac * along + 0.5);
	}else{			/* indeterminate: a sliding chunk */
		span = along/3;
		if(span < 4) span = 4;
		lo = d->phase % (2*(along-span > 0 ? along-span : 1));
		if(lo > along-span)
			lo = 2*(along-span) - lo;	/* bounce */
		if(lo < 0) lo = 0;
		hi = lo + span;
	}

	br = tr;
	if(d->orient == Tkvertical){
		/* fill from the bottom up */
		br.max.y = tr.max.y - lo;
		br.min.y = tr.max.y - hi;
	}else{
		br.min.x = tr.min.x + lo;
		br.max.x = tr.min.x + hi;
	}
	if(hi > lo)
		draw(i, br, bar, nil, ZP);

	r.min.x = tk->act.x + orig.x;
	r.min.y = tk->act.y + orig.y;
	r.max = addpt(r.min, sz);
	draw(dst, r, i, nil, ZP);
	return nil;
}

static void
ttkprogvarchanged(Tk *tk, char *var, char *val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	int v;

	if(d->variable == nil || strcmp(d->variable, var) != 0)
		return;
	if(tkfrac(&val, &v, nil) == nil){
		d->pvalue = v;
		tk->dirty = tkrect(tk, 1);
		tkdirty(tk);
	}
}

/* animation tick for indeterminate mode */
static void
ttkprogtick(Tk *tk, void *note, int cancelled)
{
	TkTtk *d = TKobj(TkTtk, tk);

	USED(note);
	if(cancelled){
		d->prunning = 0;
		return;
	}
	d->phase += 3;
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	tkupdate(tk->env->top);
}

static char*
ttkprogcget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[3];
	tko[0].ptr = tk; tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkTtk, tk); tko[1].optab = ttkprogopts;
	tko[2].ptr = nil;
	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
ttkprogconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[3];

	tko[0].ptr = tk; tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkTtk, tk); tko[1].optab = ttkprogopts;
	tko[2].ptr = nil;
	if(*arg == '\0')
		return tkconflist(tko, val);
	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	ttkprogsize(tk);
	tkgeomchg(tk, &g, bd);
	tk->dirty = tkrect(tk, 1);
	return e;
}

static char*
ttkprogstep(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	char *buf;
	int amt;

	USED(val);
	amt = Tkfpscalar;	/* default 1.0 */
	buf = mallocz(Tkmaxitem, 0);
	if(buf != nil){
		tkword(tk->env->top, arg, buf, buf+Tkmaxitem, nil);
		if(buf[0] != '\0'){
			char *p = buf;
			tkfrac(&p, &amt, nil);
		}
		free(buf);
	}
	d->pvalue += amt;
	if(d->pmaximum > 0)
		d->pvalue %= d->pmaximum;
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static char*
ttkprogstart(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	char *buf;
	int interval;

	USED(arg);
	USED(val);
	interval = 50;
	buf = mallocz(Tkmaxitem, 0);
	if(buf != nil){
		tkword(tk->env->top, arg, buf, buf+Tkmaxitem, nil);
		if(buf[0] != '\0')
			interval = atoi(buf);
		free(buf);
	}
	if(interval < 10)
		interval = 10;
	d->pmode = 1;
	d->prunning = 1;
	tkrepeat(tk, ttkprogtick, nil, interval, interval);
	return nil;
}

static char*
ttkprogstop(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	USED(arg);
	USED(val);
	d->prunning = 0;
	tkcancelrepeat(tk);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	return nil;
}

static void
ttkprogfree(Tk *tk)
{
	if(tk == nil)
		return;
	tkcancelrepeat(tk);
	ttkfreedata(tk);
}

char*
tkttkprogressbar(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkTtk *d;
	TkName *names;
	TkOptab tko[3];

	tk = ttknewobj(t, TKttkprogressbar, nil);
	if(tk == nil)
		return TkNomem;
	d = TKobj(TkTtk, tk);
	tko[0].ptr = tk; tko[0].optab = tkgeneric;
	tko[1].ptr = d; tko[1].optab = ttkprogopts;
	tko[2].ptr = nil;
	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	if(d->variable != nil){
		TkVar *v = tkmkvar(t, d->variable, 0);
		if(v != nil && v->type == TkVstring && v->value != nil)
			ttkprogvarchanged(tk, d->variable, v->value);
	}
	ttkprogsize(tk);
	e = tkaddchild(t, tk, &names);
	tkfreename(names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;
	return tkvalue(ret, "%s", tk->name->name);
}

static TkCmdtab ttkprogcmd[] =
{
	"cget",		ttkprogcget,
	"configure",	ttkprogconf,
	"step",		ttkprogstep,
	"start",	ttkprogstart,
	"stop",		ttkprogstop,
	"instate",	ttkinstatecmd,
	"state",	ttkstatecmd,
	"style",	ttkstylecmd,
	"identify",	ttkidentcmd,
	nil
};

TkMethod ttkprogressbarmethod = {
	"TProgressbar", ttkprogcmd, ttkprogfree, ttkprogdraw,
	nil, nil, nil, nil, nil, nil, nil, nil, ttkprogvarchanged
};

/* ---- labelframe ---- */

static char*
ttklfdraw(Tk *tk, Point orig)
{
	TkTtk *d = TKobj(TkTtk, tk);
	TkEnv *e = tk->env;
	Image *i;
	Point p, tp;
	Tk *f;
	int bw, ty;
	Rectangle slaver, r;

	i = tkimageof(tk);
	if(i == nil)
		return nil;
	p.x = orig.x + tk->act.x + tk->borderwidth;
	p.y = orig.y + tk->act.y + tk->borderwidth;
	draw(i, rectaddpt(tk->dirty, p), tkgc(e, TkCbackgnd), nil, ZP);

	for(f = tk->slave; f; f = f->next){
		bw = f->borderwidth;
		slaver.min.x = f->act.x;
		slaver.min.y = f->act.y;
		slaver.max.x = slaver.min.x + f->act.width + 2*bw;
		slaver.max.y = slaver.min.y + f->act.height + 2*bw;
		if(rectclip(&slaver, tk->dirty)){
			f->flag |= Tkrefresh;
			slaver = rectsubpt(slaver, Pt(f->act.x + bw, f->act.y + bw));
			combinerect(&f->dirty, slaver);
		}
	}
	p.x -= tk->borderwidth;
	p.y -= tk->borderwidth;

	/* border box with a gap for the title at the top */
	ty = e->font->height/2;
	r = rectaddpt(tkrect(tk, 0), p);
	r.min.y += ty;
	tkbox(i, r, 1, tkgc(e, TkCbackgnddark));

	if(d->text != nil && d->text[0] != '\0'){
		Point ts = tkstringsize(tk, d->text);
		int tw = ts.x;
		tp.x = p.x + Lfpad;
		tp.y = p.y;
		/* erase the border under the title, then draw the title */
		r = rectaddpt(Rect(Lfpad-2, 0, Lfpad+tw+2, e->font->height), p);
		draw(i, r, tkgc(e, TkCbackgnd), nil, ZP);
		tkdrawstring(tk, i, tp, d->text, -1, tkgc(e, TkCforegnd), Tkleft);
	}
	return nil;
}

static char*
ttklfcget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[3];
	tko[0].ptr = tk; tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkTtk, tk); tko[1].optab = ttklfopts;
	tko[2].ptr = nil;
	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
ttklfconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[3];

	tko[0].ptr = tk; tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkTtk, tk); tko[1].optab = ttklfopts;
	tko[2].ptr = nil;
	if(*arg == '\0')
		return tkconflist(tko, val);
	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	tkgeomchg(tk, &g, bd);
	tk->dirty = tkrect(tk, 1);
	return e;
}

static void
ttklffocusorder(Tk *tk)
{
	int i, n;
	Tk *sub;
	TkWinfo *inf;

	n = 0;
	for(sub = tk->slave; sub != nil; sub = sub->next)
		n++;
	if(n == 0)
		return;
	inf = malloc(sizeof(*inf) * n);
	if(inf == nil)
		return;
	i = 0;
	for(sub = tk->slave; sub != nil; sub = sub->next){
		inf[i].w = sub;
		inf[i].r = rectaddpt(tkrect(sub, 1), Pt(sub->act.x, sub->act.y));
		i++;
	}
	tksortfocusorder(inf, n);
	for(i = 0; i < n; i++)
		tkappendfocusorder(inf[i].w);
	free(inf);
}

static void
ttklffree(Tk *tk)
{
	ttkfreedata(tk);
}

char*
tkttklabelframe(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkTtk *d;
	TkName *names;
	TkOptab tko[3];

	tk = ttknewobj(t, TKttklabelframe, nil);
	if(tk == nil)
		return TkNomem;
	d = TKobj(TkTtk, tk);
	tk->borderwidth = 0;
	tko[0].ptr = tk; tko[0].optab = tkgeneric;
	tko[1].ptr = d; tko[1].optab = ttklfopts;
	tko[2].ptr = nil;
	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
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

static TkCmdtab ttklfcmd[] =
{
	"cget",		ttklfcget,
	"configure",	ttklfconf,
	"instate",	ttkinstatecmd,
	"state",	ttkstatecmd,
	"style",	ttkstylecmd,
	nil
};

TkMethod ttklabelframemethod = {
	"TLabelframe", ttklfcmd, ttklffree, ttklfdraw,
	nil, nil, ttklffocusorder
};
