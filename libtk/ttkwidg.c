#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "tk.h"
#include "ttk.h"

/*
 * The ttk basic widgets: ttk::frame, ttk::label, ttk::button,
 * ttk::checkbutton, ttk::radiobutton, ttk::separator.  Each is a distinct
 * widget type (class TFrame/TLabel/...) that paints through the style engine
 * in ttk.c and carries the ttk state machine (state/instate subcommands).
 *
 * Parallel to the classic widgets, which are untouched.
 */

#define	O(t, e)		((long)(&((t*)0)->e))

enum
{
	Ind		= 13,	/* check/radio indicator box/circle size */
	Indgap		= 5,	/* gap between indicator and text */
	Btnpadx		= 8,	/* default button text padding */
	Btnpady		= 4,
	Lblpad		= 1
};

extern TkStab tkanchor[];
extern TkStab tkjustify[];
extern TkStab tkorient[];

/* ---- option tables ---- */

static TkOption ttklabelopts[] =
{
	"text",		OPTtext,	O(TkTtk, text),		nil,
	"textvariable",	OPTtext,	O(TkTtk, textvar),	nil,
	"style",	OPTtext,	O(TkTtk, style),	nil,
	"underline",	OPTdist,	O(TkTtk, ul),		nil,
	"anchor",	OPTflag,	O(TkTtk, anchor),	tkanchor,
	"justify",	OPTstab,	O(TkTtk, justify),	tkjustify,
	"width",	OPTdist,	O(TkTtk, width),	nil,
	nil
};

static TkOption ttkbuttonopts[] =
{
	"text",		OPTtext,	O(TkTtk, text),		nil,
	"textvariable",	OPTtext,	O(TkTtk, textvar),	nil,
	"style",	OPTtext,	O(TkTtk, style),	nil,
	"command",	OPTtext,	O(TkTtk, command),	nil,
	"underline",	OPTdist,	O(TkTtk, ul),		nil,
	"anchor",	OPTflag,	O(TkTtk, anchor),	tkanchor,
	"justify",	OPTstab,	O(TkTtk, justify),	tkjustify,
	"width",	OPTdist,	O(TkTtk, width),	nil,
	nil
};

static TkOption ttkcheckopts[] =
{
	"text",		OPTtext,	O(TkTtk, text),		nil,
	"textvariable",	OPTtext,	O(TkTtk, textvar),	nil,
	"style",	OPTtext,	O(TkTtk, style),	nil,
	"command",	OPTtext,	O(TkTtk, command),	nil,
	"variable",	OPTtext,	O(TkTtk, variable),	nil,
	"onvalue",	OPTtext,	O(TkTtk, onvalue),	nil,
	"offvalue",	OPTtext,	O(TkTtk, offvalue),	nil,
	"underline",	OPTdist,	O(TkTtk, ul),		nil,
	"width",	OPTdist,	O(TkTtk, width),	nil,
	nil
};

static TkOption ttkradioopts[] =
{
	"text",		OPTtext,	O(TkTtk, text),		nil,
	"textvariable",	OPTtext,	O(TkTtk, textvar),	nil,
	"style",	OPTtext,	O(TkTtk, style),	nil,
	"command",	OPTtext,	O(TkTtk, command),	nil,
	"variable",	OPTtext,	O(TkTtk, variable),	nil,
	"value",	OPTtext,	O(TkTtk, value),	nil,
	"underline",	OPTdist,	O(TkTtk, ul),		nil,
	"width",	OPTdist,	O(TkTtk, width),	nil,
	nil
};

static TkOption ttkframeopts[] =
{
	"style",	OPTtext,	O(TkTtk, style),	nil,
	nil
};

static TkOption ttksepopts[] =
{
	"style",	OPTtext,	O(TkTtk, style),	nil,
	"orient",	OPTstab,	O(TkTtk, orient),	tkorient,
	nil
};

/* ---- bindings ---- */

static TkEbind ttkbb[] =
{
	{TkEnter,	"%W tkttkEnter"},
	{TkLeave,	"%W tkttkLeave"},
	{TkButton1P,	"%W tkttkPress"},
	{TkButton1R,	"%W tkttkRelease %x %y"},
	{TkKey,		"%W tkttkKey 0x%K"},
};

/* ---- helpers ---- */

