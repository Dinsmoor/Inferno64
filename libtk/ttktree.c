#include <lib9.h>
#include <kernel.h>
#include "draw.h"
#include "keyboard.h"
#include "tk.h"
#include "ttk.h"

/*
 * ttk::treeview - a hierarchical multi-column item list.
 *
 * Items form a tree rooted at an unnamed sentinel; each carries the text for
 * the tree column (#0) plus a value per data column.  Only items all of whose
 * ancestors are `open' are drawn.  A self-drawing leaf widget like the classic
 * listbox (no embedded child widgets): rows, headings, the disclosure
 * triangle and the selection highlight are painted directly, and the body
 * scrolls vertically through a yscrollcommand/yview pair.
 *
 * Parallel to the classic widget set, which is untouched.
 */

#define	O(t, e)		((long)(&((t*)0)->e))

enum
{
	Rowpad		= 2,	/* extra vertical padding per row */
	Tvpadx		= 4,	/* horizontal text padding within a cell */
	Indent		= 18,	/* per-level indent of the tree column */
	Colmin		= 20,	/* minimum column width */
	Tvinset		= 1,	/* inset of content within the border */

	Showtree	= 1<<0,
	Showhead	= 1<<1
};

/* selection modes */
enum
{
	SELbrowse,
	SELextended,
	SELnone
};

typedef struct Tvitem Tvitem;
typedef struct Tvcol Tvcol;
typedef struct Tvtag Tvtag;
typedef struct TkTree TkTree;

struct Tvitem
{
	char*	id;
	char*	text;		/* #0 column text */
	char**	vals;		/* data-column values */
	int	nvals;
	char*	tags;		/* space-separated tag names */
	int	open;
	int	sel;
	Tvitem*	parent;
	Tvitem*	child;		/* first child */
	Tvitem*	next;		/* next sibling */
	int	depth;		/* transient: set by flatten */
	int	vy;		/* transient: flattened visible index */
};

struct Tvcol
{
	char*	id;		/* column identifier */
	char*	heading;	/* heading -text */
	int	width;
	int	minwidth;
	int	anchor;		/* Tk anchor for the cell text */
	int	hanchor;	/* heading anchor */
};

struct Tvtag
{
	char*	name;
	char*	fg;		/* -foreground colour name, or nil */
	char*	bg;		/* -background colour name, or nil */
	Tvtag*	link;
};

struct TkTree
{
	ulong	state;
	char*	style;
	Tvitem*	root;		/* sentinel; root->child is the top level */
	Tvitem*	detached;	/* detached subtrees (parent==nil), via ->next */
	int	nitem;		/* total items (excluding sentinel) */
	Tvcol	col0;		/* the tree column, #0 */
	Tvcol*	cols;		/* data columns */
	int	ncol;
	char*	columnspec;	/* raw -columns */
	char*	showspec;	/* raw -show */
	int	show;		/* Showtree|Showhead */
	int	selmode;
	int	heightrows;	/* -height, in rows */
	int	rowh;		/* set by tvsize */
	int	top;		/* first visible flattened row */
	int	nvis;		/* flattened visible count (set by flatten) */
	char*	yscroll;
	char*	xscroll;
	Tvitem*	focusit;
	Tvtag*	tags;
	int	idgen;
};

/* ---- options ---- */

static TkStab tvselmode[] =
{
	"browse",	SELbrowse,
	"extended",	SELextended,
	"none",		SELnone,
	nil
};

static TkOption tvopts[] =
{
	"style",		OPTtext,	O(TkTree, style),	nil,
	"columns",		OPTtext,	O(TkTree, columnspec),	nil,
	"show",			OPTtext,	O(TkTree, showspec),	nil,
	"selectmode",		OPTstab,	O(TkTree, selmode),	tvselmode,
	"height",		OPTnndist,	O(TkTree, heightrows),	nil,
	"xscrollcommand",	OPTtext,	O(TkTree, xscroll),	nil,
	"yscrollcommand",	OPTtext,	O(TkTree, yscroll),	nil,
	nil
};

/* ---- bindings ---- */

static TkEbind tvb[] =
{
	{TkButton1P,	"%W tkttktvPress %x %y"},
	{TkKey,		"%W tkttktvKey 0x%K"},
};

/* ---- helpers ---- */

static char*
tvstylename(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);

	if(t->style != nil && t->style[0] != '\0')
		return t->style;
	return "Treeview";
}

static ulong
tvstate(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);
	ulong st;

	st = t->state;
	if(tk->flag & Tkdisabled)
		st |= Sdisabled;
	if(tkhaskeyfocus(tk))
		st |= Sfocus;
	return st;
}

static int
rowheight(Tk *tk)
{
	return tk->env->font->height + 2*Rowpad;
}

/* the row used as a heading; same metrics as a body row */
static int
headheight(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);

	if(t->show & Showhead)
		return rowheight(tk);
	return 0;
}

static Tvtag*
tvtagfind(TkTree *t, char *name, int create)
{
	Tvtag *g;

	for(g = t->tags; g != nil; g = g->link)
		if(strcmp(g->name, name) == 0)
			return g;
	if(!create)
		return nil;
	g = mallocz(sizeof(Tvtag), 1);
	if(g == nil)
		return nil;
	g->name = strdup(name);
	g->link = t->tags;
	t->tags = g;
	return g;
}

/* first tag of an item that defines fg/bg (which==0 fg, 1 bg) */
static char*
tvtagcolour(TkTree *t, Tvitem *it, int bg)
{
	char *p, *q, name[Tkmaxitem];
	Tvtag *g;
	int n;

	if(it->tags == nil)
		return nil;
	p = it->tags;
	while(*p != '\0'){
		while(*p == ' ')
			p++;
		q = p;
		while(*q != '\0' && *q != ' ')
			q++;
		n = q - p;
		if(n > 0 && n < Tkmaxitem){
			memmove(name, p, n);
			name[n] = '\0';
			g = tvtagfind(t, name, 0);
			if(g != nil){
				if(bg && g->bg != nil)
					return g->bg;
				if(!bg && g->fg != nil)
					return g->fg;
			}
		}
		p = q;
	}
	return nil;
}

/* ---- item tree ---- */

/* depth-first search of a subtree for id */
static Tvitem*
findrec(Tvitem *it, char *id)
{
	Tvitem *c, *r;

	for(c = it->child; c != nil; c = c->next){
		if(c->id != nil && strcmp(c->id, id) == 0)
			return c;
		r = findrec(c, id);
		if(r != nil)
			return r;
	}
	return nil;
}

