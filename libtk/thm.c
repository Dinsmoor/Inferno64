#include "lib9.h"
#include "draw.h"
#include "tk.h"

/*
 * The "theme" Tk command: mutate the system-wide palette/font/relief (tktheme,
 * libtk/colrs.c) at runtime and re-theme live windows.  Because every toplevel
 * inherits its palette through tksetenvcolours() and widgets COW-share their
 * toplevel's env (tkdupenv), changing tktheme then re-running tksetenvcolours
 * on a toplevel's env re-colours every default widget at once; explicit
 * per-widget -background/-foreground values are preserved.
 *
 *	theme set <key> <val> ...	keys: fg bg activebg activefg select
 *					selectbg selectfg disablefg font
 *					borderwidth relief
 *	theme reset			restore built-in defaults
 *	theme get			report current as "key val ..."
 *	theme reapply			rebuild THIS top's env + repaint its tree
 */

extern char* tkfont;			/* libtk/utils.c */

static char defaultfont[] = "/fonts/pelm/unicode.8.font";
static char *fontbuf;			/* our heap copy backing tkfont */

static ulong*
themecolour(char *key)
{
	if(strcmp(key, "fg") == 0 || strcmp(key, "foreground") == 0)
		return &tktheme.fg;
	if(strcmp(key, "bg") == 0 || strcmp(key, "background") == 0)
		return &tktheme.bg;
	if(strcmp(key, "activebg") == 0)
		return &tktheme.activebg;
	if(strcmp(key, "activefg") == 0)
		return &tktheme.activefg;
	if(strcmp(key, "select") == 0)
		return &tktheme.select;
	if(strcmp(key, "selectbg") == 0)
		return &tktheme.selectbg;
	if(strcmp(key, "selectfg") == 0)
		return &tktheme.selectfg;
	if(strcmp(key, "disablefg") == 0)
		return &tktheme.disablefg;
	return nil;
}

static void
setthemefont(char *path)
{
	char *n;

	n = malloc(strlen(path)+1);
	if(n == nil)
		return;
	strcpy(n, path);
	free(fontbuf);
	fontbuf = n;
	tkfont = fontbuf;
}

static char*
themeset(TkTop *t, char *arg)
{
	char key[Tkmaxitem], val[Tkmaxitem];
	char *e;
	ulong rgba, *cp;

	for(;;){
		arg = tkword(t, arg, key, key+sizeof(key), nil);
		if(key[0] == '\0')
			break;
		arg = tkword(t, arg, val, val+sizeof(val), nil);
		if(val[0] == '\0')
			return TkBadvl;
		cp = themecolour(key);
		if(cp != nil){
			e = tkparsecolor(val, &rgba);
			if(e != nil)
				return e;
			*cp = rgba;
		}else if(strcmp(key, "font") == 0){
			setthemefont(val);
		}else if(strcmp(key, "borderwidth") == 0){
			tktheme.borderwidth = atoi(val);
		}else if(strcmp(key, "relief") == 0){
			strncpy(tktheme.relief, val, sizeof(tktheme.relief)-1);
			tktheme.relief[sizeof(tktheme.relief)-1] = '\0';
		}else
			return TkBadop;
	}
	return nil;
}

/* colours are stored as 32-bit RGBA in a ulong; mask off any sign-extension
 * (the R<<24 in the colour macros overflows int) before reporting them. */
#define RGBA32(c)	((ulong)((c) & 0xffffffffUL))

static char*
themeget(char **ret)
{
	char *e;

	e = tkvalue(ret, "fg #%.8lux bg #%.8lux activebg #%.8lux activefg #%.8lux ",
		RGBA32(tktheme.fg), RGBA32(tktheme.bg), RGBA32(tktheme.activebg), RGBA32(tktheme.activefg));
	if(e != nil)
		return e;
	e = tkvalue(ret, "select #%.8lux selectbg #%.8lux selectfg #%.8lux disablefg #%.8lux ",
		RGBA32(tktheme.select), RGBA32(tktheme.selectbg), RGBA32(tktheme.selectfg), RGBA32(tktheme.disablefg));
	if(e != nil)
		return e;
	return tkvalue(ret, "font %s borderwidth %d relief %s",
		tkfont != nil ? tkfont : defaultfont, tktheme.borderwidth, tktheme.relief);
}

static char*
themereapply(TkTop *t)
{
	Tk *tk;
	Display *d;
	Font *nf;
	int locked;

	if(t->env != nil){
		tksetenvcolours(t->env);
		if(t->env->font != nil && tkfont != nil &&
		   strcmp(t->env->font->name, tkfont) != 0){
			d = t->display;
			locked = lockdisplay(d);
			nf = font_open(d, tkfont);
			if(nf != nil){
				font_close(t->env->font);
				t->env->font = nf;
				t->env->wzero = stringwidth(nf, "0");
				if(t->env->wzero <= 0)
					t->env->wzero = nf->height / 2;
			}
			if(locked)
				unlockdisplay(d);
		}
	}
	for(tk = t->root; tk != nil; tk = tk->siblings)
		tk->dirty = tkrect(tk, 1);
	t->dirty = 1;
	return tkupdate(t);
}

char*
tkthemecmd(TkTop *t, char *arg, char **ret)
{
	char sub[Tkmaxitem];

	arg = tkword(t, arg, sub, sub+sizeof(sub), nil);
	if(strcmp(sub, "set") == 0)
		return themeset(t, arg);
	if(strcmp(sub, "reset") == 0){
		tkthemereset();
		free(fontbuf);
		fontbuf = nil;
		tkfont = defaultfont;
		return nil;
	}
	if(strcmp(sub, "get") == 0)
		return themeget(ret);
	if(strcmp(sub, "reapply") == 0)
		return themereapply(t);
	return TkBadop;
}
