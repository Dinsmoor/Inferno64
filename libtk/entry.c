#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "keyboard.h"
#include "tk.h"
#include "ttk.h"

/* Widget Commands (+ means implemented)
	+bbox
	+cget
	+configure
	+delete
	+get
	+icursor
	+index
	 scan
	+selection
	+xview
	+see
*/

#define	O(t, e)		((long)(&((t*)0)->e))

#define CNTL(c) ((c)&0x1f)
#define DEL 0x7f

/* Layout constants */
enum {
	Entrypady	= 0,
	Entrypadx	= 0,
	Inswidth = 2,

	Ecursoron = 1<<0,
	Ecenter = 1<<1,
	Eright = 1<<2,
	Eleft = 1<<3,
	Ewordsel = 1<<4,

	Ejustify = Ecenter|Eleft|Eright
};

static TkStab tkjust[] =
{
	"left",	Eleft,
	"right",	Eright,
	"center",	Ecenter,
	nil
};

static
TkEbind b[] = 
{
	{TkKey,			"%W delete sel.first sel.last; %W insert insert {%A};%W see insert"},
	{TkKey|CNTL('a'),	"%W icursor 0;%W see insert;%W selection clear"},
	{TkKey|Home,		"%W icursor 0;%W see insert;%W selection clear"},
	{TkKey|CNTL('d'),	"%W delete insert; %W see insert"},
	{TkKey|CNTL('e'),    "%W icursor end; %W see insert;%W selection clear"},
	{TkKey|End,	     "%W icursor end; %W see insert;%W selection clear"},
	{TkKey|CNTL('h'),	"%W tkEntryBS;%W see insert"},
	{TkKey|CNTL('k'),	"%W delete insert end;%W see insert"},
	{TkKey|CNTL('u'),	"%W delete 0 end;%W see insert"},
	{TkKey|CNTL('w'),	"%W delete sel.first sel.last; %W tkEntryBW;%W see insert"},
	{TkKey|DEL,		"%W tkEntryBS 1;%W see insert"},
	{TkKey|CNTL('\\'),	"%W selection clear"},
	{TkKey|CNTL('/'),	"%W selection range 0 end"},
	{TkKey|Left,	"%W icursor insert-1;%W selection clear;%W selection from insert;%W see insert"},
	{TkKey|Right,	"%W icursor insert+1;%W selection clear;%W selection from insert;%W see insert"},
	{TkButton1P,		"focus %W; %W tkEntryB1P %X %Y"},
	{TkButton1P|TkMotion, 	"%W tkEntryB1M %X"},
	{TkButton1R,		"%W tkEntryB1R"},
	{TkButton1P|TkDouble,	"%W tkEntryB1P %X %Y;%W selection word @%x"},
	{TkButton2P,			"%W tkEntryB2P %x"},
	{TkButton2P|TkMotion,	"%W xview scroll %x scr"},
	{TkFocusin,		"%W tkEntryFocus in"},
	{TkFocusout,		"%W tkEntryFocus out"},
	{TkKey|APP|'\t',	""},
	{TkKey|BackTab,		""},
};

/* extra bindings layered on for ttk::spinbox: Up/Down step the value */
static TkEbind bspin[] =
{
	{TkKey|Up,	"%W tkSpinStep 1"},
	{TkKey|Down,	"%W tkSpinStep -1"},
};

typedef struct TkEntry TkEntry;
struct TkEntry
{
	Rune*	text;
	int		textlen;

	char*	xscroll;
	char*	show;
	int		flag;
	int		oldx;

	int		icursor;		/* index of insertion cursor */
	int		anchor;		/* selection anchor point */
	int		sel0;			/* index of start of selection */
	int		sel1;			/* index of end of selection */

	int		x0;			/* x-offset of visible area */

	/* derived values */
	int		v0;			/* index of first visible character */
	int		v1;			/* index of last visible character + 1 */
	int		xlen;			/* length of text in pixels*/
	int		xv0;			/* position of first visible character */
	int		xsel0;		/* position of start of selection */
	int		xsel1;		/* position of end of selection */
	int		xicursor;		/* position of insertion cursor */

	/* ttk (ttk::entry) extension; zero/nil for the classic entry */
	int		ttk;		/* 1 => themed chrome + state subcommands */
	ulong		tstate;		/* ttk S* state bits */
	char*		tstyle;		/* explicit -style, nil => "TEntry"/"TCombobox" */

	/* ttk::combobox extension; zero/nil unless combo */
	int		combo;		/* 1 => ttk::combobox (entry + dropdown) */
	char*		values;		/* raw -values list */
	char**		valv;		/* parsed -values */
	int		valc;
	int		curidx;		/* selected index in valv, -1 if none */

	/* ttk::spinbox extension; zero/nil unless spin (shares values/valv/curidx) */
	int		spin;		/* 1 => ttk::spinbox (entry + up/down spinners) */
	int		spinfrom;	/* fixed-point -from */
	int		spinto;		/* fixed-point -to */
	int		spininc;	/* fixed-point -increment */
	int		spinwrap;	/* -wrap: step past an end wraps round */
	char*		spincmd;	/* -command, run after each step */
};

static void blinkreset(Tk*);

static
TkOption opts[] =
{
	"xscrollcommand",	OPTtext,	O(TkEntry, xscroll),	nil,
	"justify",		OPTstab,	O(TkEntry, flag),	tkjust,
	"show",			OPTtext,	O(TkEntry, show),	nil,
	nil
};

/* ttk::entry shares the editing core but adds -style; selected when tke->ttk */
static
TkOption ttkopts[] =
{
	"xscrollcommand",	OPTtext,	O(TkEntry, xscroll),	nil,
	"justify",		OPTstab,	O(TkEntry, flag),	tkjust,
	"show",			OPTtext,	O(TkEntry, show),	nil,
	"style",		OPTtext,	O(TkEntry, tstyle),	nil,
	nil
};

/* ttk::combobox shares the editing core; adds -values to the ttk set */
static
TkOption comboopts[] =
{
	"xscrollcommand",	OPTtext,	O(TkEntry, xscroll),	nil,
	"justify",		OPTstab,	O(TkEntry, flag),	tkjust,
	"show",			OPTtext,	O(TkEntry, show),	nil,
	"style",		OPTtext,	O(TkEntry, tstyle),	nil,
	"values",		OPTtext,	O(TkEntry, values),	nil,
	nil
};

/* ttk::spinbox shares the editing core; adds the spinner range/list options */
static
TkOption spinopts[] =
{
	"xscrollcommand",	OPTtext,	O(TkEntry, xscroll),	nil,
	"justify",		OPTstab,	O(TkEntry, flag),	tkjust,
	"show",			OPTtext,	O(TkEntry, show),	nil,
	"style",		OPTtext,	O(TkEntry, tstyle),	nil,
	"values",		OPTtext,	O(TkEntry, values),	nil,
	"from",			OPTfrac,	O(TkEntry, spinfrom),	nil,
	"to",			OPTfrac,	O(TkEntry, spinto),	nil,
	"increment",		OPTfrac,	O(TkEntry, spininc),	nil,
	"wrap",			OPTstab,	O(TkEntry, spinwrap),	tkbool,
	"command",		OPTtext,	O(TkEntry, spincmd),	nil,
	nil
};

