#pragma	src	"/usr/inferno/libmemdraw"

typedef struct	Memimage Memimage;
typedef struct	Memdata Memdata;
typedef struct	Memsubfont Memsubfont;
typedef struct	Memlayer Memlayer;
typedef struct	Memcmap Memcmap;
typedef struct	Memdrawparam	Memdrawparam;

#pragma incomplete Memlayer

/*
 * Memdata is allocated from main pool, but .data from the image pool.
 * Memdata is allocated separately to permit patching its pointer after
 * compaction when windows share the image data.
 * The first word of data is a back pointer to the Memdata, to find
 * The word to patch.
 */

struct Memdata
{
	ulong	*base;	/* allocated data pointer */
	uchar	*bdata;	/* pointer to first byte of actual data; word-aligned */
	int		ref;		/* number of Memimages using this data */
	void*	imref;
	int		allocd;	/* is this malloc'd? */
};

enum {
	Frepl		= 1<<0,	/* is replicated */
	Fsimple	= 1<<1,	/* is 1x1 */
	Fgrey	= 1<<2,	/* is grey */
	Falpha	= 1<<3,	/* has explicit alpha */
	Fcmap	= 1<<4,	/* has cmap channel */
	Fbytes	= 1<<5,	/* has only 8-bit channels */
};

struct Memimage
{
	Rectangle	r;		/* rectangle in data area, local coords */
	Rectangle	clipr;		/* clipping region */
	int		depth;	/* number of bits of storage per pixel */
	int		nchan;	/* number of channels */
	ulong	chan;	/* channel descriptions */
	Memcmap	*cmap;

	Memdata	*data;	/* pointer to data; shared by windows in this image */
	int		zero;		/* data->bdata+zero==&byte containing (0,0) */
	ulong	width;	/* width in words of a single scan line */
	Memlayer	*layer;	/* nil if not a layer*/
	ulong	flags;

	int		shift[NChan];
	int		mask[NChan];
	int		nbits[NChan];
};

struct Memcmap
{
	uchar	cmap2rgb[3*256];
	uchar	rgb2cmap[16*16*16];
};

/*
 * Subfonts
 *
 * given char c, Subfont *f, Fontchar *i, and Point p, one says
 *	i = f->info+c;
 *	draw(b, Rect(p.x+i->left, p.y+i->top,
 *		p.x+i->left+((i+1)->x-i->x), p.y+i->bottom),
 *		color, f->bits, Pt(i->x, i->top));
 *	p.x += i->width;
 * to draw characters in the specified color (itself a Memimage) in Memimage b.
 */

struct	Memsubfont
{
	char		*name;
	short	n;		/* number of chars in font */
	uchar	height;		/* height of bitmap */
	char	ascent;		/* top of bitmap to baseline */
	Fontchar *info;		/* n+1 character descriptors */
	Memimage	*bits;		/* of font */
};

/*
 * Encapsulated parameters and information for sub-draw routines.
 */
enum {
	Simplesrc=1<<0,
	Simplemask=1<<1,
	Replsrc=1<<2,
	Replmask=1<<3,
	Fullmask=1<<4,
};
struct	Memdrawparam
{
	Memimage *dst;
	Rectangle	r;
	Memimage *src;
	Rectangle sr;
	Memimage *mask;
	Rectangle mr;
	int op;

	ulong state;
	ulong mval;	/* if Simplemask, the mask pixel in mask format */
	ulong mrgba;	/* mval in rgba */
	ulong sval;	/* if Simplesrc, the source pixel in src format */
	ulong srgba;	/* sval in rgba */
	ulong sdval;	/* sval in dst format */
};

/*
 * Memimage management
 */

extern Memimage*	allocmemimage(Rectangle, ulong);
extern Memimage*	allocmemimaged(Rectangle, ulong, Memdata*);
extern Memimage*	readmemimage(int);
extern Memimage*	creadmemimage(int);
extern int	writememimage(int, Memimage*);
extern void	freememimage(Memimage*);
extern int		loadmemimage(Memimage*, Rectangle, uchar*, int);
extern int		cloadmemimage(Memimage*, Rectangle, uchar*, int);
extern int		unloadmemimage(Memimage*, Rectangle, uchar*, int);
extern ulong*	wordaddr(Memimage*, Point);
extern uchar*	byteaddr(Memimage*, Point);
extern int		drawclip(Memimage*, Rectangle*, Memimage*, Point*, Memimage*, Point*, Rectangle*, Rectangle*);
extern void	memfillcolor(Memimage*, ulong);
extern int		memsetchan(Memimage*, ulong);