static char*
efftext(Tk *tk)
{
	TkTtk *d = TKobj(TkTtk, tk);
	return d->text;
}

static int
hasindicator(Tk *tk)
{
	return tk->type == TKttkcheckbutton || tk->type == TKttkradiobutton;
}

void
ttksize(Tk *tk)
{
	TkTtk *d = TKobj(TkTtk, tk);
	Point p;
	int w, h, padx, pady, tw, th;
	char *text;

	if(d->anchor == 0)
		d->anchor = Tkcenter;

	switch(tk->type){
	case TKttkbutton:
		padx = Btnpadx; pady = Btnpady; break;
	case TKttkcheckbutton:
	case TKttkradiobutton:
		padx = Lblpad; pady = Lblpad; break;
	default:
		padx = Lblpad; pady = Lblpad; break;
	}

	tw = 0;
	th = tk->env->font->height;
	text = efftext(tk);
	if(text != nil && text[0] != '\0'){
		p = tkstringsize(tk, text);
		tw = p.x;
		th = p.y;
		if(d->ul != -1 && d->ul > strlen(text))
			d->ul = strlen(text);
	}
	d->tsize.x = tw;
	d->tsize.y = th;

	if(d->width > 0)
		tw = d->width * tk->env->wzero;

	w = tw + 2*padx;
	h = th + 2*pady;
	if(hasindicator(tk)){
		w += Ind + Indgap;
		if(h < Ind)
			h = Ind;
	}
	w += 2*tk->highlightwidth + 2*tk->borderwidth;
	h += 2*tk->highlightwidth + 2*tk->borderwidth;

	if((tk->flag & Tksetwidth) == 0)
		tk->req.width = w;
	if((tk->flag & Tksetheight) == 0)
		tk->req.height = h;
}

static int
fgslot(ulong state)
{
	if(state & Sdisabled)
		return TkCdisablefgnd;
	if(state & Sactive)
		return TkCactivefgnd;
	return TkCforegnd;
}

/* draw a check tick or radio dot indicator at u, box size Ind */
static void
drawindicator(Tk *tk, Image *i, Point u)
{
	TkTtk *d = TKobj(TkTtk, tk);
	TkEnv *e = tk->env;
	Point v, pp[4];
	Rectangle r;

	r.min = u;
	r.max.x = u.x + Ind;
	r.max.y = u.y + Ind;
	if(tk->type == TKttkcheckbutton){
		draw(i, r, tkgc(e, (d->state&Sdisabled)? TkCbackgnd : TkCbackgndlght), nil, ZP);
		tkbox(i, r, 1, tkgc(e, TkCbackgnddark));
		if(d->check){
			pp[0] = Pt(u.x+3, u.y+Ind/2);
			pp[1] = Pt(u.x+3+2, u.y+Ind/2+2);
			pp[2] = Pt(u.x+Ind-3, u.y+3);
			pp[3] = pp[2];
			bezspline(i, pp, 4, Enddisc, Enddisc, 1, tkgc(e, fgslot(d->state)), ZP);
		}
	}else{
		v = Pt(u.x+Ind/2, u.y+Ind/2);
		draw(i, r, tkgc(e, (d->state&Sdisabled)? TkCbackgnd : TkCbackgndlght), nil, ZP);
		ellipse(i, v, Ind/2-1, Ind/2-1, 1, tkgc(e, TkCbackgnddark), ZP);
		if(d->check)
			fillellipse(i, v, Ind/2-4, Ind/2-4, tkgc(e, fgslot(d->state)), ZP);
	}
}