static TkOption*
entryopts(TkEntry *tke)
{
	if(tke->spin)
		return spinopts;
	if(tke->combo)
		return comboopts;
	return tke->ttk ? ttkopts : opts;
}

/* the resolved ttk style name for a themed entry */
static char*
ttkentrystylename(TkEntry *tke)
{
	if(tke->tstyle != nil && tke->tstyle[0] != '\0')
		return tke->tstyle;
	if(tke->spin)
		return "TSpinbox";
	return tke->combo ? "TCombobox" : "TEntry";
}

/* live ttk state: stored bits plus focus/disabled derived from Tk.flag */
static ulong
ttkentrystate(Tk *tk)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	ulong st = tke->tstate;

	if(tk->flag & Tkdisabled)
		st |= Sdisabled;
	if(tkhaskeyfocus(tk))
		st |= Sfocus;
	return st;
}

/* an Image* for a themed-entry colour option, falling back to an env slot */
static Image*
ttkentrycolor(Tk *tk, char *opt, int slot)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	char *s;
	ulong pix;

	s = ttkresolve(tk->env->top, ttkentrystylename(tke), opt, ttkentrystate(tk));
	if(s != nil && s[0] != '\0' && tkparsecolor(s, &pix) == nil)
		return tkcolor(tk->env->top->ctxt, pix);
	return tkgc(tk->env, slot);
}

static int
xinset(Tk *tk)
{
	return Entrypadx + tk->highlightwidth;
}

static int
yinset(Tk *tk)
{
	return Entrypady + tk->highlightwidth;
}

/* width of the arrow column (0 unless this is a combobox or spinbox) */
static int
arrowwidth(Tk *tk)
{
	TkEntry *tke = TKobj(TkEntry, tk);

	if(!tke->combo && !tke->spin)
		return 0;
	return tk->env->font->height + 4;
}

/* width available for text, after both insets and the arrow column */
static int
textavail(Tk *tk)
{
	return tk->act.width - 2*xinset(tk) - arrowwidth(tk);
}

static void
tksizeentry(Tk *tk)
{
	if((tk->flag & Tksetwidth) == 0)
		tk->req.width = tk->env->wzero*25 + 2*xinset(tk) + Inswidth + arrowwidth(tk);
	if((tk->flag & Tksetheight) == 0)
		tk->req.height = tk->env->font->height+ 2*yinset(tk);
}

int
entrytextwidth(Tk *tk, int n)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	Rune c;
	Font *f;

	f = tk->env->font;
	if (tke->show != nil) {
		chartorune(&c, tke->show);
		return n * runestringnwidth(f, &c, 1);
	}
	return runestringnwidth(f, tke->text, n);
}

static int
x2index(Tk *tk,  int x, int *xc)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	int t0, t1, r, q;

	t0 = 0;
	t1 = tke->textlen;
	while (t0 <= t1) {
		r = (t0 + t1) / 2;
		q = entrytextwidth(tk, r);
		if (q == x) {
			if (xc != nil)
				*xc = q;
			return r;
		}
		if (q < x)
			t0 = r + 1;
		else
			t1 = r - 1;
	}
	if (xc != nil)
		*xc = t1 > 0 ? entrytextwidth(tk, t1) : 0;
	if (t1 < 0)
		t1 = 0;
	return t1;
}

/*
 * recalculate derived values
 */
static void
recalcentry(Tk *tk)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	int x, avail, locked;

	locked = lockdisplay(tk->env->top->display);

	tke->xlen = entrytextwidth(tk, tke->textlen) + Inswidth;

	avail = textavail(tk);
	if (tke->xlen < avail) {
		switch(tke->flag & Ejustify) {
		default:
			tke->x0 = 0;
			break;
		case Eright:
			tke->x0 = -(avail - tke->xlen);
			break;
		case Ecenter:
			tke->x0 = -(avail - tke->xlen) / 2;
			break;
		}
	}

	tke->v0 = x2index(tk, tke->x0, &tke->xv0);
	tke->v1 = x2index(tk, tk->act.width - arrowwidth(tk) + tke->x0, &x);
	/* perhaps include partial last character */
	if (tke->v1 < tke->textlen && x < avail + tke->x0)
		tke->v1++;
	tke->xsel0 = entrytextwidth(tk, tke->sel0);
	tke->xsel1 = entrytextwidth(tk, tke->sel1);
	tke->xicursor = entrytextwidth(tk, tke->icursor);

	if (locked)
		unlockdisplay(tk->env->top->display);
}

/* (re)build tke->valv from the raw tke->values list */
static void
comboparsevalues(Tk *tk)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	TkTop *top = tk->env->top;
	char *p, *val;
	char **nv;
	int n, cap;

	for(n = 0; n < tke->valc; n++)
		free(tke->valv[n]);
	free(tke->valv);
	tke->valv = nil;
	tke->valc = 0;
	if(tke->values == nil)
		return;

	val = mallocz(Tkmaxitem, 0);
	if(val == nil)
		return;
	n = 0;
	cap = 0;
	nv = nil;
	p = tke->values;
	for(;;){
		p = tkword(top, p, val, val+Tkmaxitem, nil);
		if(val[0] == '\0')
			break;
		if(n >= cap){
			cap = cap ? cap*2 : 4;
			nv = realloc(nv, cap*sizeof(char*));
			if(nv == nil){
				free(val);
				return;
			}
		}
		nv[n++] = strdup(val);
	}
	free(val);
	tke->valv = nv;
	tke->valc = n;
}

/* replace the entry text with a UTF-8 string, bypassing the readonly gate */
static void
comboreplace(Tk *tk, char *s)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	Rune *rt;
	int n, i, locked;
	char *p;

	n = utflen(s);
	rt = mallocz((n+1)*sizeof(Rune), 0);
	if(rt == nil)
		return;
	p = s;
	for(i = 0; i < n; i++)
		p += chartorune(rt+i, p);
	free(tke->text);
	tke->text = rt;
	tke->textlen = n;
	tke->sel0 = tke->sel1 = 0;
	tke->icursor = n;
	tke->anchor = 0;
	tke->x0 = 0;
	locked = lockdisplay(tk->env->top->display);
	recalcentry(tk);
	if(locked)
		unlockdisplay(tk->env->top->display);
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
}

/* run a spinbox -command after a step (if any) */
static char*
spinrun(Tk *tk)
{
	TkEntry *tke = TKobj(TkEntry, tk);

	if(tke->spincmd != nil && tke->spincmd[0] != '\0')
		return tkexec(tk->env->top, tke->spincmd, nil);
	return nil;
}

/*
 * spinbox step: dir>0 increments, dir<0 decrements.  In -values mode it cycles
 * the list (wrapping iff -wrap); otherwise it steps the numeric value by
 * -increment, clamped to [-from,-to] (wrapping round iff -wrap).
 */