/*
 * 3D software rasterizer (mesh.c): triangle fill with a per-pixel depth buffer,
 * flat/Gouraud/perspective-correct-textured, writing into any 8-bit-channel
 * Memimage in its own channel order.  A Memvtx is a vertex already projected to
 * screen space; its layout matches the Limbo $Raster3 Vtx adt (10 contiguous
 * doubles) so a Limbo Vtx array can be passed straight through.
 */
typedef struct Memvtx Memvtx;
struct Memvtx
{
	double	x, y;		/* screen pixel coordinates (image-local) */
	double	z;		/* depth (NDC z); smaller is nearer */
	double	iw;		/* 1/w_clip, for perspective-correct interpolation */
	double	u, v;		/* texture coordinates 0..1 */
	double	r, g, b, a;	/* colour 0..1 */
};

enum {				/* shading modes */
	MEMmeshFLAT	= 0,
	MEMmeshGOURAUD	= 1,
	MEMmeshTEXTURED	= 2,
};
enum {				/* back-face culling by signed screen area */
	MEMmeshCULLNONE	= 0,
	MEMmeshCULLNEG	= 1,
	MEMmeshCULLPOS	= 2,
};

extern int	memmesh(Memimage*, double*, Memvtx*, int, int*, int, Memimage*, int, int);
extern void	memmeshproject(Memvtx*, double*, double*, double*, int,
			double*, double*, double, double, double*, double, double*);

/*
 * Graphics
 */
extern void	memdraw(Memimage*, Rectangle, Memimage*, Point, Memimage*, Point, int);
extern void	memline(Memimage*, Point, Point, int, int, int, Memimage*, Point, int);
extern void	mempoly(Memimage*, Point*, int, int, int, int, Memimage*, Point, int);
extern void	memfillpoly(Memimage*, Point*, int, int, Memimage*, Point, int);
extern void	_memfillpolysc(Memimage*, Point*, int, int, Memimage*, Point, int, int, int, int);
extern void	memimagedraw(Memimage*, Rectangle, Memimage*, Point, Memimage*, Point, int);
extern int	hwdraw(Memdrawparam*);
extern void	memimageline(Memimage*, Point, Point, int, int, int, Memimage*, Point, int);
extern void	_memimageline(Memimage*, Point, Point, int, int, int, Memimage*, Point, Rectangle, int);
extern Point	memimagestring(Memimage*, Point, Memimage*, Point, Memsubfont*, char*);
extern void	memellipse(Memimage*, Point, int, int, int, Memimage*, Point, int);
extern void	memarc(Memimage*, Point, int, int, int, Memimage*, Point, int, int, int);
extern Rectangle	memlinebbox(Point, Point, int, int, int);
extern int	memlineendsize(int);
extern void	_memmkcmap(void);
extern void	memimageinit(void);

/*
 * Subfont management
 */
extern Memsubfont*	allocmemsubfont(char*, int, int, int, Fontchar*, Memimage*);
extern Memsubfont*	openmemsubfont(char*);
extern void	freememsubfont(Memsubfont*);
extern Point	memsubfontwidth(Memsubfont*, char*);
extern Memsubfont*	getmemdefont(void);

/*
 * Predefined 
 */
extern	Memimage*	memwhite;
extern	Memimage*	memblack;
extern	Memimage*	memopaque;
extern	Memimage*	memtransparent;
extern	Memcmap	*memdefcmap;

/*
 * Kernel interface
 */
uchar*	attachscreen(Rectangle*, ulong*, int*, int*, int*);
void		memimagemove(void*, void*);

/*
 * Kernel cruft
 */
extern void	rdb(void);
extern int		iprint(char*, ...);
#pragma varargck argpos iprint 1
extern int		drawdebug;

/*
 * doprint interface: numbconv bit strings
 */
#pragma varargck type "llb" vlong
#pragma varargck type "llb" uvlong
#pragma varargck type "lb" long
#pragma varargck type "lb" ulong
#pragma varargck type "b" int
#pragma varargck type "b" uint