static Tvitem*
tvfind(TkTree *t, char *id)
{
	Tvitem *d, *r;

	if(id == nil || id[0] == '\0')
		return t->root;
	r = findrec(t->root, id);
	if(r != nil)
		return r;
	/* also search detached subtrees */
	for(d = t->detached; d != nil; d = d->next){
		if(d->id != nil && strcmp(d->id, id) == 0)
			return d;
		r = findrec(d, id);
		if(r != nil)
			return r;
	}
	return nil;
}

/* detach it from wherever it is (tree or the detached list) */
static void
tvremove(TkTree *t, Tvitem *it)
{
	Tvitem **l;

	if(it->parent != nil){
		for(l = &it->parent->child; *l != nil; l = &(*l)->next)
			if(*l == it){
				*l = it->next;
				break;
			}
	}else{
		for(l = &t->detached; *l != nil; l = &(*l)->next)
			if(*l == it){
				*l = it->next;
				break;
			}
	}
	it->next = nil;
	it->parent = nil;
}

/* insert it as a child of parent at position index (>=0; large = append) */
static void
tvlink(Tvitem *parent, Tvitem *it, int index)
{
	Tvitem **l;
	int i;

	it->parent = parent;
	l = &parent->child;
	for(i = 0; *l != nil && i < index; l = &(*l)->next)
		i++;
	it->next = *l;
	*l = it;
}

static void
tvfreeitem(Tvitem *it)
{
	int i;

	free(it->id);
	free(it->text);
	free(it->tags);
	for(i = 0; i < it->nvals; i++)
		free(it->vals[i]);
	free(it->vals);
	free(it);
}

/* is target somewhere in the subtree rooted at it (inclusive)? */
static int
subtreehas(Tvitem *it, Tvitem *target)
{
	Tvitem *c;

	if(it == target)
		return 1;
	for(c = it->child; c != nil; c = c->next)
		if(subtreehas(c, target))
			return 1;
	return 0;
}

/* recursively free a subtree (not counting/unlinking) */
static void
tvfreetree(TkTree *t, Tvitem *it)
{
	Tvitem *c, *nc;

	for(c = it->child; c != nil; c = nc){
		nc = c->next;
		tvfreetree(t, c);
	}
	if(it != t->root){
		t->nitem--;
		tvfreeitem(it);
	}
}

/* ---- flatten (visible rows in display order) ---- */

static void
flattenrec(Tvitem *it, int depth, Tvitem **arr, int *np)
{
	Tvitem *c;

	for(c = it->child; c != nil; c = c->next){
		c->depth = depth;
		c->vy = *np;
		if(arr != nil)
			arr[*np] = c;
		(*np)++;
		if(c->open)
			flattenrec(c, depth+1, arr, np);
	}
}

/* fill *arrp with the visible items (caller frees); returns the count */
static int
tvflatten(TkTree *t, Tvitem ***arrp)
{
	Tvitem **arr;
	int n;

	arr = nil;
	if(arrp != nil && t->nitem > 0){
		arr = malloc(t->nitem * sizeof(Tvitem*));
		if(arr == nil){
			*arrp = nil;
			return 0;
		}
	}
	n = 0;
	flattenrec(t->root, 0, arr, &n);
	t->nvis = n;
	if(arrp != nil)
		*arrp = arr;
	return n;
}

/* ---- column geometry ---- */

/* number of display columns (tree column counts when shown) */
static int
ndisp(TkTree *t)
{
	return ((t->show & Showtree) ? 1 : 0) + t->ncol;
}

/* the Tvcol* and left x (content coords) of display column d */
static Tvcol*
dispcol(TkTree *t, int d, int *xp)
{
	int x, i;
	Tvcol *c;

	x = Tvinset;
	if(t->show & Showtree){
		if(d == 0){
			if(xp != nil)
				*xp = x;
			return &t->col0;
		}
		x += t->col0.width;
		d--;
	}
	for(i = 0; i < t->ncol; i++){
		c = &t->cols[i];
		if(i == d){
			if(xp != nil)
				*xp = x;
			return c;
		}
		x += c->width;
	}
	return nil;
}

static int
contentwidth(TkTree *t)
{
	int w, i;

	w = 0;
	if(t->show & Showtree)
		w += t->col0.width;
	for(i = 0; i < t->ncol; i++)
		w += t->cols[i].width;
	return w;
}

/* ---- (re)build the data-column array from -columns ---- */

static void
tvsynccols(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *p, name[Tkmaxitem];
	Tvcol *nc, *old;
	int n, i, oldn;

	/* count the column ids in the spec */
	n = 0;
	if(t->columnspec != nil){
		p = t->columnspec;
		for(;;){
			p = tkword(top, p, name, name+sizeof(name), nil);
			if(name[0] == '\0')
				break;
			n++;
		}
	}

	old = t->cols;
	oldn = t->ncol;
	nc = nil;
	if(n > 0){
		nc = mallocz(n*sizeof(Tvcol), 1);
		if(nc == nil)
			return;
	}

	i = 0;
	if(t->columnspec != nil){
		p = t->columnspec;
		for(;;){
			p = tkword(top, p, name, name+sizeof(name), nil);
			if(name[0] == '\0')
				break;
			nc[i].id = strdup(name);
			nc[i].width = 100;
			nc[i].minwidth = Colmin;
			nc[i].anchor = Tkwest;
			nc[i].hanchor = Tkwest;
			/* carry over width/heading/anchor from a same-id old column */
			if(old != nil){
				int j;
				for(j = 0; j < oldn; j++)
					if(old[j].id != nil && strcmp(old[j].id, name) == 0){
						nc[i].width = old[j].width;
						nc[i].minwidth = old[j].minwidth;
						nc[i].anchor = old[j].anchor;
						nc[i].hanchor = old[j].hanchor;
						if(old[j].heading != nil)
							nc[i].heading = strdup(old[j].heading);
						break;
					}
			}
			i++;
		}
	}

	for(i = 0; i < oldn; i++){
		free(old[i].id);
		free(old[i].heading);
	}
	free(old);
	t->cols = nc;
	t->ncol = n;
}