static char*
spinstep(Tk *tk, int dir)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	char buf[64], *p;
	int v, lo, hi, idx;

	if(tke->tstate & Sdisabled)
		return nil;

	if(tke->valc > 0){
		idx = tke->curidx;
		if(idx < 0)
			idx = (dir > 0) ? -1 : tke->valc;
		idx += dir;
		if(idx < 0)
			idx = tke->spinwrap ? tke->valc - 1 : 0;
		else if(idx >= tke->valc)
			idx = tke->spinwrap ? 0 : tke->valc - 1;
		tke->curidx = idx;
		comboreplace(tk, tke->valv[idx]);
		return spinrun(tk);
	}

	lo = tke->spinfrom;
	hi = tke->spinto;
	buf[0] = '\0';
	if(tke->text != nil)
		snprint(buf, sizeof(buf), "%.*S", tke->textlen, tke->text);
	p = buf;
	if(buf[0] == '\0' || tkfrac(&p, &v, nil) != nil)
		v = lo;
	v += dir * tke->spininc;
	if(hi >= lo){
		if(v < lo)
			v = tke->spinwrap ? hi : lo;
		else if(v > hi)
			v = tke->spinwrap ? lo : hi;
	}
	tkfprint(buf, v);
	comboreplace(tk, buf);
	return spinrun(tk);
}

static char*
entrymake(TkTop *t, char *arg, char **ret, int mode)
{
	Tk *tk;
	char *e;
	TkName *names;
	TkEntry *tke;
	TkOptab tko[3];
	int ttk, combo, spin, type;

	ttk = (mode >= 1);
	combo = (mode == 2);
	spin = (mode == 3);
	type = spin ? TKttkspinbox :
		combo ? TKttkcombobox : (ttk ? TKttkentry : TKentry);

	tk = tknewobj(t, type, sizeof(Tk)+sizeof(TkEntry));
	if(tk == nil)
		return TkNomem;

	tk->flag |= Tktakefocus;
	tke = TKobj(TkEntry, tk);
	tke->ttk = ttk;
	tke->combo = combo;
	tke->curidx = -1;
	tke->spin = spin;
	if(spin)
		tke->spininc = TKI2F(1);	/* Tk default -increment */
	if(ttk){
		/* themed chrome: flat border + focus ring, no 3D relief/highlight */
		tk->relief = TKflat;
		tk->borderwidth = 1;
		tk->highlightwidth = 0;
	}else{
		tk->relief = TKsunken;
		tk->borderwidth = 1;
		tk->highlightwidth = 1;
	}

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tke;
	tko[1].optab = entryopts(tke);
	tko[2].ptr = nil;

	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}
	if(combo || spin)
		comboparsevalues(tk);
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));
	tksizeentry(tk);
	e = tkbindings(t, tk, b, nelem(b));
	if(e == nil && spin)
		e = tkbindings(t, tk, bspin, nelem(bspin));

	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}

	e = tkaddchild(t, tk, &names);
	tkfreename(names);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;
	recalcentry(tk);

	return tkvalue(ret, "%s", tk->name->name);
}

char*
tkentry(TkTop *t, char *arg, char **ret)
{
	return entrymake(t, arg, ret, 0);
}

char*
tkttkcombobox(TkTop *t, char *arg, char **ret)
{
	return entrymake(t, arg, ret, 2);
}

char*
tkttkentry(TkTop *t, char *arg, char **ret)
{
	return entrymake(t, arg, ret, 1);
}

char*
tkttkspinbox(TkTop *t, char *arg, char **ret)
{
	return entrymake(t, arg, ret, 3);
}

static char*
tkentrycget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[3];
	TkEntry *tke = TKobj(TkEntry, tk);

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tke;
	tko[1].optab = entryopts(tke);
	tko[2].ptr = nil;

	return tkgencget(tko, arg, val, tk->env->top);
}

void
tkfreeentry(Tk *tk)
{
	TkEntry *tke = TKobj(TkEntry, tk);

	int i;

	free(tke->xscroll);
	free(tke->text);
	free(tke->show);
	free(tke->tstyle);
	free(tke->values);
	free(tke->spincmd);
	for(i = 0; i < tke->valc; i++)
		free(tke->valv[i]);
	free(tke->valv);
}

static void
tkentrytext(Image *i, Rectangle s, Tk *tk, TkEnv *env)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	Point dp;
	int s0, s1, xs0, xs1, j;
	Rectangle r;
	Rune showr, *text;

	dp = Pt(s.min.x - (tke->x0 - tke->xv0), s.min.y);
	if (tke->show) {
		chartorune(&showr, tke->show);
		text = mallocz(sizeof(Rune) * (tke->textlen+1), 0);
		if (text == nil)
			return;
		for (j = 0; j < tke->textlen; j++)
			text[j] = showr;
	} else
		text = tke->text;

	runestringn(i, dp, tkgc(env, TkCforegnd), dp, env->font,
				text+tke->v0, tke->v1-tke->v0);

	if (tke->sel0 < tke->v1 && tke->sel1 > tke->v0) {
		if (tke->sel0 < tke->v0) {
			s0 = tke->v0;
			xs0 = tke->xv0 - tke->x0;
		} else {
			s0 = tke->sel0;
			xs0 = tke->xsel0 - tke->x0;
		}

		if (tke->sel1 > tke->v1) {
			s1 = tke->v1;
			xs1 = s.max.x;
		} else {
			s1 = tke->sel1;
			xs1 = tke->xsel1 - tke->x0;
		}

		r = rectaddpt(Rect(xs0, 0, xs1, env->font->height), s.min);
		tktextsdraw(i, r, env, 1);
		runestringn(i, r.min, tkgc(env, TkCselectfgnd), r.min, env->font,
				text+s0, s1-s0);
	}

	if((tke->flag&Ecursoron) && tke->icursor >= tke->v0 && tke->icursor <= tke->v1) {
		r = Rect(
			tke->xicursor - tke->x0, 0, 
			tke->xicursor - tke->x0 + Inswidth, env->font->height
		);
		draw(i, rectaddpt(r, s.min), tkgc(env, TkCforegnd), nil, ZP);
	}
	if (tke->show)
		free(text);
}

