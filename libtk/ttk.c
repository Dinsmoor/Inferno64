#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "tk.h"
#include "ttk.h"

/*
 * The ttk style engine: a named-style registry (kept per TkTop), a state
 * machine, option resolution with style inheritance, and the element
 * painters the ttk widgets draw with.  `ttk::style configure/map/lookup'
 * drives it from Limbo.  Defaults fall back to the themed TkEnv colour
 * slots, so the existing `theme' command themes ttk widgets too.
 *
 * Everything here is additive; no classic widget reaches this code.
 */

static struct { char *name; ulong bit; } statebits[] =
{
	{"active",	Sactive},
	{"disabled",	Sdisabled},
	{"focus",	Sfocus},
	{"pressed",	Spressed},
	{"selected",	Sselected},
	{"background",	Sbackground},
	{"alternate",	Salternate},
	{"invalid",	Sinvalid},
	{"readonly",	Sreadonly},
	{"hover",	Shover},
};

/* parse "active !disabled focus" into on/off masks; returns -1 on a bad name */
int
ttkstateparse(char *spec, ulong *onp, ulong *offp)
{
	char tok[64], *p;
	int i, neg, n;
	ulong on, off;

	on = off = 0;
	while(*spec != '\0'){
		while(*spec == ' ' || *spec == '\t')
			spec++;
		if(*spec == '\0')
			break;
		neg = 0;
		if(*spec == '!'){
			neg = 1;
			spec++;
		}
		p = tok;
		n = 0;
		while(*spec != '\0' && *spec != ' ' && *spec != '\t' && n < sizeof(tok)-1){
			*p++ = *spec++;
			n++;
		}
		*p = '\0';
		if(tok[0] == '\0')
			continue;
		for(i = 0; i < nelem(statebits); i++)
			if(strcmp(tok, statebits[i].name) == 0)
				break;
		if(i >= nelem(statebits))
			return -1;
		if(neg)
			off |= statebits[i].bit;
		else
			on |= statebits[i].bit;
	}
	*onp = on;
	*offp = off;
	return 0;
}

/* render the set bits of a state to a space-separated string */
char*
ttkstatestr(ulong state, char *buf, int len)
{
	int i, first;
	char *p, *e;

	p = buf;
	e = buf+len-1;
	first = 1;
	for(i = 0; i < nelem(statebits); i++){
		if((state & statebits[i].bit) == 0)
			continue;
		if(!first && p < e)
			*p++ = ' ';
		first = 0;
		p += snprint(p, e-p, "%s", statebits[i].name);
	}
	*p = '\0';
	return buf;
}

/* ---- style registry (per TkTop->ttk) ---- */

static Ttkstyle*
findstyle(TkTop *t, char *name)
{
	Ttkstyle *s;

	for(s = (Ttkstyle*)t->ttk; s != nil; s = s->link)
		if(strcmp(s->name, name) == 0)
			return s;
	return nil;
}

static Ttkstyle*
mkstyle(TkTop *t, char *name)
{
	Ttkstyle *s;

	s = findstyle(t, name);
	if(s != nil)
		return s;
	s = mallocz(sizeof(Ttkstyle), 1);
	if(s == nil)
		return nil;
	s->name = strdup(name);
	if(s->name == nil){
		free(s);
		return nil;
	}
	s->link = (Ttkstyle*)t->ttk;
	t->ttk = s;
	return s;
}

static void
setopt(Ttkstyle *s, char *name, char *val)
{
	Ttkopt *o;

	for(o = s->opts; o != nil; o = o->link)
		if(strcmp(o->name, name) == 0){
			free(o->val);
			o->val = strdup(val);
			return;
		}
	o = mallocz(sizeof(Ttkopt), 1);
	if(o == nil)
		return;
	o->name = strdup(name);
	o->val = strdup(val);
	o->link = s->opts;
	s->opts = o;
}

