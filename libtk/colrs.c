#include "lib9.h"
#include "draw.h"
#include "tk.h"

#define RGB(R,G,B) ((R<<24)|(G<<16)|(B<<8)|(0xff))

enum
{
	tkBackR		= 0xdd,		/* Background base color */
	tkBackG 	= 0xdd,
	tkBackB 	= 0xdd,

	tkSelectR	= 0xb0,		/* Check box selected color */
	tkSelectG	= 0x30,
	tkSelectB	= 0x60,

	tkSelectbgndR	= 0x40,		/* Selected item background */
	tkSelectbgndG	= 0x40,
	tkSelectbgndB	= 0x40
};

/*
 * System-wide Tk theme.  Every toplevel's default palette and the default
 * relief/borderwidth flow from here through tksetenvcolours(); see thm.c for
 * the runtime "theme" command that mutates it and re-themes live windows.
 * The eight base colours below are the only ones a theme names; the light/dark
 * shades of the three "group of 3" colours are derived with tkrgbashade().
 */
#define THEMEDEFAULTS \
{ \
	RGB(0, 0, 0),					/* fg */ \
	RGB(tkBackR, tkBackG, tkBackB),			/* bg */ \
	RGB(tkBackR+0x10, tkBackG+0x10, tkBackB+0x10),	/* activebg */ \
	RGB(0, 0, 0),					/* activefg */ \
	RGB(tkSelectR, tkSelectG, tkSelectB),		/* select */ \
	RGB(tkSelectbgndR, tkSelectbgndG, tkSelectbgndB),	/* selectbg */ \
	RGB(0xff, 0xff, 0xff),				/* selectfg */ \
	RGB(0x88, 0x88, 0x88),				/* disablefg */ \
	RGB(0xaa, 0xaa, 0xaa),				/* titlebg (unfocused) */ \
	RGB(0xff, 0xff, 0xff),				/* titlefg */ \
	RGB(0x00, 0x00, 0xff),				/* titlefocusbg (focused) */ \
	1,						/* borderwidth */ \
	"raised",					/* relief */ \
}

TkTheme tktheme = THEMEDEFAULTS;

void
tkthemereset(void)
{
	static TkTheme defs = THEMEDEFAULTS;
	tktheme = defs;
}

static void
setshades(TkEnv *env, int base, ulong rgba)
{
	env->colors[base]   = tkrgbashade(rgba, TkSameshade);
	env->colors[base+1] = tkrgbashade(rgba, TkLightshade);
	env->colors[base+2] = tkrgbashade(rgba, TkDarkshade);
	env->set |= (1<<base) | (1<<(base+1)) | (1<<(base+2));
}

static void
setcolour(TkEnv *env, int c, ulong rgba)
{
	env->colors[c] = tkrgbashade(rgba, TkSameshade);
	env->set |= (1<<c);
}

void
tksetenvcolours(TkEnv *env)
{
	setshades(env, TkCbackgnd, tktheme.bg);
	setshades(env, TkCactivebgnd, tktheme.activebg);
	setshades(env, TkCselectbgnd, tktheme.selectbg);

	setcolour(env, TkCforegnd, tktheme.fg);
	setcolour(env, TkCactivefgnd, tktheme.activefg);
	setcolour(env, TkCselect, tktheme.select);
	setcolour(env, TkCselectfgnd, tktheme.selectfg);
	setcolour(env, TkCdisablefgnd, tktheme.disablefg);
	setcolour(env, TkChighlightfgnd, tktheme.fg);
	setcolour(env, TkCtransparent, DTransparent);
}