char*
tkdrawentry(Tk *tk, Point orig)
{
	Point p;
	TkEnv *env;
	Rectangle r, s;
	Image *i;
	int xp, yp;
	TkEntry *tke;

	env = tk->env;

	r.min = ZP;
	r.max.x = tk->act.width + 2*tk->borderwidth;
	r.max.y = tk->act.height + 2*tk->borderwidth;
	i = tkitmp(env, r.max, TkCbackgnd);
	if(i == nil)
		return nil;

	tke = TKobj(TkEntry, tk);
	if(tke->ttk)	/* themed field background under the text */
		draw(i, r, ttkentrycolor(tk, "-fieldbackground", TkCbackgnd), nil, ZP);

	xp = tk->borderwidth + xinset(tk);
	yp = tk->borderwidth + yinset(tk);
	s = r;
	s.min.x += xp;
	s.max.x -= xp + arrowwidth(tk);
	s.min.y += yp;
	s.max.y -= yp;
	tkentrytext(i, s, tk, env);

	/* combobox dropdown arrow / spinbox up-down arrows, in the right column */
	if(tke->combo || tke->spin){
		Rectangle ar;
		Point a[3];
		Image *col;
		ulong st = ttkentrystate(tk);
		int cx, cy, sz;

		ar.min.x = r.max.x - tk->borderwidth - arrowwidth(tk);
		ar.min.y = r.min.y + tk->borderwidth;
		ar.max.x = r.max.x - tk->borderwidth;
		ar.max.y = r.max.y - tk->borderwidth;
		draw(i, ar, ttkentrycolor(tk, "-background", TkCbackgnd), nil, ZP);
		tkbox(i, ar, 1, ttkentrycolor(tk, "-bordercolor", TkCbackgnddark));
		col = (st & Sdisabled) ? tkgc(env, TkCdisablefgnd) : tkgc(env, TkCforegnd);
		sz = env->font->height/3;
		if(sz < 2)
			sz = 2;
		cx = (ar.min.x + ar.max.x)/2;
		if(tke->combo){
			cy = (ar.min.y + ar.max.y)/2;
			a[0] = Pt(cx - sz, cy - sz/2);
			a[1] = Pt(cx + sz, cy - sz/2);
			a[2] = Pt(cx, cy + sz/2 + 1);
			fillpoly(i, a, 3, ~0, col, a[0]);
		}else{
			/* spinbox: an up triangle in the top half, down in the bottom */
			int qh = (ar.max.y - ar.min.y)/4;
			cy = ar.min.y + qh + 1;
			a[0] = Pt(cx, cy - sz/2);
			a[1] = Pt(cx - sz, cy + sz/2 + 1);
			a[2] = Pt(cx + sz, cy + sz/2 + 1);
			fillpoly(i, a, 3, ~0, col, a[0]);
			{	/* a 1px divider between the up and down halves */
				Rectangle dv;
				dv.min.x = ar.min.x;
				dv.min.y = (ar.min.y + ar.max.y)/2;
				dv.max.x = ar.max.x;
				dv.max.y = dv.min.y + 1;
				draw(i, dv, ttkentrycolor(tk, "-bordercolor", TkCbackgnddark), nil, ZP);
			}
			cy = ar.max.y - qh - 1;
			a[0] = Pt(cx - sz, cy - sz/2);
			a[1] = Pt(cx + sz, cy - sz/2);
			a[2] = Pt(cx, cy + sz/2 + 1);
			fillpoly(i, a, 3, ~0, col, a[0]);
		}
	}

	if(tke->ttk){
		ulong st = ttkentrystate(tk);
		if(tk->borderwidth > 0)
			tkbox(i, r, tk->borderwidth,
				ttkentrycolor(tk, "-bordercolor", TkCbackgnddark));
		if(st & Sfocus)
			tkbox(i, insetrect(r, tk->borderwidth+1), 1,
				tkgc(env, TkChighlightfgnd));
	}else{
		tkdrawrelief(i, tk, ZP, TkCbackgnd, tk->relief);
		if (tkhaskeyfocus(tk))
			tkbox(i, insetrect(r, tk->borderwidth), tk->highlightwidth, tkgc(tk->env, TkChighlightfgnd));
	}

	p.x = tk->act.x + orig.x;
	p.y = tk->act.y + orig.y;
	r = rectaddpt(r, p);
	draw(tkimageof(tk), r, i, nil, ZP);

	return nil;
}
	
char*
tkentrysh(Tk *tk)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	int dx, top, bot;
	char *val, *cmd, *v, *e;

	if(tke->xscroll == nil)
		return nil;

	bot = 0;
	top = Tkfpscalar;

	if(tke->text != 0 && tke->textlen != 0) {
		dx = textavail(tk);

		if (tke->xlen > dx) {
			bot = TKI2F(tke->x0) / tke->xlen;
			top = TKI2F(tke->x0 + dx) / tke->xlen;
		}
	}

	val = mallocz(Tkminitem, 0);
	if(val == nil)
		return TkNomem;
	v = tkfprint(val, bot);
	*v++ = ' ';
	tkfprint(v, top);
	cmd = mallocz(Tkminitem, 0);
	if(cmd == nil) {
		free(val);
		return TkNomem;
	}
	sprint(cmd, "%s %s", tke->xscroll, val);
	e = tkexec(tk->env->top, cmd, nil);
	free(cmd);
	free(val);
	return e;
}

void
tkentrygeom(Tk *tk)
{
	char *e;
	e = tkentrysh(tk);
	if ((e != nil) &&	/* XXX - Tad: should propagate not print */
             (tk->name != nil))
		print("tk: xscrollcommand \"%s\": %s\n", tk->name->name, e);
	recalcentry(tk);
}

static char*
tkentryconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[3];
	TkEntry *tke = TKobj(TkEntry, tk);

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tke;
	tko[1].optab = entryopts(tke);
	tko[2].ptr = nil;

	if(*arg == '\0')
		return tkconflist(tko, val);

	bd = tk->borderwidth;
	g = tk->req;
	e = tkparse(tk->env->top, arg, tko, nil);
	if(tke->combo || tke->spin)
		comboparsevalues(tk);
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));
	tksizeentry(tk);
	tkgeomchg(tk, &g, bd);
	recalcentry(tk);
	tk->dirty = tkrect(tk, 1);
	return e;
}

static char*
tkentryparseindex(Tk *tk, char *buf, int *index)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	TkEnv *env;
	char *mod;
	int i, x, locked, modstart;

	modstart = 0;
	for(mod = buf; *mod != '\0'; mod++)
		if(*mod == '-' || *mod == '+') {
			modstart = *mod;
			*mod = '\0';
			break;
		}
	if(strcmp(buf, "end") == 0)
		i = tke->textlen;
	else
	if(strcmp(buf, "anchor") == 0)
		i = tke->anchor;
	else
	if(strcmp(buf, "insert") == 0)
		i = tke->icursor;
	else
	if(strcmp(buf, "sel.first") == 0)
		i = tke->sel0;
	else
	if(strcmp(buf, "sel.last") == 0)
		i = tke->sel1;
	else
	if(buf[0] >= '0' && buf[0] <= '9')
		i = atoi(buf);
	else
	if(buf[0] == '@') {
		x = atoi(buf+1) - xinset(tk);
		if(tke->textlen == 0) {
			*index = 0;
			return nil;
		}
		env = tk->env;
		locked = lockdisplay(env->top->display);
		i = x2index(tk, x + tke->x0, nil);	/* XXX could possibly select nearest character? */
		if(locked)
			unlockdisplay(env->top->display);
	}
	else
		return TkBadix;

	if(i < 0 || i > tke->textlen)
		return TkBadix;
	if(modstart) {
		*mod = modstart;
		i += atoi(mod);
		if(i < 0)
			i = 0;
		if(i > tke->textlen)
			i = tke->textlen;
	}
	*index = i;
	return nil;
}

/*
 * return bounding box of character at index, in coords relative to
 * the top left position of the text.
 */
static Rectangle
tkentrybbox(Tk *tk, int index)
{
	TkEntry *tke;
	TkEnv *env;
	Display *d;
	int x, cw, locked;
	Rectangle r;

	tke = TKobj(TkEntry, tk);
	env = tk->env;

	d = env->top->display;

	locked = lockdisplay(d);
	x = entrytextwidth(tk, index);
	if (index < tke->textlen)
		cw = entrytextwidth(tk, index+1) - x;
	else
		cw = Inswidth;
	if(locked)
		unlockdisplay(d);

	r.min.x = x;
	r.min.y = 0;
	r.max.x = x + cw;
	r.max.y = env->font->height;
	return r;
}