/* parse the -show spec ("tree headings"); empty => both */
static void
tvsyncshow(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *p, name[Tkmaxitem];

	if(t->showspec == nil || t->showspec[0] == '\0'){
		t->show = Showtree|Showhead;
		return;
	}
	t->show = 0;
	p = t->showspec;
	for(;;){
		p = tkword(top, p, name, name+sizeof(name), nil);
		if(name[0] == '\0')
			break;
		if(strcmp(name, "tree") == 0)
			t->show |= Showtree;
		else if(strcmp(name, "headings") == 0)
			t->show |= Showhead;
	}
}

/* ---- size / scroll ---- */

static void
tvsize(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);
	int w, h;

	t->rowh = rowheight(tk);
	w = contentwidth(t) + 2*Tvinset;
	h = headheight(tk) + t->heightrows*t->rowh + 2*Tvinset;

	if((tk->flag & Tksetwidth) == 0)
		tk->req.width = w;
	if((tk->flag & Tksetheight) == 0)
		tk->req.height = h;
}

/* visible body rows */
static int
bodyrows(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);
	int bh;

	bh = tk->act.height - headheight(tk) - 2*Tvinset;
	if(bh < 0)
		bh = 0;
	return bh / t->rowh;
}

static void
tvscrollv(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);
	int nl, top, bot;
	char val[Tkminitem], cmd[Tkmaxitem], *v, *e;

	if(t->yscroll == nil || t->yscroll[0] == '\0')
		return;

	tvflatten(t, nil);
	top = 0;
	bot = TKI2F(1);
	if(t->nvis != 0){
		nl = bodyrows(tk);
		top = TKI2F(t->top)/t->nvis;
		bot = TKI2F(t->top+nl)/t->nvis;
	}
	v = tkfprint(val, top);
	*v++ = ' ';
	tkfprint(v, bot);
	snprint(cmd, sizeof(cmd), "%s %s", t->yscroll, val);
	e = tkexec(tk->env->top, cmd, nil);
	if(e != nil && tk->name != nil)
		print("tk: yscrollcommand \"%s\": %s\n", tk->name->name, e);
}

static void
tvclamptop(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);
	int nl, max;

	tvflatten(t, nil);
	nl = bodyrows(tk);
	max = t->nvis - nl;
	if(t->top > max)
		t->top = max;
	if(t->top < 0)
		t->top = 0;
}

static void
tvgeom(Tk *tk)
{
	tvclamptop(tk);
	tvscrollv(tk);
}

static void
tvredraw(Tk *tk)
{
	tk->dirty = tkrect(tk, 1);
	tkdirty(tk);
}

/* ---- draw ---- */

/* a triangle disclosure indicator in box b, pointing down if open */
static void
drawtri(Tk *tk, Image *i, Rectangle b, int open, Image *col)
{
	Point p[3];
	int s, cx, cy;

	s = (tk->env->font->height)/2;
	if(s < 3)
		s = 3;
	cx = (b.min.x + b.max.x)/2;
	cy = (b.min.y + b.max.y)/2;
	if(open){
		p[0] = Pt(cx - s, cy - s/2);
		p[1] = Pt(cx + s, cy - s/2);
		p[2] = Pt(cx, cy + s/2 + 1);
	}else{
		p[0] = Pt(cx - s/2, cy - s);
		p[1] = Pt(cx - s/2, cy + s);
		p[2] = Pt(cx + s/2 + 1, cy);
	}
	fillpoly(i, p, 3, ~0, col, p[0]);
}

static char*
ttkdrawtv(Tk *tk, Point orig)
{
	TkTree *t = TKobj(TkTree, tk);
	TkEnv *env = tk->env;
	Image *i, *bg, *line, *fg, *selbg, *selfg;
	Point po, tp;
	Rectangle r, body, row, cell;
	char *style;
	ulong st;
	int hh, nl, d, x, k, cw, headh;
	Tvitem **vis, *it;
	Tvcol *c;

	i = tkimageof(tk);
	if(i == nil)
		return nil;
	style = tvstylename(tk);
	st = tvstate(tk);

	po.x = orig.x + tk->act.x + tk->borderwidth;
	po.y = orig.y + tk->act.y + tk->borderwidth;

	/*
	 * The body is the primary content surface, so it falls back to the plain
	 * themed background (TkCbackgnd) like a listbox/text/entry -- NOT the light
	 * shade.  tkrgbashade() brightens only HSV value, so a "light" shade of a
	 * saturated themed bg stays fully saturated; filling the whole data region
	 * with it makes the body glow in-hue on a coloured desktop theme.  The
	 * heading (below) takes the dark shade so it still reads as a distinct band.
	 */
	bg = ttkcolorx(tk, style, st, "-fieldbackground", TkCbackgnd);
	line = ttkcolorx(tk, style, st, "-bordercolor", TkCbackgnddark);
	fg = ttkcolorx(tk, style, st, "-foreground", TkCforegnd);
	selbg = tkgc(env, TkCselectbgnd);
	selfg = tkgc(env, TkCselectfgnd);

	/* whole-widget background */
	draw(i, rectaddpt(tk->dirty, po), bg, nil, ZP);

	t->rowh = rowheight(tk);
	headh = headheight(tk);
	nl = bodyrows(tk);

	/* heading row */
	if(t->show & Showhead){
		Image *hbg = ttkcolorx(tk, style, st, "-background", TkCbackgnddark);
		row.min.x = po.x + Tvinset;
		row.min.y = po.y + Tvinset;
		row.max.x = po.x + tk->act.width - Tvinset;
		row.max.y = row.min.y + headh;
		draw(i, row, hbg, nil, ZP);
		for(d = 0; d < ndisp(t); d++){
			char *htext;
			c = dispcol(t, d, &x);
			if(c == nil)
				continue;
			cw = c->width;
			cell.min.x = po.x + x;
			cell.min.y = row.min.y;
			cell.max.x = cell.min.x + cw;
			cell.max.y = row.max.y;
			tkbox(i, cell, 1, line);
			htext = c->heading;
			if(htext != nil && htext[0] != '\0'){
				Point ts = tkstringsize(tk, htext);
				tp.x = cell.min.x + Tvpadx;
				tp.y = cell.min.y + (Dy(cell) - ts.y)/2;
				tkdrawstring(tk, i, tp, htext, -1, fg, Tkleft);
			}
		}
	}

	/* body */
	body.min.x = po.x + Tvinset;
	body.min.y = po.y + Tvinset + headh;
	body.max.x = po.x + tk->act.width - Tvinset;
	body.max.y = po.y + tk->act.height - Tvinset;

	vis = nil;
	tvflatten(t, &vis);
	for(k = 0; k < nl && t->top+k < t->nvis; k++){
		it = vis[t->top+k];
		row.min.x = body.min.x;
		row.min.y = body.min.y + k*t->rowh;
		row.max.x = body.max.x;
		row.max.y = row.min.y + t->rowh;

		if(it->sel)
			draw(i, row, selbg, nil, ZP);

		/* tree column #0 */
		if(t->show & Showtree){
			Image *cellfg = it->sel ? selfg : fg;
			char *cn;
			int indic;
			c = &t->col0;
			x = Tvinset;
			cn = tvtagcolour(t, it, 0);
			if(cn != nil && !it->sel){
				ulong pix;
				if(tkparsecolor(cn, &pix) == nil)
					cellfg = tkcolor(tk->env->top->ctxt, pix);
			}
			/* indicator column, then the text just right of it */
			indic = po.x + x + Tvpadx + it->depth*Indent;
			tp.x = indic + Indent;
			if(it->child != nil){
				Rectangle tb;
				tb.min.x = indic;
				tb.min.y = row.min.y;
				tb.max.x = indic + Indent;
				tb.max.y = row.max.y;
				drawtri(tk, i, tb, it->open, cellfg);
			}
			if(it->text != nil && it->text[0] != '\0'){
				Point ts = tkstringsize(tk, it->text);
				int ty = row.min.y + (t->rowh - ts.y)/2;
				tkdrawstring(tk, i, Pt(tp.x, ty), it->text, -1, cellfg, Tkleft);
			}
		}

		/* data columns */
		for(d = 0; d < t->ncol; d++){
			Image *cellfg = it->sel ? selfg : fg;
			char *v;
			c = dispcol(t, ((t->show & Showtree) ? 1 : 0) + d, &x);
			if(c == nil)
				continue;
			v = (d < it->nvals) ? it->vals[d] : nil;
			if(v != nil && v[0] != '\0'){
				Point ts = tkstringsize(tk, v);
				int ty = row.min.y + (t->rowh - ts.y)/2;
				int tx = po.x + x + Tvpadx;
				if(c->anchor & Tkeast)
					tx = po.x + x + c->width - Tvpadx - ts.x;
				else if((c->anchor & (Tkeast|Tkwest)) == 0)
					tx = po.x + x + (c->width - ts.x)/2;
				tkdrawstring(tk, i, Pt(tx, ty), v, -1, cellfg, Tkleft);
			}
		}

		/* focus ring */
		if(it == t->focusit && tkhaskeyfocus(tk))
			tkbox(i, row, 1, fg);
	}
	free(vis);

	/* border */
	r = rectaddpt(tkrect(tk, 0), po);
	tkbox(i, r, 1, line);

	USED(hh);
	return nil;
}