char*
ttkdraw(Tk *tk, Point orig)
{
	TkTtk *d = TKobj(TkTtk, tk);
	TkEnv *e = tk->env;
	Image *dst, *i, *ct;
	Rectangle r, mainr;
	Point p, u, sz;
	char *text;
	int dx, dy, padx, pady;

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

	ttkfillbg(tk, i, r, d->state);
	if(tk->type == TKttkbutton)
		ttkborder(tk, i, r, d->state);

	mainr = insetrect(r, tk->borderwidth + tk->highlightwidth);
	switch(tk->type){
	case TKttkbutton:
		padx = Btnpadx; pady = Btnpady; break;
	default:
		padx = Lblpad; pady = Lblpad; break;
	}

	p = mainr.min;
	u = ZP;

	/* indicator on the left for check/radio */
	if(hasindicator(tk)){
		Point iu;
		iu.x = p.x;
		iu.y = p.y + (Dy(mainr) - Ind)/2;
		drawindicator(tk, i, iu);
		u.x += Ind + Indgap;
	}

	text = efftext(tk);
	if(text != nil && text[0] != '\0'){
		Point tp;
		dx = Dx(mainr) - u.x - d->tsize.x - 2*padx;
		dy = Dy(mainr) - d->tsize.y - 2*pady;
		tp.x = p.x + u.x + padx;
		tp.y = p.y + pady;
		if(!hasindicator(tk)){
			if((d->anchor & (Tkeast|Tkwest)) == 0)
				tp.x += dx/2;
			else if(d->anchor & Tkeast)
				tp.x += dx;
		}
		if((d->anchor & (Tknorth|Tksouth)) == 0)
			tp.y += dy/2;
		else if(d->anchor & Tksouth)
			tp.y += dy;
		if(tk->type == TKttkbutton && (d->state & Spressed)){
			tp.x++;
			tp.y++;
		}
		ct = tkgc(e, fgslot(d->state));
		tkdrawstring(tk, i, tp, text, d->ul, ct, d->justify);
	}

	ttkfocusring(tk, i, r, d->state);

	p.x = tk->act.x + orig.x;
	p.y = tk->act.y + orig.y;
	r = rectaddpt(r, p);
	draw(dst, r, i, nil, ZP);
	return nil;
}

/* ---- frame ---- */

char*
ttkdrawframe(Tk *tk, Point orig)
{
	TkTtk *d = TKobj(TkTtk, tk);
	Image *i;
	Point p;
	Tk *f;
	int bw;
	Rectangle slaver;

	i = tkimageof(tk);
	if(i == nil)
		return nil;
	p.x = orig.x + tk->act.x + tk->borderwidth;
	p.y = orig.y + tk->act.y + tk->borderwidth;
	draw(i, rectaddpt(tk->dirty, p), ttkcolor(tk, "-background", TkCbackgnd), nil, ZP);

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
	if(!rectinrect(tk->dirty, tkrect(tk, 0)))
		tkdrawrelief(i, tk, p, TkCbackgnd, tk->relief);
	USED(d);
	return nil;
}

static void
ttkframefocusorder(Tk *tk)
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

/* ---- separator ---- */

char*
ttkdrawsep(Tk *tk, Point orig)
{
	TkTtk *d = TKobj(TkTtk, tk);
	Image *i;
	Point p;
	Rectangle r;

	i = tkimageof(tk);
	if(i == nil)
		return nil;
	p.x = orig.x + tk->act.x + tk->borderwidth;
	p.y = orig.y + tk->act.y + tk->borderwidth;
	r = rectaddpt(tkrect(tk, 0), p);
	draw(i, r, tkgc(tk->env, TkCbackgnd), nil, ZP);
	if(d->orient == Tkvertical){
		r.min.x += (Dx(r)-2)/2;
		r.max.x = r.min.x+1;
		draw(i, r, tkgc(tk->env, TkCbackgnddark), nil, ZP);
		r.min.x += 1; r.max.x += 1;
		draw(i, r, tkgc(tk->env, TkCbackgndlght), nil, ZP);
	}else{
		r.min.y += (Dy(r)-2)/2;
		r.max.y = r.min.y+1;
		draw(i, r, tkgc(tk->env, TkCbackgnddark), nil, ZP);
		r.min.y += 1; r.max.y += 1;
		draw(i, r, tkgc(tk->env, TkCbackgndlght), nil, ZP);
	}
	return nil;
}

/* ---- variable / textvariable plumbing ---- */

static void
ttkvarchanged(Tk *tk, char *var, char *val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	char *on;

	if(d->textvar != nil && strcmp(d->textvar, var) == 0){
		free(d->text);
		d->text = strdup(val);
		ttksize(tk);
		tk->dirty = tkrect(tk, 1);
		tkdirty(tk);
		return;
	}
	if(d->variable != nil && strcmp(d->variable, var) == 0){
		if(tk->type == TKttkcheckbutton)
			on = d->onvalue ? d->onvalue : "1";
		else
			on = d->value ? d->value : "";
		d->check = (strcmp(val, on) == 0);
		if(d->check)
			d->state |= Sselected;
		else
			d->state &= ~Sselected;
		tk->dirty = tkrect(tk, 1);
		tkdirty(tk);
	}
}