static void
tkentrysee(Tk *tk, int index, int jump)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	int dx, margin;
	Rectangle r;

	r = tkentrybbox(tk, index);
	dx = textavail(tk);
	if (jump)
		margin = dx / 4;
	else
		margin = 0;
	if (r.min.x <= tke->x0 || r.max.x > tke->x0 + dx) {
		if (r.min.x <= tke->x0) {
			tke->x0 = r.min.x - margin;
			if (tke->x0 < 0)
				tke->x0 = 0;
		} else if (r.max.x >= tke->x0 + dx) {
			tke->x0 = r.max.x - dx + margin;
			if (tke->x0 > tke->xlen - dx)
				tke->x0 = tke->xlen - dx;
		}
		tk->dirty = tkrect(tk, 0);
	}
	r = rectaddpt(r, Pt(xinset(tk) - tke->x0, yinset(tk)));
	tksee(tk, r, r.min);
}

static char*
tkentryseecmd(Tk *tk, char *arg, char **val)
{
	int index;
	char *e, *buf;

	USED(val);

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(tk->env->top, arg, buf, buf+Tkmaxitem, nil);
	e = tkentryparseindex(tk, buf, &index);
	free(buf);
	if(e != nil)
		return e;

	tkentrysee(tk, index, 1);
	recalcentry(tk);
	
	return nil;
}

static char*
tkentrybboxcmd(Tk *tk, char *arg, char **val)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	char *r, *buf;
	int index;
	Rectangle bbox;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(tk->env->top, arg, buf, buf+Tkmaxitem, nil);
	r = tkentryparseindex(tk, buf, &index);
	free(buf);
	if(r != nil)
		return r;
	bbox = rectaddpt(tkentrybbox(tk, index), Pt(xinset(tk) - tke->x0, yinset(tk)));
	return tkvalue(val, "%d %d %d %d", bbox.min.x, bbox.min.y, bbox.max.x, bbox.max.y);
}

static char*
tkentryindex(Tk *tk, char *arg, char **val)
{
	int index;
	char *r, *buf;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(tk->env->top, arg, buf, buf+Tkmaxitem, nil);
	r = tkentryparseindex(tk, buf, &index);
	free(buf);
	if(r != nil)
		return r;
	return tkvalue(val, "%d", index);
}

static char*
tkentryicursor(Tk *tk, char *arg, char **val)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	int index, locked;
	char *r, *buf;

	USED(val);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(tk->env->top, arg, buf, buf+Tkmaxitem, nil);
	r = tkentryparseindex(tk, buf, &index);
	free(buf);
	if(r != nil)
		return r;
	tke->icursor = index;
	locked = lockdisplay(tk->env->top->display);
	tke->xicursor = entrytextwidth(tk, tke->icursor);
	if (locked)
		unlockdisplay(tk->env->top->display);

	blinkreset(tk);
	tk->dirty = tkrect(tk, 1);
	return nil;
}

static int
adjustforins(int i, int n, int q)
{
	if (i <= q)
		q += n;
	return q;
}

static int
adjustfordel(int d0, int d1, int q)
{
	if (d1 <= q)
		q -= d1 - d0;
	else if (d0 <= q && q <= d1)
		q = d0;
	return q;
}

static char*
tkentryget(Tk *tk, char *arg, char **val)
{
	TkTop *top;
	TkEntry *tke;
	int first, last;
	char *e, *buf;

	tke = TKobj(TkEntry, tk);	
	if(tke->text == nil)
		return nil;

	arg = tkskip(arg, " \t");
	if(*arg == '\0')
		return tkvalue(val, "%.*S", tke->textlen, tke->text);

	top = tk->env->top;
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
	e = tkentryparseindex(tk, buf, &first);
	if(e != nil) {
		free(buf);
		return e;
	}
	last = first+1;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	if(buf[0] != '\0') {
		e = tkentryparseindex(tk, buf, &last);
		if(e != nil) {
			free(buf);
			return e;
		}
	}
	free(buf);
	if(last <= first || tke->textlen == 0 || first == tke->textlen)
		return tkvalue(val, "%S", L"");
	return tkvalue(val, "%.*S", last-first, tke->text+first);
}

static char*
tkentryinsert(Tk *tk, char *arg, char **val)
{
	TkTop *top;
	TkEntry *tke;
	int ins, i, n, locked;
	char *e, *t, *text, *buf;
	Rune *etext;

	USED(val);
	tke = TKobj(TkEntry, tk);
	if(tke->ttk && (tke->tstate & (Sdisabled|Sreadonly)))
		return nil;

	top = tk->env->top;
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
	e = tkentryparseindex(tk, buf, &ins);
	free(buf);
	if(e != nil)
		return e;

	if(*arg == '\0')
		return nil;

	n = strlen(arg) + 1;
	if(n < Tkmaxitem)
		n = Tkmaxitem;
	text = malloc(n);
	if(text == nil)
		return TkNomem;

	tkword(top, arg, text, text+n, nil);
	n = utflen(text);
	etext = realloc(tke->text, (tke->textlen+n+1)*sizeof(Rune));
	if(etext == nil) {
		free(text);
		return TkNomem;
	}
	tke->text = etext;

	memmove(tke->text+ins+n, tke->text+ins, (tke->textlen-ins)*sizeof(Rune));
	t = text;
	for(i=0; i<n; i++)
		t += chartorune(tke->text+ins+i, t);
	free(text);

	tke->textlen += n;

	tke->sel0 = adjustforins(ins, n, tke->sel0);
	tke->sel1 = adjustforins(ins, n, tke->sel1);
	tke->icursor = adjustforins(ins, n, tke->icursor);
	tke->anchor = adjustforins(ins, n, tke->anchor);

	locked = lockdisplay(tk->env->top->display);
	if (ins < tke->v0)
		tke->x0 += entrytextwidth(tk, tke->v0 + n) + (tke->x0 - tke->xv0);
	if (locked)
		unlockdisplay(tk->env->top->display);
	recalcentry(tk);

	e = tkentrysh(tk);
	blinkreset(tk);
	tk->dirty = tkrect(tk, 1);

	return e;
}

static char*
tkentrydelete(Tk *tk, char *arg, char **val)
{
	TkTop *top;
	TkEntry *tke;
	int d0, d1, locked;
	char *e, *buf;
	Rune *text;

	USED(val);

	tke = TKobj(TkEntry, tk);
	if(tke->ttk && (tke->tstate & (Sdisabled|Sreadonly)))
		return nil;

	top = tk->env->top;
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
	e = tkentryparseindex(tk, buf, &d0);
	if(e != nil) {
		free(buf);
		return e;
	}

	d1 = d0+1;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	if(buf[0] != '\0') {
		e = tkentryparseindex(tk, buf, &d1);
		if(e != nil) {
			free(buf);
			return e;
		}
	}
	free(buf);
	if(d1 <= d0 || tke->textlen == 0 || d0 >= tke->textlen)
		return nil;

	memmove(tke->text+d0, tke->text+d1, (tke->textlen-d1)*sizeof(Rune));
	tke->textlen -= d1 - d0;

	text = realloc(tke->text, (tke->textlen+1) * sizeof(Rune));
	if (text != nil)
		tke->text = text;
	tke->sel0 = adjustfordel(d0, d1, tke->sel0);
	tke->sel1 = adjustfordel(d0, d1, tke->sel1);
	tke->icursor = adjustfordel(d0, d1, tke->icursor);
	tke->anchor = adjustfordel(d0, d1, tke->anchor);

	locked = lockdisplay(tk->env->top->display);
	if (d1 < tke->v0)
		tke->x0 = entrytextwidth(tk, tke->v0 - (d1 - d0)) + (tke->x0 - tke->xv0);
	else if (d0 < tke->v0)
		tke->x0 = entrytextwidth(tk, d0);
	if (locked)
		unlockdisplay(tk->env->top->display);
	recalcentry(tk);

	e = tkentrysh(tk);
	blinkreset(tk);
	tk->dirty = tkrect(tk, 1);

	return e;
}