static Ttkmap*
findmap(Ttkstyle *s, char *name, int create)
{
	Ttkmap *m;

	for(m = s->maps; m != nil; m = m->link)
		if(strcmp(m->name, name) == 0)
			return m;
	if(!create)
		return nil;
	m = mallocz(sizeof(Ttkmap), 1);
	if(m == nil)
		return nil;
	m->name = strdup(name);
	m->link = s->maps;
	s->maps = m;
	return m;
}

static void
clearmap(Ttkmap *m)
{
	Ttkmapent *e, *next;

	for(e = m->ents; e != nil; e = next){
		next = e->link;
		free(e->val);
		free(e);
	}
	m->ents = nil;
}

/* resolve one option for a style + state, following dotted-prefix inheritance */
char*
ttkresolve(TkTop *t, char *style, char *opt, ulong state)
{
	Ttkstyle *s;
	Ttkmap *m;
	Ttkmapent *e;
	Ttkopt *o;
	char *cur;

	for(cur = style; cur != nil; ){
		s = findstyle(t, cur);
		if(s != nil){
			m = findmap(s, opt, 0);
			if(m != nil)
				for(e = m->ents; e != nil; e = e->link)
					if((state & e->on) == e->on && (state & e->off) == 0)
						return e->val;
			for(o = s->opts; o != nil; o = o->link)
				if(strcmp(o->name, opt) == 0)
					return o->val;
		}
		cur = strchr(cur, '.');
		if(cur != nil)
			cur++;
	}
	return nil;
}

/* the class-default style name for a ttk widget type */
static char*
classstyle(int type)
{
	switch(type){
	case TKttkframe:	return "TFrame";
	case TKttklabel:	return "TLabel";
	case TKttkbutton:	return "TButton";
	case TKttkcheckbutton:	return "TCheckbutton";
	case TKttkradiobutton:	return "TRadiobutton";
	case TKttkseparator:	return "TSeparator";
	case TKttksizegrip:	return "TSizegrip";
	case TKttknotebook:	return "TNotebook";
	case TKttkpanedwindow:	return "TPanedwindow";
	case TKttktreeview:	return "Treeview";
	case TKttkcombobox:	return "TCombobox";
	case TKttkspinbox:	return "TSpinbox";
	case TKttkmenubutton:	return "TMenubutton";
	}
	return "TFrame";
}

char*
ttkstylename(Tk *tk)
{
	TkTtk *d = TKobj(TkTtk, tk);

	if(d->style != nil && d->style[0] != '\0')
		return d->style;
	return classstyle(tk->type);
}

char*
ttkget(Tk *tk, char *opt)
{
	TkTtk *d = TKobj(TkTtk, tk);
	return ttkresolve(tk->env->top, ttkstylename(tk), opt, d->state);
}

int
ttkgetint(Tk *tk, char *opt, int dflt)
{
	char *s = ttkget(tk, opt);
	if(s == nil || s[0] == '\0')
		return dflt;
	return atoi(s);
}

/*
 * an Image* for a colour option of an explicit style+state, falling back to a
 * themed env slot.  Layout-agnostic: widgets that don't use the TkTtk struct
 * (entry/scale/scrollbar, which reuse a classic editing core) call this with
 * their own resolved style name and live state.
 */
Image*
ttkcolorx(Tk *tk, char *style, ulong state, char *opt, int fallbackslot)
{
	char *s;
	ulong pix;

	s = ttkresolve(tk->env->top, style, opt, state);
	if(s != nil && s[0] != '\0' && tkparsecolor(s, &pix) == nil)
		return tkcolor(tk->env->top->ctxt, pix);
	return tkgc(tk->env, fallbackslot);
}

/* an Image* for a colour option, falling back to a themed env slot */
Image*
ttkcolor(Tk *tk, char *opt, int fallbackslot)
{
	TkTtk *d = TKobj(TkTtk, tk);
	return ttkcolorx(tk, ttkstylename(tk), d->state, opt, fallbackslot);
}

