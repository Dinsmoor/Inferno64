#include "lib9.h"
#include "draw.h"
#include "tk.h"
#include <kernel.h>

/*
 * The `font' command.  Inferno has no Tcl named-font object; a font is a
 * font-file spec opened with font_open().  This exposes the measurement
 * subset modern Tk code (and the ttk layout engine) relies on:
 *
 *	font measure  <fontspec> <text>
 *	font metrics  <fontspec> ?-ascent|-descent|-linespace|-fixed?
 *	font actual   <fontspec> ?option?
 *	font families
 *	font names
 *
 * <fontspec> is a font file (e.g. /fonts/pelm/unicode.9.font); an empty
 * spec, or "." style default, uses the toplevel's default font.  Named-font
 * creation (`font create') is intentionally not provided yet — apps name
 * fonts directly through the existing -font option.
 *
 * Purely additive: a brand-new top-level command; no existing behaviour moves.
 */

/* resolve a fontspec to a Font*; *opened set if the caller must close it */
static Font*
fontresolve(TkTop *t, char *spec, int *opened)
{
	Font *f;

	*opened = 0;
	if(spec[0] == '\0')
		return t->env != nil ? t->env->font : nil;
	f = font_open(t->display, spec);
	if(f != nil)
		*opened = 1;
	return f;
}

static char*
fontmeasure(TkTop *t, char *arg, char **ret)
{
	Font *f;
	int opened, w, locked;
	char *e, *spec, *text;

	spec = mallocz(Tkmaxitem, 0);
	text = mallocz(Tkmaxitem, 0);
	if(spec == nil || text == nil){
		free(spec); free(text);
		return TkNomem;
	}
	arg = tkword(t, arg, spec, spec+Tkmaxitem, nil);
	tkword(t, arg, text, text+Tkmaxitem, nil);

	f = fontresolve(t, spec, &opened);
	if(f == nil){
		free(spec); free(text);
		return TkBadft;
	}
	locked = lockdisplay(t->display);
	w = stringwidth(f, text);
	if(locked)
		unlockdisplay(t->display);
	if(opened)
		freefont(f);

	e = tkvalue(ret, "%d", w);
	free(spec); free(text);
	return e;
}

static char*
fontmetrics(TkTop *t, char *arg, char **ret)
{
	Font *f;
	int opened, asc, desc, line;
	char *e, *spec, *opt;

	spec = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	if(spec == nil || opt == nil){
		free(spec); free(opt);
		return TkNomem;
	}
	arg = tkword(t, arg, spec, spec+Tkmaxitem, nil);
	tkword(t, arg, opt, opt+Tkmaxitem, nil);

	f = fontresolve(t, spec, &opened);
	if(f == nil){
		free(spec); free(opt);
		return TkBadft;
	}
	line = f->height;
	asc = f->ascent;
	desc = f->height - f->ascent;
	if(opened)
		freefont(f);

	if(strcmp(opt, "-ascent") == 0)
		e = tkvalue(ret, "%d", asc);
	else if(strcmp(opt, "-descent") == 0)
		e = tkvalue(ret, "%d", desc);
	else if(strcmp(opt, "-linespace") == 0)
		e = tkvalue(ret, "%d", line);
	else if(strcmp(opt, "-fixed") == 0)
		e = tkvalue(ret, "%d", 0);
	else if(opt[0] == '\0')
		e = tkvalue(ret, "-ascent %d -descent %d -linespace %d -fixed 0",
			asc, desc, line);
	else
		e = TkBadvl;

	free(spec); free(opt);
	return e;
}

static char*
fontactual(TkTop *t, char *arg, char **ret)
{
	Font *f;
	int opened;
	char *e, *spec;

	spec = mallocz(Tkmaxitem, 0);
	if(spec == nil)
		return TkNomem;
	tkword(t, arg, spec, spec+Tkmaxitem, nil);
	f = fontresolve(t, spec, &opened);
	if(f == nil){
		free(spec);
		return TkBadft;
	}
	e = tkvalue(ret, "%s", f->name != nil ? f->name : spec);
	if(opened)
		freefont(f);
	free(spec);
	return e;
}

char*
tkfontcmd(TkTop *t, char *arg, char **ret)
{
	char *sub, *e;

	sub = mallocz(Tkmaxitem, 0);
	if(sub == nil)
		return TkNomem;
	arg = tkword(t, arg, sub, sub+Tkmaxitem, nil);

	if(strcmp(sub, "measure") == 0)
		e = fontmeasure(t, arg, ret);
	else if(strcmp(sub, "metrics") == 0)
		e = fontmetrics(t, arg, ret);
	else if(strcmp(sub, "actual") == 0)
		e = fontactual(t, arg, ret);
	else if(strcmp(sub, "families") == 0)
		e = tkvalue(ret, "");
	else if(strcmp(sub, "names") == 0)
		e = tkvalue(ret, "");
	else
		e = TkBadcm;

	free(sub);
	return e;
}