/* ---- id allocation ---- */

static char*
tvnewid(TkTree *t)
{
	char buf[32];

	do {
		snprint(buf, sizeof(buf), "I%03d", ++t->idgen);
	} while(tvfind(t, buf) != nil);
	return strdup(buf);
}

/* ---- item option parsing ---- */

static void
setvals(Tvitem *it, char *list, TkTop *top)
{
	char *p, val[Tkmaxitem];
	char **nv;
	int n, cap;

	for(n = 0; n < it->nvals; n++)
		free(it->vals[n]);
	free(it->vals);
	it->vals = nil;
	it->nvals = 0;

	n = 0;
	cap = 0;
	nv = nil;
	p = list;
	for(;;){
		p = tkword(top, p, val, val+sizeof(val), nil);
		if(val[0] == '\0')
			break;
		if(n >= cap){
			cap = cap ? cap*2 : 4;
			nv = realloc(nv, cap*sizeof(char*));
			if(nv == nil)
				return;
		}
		nv[n++] = strdup(val);
	}
	it->vals = nv;
	it->nvals = n;
}

/* apply -text/-values/-open/-tags/-image options; returns id if -id seen */
static char*
itemopts(Tk *tk, Tvitem *it, char *arg, char **idp)
{
	TkTop *top = tk->env->top;
	char *opt, *val;

	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(opt == nil || val == nil){
		free(opt); free(val);
		return TkNomem;
	}
	for(;;){
		arg = tkword(top, arg, opt, opt+Tkmaxitem, nil);
		if(opt[0] == '\0')
			break;
		arg = tkword(top, arg, val, val+Tkmaxitem, nil);
		if(strcmp(opt, "-text") == 0){
			free(it->text);
			it->text = strdup(val);
		}else if(strcmp(opt, "-values") == 0){
			setvals(it, val, top);
		}else if(strcmp(opt, "-open") == 0){
			it->open = (val[0]=='1'||val[0]=='t'||val[0]=='y'||val[0]=='T'||val[0]=='Y');
		}else if(strcmp(opt, "-tags") == 0){
			free(it->tags);
			it->tags = strdup(val);
		}else if(strcmp(opt, "-id") == 0){
			if(idp != nil)
				*idp = strdup(val);
		}
		/* -image accepted and ignored: images not yet supported */
	}
	free(opt);
	free(val);
	return nil;
}

/* ---- subcommands ---- */

static char*
tvinsert(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *pbuf, *ibuf, *e, *id;
	Tvitem *parent, *it;
	int index;

	pbuf = mallocz(Tkmaxitem, 0);
	ibuf = mallocz(Tkmaxitem, 0);
	if(pbuf == nil || ibuf == nil){
		free(pbuf); free(ibuf);
		return TkNomem;
	}
	arg = tkword(top, arg, pbuf, pbuf+Tkmaxitem, nil);
	arg = tkword(top, arg, ibuf, ibuf+Tkmaxitem, nil);
	parent = tvfind(t, pbuf);
	if(parent == nil){
		free(pbuf); free(ibuf);
		return TkBadix;
	}
	if(strcmp(ibuf, "end") == 0)
		index = 0x7fffffff;
	else
		index = atoi(ibuf);
	free(pbuf); free(ibuf);

	it = mallocz(sizeof(Tvitem), 1);
	if(it == nil)
		return TkNomem;
	it->vy = -1;

	id = nil;
	e = itemopts(tk, it, arg, &id);
	if(e != nil){
		tvfreeitem(it);
		free(id);
		return e;
	}
	if(id != nil && id[0] != '\0'){
		if(tvfind(t, id) != nil){
			tvfreeitem(it);
			free(id);
			return "item already exists";
		}
		it->id = id;
	}else{
		free(id);
		it->id = tvnewid(t);
	}

	tvlink(parent, it, index);
	t->nitem++;

	tvsize(tk);
	tvgeom(tk);
	tvredraw(tk);
	return tkvalue(ret, "%s", it->id);
}