/*	Used for both backspace and DEL.  If a selection exists, delete it.
 *	Otherwise delete the character to the left(right) of the insertion
 *	cursor, if any.
 */
static char*
tkentrybs(Tk *tk, char *arg, char **val)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	char *buf, *e;
	int ix;

	USED(val);
	USED(arg);

	if(tke->textlen == 0)
		return nil;

	if(tke->sel0 < tke->sel1)
		return tkentrydelete(tk, "sel.first sel.last", nil);

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(tk->env->top, arg, buf, buf+Tkmaxitem, nil);
	ix = -1;
	if(buf[0] != '\0') {
		e = tkentryparseindex(tk, buf, &ix);
		if(e != nil) {
			free(buf);
			return e;
		}
	}
	if(ix > -1) {			/* DEL */
		if(tke->icursor >= tke->textlen) {
			free(buf);
			return nil;
		}
	}
	else {				/* backspace */
		if(tke->icursor == 0) {
			free(buf);
			return nil;
		}
		tke->icursor--;
	}
	snprint(buf, Tkmaxitem, "%d", tke->icursor);
	e = tkentrydelete(tk, buf, nil);
	free(buf);
	return e;
}

static char*
tkentrybw(Tk *tk, char *arg, char **val)
{
	int start;
	Rune *text;
	TkEntry *tke;
	char buf[32];

	USED(val);
	USED(arg);

	tke = TKobj(TkEntry, tk);
	if(tke->textlen == 0 || tke->icursor == 0)
		return nil;

	text = tke->text;
	start = tke->icursor-1;
	while(start > 0 && !tkiswordchar(text[start]))
		--start;
	while(start > 0 && tkiswordchar(text[start-1]))
		--start;

	snprint(buf, sizeof(buf), "%d %d", start, tke->icursor);
	return tkentrydelete(tk, buf, nil);
}

char*
tkentryselect(Tk *tk, char *arg, char **val)
{
	TkTop *top;
	int start, from, to, locked;
	TkEntry *tke;
	char *e, *buf;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;

	tke = TKobj(TkEntry, tk);

	top = tk->env->top;
	arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
	if(strcmp(buf, "clear") == 0) {
		tke->sel0 = 0;
		tke->sel1 = 0;
	}
	else
	if(strcmp(buf, "from") == 0) {
		tkword(top, arg, buf, buf+Tkmaxitem, nil);
		e = tkentryparseindex(tk, buf, &tke->anchor);
		tke->flag &= ~Ewordsel;
		free(buf);
		return e;
	}
	else
	if(strcmp(buf, "to") == 0) {
		tkword(top, arg, buf, buf+Tkmaxitem, nil);
		e = tkentryparseindex(tk, buf, &to);
		if(e != nil) {
			free(buf);
			return e;
		}
		
		if(to < tke->anchor) {
			if(tke->flag & Ewordsel)
				while(to > 0 && tkiswordchar(tke->text[to-1]))
					--to;
			tke->sel0 = to;
			tke->sel1 = tke->anchor;
		}
		else
		if(to >= tke->anchor) {
			if(tke->flag & Ewordsel)
				while(to < tke->textlen &&
						tkiswordchar(tke->text[to]))
					to++;
			tke->sel0 = tke->anchor;
			tke->sel1 = to;
		}
		tkentrysee(tk, to, 0);
		recalcentry(tk);
	}
	else
	if(strcmp(buf, "word") == 0) {	/* inferno invention */
		tkword(top, arg, buf, buf+Tkmaxitem, nil);
		e = tkentryparseindex(tk, buf, &start);
		if(e != nil) {
			free(buf);
			return e;
		}
		from = start;
		while(from > 0 && tkiswordchar(tke->text[from-1]))
			--from;
		to = start;
		while(to < tke->textlen && tkiswordchar(tke->text[to]))
			to++;
		tke->sel0 = from;
		tke->sel1 = to;
		tke->anchor = from;
		tke->icursor = from;
		tke->flag |= Ewordsel;
		locked = lockdisplay(tk->env->top->display);
		tke->xicursor = entrytextwidth(tk, tke->icursor);
		if (locked)
			unlockdisplay(tk->env->top->display);
	}
	else
	if(strcmp(buf, "present") == 0) {
		e = tkvalue(val, "%d", tke->sel1 > tke->sel0);
		free(buf);
		return e;
	}
	else
	if(strcmp(buf, "range") == 0) {
		arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
		e = tkentryparseindex(tk, buf, &from);
		if(e != nil) {
			free(buf);
			return e;
		}
		tkword(top, arg, buf, buf+Tkmaxitem, nil);
		e = tkentryparseindex(tk, buf, &to);
		if(e != nil) {
			free(buf);
			return e;
		}
		tke->sel0 = from;
		tke->sel1 = to;
		if(to <= from) {
			tke->sel0 = 0;
			tke->sel1 = 0;
		}
	}
	else
	if(strcmp(buf, "adjust") == 0) {
		tkword(top, arg, buf, buf+Tkmaxitem, nil);
		e = tkentryparseindex(tk, buf, &to);
		if(e != nil) {
			free(buf);
			return e;
		}
		if(tke->sel0 == 0 && tke->sel1 == 0) {
			tke->sel0 = tke->anchor;
			tke->sel1 = to;
		}
		else {
			if(abs(tke->sel0-to) < abs(tke->sel1-to)) {
				tke->sel0 = to;
				tke->anchor = tke->sel1;
			}
			else {
				tke->sel1 = to;
				tke->anchor = tke->sel0;
			}
		}
		if(tke->sel0 > tke->sel1) {
			to = tke->sel0;
			tke->sel0 = tke->sel1;
			tke->sel1 = to;
		}
	}
	else {
		free(buf);
		return TkBadcm;
	}
	locked = lockdisplay(tk->env->top->display);
	tke->xsel0 = entrytextwidth(tk, tke->sel0);
	tke->xsel1 = entrytextwidth(tk, tke->sel1);
	if (locked)
		unlockdisplay(tk->env->top->display);
	tk->dirty = tkrect(tk, 1);
	free(buf);
	return nil;
}


static char*
tkentryb2p(Tk *tk, char *arg, char **val)
{
	TkEntry *tke;
	char *buf;

	USED(val);

	tke = TKobj(TkEntry, tk);
	buf = malloc(Tkmaxitem);
	if (buf == nil)
		return TkNomem;

	tkword(tk->env->top, arg, buf, buf+Tkmaxitem, nil);
	tke->oldx = atoi(buf);
	return nil;
}