/* ---- element painters ---- */

Image*
ttktmpimage(Tk *tk, Point size, ulong state)
{
	USED(state);
	return tkitmp(tk->env, size, TkCbackgnd);
}

/* fill the background of r in the style/state background colour */
void
ttkfillbg(Tk *tk, Image *i, Rectangle r, ulong state)
{
	int slot;

	slot = TkCbackgnd;
	if(state & Sdisabled)
		slot = TkCbackgnd;
	else if(state & Spressed)
		slot = TkCbackgnddark;
	else if(state & Sactive)
		slot = TkCactivebgnd;
	draw(i, r, ttkcolor(tk, "-background", slot), nil, ZP);
}

/* draw a flat themed border (the ttk default look) */
void
ttkborder(Tk *tk, Image *i, Rectangle r, ulong state)
{
	USED(state);
	if(tk->borderwidth <= 0)
		return;
	tkbox(i, r, tk->borderwidth, ttkcolor(tk, "-bordercolor", TkCbackgnddark));
}

/* a focus ring just inside r */
void
ttkfocusring(Tk *tk, Image *i, Rectangle r, ulong state)
{
	if((state & Sfocus) == 0)
		return;
	tkbox(i, insetrect(r, tk->borderwidth+1), 1, tkgc(tk->env, TkChighlightfgnd));
}

/* ---- widget base helpers ---- */

Tk*
ttknewobj(TkTop *t, int type, char *defstyle)
{
	Tk *tk;
	TkTtk *d;

	USED(defstyle);
	tk = tknewobj(t, type, sizeof(Tk)+sizeof(TkTtk));
	if(tk == nil)
		return nil;
	d = TKobj(TkTtk, tk);
	d->state = 0;
	d->ul = -1;
	d->anchor = Tkcenter;
	d->justify = Tkleft;
	d->pmaximum = 100*Tkfpscalar;
	d->length = 100;
	d->orient = Tkhorizontal;
	return tk;
}

void
ttkfreedata(Tk *tk)
{
	TkTtk *d = TKobj(TkTtk, tk);

	free(d->style);
	free(d->text);
	free(d->command);
	free(d->menu);
	free(d->value);
	free(d->onvalue);
	free(d->offvalue);
	if(d->textvar != nil){
		tkfreevar(tk->env->top, d->textvar, tk->flag & Tkswept);
		free(d->textvar);
	}
	if(d->variable != nil){
		tkfreevar(tk->env->top, d->variable, tk->flag & Tkswept);
		free(d->variable);
	}
}

/* apply a new state set, mirror disabled/active into Tk.flag, repaint */
void
ttksetstate(Tk *tk, ulong state)
{
	TkTtk *d = TKobj(TkTtk, tk);

	d->state = state;
	if(state & Sdisabled)
		tk->flag |= Tkdisabled;
	else
		tk->flag &= ~Tkdisabled;
	if(state & Sactive)
		tk->flag |= Tkactive;
	else
		tk->flag &= ~Tkactive;
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
}

/* build the spec that restores `old' given the new state (changed bits) */
char*
ttkrestorespec(ulong old, ulong new, char *buf, int len)
{
	int i, first;
	char *p, *e;
	ulong changed;

	changed = old ^ new;
	p = buf;
	e = buf+len-1;
	first = 1;
	for(i = 0; i < nelem(statebits); i++){
		if((changed & statebits[i].bit) == 0)
			continue;
		if(!first && p < e)
			*p++ = ' ';
		first = 0;
		/* to restore old: if the bit was set in old, name; else !name */
		if((old & statebits[i].bit) == 0 && p < e)
			*p++ = '!';
		p += snprint(p, e-p, "%s", statebits[i].name);
	}
	*p = '\0';
	return buf;
}