/* sync from variables after a configure/parse */
static char*
ttkbindvars(Tk *tk)
{
	TkTtk *d = TKobj(TkTtk, tk);
	TkTop *t = tk->env->top;
	TkVar *v;

	if(d->textvar != nil){
		v = tkmkvar(t, d->textvar, 0);
		if(v != nil && v->type == TkVstring && v->value != nil){
			free(d->text);
			d->text = strdup(v->value);
		}
	}
	if(d->variable != nil){
		v = tkmkvar(t, d->variable, 0);
		if(v == nil){
			char *init = (tk->type == TKttkcheckbutton) ?
				(d->offvalue ? d->offvalue : "0") : "";
			tksetvar(t, d->variable, init);
		}else if(v->type == TkVstring && v->value != nil)
			ttkvarchanged(tk, d->variable, v->value);
	}
	return nil;
}

/* ---- generic construct / configure / cget ---- */

static char*
ttkmake(TkTop *t, int type, char *arg, char **ret, TkOption *opts,
	TkEbind *binds, int nbinds)
{
	Tk *tk;
	char *e;
	TkTtk *d;
	TkName *names;
	TkOptab tko[3];

	tk = ttknewobj(t, type, nil);
	if(tk == nil)
		return TkNomem;
	d = TKobj(TkTtk, tk);

	switch(type){
	case TKttkbutton:
		tk->borderwidth = 1;
		tk->highlightwidth = 1;
		tk->flag |= Tktakefocus;
		break;
	case TKttkcheckbutton:
	case TKttkradiobutton:
		tk->highlightwidth = 1;
		tk->flag |= Tktakefocus;
		break;
	}

	if(binds != nil){
		e = tkbindings(t, tk, binds, nbinds);
		if(e != nil){
			tkfreeobj(tk);
			return e;
		}
	}

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = d;
	tko[1].optab = opts;
	tko[2].ptr = nil;

	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	ttkbindvars(tk);
	ttksize(tk);
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));

	e = tkaddchild(t, tk, &names);
	tkfreename(names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;
	USED(ret);
	return tkvalue(ret, "%s", tk->name->name);
}

static char*
ttkcget(Tk *tk, char *arg, char **val, TkOption *opts)
{
	TkOptab tko[3];

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkTtk, tk);
	tko[1].optab = opts;
	tko[2].ptr = nil;
	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
ttkconf(Tk *tk, char *arg, char **val, TkOption *opts)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[3];

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = TKobj(TkTtk, tk);
	tko[1].optab = opts;
	tko[2].ptr = nil;

	if(*arg == '\0')
		return tkconflist(tko, val);

	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	ttkbindvars(tk);
	/* bridge classic -state into the ttk state set */
	{
		TkTtk *d = TKobj(TkTtk, tk);
		if(tk->flag & Tkdisabled)
			d->state |= Sdisabled;
		else
			d->state &= ~Sdisabled;
	}
	ttksize(tk);
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));
	tkgeomchg(tk, &g, bd);
	tk->dirty = tkrect(tk, 1);
	return e;
}

/* per-class cget/configure wrappers (needed: opts table differs) */
#define WRAP(pfx, optab) \
	static char* pfx##cget(Tk *tk, char *a, char **v){ return ttkcget(tk, a, v, optab); } \
	static char* pfx##conf(Tk *tk, char *a, char **v){ return ttkconf(tk, a, v, optab); }

WRAP(ttklbl, ttklabelopts)
WRAP(ttkbtn, ttkbuttonopts)
WRAP(ttkchk, ttkcheckopts)
WRAP(ttkrad, ttkradioopts)
WRAP(ttkfrm, ttkframeopts)
WRAP(ttksep, ttksepopts)

/* ---- interaction subcommands (button/check/radio) ---- */