static char*
tkentryxview(Tk *tk, char *arg, char **val)
{
	int locked;
	TkEnv *env;
	TkEntry *tke;
	char *buf, *v;
	int dx, top, bot, amount, ix, x;
	char *e;

	tke = TKobj(TkEntry, tk);
	env = tk->env;
	dx = textavail(tk);

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;

	if(*arg == '\0') {
		if (tke->textlen == 0 || tke->xlen < dx) {
			bot = TKI2F(0);
			top = TKI2F(1);
		} else {
			bot = TKI2F(tke->x0) / tke->xlen;
			top = TKI2F(tke->x0 + dx) / tke->xlen;
		}
		v = tkfprint(buf, bot);
		*v++ = ' ';
		tkfprint(v, top);
		e = tkvalue(val, "%s", buf);
		free(buf);
		return e;
	}

	arg = tkitem(buf, arg);
	if(strcmp(buf, "moveto") == 0) {
		e = tkfracword(env->top, &arg, &top, nil);
		if (e != nil) {
			free(buf);
			return e;
		}
		tke->x0 = TKF2I(top*tke->xlen);
	}
	else
	if(strcmp(buf, "scroll") == 0) {
		arg = tkitem(buf, arg);
		amount = atoi(buf);
		if(*arg == 'p')		/* Pages */
			amount *= (9*tke->xlen)/10;
		else
		if(*arg == 's') {		/* Inferno-ism, "scr", must be used in the context of button2p */
			x = amount;
			amount = x < tke->oldx ? env->wzero : (x > tke->oldx ? -env->wzero : 0);
			tke->oldx = x;
		}
		tke->x0 += amount;
	}
	else {
		e = tkentryparseindex(tk, buf, &ix);
		if(e != nil) {
			free(buf);
			return e;
		}
		locked = lockdisplay(env->top->display);
		tke->x0 = entrytextwidth(tk, ix);
		if (locked)
			unlockdisplay(env->top->display);
	}
	free(buf);

	if (tke->x0 > tke->xlen - dx)
		tke->x0 = tke->xlen - dx;
	if (tke->x0 < 0)
		tke->x0 = 0;
	recalcentry(tk);
	e = tkentrysh(tk);
	blinkreset(tk);
	tk->dirty = tkrect(tk, 1);
	return e;
}

static void
autoselect(Tk *tk, void *v, int cancelled)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	Rectangle hitr;
	char buf[32];
	Point p;

	USED(v);

	if (cancelled)
		return;

	p = tkscrn2local(tk, Pt(tke->oldx, 0));
	p.y = 0;
	if (tkvisiblerect(tk, &hitr) && ptinrect(p, hitr))
		return;

	snprint(buf, sizeof(buf), "to @%d", p.x);
	tkentryselect(tk, buf, nil);
	tkdirty(tk);
	tkupdate(tk->env->top);
}

static char*
tkentryb1p(Tk *tk, char* arg, char **ret)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	Point p;
	int i, locked, x, y;
	char buf[32], *e;
	USED(ret);

	x = strtol(arg, &e, 10);
	y = atoi(e);			/* second token, 0 for the classic %X-only callers */
	p = tkscrn2local(tk, Pt(x, y));

	/* a combobox click on the arrow column (or anywhere when readonly)
	 * drops the value list instead of positioning the cursor */
	if(tke->combo && !(tke->tstate & Sdisabled) &&
	   (p.x >= tk->act.width - arrowwidth(tk) || (tke->tstate & Sreadonly)))
		return tkpostlist(tk, tke->valv, tke->valc, tke->curidx, "tkComboPick");

	/* a spinbox click in the arrow column steps: top half up, bottom down */
	if(tke->spin && !(tke->tstate & Sdisabled) &&
	   p.x >= tk->act.width - arrowwidth(tk))
		return spinstep(tk, p.y < tk->act.height/2 ? +1 : -1);

	sprint(buf, "@%d", p.x);
	e = tkentryparseindex(tk, buf, &i);
	if (e != nil)
		return e;
	tke->sel0 = 0;
	tke->sel1 = 0;
	tke->icursor = i;
	tke->anchor = i;
	tke->flag &= ~Ewordsel;

	locked = lockdisplay(tk->env->top->display);
	tke->xsel0 = 0;
	tke->xsel1 = 0;
	tke->xicursor = entrytextwidth(tk, tke->icursor);
	if (locked)
		unlockdisplay(tk->env->top->display);

	tke->oldx = x;
	blinkreset(tk);
	tkrepeat(tk, autoselect, nil, TkRptpause, TkRptinterval);
	tk->dirty = tkrect(tk, 0);
	return nil;
}

static char*
tkentryb1m(Tk *tk, char* arg, char **ret)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	Point p;
	Rectangle hitr;
	char buf[32];
	USED(ret);

	p.x = atoi(arg);
	tke->oldx = p.x;
	p = tkscrn2local(tk, p);
	p.y = 0;
	if (!tkvisiblerect(tk, &hitr) || !ptinrect(p, hitr))
		return nil;
	snprint(buf, sizeof(buf), "to @%d", p.x);
	tkentryselect(tk, buf, nil);
	return nil;
}

static char*
tkentryb1r(Tk *tk, char* arg, char **ret)
{
	USED(tk);
	USED(arg);
	USED(ret);
	tkcancelrepeat(tk);
	return nil;
}

static void
blinkreset(Tk *tk)
{
	TkEntry *e = TKobj(TkEntry, tk);
	if (!tkhaskeyfocus(tk) || tk->flag&Tkdisabled)
		return;
	e->flag |= Ecursoron;
	tkblinkreset(tk);
}

static void
showcaret(Tk *tk, int on)
{
	TkEntry *e = TKobj(TkEntry, tk);

	if (on)
		e->flag |= Ecursoron;
	else
		e->flag &= ~Ecursoron;
	tk->dirty = tkrect(tk, 0);
}

char*
tkentryfocus(Tk *tk, char* arg, char **ret)
{
	int on = 0;
	USED(ret);

	if (tk->flag&Tkdisabled)
		return nil;

	if(strcmp(arg, " in") == 0) {
		tkblink(tk, showcaret);
		on = 1;
	}
	else
		tkblink(nil, nil);

	showcaret(tk, on);
	return nil;
}

static
TkCmdtab tkentrycmd[] =
{
	"cget",			tkentrycget,
	"configure",		tkentryconf,
	"delete",		tkentrydelete,
	"get",			tkentryget,
	"icursor",		tkentryicursor,
	"index",		tkentryindex,
	"insert",		tkentryinsert,
	"selection",		tkentryselect,
	"xview",		tkentryxview,
	"tkEntryBS",		tkentrybs,
	"tkEntryBW",		tkentrybw,
	"tkEntryB1P",		tkentryb1p,
	"tkEntryB1M",		tkentryb1m,
	"tkEntryB1R",		tkentryb1r,
	"tkEntryB2P",		tkentryb2p,
	"tkEntryFocus",		tkentryfocus,
	"bbox",			tkentrybboxcmd,
	"see",		tkentryseecmd,
	nil
};

TkMethod entrymethod = {
	"entry",
	tkentrycmd,
	tkfreeentry,
	tkdrawentry,
	tkentrygeom
};

/* ---- ttk::entry: the same editing core, themed chrome + state machine ---- */

