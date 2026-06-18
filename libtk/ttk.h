/*
 * ttk.h - private definitions shared by the native ttk engine (ttk.c) and
 * the ttk widgets (ttkwidg.c et al).  Not installed; libtk-internal.
 *
 * The ttk widgets are a parallel set (class names TFrame/TLabel/TButton/...)
 * that paint through the style engine here rather than hand-painting a fixed
 * 3D look.  Classic widgets are untouched.  Defaults are seeded from the
 * existing themed TkEnv colour slots, so `theme' keeps theming ttk too.
 */

/* ttk widget state bits (TkTtk.state) */
enum
{
	Sactive		= 1<<0,	/* pointer over the widget (ttk "active") */
	Sdisabled	= 1<<1,
	Sfocus		= 1<<2,
	Spressed	= 1<<3,
	Sselected	= 1<<4,
	Sbackground	= 1<<5,
	Salternate	= 1<<6,
	Sinvalid	= 1<<7,
	Sreadonly	= 1<<8,
	Shover		= 1<<9
};

typedef struct TkTtk TkTtk;
typedef struct Ttkopt Ttkopt;
typedef struct Ttkmapent Ttkmapent;
typedef struct Ttkmap Ttkmap;
typedef struct Ttkstyle Ttkstyle;

/* per-widget data, appended after Tk via TKobj(TkTtk, tk) */
struct TkTtk
{
	ulong	state;		/* S* bits */
	char*	style;		/* explicit -style, or nil => class default */
	char*	text;		/* -text */
	char*	command;	/* -command (button/check/radio) */
	char*	textvar;	/* -textvariable */
	char*	variable;	/* -variable (check/radio) */
	char*	onvalue;	/* -onvalue (check) */
	char*	offvalue;	/* -offvalue (check) */
	char*	value;		/* -value (radio) */
	int	check;		/* check/radio currently selected */
	int	ul;		/* -underline */
	int	anchor;		/* -anchor (Tk* anchor bits) */
	int	justify;
	int	width;		/* -width in chars, 0 = natural */
	int	orient;		/* Tkhorizontal/Tkvertical (separator/progress) */
	int	pvalue;		/* -value (progressbar, fixed point Tkfpscalar) */
	int	pmaximum;	/* -maximum (progressbar, fixed point) */
	int	length;		/* -length (progressbar, px) */
	int	pmode;		/* 0 = determinate, 1 = indeterminate */
	int	prunning;	/* progressbar animation active */
	int	phase;		/* indeterminate animation phase */
	Point	tsize;		/* natural content size, set by ttksize */
};

/* one option fixed by `ttk::style configure STYLE -opt val' */
struct Ttkopt
{
	char*	name;
	char*	val;
	Ttkopt*	link;
};

/* one (statespec -> value) entry within a `ttk::style map' option */
struct Ttkmapent
{
	ulong	on;		/* states that must be set */
	ulong	off;		/* states that must be clear */
	char*	val;
	Ttkmapent* link;
};

/* the state map for a single option of a style */
struct Ttkmap
{
	char*	name;
	Ttkmapent* ents;
	Ttkmap*	link;
};

/* a named style */
struct Ttkstyle
{
	char*	name;
	Ttkopt*	opts;
	Ttkmap*	maps;
	Ttkstyle* link;
};

/* engine entry points (ttk.c) */
extern	int	ttkstateparse(char*, ulong*, ulong*);
extern	char*	ttkstatestr(ulong, char*, int);
extern	char*	ttkrestorespec(ulong, ulong, char*, int);
extern	char*	ttkresolve(TkTop*, char*, char*, ulong);
extern	Image*	ttkcolor(Tk*, char*, int);
extern	char*	ttkget(Tk*, char*);
extern	int	ttkgetint(Tk*, char*, int);
extern	char*	ttkstylename(Tk*);
extern	void	ttkfreetop(TkTop*);

/* shared widget helpers (ttk.c) */
extern	Tk*	ttknewobj(TkTop*, int, char*);
extern	char*	ttkstatecmd(Tk*, char*, char**);
extern	char*	ttkinstatecmd(Tk*, char*, char**);
extern	char*	ttkstylecmd(Tk*, char*, char**);
extern	char*	ttkidentcmd(Tk*, char*, char**);
extern	void	ttksetstate(Tk*, ulong);
extern	void	ttkfreedata(Tk*);

/* element painters (ttk.c) */
extern	void	ttkfillbg(Tk*, Image*, Rectangle, ulong);
extern	void	ttkborder(Tk*, Image*, Rectangle, ulong);
extern	void	ttkfocusring(Tk*, Image*, Rectangle, ulong);
extern	Image*	ttktmpimage(Tk*, Point, ulong);

/* from label.h family, used by ttkwidg.c */
extern	char*	tksetvar(TkTop*, char*, char*);