static char*
tvdelete(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf;
	Tvitem *it;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	for(;;){
		arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
		if(buf[0] == '\0')
			break;
		it = tvfind(t, buf);
		if(it == nil || it == t->root)
			continue;
		if(t->focusit != nil && subtreehas(it, t->focusit))
			t->focusit = nil;
		tvremove(t, it);
		tvfreetree(t, it);	/* frees the subtree, including it */
	}
	free(buf);
	tvsize(tk);
	tvgeom(tk);
	tvredraw(tk);
	return nil;
}

static char*
tvchildren(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf, *e;
	Tvitem *parent, *c;
	int first;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
	parent = tvfind(t, buf);
	free(buf);
	if(parent == nil)
		return TkBadix;
	/* the two-arg form (set children) is not supported; query only */
	first = 1;
	for(c = parent->child; c != nil; c = c->next){
		e = tkvalue(ret, "%s%s", first ? "" : " ", c->id);
		if(e != nil)
			return e;
		first = 0;
	}
	return nil;
}

static char*
tvparent(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf;
	Tvitem *it;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	it = tvfind(t, buf);
	free(buf);
	if(it == nil)
		return TkBadix;
	if(it->parent == nil || it->parent == t->root)
		return tkvalue(ret, "");
	return tkvalue(ret, "%s", it->parent->id);
}

static char*
tvindexcmd(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf;
	Tvitem *it, *c;
	int n;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	it = tvfind(t, buf);
	free(buf);
	if(it == nil || it->parent == nil)
		return TkBadix;
	n = 0;
	for(c = it->parent->child; c != nil && c != it; c = c->next)
		n++;
	return tkvalue(ret, "%d", n);
}

static char*
tvexists(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf;
	Tvitem *it;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	it = tvfind(t, buf);
	free(buf);
	return tkvalue(ret, "%d", (it != nil && it != t->root) ? 1 : 0);
}

static char*
tvmove(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *ib, *pb, *xb;
	Tvitem *it, *parent, *a;
	int index;

	USED(ret);
	ib = mallocz(Tkmaxitem, 0);
	pb = mallocz(Tkmaxitem, 0);
	xb = mallocz(Tkmaxitem, 0);
	if(ib == nil || pb == nil || xb == nil){
		free(ib); free(pb); free(xb);
		return TkNomem;
	}
	arg = tkword(top, arg, ib, ib+Tkmaxitem, nil);
	arg = tkword(top, arg, pb, pb+Tkmaxitem, nil);
	tkword(top, arg, xb, xb+Tkmaxitem, nil);
	it = tvfind(t, ib);
	parent = tvfind(t, pb);
	index = (strcmp(xb, "end")==0) ? 0x7fffffff : atoi(xb);
	free(ib); free(pb); free(xb);
	if(it == nil || it == t->root || parent == nil)
		return TkBadix;
	/* refuse to move an item into its own subtree */
	for(a = parent; a != nil; a = a->parent)
		if(a == it)
			return TkBadix;
	tvremove(t, it);
	tvlink(parent, it, index);
	tvsize(tk);
	tvgeom(tk);
	tvredraw(tk);
	return nil;
}

static char*
tvdetach(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf;
	Tvitem *it;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	for(;;){
		arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
		if(buf[0] == '\0')
			break;
		it = tvfind(t, buf);
		if(it == nil || it == t->root)
			continue;
		tvremove(t, it);
		/* keep it alive (re-attachable via move) on the detached list */
		it->next = t->detached;
		t->detached = it;
	}
	free(buf);
	tvsize(tk);
	tvgeom(tk);
	tvredraw(tk);
	return nil;
}

/* item ID ?-option ?value? ...? : query or configure */
static char*
tvitemcmd(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf, *opt, *val, *rest, *e;
	Tvitem *it;
	int first, i;

	buf = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(buf == nil || opt == nil || val == nil){
		free(buf); free(opt); free(val);
		return TkNomem;
	}
	arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
	it = tvfind(t, buf);
	if(it == nil || it == t->root){
		free(buf); free(opt); free(val);
		return TkBadix;
	}

	rest = tkword(top, arg, opt, opt+Tkmaxitem, nil);
	tkword(top, rest, val, val+Tkmaxitem, nil);

	/* a query: no option, or an option with no following value */
	if(opt[0] == '\0' || val[0] == '\0'){
		e = nil;
		if(opt[0] == '\0' || strcmp(opt, "-text") == 0)
			e = tkvalue(ret, "%s", it->text ? it->text : "");
		else if(strcmp(opt, "-open") == 0)
			e = tkvalue(ret, "%d", it->open);
		else if(strcmp(opt, "-tags") == 0)
			e = tkvalue(ret, "%s", it->tags ? it->tags : "");
		else if(strcmp(opt, "-values") == 0){
			first = 1;
			for(i = 0; i < it->nvals; i++){
				e = tkvalue(ret, "%s%s", first?"":" ", it->vals[i]);
				first = 0;
			}
		}else
			e = tkvalue(ret, "");
		free(buf); free(opt); free(val);
		return e;
	}
	free(buf); free(opt); free(val);

	e = itemopts(tk, it, arg, nil);
	if(e != nil)
		return e;
	tvsize(tk);
	tvgeom(tk);
	tvredraw(tk);
	return nil;
}

/* clear every selection flag */
static void
tvselclear(Tvitem *it)
{
	Tvitem *c;

	for(c = it->child; c != nil; c = c->next){
		c->sel = 0;
		tvselclear(c);
	}
}

static char*
tvselcollect(Tvitem *it, char **ret, int *first)
{
	Tvitem *c;
	char *e;

	for(c = it->child; c != nil; c = c->next){
		if(c->sel){
			e = tkvalue(ret, "%s%s", *first?"":" ", c->id);
			if(e != nil)
				return e;
			*first = 0;
		}
		e = tvselcollect(c, ret, first);
		if(e != nil)
			return e;
	}
	return nil;
}