/*
 * The `state' subcommand, layout-agnostic: parse the spec in `arg', apply it
 * to *statep, mirror disabled/active into Tk.flag, repaint, and return the
 * spec that restores the previous state.  Empty arg => report current state.
 */
char*
ttkstateop(Tk *tk, ulong *statep, char *arg, char **ret)
{
	TkTop *t = tk->env->top;
	char *spec, *e;
	char buf[256];
	ulong on, off, new;

	spec = mallocz(Tkmaxitem, 0);
	if(spec == nil)
		return TkNomem;
	tkword(t, arg, spec, spec+Tkmaxitem, nil);

	if(spec[0] == '\0'){
		ttkstatestr(*statep, buf, sizeof(buf));
		free(spec);
		return tkvalue(ret, "%s", buf);
	}
	if(ttkstateparse(spec, &on, &off) < 0){
		free(spec);
		return TkBadvl;
	}
	new = (*statep | on) & ~off;
	ttkrestorespec(*statep, new, buf, sizeof(buf));
	*statep = new;
	if(new & Sdisabled)
		tk->flag |= Tkdisabled;
	else
		tk->flag &= ~Tkdisabled;
	if(new & Sactive)
		tk->flag |= Tkactive;
	else
		tk->flag &= ~Tkactive;
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	e = tkvalue(ret, "%s", buf);
	free(spec);
	return e;
}

/* the `instate' subcommand, against an already-resolved live state */
char*
ttkinstateop(Tk *tk, ulong state, char *arg, char **ret)
{
	TkTop *t = tk->env->top;
	char *spec, *script, *e;
	ulong on, off;
	int match;

	spec = mallocz(Tkmaxitem, 0);
	script = mallocz(Tkmaxitem, 0);
	if(spec == nil || script == nil){
		free(spec); free(script);
		return TkNomem;
	}
	arg = tkword(t, arg, spec, spec+Tkmaxitem, nil);
	tkword(t, arg, script, script+Tkmaxitem, nil);

	if(ttkstateparse(spec, &on, &off) < 0){
		free(spec); free(script);
		return TkBadvl;
	}
	match = (state & on) == on && (state & off) == 0;
	if(script[0] != '\0'){
		e = nil;
		if(match)
			e = tkexec(t, script, ret);
		free(spec); free(script);
		return e;
	}
	e = tkvalue(ret, "%d", match);
	free(spec); free(script);
	return e;
}

char*
ttkstatecmd(Tk *tk, char *arg, char **ret)
{
	TkTtk *d = TKobj(TkTtk, tk);
	return ttkstateop(tk, &d->state, arg, ret);
}

char*
ttkinstatecmd(Tk *tk, char *arg, char **ret)
{
	TkTtk *d = TKobj(TkTtk, tk);
	return ttkinstateop(tk, d->state, arg, ret);
}

char*
ttkstylecmd(Tk *tk, char *arg, char **ret)
{
	USED(arg);
	return tkvalue(ret, "%s", ttkstylename(tk));
}

char*
ttkidentcmd(Tk *tk, char *arg, char **ret)
{
	USED(tk);
	USED(arg);
	return tkvalue(ret, "");
}

void
ttkfreetop(TkTop *t)
{
	Ttkstyle *s, *nexts;
	Ttkopt *o, *nexto;
	Ttkmap *m, *nextm;

	for(s = (Ttkstyle*)t->ttk; s != nil; s = nexts){
		nexts = s->link;
		for(o = s->opts; o != nil; o = nexto){
			nexto = o->link;
			free(o->name);
			free(o->val);
			free(o);
		}
		for(m = s->maps; m != nil; m = nextm){
			nextm = m->link;
			clearmap(m);
			free(m->name);
			free(m);
		}
		free(s->name);
		free(s);
	}
	t->ttk = nil;
}

/* ---- the `ttk::style' command ---- */