static char*
ttkentrystatecmd(Tk *tk, char *arg, char **ret)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	TkTop *t = tk->env->top;
	char *spec, *e;
	char buf[256];
	ulong on, off, new;

	spec = mallocz(Tkmaxitem, 0);
	if(spec == nil)
		return TkNomem;
	tkword(t, arg, spec, spec+Tkmaxitem, nil);

	if(spec[0] == '\0'){
		ttkstatestr(ttkentrystate(tk), buf, sizeof(buf));
		free(spec);
		return tkvalue(ret, "%s", buf);
	}
	if(ttkstateparse(spec, &on, &off) < 0){
		free(spec);
		return TkBadvl;
	}
	new = (tke->tstate | on) & ~off;
	ttkrestorespec(tke->tstate, new, buf, sizeof(buf));
	tke->tstate = new;
	if(new & Sdisabled)
		tk->flag |= Tkdisabled;
	else
		tk->flag &= ~Tkdisabled;
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
	e = tkvalue(ret, "%s", buf);
	free(spec);
	return e;
}

static char*
ttkentryinstatecmd(Tk *tk, char *arg, char **ret)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	TkTop *t = tk->env->top;
	char *spec, *script, *e;
	ulong on, off, st;
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
	st = ttkentrystate(tk);
	USED(tke);
	match = (st & on) == on && (st & off) == 0;
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

static char*
ttkentrystylecmd(Tk *tk, char *arg, char **ret)
{
	TkEntry *tke = TKobj(TkEntry, tk);

	USED(arg);
	return tkvalue(ret, "%s", ttkentrystylename(tke));
}

static char*
ttkentryidentcmd(Tk *tk, char *arg, char **ret)
{
	USED(tk);
	USED(arg);
	return tkvalue(ret, "");
}

static
TkCmdtab tkttkentrycmd[] =
{
	"cget",			tkentrycget,
	"configure",		tkentryconf,
	"delete",		tkentrydelete,
	"get",			tkentryget,
	"icursor",		tkentryicursor,
	"index",		tkentryindex,
	"insert",		tkentryinsert,
	"selection",		tkentryselect,
	"xview",		tkentryxview,
	"tkEntryBS",		tkentrybs,
	"tkEntryBW",		tkentrybw,
	"tkEntryB1P",		tkentryb1p,
	"tkEntryB1M",		tkentryb1m,
	"tkEntryB1R",		tkentryb1r,
	"tkEntryB2P",		tkentryb2p,
	"tkEntryFocus",		tkentryfocus,
	"bbox",			tkentrybboxcmd,
	"see",		tkentryseecmd,
	"state",		ttkentrystatecmd,
	"instate",		ttkentryinstatecmd,
	"style",		ttkentrystylecmd,
	"identify",		ttkentryidentcmd,
	nil
};

TkMethod ttkentrymethod = {
	"TEntry",
	tkttkentrycmd,
	tkfreeentry,
	tkdrawentry,
	tkentrygeom
};

/* ---- ttk::combobox: the entry core + a -values dropdown ---- */

/* `current ?index?': get/set the selected index into -values */
static char*
tkcombocurrent(Tk *tk, char *arg, char **ret)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	TkTop *top = tk->env->top;
	char *buf;
	int idx;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	if(buf[0] == '\0'){
		free(buf);
		if(tke->curidx < 0)
			return tkvalue(ret, "");
		return tkvalue(ret, "%d", tke->curidx);
	}
	idx = atoi(buf);
	free(buf);
	if(idx < 0 || idx >= tke->valc)
		return TkBadix;
	tke->curidx = idx;
	comboreplace(tk, tke->valv[idx]);
	return nil;
}

/* `set value': set the displayed text (and sync curidx if it's a -value) */
static char*
tkcomboset(Tk *tk, char *arg, char **ret)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	TkTop *top = tk->env->top;
	char *buf;
	int i;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	tke->curidx = -1;
	for(i = 0; i < tke->valc; i++)
		if(strcmp(tke->valv[i], buf) == 0){
			tke->curidx = i;
			break;
		}
	comboreplace(tk, buf);
	free(buf);
	return nil;
}

/* internal: a dropdown item was chosen (command "<cb> tkComboPick <i>") */
static char*
tkcombopick(Tk *tk, char *arg, char **ret)
{
	TkEntry *tke = TKobj(TkEntry, tk);
	int idx;

	USED(ret);
	idx = atoi(arg);
	if(idx < 0 || idx >= tke->valc)
		return nil;
	tke->curidx = idx;
	comboreplace(tk, tke->valv[idx]);
	tkvirtgen(tk->env->top, tk, "ComboboxSelected");
	return nil;
}

static
TkCmdtab tkttkcombocmd[] =
{
	"cget",			tkentrycget,
	"configure",		tkentryconf,
	"current",		tkcombocurrent,
	"delete",		tkentrydelete,
	"get",			tkentryget,
	"icursor",		tkentryicursor,
	"identify",		ttkentryidentcmd,
	"index",		tkentryindex,
	"insert",		tkentryinsert,
	"instate",		ttkentryinstatecmd,
	"selection",		tkentryselect,
	"set",			tkcomboset,
	"state",		ttkentrystatecmd,
	"style",		ttkentrystylecmd,
	"xview",		tkentryxview,
	"bbox",			tkentrybboxcmd,
	"see",			tkentryseecmd,
	"tkEntryBS",		tkentrybs,
	"tkEntryBW",		tkentrybw,
	"tkEntryB1P",		tkentryb1p,
	"tkEntryB1M",		tkentryb1m,
	"tkEntryB1R",		tkentryb1r,
	"tkEntryB2P",		tkentryb2p,
	"tkEntryFocus",		tkentryfocus,
	"tkComboPick",		tkcombopick,
	nil
};

TkMethod ttkcomboboxmethod = {
	"TCombobox",
	tkttkcombocmd,
	tkfreeentry,
	tkdrawentry,
	tkentrygeom
};

/* ---- ttk::spinbox: the entry core + up/down steppers ---- */

/* `tkSpinStep dir': step up (dir>=0) or down (dir<0); also keyboard Up/Down */
static char*
tkspinstepcmd(Tk *tk, char *arg, char **ret)
{
	USED(ret);
	return spinstep(tk, atoi(arg) < 0 ? -1 : +1);
}

static
TkCmdtab tkttkspincmd[] =
{
	"cget",			tkentrycget,
	"configure",		tkentryconf,
	"delete",		tkentrydelete,
	"get",			tkentryget,
	"icursor",		tkentryicursor,
	"identify",		ttkentryidentcmd,
	"index",		tkentryindex,
	"insert",		tkentryinsert,
	"instate",		ttkentryinstatecmd,
	"selection",		tkentryselect,
	"set",			tkcomboset,
	"state",		ttkentrystatecmd,
	"style",		ttkentrystylecmd,
	"xview",		tkentryxview,
	"bbox",			tkentrybboxcmd,
	"see",			tkentryseecmd,
	"tkEntryBS",		tkentrybs,
	"tkEntryBW",		tkentrybw,
	"tkEntryB1P",		tkentryb1p,
	"tkEntryB1M",		tkentryb1m,
	"tkEntryB1R",		tkentryb1r,
	"tkEntryB2P",		tkentryb2p,
	"tkEntryFocus",		tkentryfocus,
	"tkSpinStep",		tkspinstepcmd,
	nil
};

TkMethod ttkspinboxmethod = {
	"TSpinbox",
	tkttkspincmd,
	tkfreeentry,
	tkdrawentry,
	tkentrygeom
};