static char*
ttkinvoke(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	TkTop *t = tk->env->top;
	char *e, *nv;

	USED(arg);
	if(d->state & Sdisabled)
		return nil;
	e = nil;
	if(tk->type == TKttkcheckbutton){
		d->check = !d->check;
		nv = d->check ? (d->onvalue ? d->onvalue : "1")
			      : (d->offvalue ? d->offvalue : "0");
		if(d->variable != nil)
			e = tksetvar(t, d->variable, nv);
		else {
			if(d->check) d->state |= Sselected; else d->state &= ~Sselected;
			tk->dirty = tkrect(tk, 1);
			tkdirty(tk);
		}
	}else if(tk->type == TKttkradiobutton){
		if(d->variable != nil)
			e = tksetvar(t, d->variable, d->value ? d->value : "");
	}
	if(e != nil)
		return e;
	if(d->command != nil)
		return tkexec(t, d->command, val);
	return nil;
}

static char*
ttkcmdenter(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	USED(arg); USED(val);
	if((d->state & Sdisabled) == 0)
		ttksetstate(tk, d->state | Sactive);
	return nil;
}

static char*
ttkcmdleave(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	USED(arg); USED(val);
	ttksetstate(tk, d->state & ~(Sactive|Spressed));
	return nil;
}

static char*
ttkcmdpress(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	USED(arg); USED(val);
	if((d->state & Sdisabled) == 0)
		ttksetstate(tk, d->state | Spressed);
	return nil;
}

static char*
ttkcmdrelease(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	char *e;
	Point p;
	Rectangle hitr;
	int waspressed;

	waspressed = d->state & Spressed;
	ttksetstate(tk, d->state & ~Spressed);
	if(d->state & Sdisabled)
		return nil;
	e = tkxyparse(tk, &arg, &p);
	if(e != nil)
		return e;
	hitr.min = ZP;
	hitr.max.x = tk->act.width + 2*tk->borderwidth;
	hitr.max.y = tk->act.height + 2*tk->borderwidth;
	if(waspressed && ptinrect(p, hitr))
		return ttkinvoke(tk, nil, val);
	return nil;
}

static char*
ttkcmdkey(Tk *tk, char *arg, char **val)
{
	int key;
	TkTtk *d = TKobj(TkTtk, tk);

	if(d->state & Sdisabled)
		return nil;
	key = strtol(arg, nil, 0);
	if(key == '\n' || key == ' ' || key == '\r')
		return ttkinvoke(tk, nil, val);
	return nil;
}

/* check/radio explicit select/deselect (compat with classic api) */
static char*
ttkselect(Tk *tk, char *arg, char **val)
{
	TkTtk *d = TKobj(TkTtk, tk);
	TkTop *t = tk->env->top;
	USED(arg); USED(val);
	if(tk->type == TKttkradiobutton){
		if(d->variable != nil)
			return tksetvar(t, d->variable, d->value ? d->value : "");
	}else if(tk->type == TKttkcheckbutton){
		d->check = 1;
		if(d->variable != nil)
			return tksetvar(t, d->variable, d->onvalue ? d->onvalue : "1");
		d->state |= Sselected;
		tk->dirty = tkrect(tk, 1); tkdirty(tk);
	}
	return nil;
}

/* ---- free ---- */

static void
ttkfree(Tk *tk)
{
	ttkfreedata(tk);
}

/* ---- constructors ---- */

char*
tkttkframe(TkTop *t, char *arg, char **ret)
{
	return ttkmake(t, TKttkframe, arg, ret, ttkframeopts, nil, 0);
}

char*
tkttklabel(TkTop *t, char *arg, char **ret)
{
	return ttkmake(t, TKttklabel, arg, ret, ttklabelopts, nil, 0);
}

char*
tkttkbutton(TkTop *t, char *arg, char **ret)
{
	return ttkmake(t, TKttkbutton, arg, ret, ttkbuttonopts, ttkbb, nelem(ttkbb));
}

char*
tkttkcheckbutton(TkTop *t, char *arg, char **ret)
{
	return ttkmake(t, TKttkcheckbutton, arg, ret, ttkcheckopts, ttkbb, nelem(ttkbb));
}

char*
tkttkradiobutton(TkTop *t, char *arg, char **ret)
{
	return ttkmake(t, TKttkradiobutton, arg, ret, ttkradioopts, ttkbb, nelem(ttkbb));
}