static char*
stylemap(TkTop *t, Ttkstyle *s, char *opt, char *listbody)
{
	Ttkmap *m;
	Ttkmapent *e, **tail;
	char *spec, *val, *p;
	ulong on, off;

	spec = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(spec == nil || val == nil){
		free(spec); free(val);
		return TkNomem;
	}
	m = findmap(s, opt, 1);
	if(m == nil){
		free(spec); free(val);
		return TkNomem;
	}
	clearmap(m);
	tail = &m->ents;
	p = listbody;
	for(;;){
		p = tkword(t, p, spec, spec+Tkmaxitem, nil);
		if(spec[0] == '\0')
			break;
		p = tkword(t, p, val, val+Tkmaxitem, nil);
		if(ttkstateparse(spec, &on, &off) < 0)
			continue;
		e = mallocz(sizeof(Ttkmapent), 1);
		if(e == nil)
			break;
		e->on = on;
		e->off = off;
		e->val = strdup(val);
		e->link = nil;
		*tail = e;
		tail = &e->link;
	}
	free(spec);
	free(val);
	return nil;
}

char*
tkttkstyle(TkTop *t, char *arg, char **ret)
{
	Ttkstyle *s;
	Ttkopt *o;
	char *sub, *name, *opt, *val, *e, *fmt;

	sub = mallocz(Tkmaxitem, 0);
	name = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(sub == nil || name == nil || opt == nil || val == nil){
		free(sub); free(name); free(opt); free(val);
		return TkNomem;
	}
	e = nil;
	arg = tkword(t, arg, sub, sub+Tkmaxitem, nil);

	if(strcmp(sub, "configure") == 0){
		arg = tkword(t, arg, name, name+Tkmaxitem, nil);
		s = mkstyle(t, name);
		if(s == nil){ e = TkNomem; goto done; }
		if(*arg == '\0'){
			/* dump current settings */
			fmt = "%s %s";
			for(o = s->opts; o != nil; o = o->link){
				e = tkvalue(ret, fmt, o->name, o->val);
				if(e != nil) goto done;
				fmt = " %s %s";
			}
			goto done;
		}
		for(;;){
			arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
			if(opt[0] == '\0')
				break;
			arg = tkword(t, arg, val, val+Tkmaxitem, nil);
			setopt(s, opt, val);
		}
	}else if(strcmp(sub, "map") == 0){
		arg = tkword(t, arg, name, name+Tkmaxitem, nil);
		s = mkstyle(t, name);
		if(s == nil){ e = TkNomem; goto done; }
		for(;;){
			arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
			if(opt[0] == '\0')
				break;
			arg = tkword(t, arg, val, val+Tkmaxitem, nil);
			e = stylemap(t, s, opt, val);
			if(e != nil) goto done;
		}
	}else if(strcmp(sub, "lookup") == 0){
		ulong on, off, st;
		arg = tkword(t, arg, name, name+Tkmaxitem, nil);
		arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
		tkword(t, arg, val, val+Tkmaxitem, nil);
		st = 0;
		if(val[0] != '\0' && ttkstateparse(val, &on, &off) == 0)
			st = on;
		val[0] = '\0';
		{
			char *r = ttkresolve(t, name, opt, st);
			e = tkvalue(ret, "%s", r != nil ? r : "");
		}
	}else if(strcmp(sub, "theme") == 0){
		arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
		if(strcmp(opt, "names") == 0)
			e = tkvalue(ret, "default");
		else if(strcmp(opt, "use") == 0){
			tkword(t, arg, name, name+Tkmaxitem, nil);
			e = tkvalue(ret, "default");
		}else
			e = tkvalue(ret, "default");
	}else if(strcmp(sub, "element") == 0){
		arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
		if(strcmp(opt, "names") == 0)
			e = tkvalue(ret, "");
		else
			e = nil;	/* element create: accepted, no-op */
	}else
		e = TkBadcm;

done:
	free(sub); free(name); free(opt); free(val);
	return e;
}