static char*
tvselection(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *op, *buf;
	Tvitem *it;
	int first, mode;

	op = mallocz(Tkmaxitem, 0);
	buf = mallocz(Tkmaxitem, 0);
	if(op == nil || buf == nil){
		free(op); free(buf);
		return TkNomem;
	}
	arg = tkword(top, arg, op, op+Tkmaxitem, nil);
	if(op[0] == '\0'){
		free(op); free(buf);
		first = 1;
		return tvselcollect(t->root, ret, &first);
	}

	mode = -1;	/* set */
	if(strcmp(op, "set") == 0)
		mode = 0;
	else if(strcmp(op, "add") == 0)
		mode = 1;
	else if(strcmp(op, "remove") == 0)
		mode = 2;
	else if(strcmp(op, "toggle") == 0)
		mode = 3;
	if(mode == 0)
		tvselclear(t->root);

	for(;;){
		arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
		if(buf[0] == '\0')
			break;
		it = tvfind(t, buf);
		if(it == nil || it == t->root)
			continue;
		switch(mode){
		case 0: case 1:	it->sel = 1; break;
		case 2:		it->sel = 0; break;
		case 3:		it->sel = !it->sel; break;
		}
	}
	free(op); free(buf);
	tvredraw(tk);
	tkvirtgen(top, tk, "TreeviewSelect");
	return nil;
}

static char*
tvfocuscmd(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf;
	Tvitem *it;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	if(buf[0] == '\0'){
		free(buf);
		if(t->focusit != nil)
			return tkvalue(ret, "%s", t->focusit->id);
		return tkvalue(ret, "");
	}
	it = tvfind(t, buf);
	free(buf);
	if(it == nil || it == t->root)
		return TkBadix;
	t->focusit = it;
	tvredraw(tk);
	return nil;
}

/* open ancestors and scroll so item is visible */
static char*
tvsee(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf;
	Tvitem *it, *a;
	int nl;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	it = tvfind(t, buf);
	free(buf);
	if(it == nil || it == t->root)
		return TkBadix;

	for(a = it->parent; a != nil && a != t->root; a = a->parent)
		a->open = 1;

	tvflatten(t, nil);
	nl = bodyrows(tk);
	if(it->vy < t->top)
		t->top = it->vy;
	else if(it->vy >= t->top + nl)
		t->top = it->vy - (nl-1);
	tvclamptop(tk);
	tvscrollv(tk);
	tvredraw(tk);
	return nil;
}

static char*
tvyview(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf, *e;
	int nl, frac, amount, hi;

	tvflatten(t, nil);
	nl = bodyrows(tk);

	if(*arg == '\0'){
		int fa, fb;
		char val[Tkminitem], *v;
		fa = 0; fb = TKI2F(1);
		if(t->nvis != 0){
			fa = TKI2F(t->top)/t->nvis;
			fb = TKI2F(t->top+nl)/t->nvis;
		}
		v = tkfprint(val, fa);
		*v++ = ' ';
		tkfprint(v, fb);
		return tkvalue(ret, "%s", val);
	}

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
	if(strcmp(buf, "moveto") == 0){
		e = tkfracword(top, &arg, &frac, nil);
		if(e != nil){
			free(buf);
			return e;
		}
		t->top = TKF2I(frac*t->nvis);
	}else if(strcmp(buf, "scroll") == 0){
		arg = tkword(top, arg, buf, buf+Tkmaxitem, nil);
		amount = atoi(buf);
		tkword(top, arg, buf, buf+Tkmaxitem, nil);
		if(buf[0] == 'p')
			amount *= nl;
		t->top += amount;
	}
	free(buf);

	hi = t->nvis - nl;
	if(t->top > hi)
		t->top = hi;
	if(t->top < 0)
		t->top = 0;
	tvscrollv(tk);
	tvredraw(tk);
	return nil;
}

static char*
tvxview(Tk *tk, char *arg, char **ret)
{
	USED(tk); USED(arg);
	/* horizontal scrolling not implemented; report the whole range */
	return tkvalue(ret, "0 1");
}

/* heading COL ?-text str? ?-anchor a? : query/set a column heading */
static char*
tvheading(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *cb, *opt, *val;
	Tvcol *c;
	int i;

	cb = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(cb == nil || opt == nil || val == nil){
		free(cb); free(opt); free(val);
		return TkNomem;
	}
	arg = tkword(top, arg, cb, cb+Tkmaxitem, nil);
	c = nil;
	if(strcmp(cb, "#0") == 0)
		c = &t->col0;
	else for(i = 0; i < t->ncol; i++)
		if(t->cols[i].id != nil && strcmp(t->cols[i].id, cb) == 0){
			c = &t->cols[i];
			break;
		}
	if(c == nil){
		free(cb); free(opt); free(val);
		return TkBadix;
	}

	if(*arg == '\0'){
		char *e = tkvalue(ret, "%s", c->heading ? c->heading : "");
		free(cb); free(opt); free(val);
		return e;
	}
	for(;;){
		arg = tkword(top, arg, opt, opt+Tkmaxitem, nil);
		if(opt[0] == '\0')
			break;
		arg = tkword(top, arg, val, val+Tkmaxitem, nil);
		if(strcmp(opt, "-text") == 0){
			free(c->heading);
			c->heading = strdup(val);
		}else if(strcmp(opt, "-anchor") == 0){
			if(strcmp(val, "e")==0) c->hanchor = Tkeast;
			else if(strcmp(val, "center")==0) c->hanchor = 0;
			else c->hanchor = Tkwest;
		}
	}
	free(cb); free(opt); free(val);
	tvredraw(tk);
	return nil;
}

/* column COL ?-width n? ?-minwidth n? ?-anchor a? : query/set */
static char*
tvcolumncmd(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *cb, *opt, *val;
	Tvcol *c;
	int i;

	cb = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(cb == nil || opt == nil || val == nil){
		free(cb); free(opt); free(val);
		return TkNomem;
	}
	arg = tkword(top, arg, cb, cb+Tkmaxitem, nil);
	c = nil;
	if(strcmp(cb, "#0") == 0)
		c = &t->col0;
	else for(i = 0; i < t->ncol; i++)
		if(t->cols[i].id != nil && strcmp(t->cols[i].id, cb) == 0){
			c = &t->cols[i];
			break;
		}
	if(c == nil){
		free(cb); free(opt); free(val);
		return TkBadix;
	}

	if(*arg == '\0'){
		char *e = tkvalue(ret, "%d", c->width);
		free(cb); free(opt); free(val);
		return e;
	}
	for(;;){
		arg = tkword(top, arg, opt, opt+Tkmaxitem, nil);
		if(opt[0] == '\0')
			break;
		arg = tkword(top, arg, val, val+Tkmaxitem, nil);
		if(strcmp(opt, "-width") == 0){
			c->width = atoi(val);
			if(c->width < Colmin)
				c->width = Colmin;
		}else if(strcmp(opt, "-minwidth") == 0){
			c->minwidth = atoi(val);
		}else if(strcmp(opt, "-anchor") == 0){
			if(strcmp(val, "e")==0) c->anchor = Tkeast;
			else if(strcmp(val, "center")==0) c->anchor = 0;
			else c->anchor = Tkwest;
		}
	}
	free(cb); free(opt); free(val);
	tvsize(tk);
	tvgeom(tk);
	tvredraw(tk);
	return nil;
}