char*
tkttkseparator(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkName *names;
	TkOptab tko[3];
	TkTtk *d;

	tk = ttknewobj(t, TKttkseparator, nil);
	if(tk == nil)
		return TkNomem;
	d = TKobj(TkTtk, tk);
	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = d;
	tko[1].optab = ttksepopts;
	tko[2].ptr = nil;
	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	if(d->orient == Tkvertical){
		if((tk->flag & Tksetwidth) == 0) tk->req.width = 2;
	}else{
		if((tk->flag & Tksetheight) == 0) tk->req.height = 2;
	}
	e = tkaddchild(t, tk, &names);
	tkfreename(names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;
	return tkvalue(ret, "%s", tk->name->name);
}

/* ---- command tables ---- */

static TkCmdtab ttklabelcmd[] =
{
	"cget",		ttklblcget,
	"configure",	ttklblconf,
	"instate",	ttkinstatecmd,
	"state",	ttkstatecmd,
	"style",	ttkstylecmd,
	"identify",	ttkidentcmd,
	nil
};

static TkCmdtab ttkbuttoncmd[] =
{
	"cget",		ttkbtncget,
	"configure",	ttkbtnconf,
	"invoke",	ttkinvoke,
	"instate",	ttkinstatecmd,
	"state",	ttkstatecmd,
	"style",	ttkstylecmd,
	"identify",	ttkidentcmd,
	"tkttkEnter",	ttkcmdenter,
	"tkttkLeave",	ttkcmdleave,
	"tkttkPress",	ttkcmdpress,
	"tkttkRelease",	ttkcmdrelease,
	"tkttkKey",	ttkcmdkey,
	nil
};

static TkCmdtab ttkcheckcmd[] =
{
	"cget",		ttkchkcget,
	"configure",	ttkchkconf,
	"invoke",	ttkinvoke,
	"select",	ttkselect,
	"instate",	ttkinstatecmd,
	"state",	ttkstatecmd,
	"style",	ttkstylecmd,
	"identify",	ttkidentcmd,
	"tkttkEnter",	ttkcmdenter,
	"tkttkLeave",	ttkcmdleave,
	"tkttkPress",	ttkcmdpress,
	"tkttkRelease",	ttkcmdrelease,
	"tkttkKey",	ttkcmdkey,
	nil
};

static TkCmdtab ttkradiocmd[] =
{
	"cget",		ttkradcget,
	"configure",	ttkradconf,
	"invoke",	ttkinvoke,
	"select",	ttkselect,
	"instate",	ttkinstatecmd,
	"state",	ttkstatecmd,
	"style",	ttkstylecmd,
	"identify",	ttkidentcmd,
	"tkttkEnter",	ttkcmdenter,
	"tkttkLeave",	ttkcmdleave,
	"tkttkPress",	ttkcmdpress,
	"tkttkRelease",	ttkcmdrelease,
	"tkttkKey",	ttkcmdkey,
	nil
};

static TkCmdtab ttkframecmd[] =
{
	"cget",		ttkfrmcget,
	"configure",	ttkfrmconf,
	"instate",	ttkinstatecmd,
	"state",	ttkstatecmd,
	"style",	ttkstylecmd,
	nil
};

static TkCmdtab ttksepcmd[] =
{
	"cget",		ttksepcget,
	"configure",	ttksepconf,
	"instate",	ttkinstatecmd,
	"state",	ttkstatecmd,
	"style",	ttkstylecmd,
	nil
};

/* ---- method tables ---- */

TkMethod ttkframemethod = {
	"TFrame", ttkframecmd, ttkfree, ttkdrawframe,
	nil, nil, ttkframefocusorder
};

TkMethod ttklabelmethod = {
	"TLabel", ttklabelcmd, ttkfree, ttkdraw,
	nil, nil, nil, nil, nil, nil, nil, nil, ttkvarchanged
};

TkMethod ttkbuttonmethod = {
	"TButton", ttkbuttoncmd, ttkfree, ttkdraw,
	nil, nil, nil, nil, nil, nil, nil, nil, ttkvarchanged
};

TkMethod ttkcheckbuttonmethod = {
	"TCheckbutton", ttkcheckcmd, ttkfree, ttkdraw,
	nil, nil, nil, nil, nil, nil, nil, nil, ttkvarchanged
};

TkMethod ttkradiobuttonmethod = {
	"TRadiobutton", ttkradiocmd, ttkfree, ttkdraw,
	nil, nil, nil, nil, nil, nil, nil, nil, ttkvarchanged
};

TkMethod ttkseparatormethod = {
	"TSeparator", ttksepcmd, ttkfree, ttkdrawsep,
	nil, nil, nil
};