/* identify region|column|item|row x y */
static char*
tvidentify(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *what;
	Point p;
	int hh, rowidx, d, x, cw;
	Tvitem **vis;
	Tvcol *c;
	char *e;

	what = mallocz(Tkmaxitem, 0);
	if(what == nil)
		return TkNomem;
	arg = tkword(top, arg, what, what+Tkmaxitem, nil);
	e = tkxyparse(tk, &arg, &p);
	if(e != nil){
		free(what);
		return e;
	}

	hh = headheight(tk);
	if(p.y < tk->borderwidth + Tvinset + hh){
		/* in the heading band */
		if(strcmp(what, "region") == 0)
			e = tkvalue(ret, "%s", (hh>0 && p.y>=tk->borderwidth+Tvinset) ? "heading" : "nothing");
		else
			e = tkvalue(ret, "");
		free(what);
		return e;
	}

	rowidx = t->top + (p.y - tk->borderwidth - Tvinset - hh)/t->rowh;
	vis = nil;
	tvflatten(t, &vis);

	if(strcmp(what, "region") == 0){
		e = tkvalue(ret, "%s", (rowidx < t->nvis) ? "cell" : "nothing");
	}else if(strcmp(what, "item") == 0 || strcmp(what, "row") == 0){
		if(rowidx >= 0 && rowidx < t->nvis)
			e = tkvalue(ret, "%s", vis[rowidx]->id);
		else
			e = tkvalue(ret, "");
	}else if(strcmp(what, "column") == 0){
		e = tkvalue(ret, "");
		for(d = 0; d < ndisp(t); d++){
			c = dispcol(t, d, &x);
			if(c == nil)
				continue;
			cw = c->width;
			if(p.x >= tk->borderwidth+x && p.x < tk->borderwidth+x+cw){
				e = tkvalue(ret, "%s", (d==0 && (t->show&Showtree)) ? "#0" : c->id);
				break;
			}
		}
	}else
		e = tkvalue(ret, "");
	free(vis);
	free(what);
	return e;
}

/* tag configure NAME ?-foreground c? ?-background c? */
static char*
tvtagcmd(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *sub, *name, *opt, *val;
	Tvtag *g;

	sub = mallocz(Tkmaxitem, 0);
	name = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(sub == nil || name == nil || opt == nil || val == nil){
		free(sub); free(name); free(opt); free(val);
		return TkNomem;
	}
	arg = tkword(top, arg, sub, sub+Tkmaxitem, nil);
	if(strcmp(sub, "configure") != 0 && strcmp(sub, "config") != 0){
		/* unsupported tag subcommand: accept silently */
		free(sub); free(name); free(opt); free(val);
		return tkvalue(ret, "");
	}
	arg = tkword(top, arg, name, name+Tkmaxitem, nil);
	g = tvtagfind(t, name, 1);
	if(g == nil){
		free(sub); free(name); free(opt); free(val);
		return TkNomem;
	}
	for(;;){
		arg = tkword(top, arg, opt, opt+Tkmaxitem, nil);
		if(opt[0] == '\0')
			break;
		arg = tkword(top, arg, val, val+Tkmaxitem, nil);
		if(strcmp(opt, "-foreground") == 0){
			free(g->fg);
			g->fg = strdup(val);
		}else if(strcmp(opt, "-background") == 0){
			free(g->bg);
			g->bg = strdup(val);
		}
	}
	free(sub); free(name); free(opt); free(val);
	tvredraw(tk);
	return nil;
}

/* ---- press / key ---- */

static char*
tvpress(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	char *e;
	Point p;
	int hh, rowidx;
	Tvitem **vis, *it;

	USED(ret);
	e = tkxyparse(tk, &arg, &p);
	if(e != nil)
		return e;

	hh = headheight(tk);
	if(p.y < tk->borderwidth + Tvinset + hh)
		return nil;	/* heading click: no sort yet */

	rowidx = t->top + (p.y - tk->borderwidth - Tvinset - hh)/t->rowh;
	vis = nil;
	tvflatten(t, &vis);
	if(rowidx < 0 || rowidx >= t->nvis){
		free(vis);
		return nil;
	}
	it = vis[rowidx];
	free(vis);

	/* hit on the disclosure triangle toggles open/close */
	if((t->show & Showtree) && it->child != nil){
		int indic = tk->borderwidth + Tvinset + Tvpadx + it->depth*Indent;
		if(p.x >= indic && p.x < indic + Indent){
			it->open = !it->open;
			tvsize(tk);
			tvgeom(tk);
			tvredraw(tk);
			return nil;
		}
	}

	if(t->selmode != SELnone){
		tvselclear(t->root);
		it->sel = 1;
	}
	t->focusit = it;
	tvredraw(tk);
	tkvirtgen(tk->env->top, tk, "TreeviewSelect");
	return nil;
}

static char*
tvkey(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	TkTop *top = tk->env->top;
	char *buf;
	Tvitem **vis, *it;
	int key, vy, nl;

	USED(ret);
	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(top, arg, buf, buf+Tkmaxitem, nil);
	key = strtol(buf, nil, 0);
	free(buf);

	vis = nil;
	tvflatten(t, &vis);
	if(t->nvis == 0){
		free(vis);
		return nil;
	}
	vy = (t->focusit != nil) ? t->focusit->vy : -1;
	nl = bodyrows(tk);

	switch(key){
	case '\n': case '\r': case ' ':
		if(t->focusit != nil && t->focusit->child != nil){
			t->focusit->open = !t->focusit->open;
			free(vis);
			tvsize(tk);
			tvgeom(tk);
			tvredraw(tk);
			return nil;
		}
		break;
	case Up:
		vy--;
		break;
	case Down:
		vy++;
		break;
	case Pgup:
		vy -= nl;
		break;
	case Pgdown:
		vy += nl;
		break;
	default:
		free(vis);
		return nil;
	}
	if(vy < 0)
		vy = 0;
	if(vy >= t->nvis)
		vy = t->nvis-1;
	it = vis[vy];
	free(vis);

	if(t->selmode != SELnone){
		tvselclear(t->root);
		it->sel = 1;
	}
	t->focusit = it;

	/* keep it visible */
	if(vy < t->top)
		t->top = vy;
	else if(vy >= t->top + nl)
		t->top = vy - (nl-1);
	tvclamptop(tk);
	tvscrollv(tk);
	tvredraw(tk);
	tkvirtgen(top, tk, "TreeviewSelect");
	return nil;
}

/* ---- state / instate / style ---- */

static char*
tvstatecmd(Tk *tk, char *arg, char **ret)
{
	TkTree *t = TKobj(TkTree, tk);
	return ttkstateop(tk, &t->state, arg, ret);
}

static char*
tvinstatecmd(Tk *tk, char *arg, char **ret)
{
	return ttkinstateop(tk, tvstate(tk), arg, ret);
}

static char*
tvstylecmd(Tk *tk, char *arg, char **ret)
{
	USED(arg);
	return tkvalue(ret, "%s", tvstylename(tk));
}

/* ---- cget / configure ---- */

static char*
tvcget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[3];

	tko[0].ptr = TKobj(TkTree, tk);
	tko[0].optab = tvopts;
	tko[1].ptr = tk;
	tko[1].optab = tkgeneric;
	tko[2].ptr = nil;
	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
tvconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[3];

	tko[0].ptr = TKobj(TkTree, tk);
	tko[0].optab = tvopts;
	tko[1].ptr = tk;
	tko[1].optab = tkgeneric;
	tko[2].ptr = nil;

	if(*arg == '\0')
		return tkconflist(tko, val);
	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	tvsynccols(tk);
	tvsyncshow(tk);
	tvsize(tk);
	tkgeomchg(tk, &g, bd);
	tvgeom(tk);
	tvredraw(tk);
	return e;
}

/* ---- free ---- */

static void
tvfree(Tk *tk)
{
	TkTree *t = TKobj(TkTree, tk);
	Tvtag *g, *ng;
	Tvitem *c, *nc;
	int i;

	if(t->root != nil){
		for(c = t->root->child; c != nil; c = nc){
			nc = c->next;
			tvfreetree(t, c);
		}
		free(t->root);
		t->root = nil;
	}
	for(c = t->detached; c != nil; c = nc){
		nc = c->next;
		tvfreetree(t, c);
	}
	t->detached = nil;
	for(g = t->tags; g != nil; g = ng){
		ng = g->link;
		free(g->name);
		free(g->fg);
		free(g->bg);
		free(g);
	}
	t->tags = nil;
	for(i = 0; i < t->ncol; i++){
		free(t->cols[i].id);
		free(t->cols[i].heading);
	}
	free(t->cols);
	t->cols = nil;
	free(t->col0.id);
	free(t->col0.heading);
	free(t->style);
	free(t->columnspec);
	free(t->showspec);
	free(t->yscroll);
	free(t->xscroll);
}

/* ---- geometry callback ---- */

static void
ttktvgeom(Tk *tk)
{
	tvgeom(tk);
	tk->dirty = tkrect(tk, 1);
}

/* ---- constructor ---- */

char*
tkttktreeview(TkTop *top, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkTree *t;
	TkName *names;
	TkOptab tko[3];

	tk = tknewobj(top, TKttktreeview, sizeof(Tk)+sizeof(TkTree));
	if(tk == nil)
		return TkNomem;
	t = TKobj(TkTree, tk);
	t->state = 0;
	t->style = nil;
	t->cols = nil;
	t->ncol = 0;
	t->columnspec = nil;
	t->showspec = nil;
	t->show = Showtree|Showhead;
	t->selmode = SELbrowse;
	t->heightrows = 10;
	t->top = 0;
	t->nvis = 0;
	t->nitem = 0;
	t->detached = nil;
	t->yscroll = nil;
	t->xscroll = nil;
	t->focusit = nil;
	t->tags = nil;
	t->idgen = 0;

	t->root = mallocz(sizeof(Tvitem), 1);
	if(t->root == nil){
		tkfreeobj(tk);
		return TkNomem;
	}
	t->root->vy = -1;

	t->col0.id = strdup("#0");
	t->col0.width = 200;
	t->col0.minwidth = Colmin;
	t->col0.anchor = Tkwest;
	t->col0.hanchor = Tkwest;

	tk->relief = TKsunken;
	tk->borderwidth = 1;
	tk->highlightwidth = 0;
	tk->flag |= Tktakefocus;

	e = tkbindings(top, tk, tvb, nelem(tvb));
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}

	tko[0].ptr = t;
	tko[0].optab = tvopts;
	tko[1].ptr = tk;
	tko[1].optab = tkgeneric;
	tko[2].ptr = nil;
	names = nil;
	e = tkparse(top, arg, tko, &names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	tvsynccols(tk);
	tvsyncshow(tk);
	tvsize(tk);
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));

	e = tkaddchild(top, tk, &names);
	tkfreename(names);
	if(e != nil){
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;
	return tkvalue(ret, "%s", tk->name->name);
}

/* ---- command + method tables ---- */

static TkCmdtab ttktvcmd[] =
{
	"cget",			tvcget,
	"children",		tvchildren,
	"column",		tvcolumncmd,
	"configure",		tvconf,
	"delete",		tvdelete,
	"detach",		tvdetach,
	"exists",		tvexists,
	"focus",		tvfocuscmd,
	"heading",		tvheading,
	"identify",		tvidentify,
	"index",		tvindexcmd,
	"insert",		tvinsert,
	"instate",		tvinstatecmd,
	"item",			tvitemcmd,
	"move",			tvmove,
	"parent",		tvparent,
	"see",			tvsee,
	"selection",		tvselection,
	"state",		tvstatecmd,
	"style",		tvstylecmd,
	"tag",			tvtagcmd,
	"xview",		tvxview,
	"yview",		tvyview,
	"tkttktvPress",		tvpress,
	"tkttktvKey",		tvkey,
	nil
};

TkMethod ttktreeviewmethod = {
	"Treeview",
	ttktvcmd,
	tvfree,
	ttkdrawtv,
	ttktvgeom,
};
