#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * qemu ramfb display via fw_cfg (boot with -device ramfb).
 *
 * fw_cfg on -M virt is the MMIO flavour at 0x09020000: data at +0,
 * selector at +8, DMA register at +16.  Everything the device reads or
 * returns is BIG-endian.  We use only the DMA interface: point the DMA
 * register at a FWCfgDma descriptor and the device performs the
 * transfer synchronously (clears the control word when done).
 *
 * ramfb itself is just one fw_cfg file, "etc/ramfb": write a 28-byte
 * {addr, fourcc, flags, width, height, stride} blob to it and qemu
 * scans the framebuffer in guest RAM every refresh.  No flush, no
 * vsync, no registers.
 */

enum {
	/* FWCFG_PHYS comes from io.h */
	FWdata		= 0x00,
	FWselector	= 0x08,
	FWdma		= 0x10,

	FWSIGNATURE	= 0x0000,	/* "QEMU" */
	FWFILEDIR	= 0x0019,	/* directory of named blobs */

	/* FWCfgDma control bits */
	DMAerror	= 1<<0,
	DMAread		= 1<<1,
	DMAskip		= 1<<2,
	DMAselect	= 1<<3,
	DMAwrite	= 1<<4,

	FOURCC_XR24	= 0x34325258,	/* DRM XRGB8888: b,g,r,x in memory */
};

#define BE16(x)	__builtin_bswap16(x)
#define BE32(x)	__builtin_bswap32(x)
#define BE64(x)	__builtin_bswap64(x)

typedef struct FWCfgDma FWCfgDma;
struct FWCfgDma {
	u32int	control;	/* BE */
	u32int	len;		/* BE */
	u64int	addr;		/* BE */
};

typedef struct FWCfgFile FWCfgFile;
struct FWCfgFile {
	u32int	size;		/* BE */
	u16int	select;		/* BE */
	u16int	reserved;
	char	name[56];
};

typedef struct Ramfbcfg Ramfbcfg;
struct Ramfbcfg {
	u64int	addr;		/* all BE */
	u32int	fourcc;
	u32int	flags;
	u32int	width;
	u32int	height;
	u32int	stride;
};
#define RAMFBCFGLEN 28		/* sizeof pads to 32; the device wants exactly 28 */

#define IOREG64(base, off)	(*(volatile u64int*)((uintptr)(base)+(off)))

static int
fwcfgdma(int ctl, int select, void *data, ulong len)
{
	static FWCfgDma dma;
	int i;

	dma.control = BE32(((u32int)select<<16) | ctl);
	dma.len = BE32(len);
	dma.addr = BE64((uintptr)data);
	coherence();
	IOREG64(FWCFG_PHYS, FWdma) = BE64((uintptr)&dma);
	coherence();
	for(i = 0; i < 1000000; i++){
		if(BE32(dma.control) == 0)
			return 0;
		if(BE32(dma.control) & DMAerror)
			return -1;
	}
	return -1;
}

/* read more of the currently selected item (no select bit: continues at the offset) */
static int
fwcfgread(void *data, ulong len)
{
	return fwcfgdma(DMAread, 0, data, len);
}

static int
fwcfgfindfile(char *name, FWCfgFile *f)
{
	u32int n;
	int i;

	if(fwcfgdma(DMAselect|DMAread, FWFILEDIR, &n, 4) < 0)
		return -1;
	n = BE32(n);
	if(n > 256)		/* sanity: qemu has a few dozen */
		return -1;
	for(i = 0; i < n; i++){
		if(fwcfgread(f, sizeof *f) < 0)
			return -1;
		if(strncmp(f->name, name, sizeof f->name) == 0){
			f->select = BE16(f->select);	/* directory entries are BE too */
			f->size = BE32(f->size);
			return 0;
		}
	}
	return -1;
}

uchar*
ramfbinit(int *width, int *height)
{
	char sig[5];
	FWCfgFile f;
	Ramfbcfg cfg;
	uchar *fb;
	int w, h;

	/* probe fw_cfg itself before trusting the DMA path */
	if(fwcfgdma(DMAselect|DMAread, FWSIGNATURE, sig, 4) < 0)
		return nil;
	sig[4] = 0;
	if(strcmp(sig, "QEMU") != 0)
		return nil;

	if(fwcfgfindfile("etc/ramfb", &f) < 0){
		print("ramfb: no etc/ramfb (boot qemu with -device ramfb)\n");
		return nil;
	}

	w = 1024;
	h = 768;
	fb = xspanalloc(w*h*4, BY2PG, 0);
	if(fb == nil)
		return nil;
	memset(fb, 0, w*h*4);

	cfg.addr = BE64((uintptr)fb);
	cfg.fourcc = BE32(FOURCC_XR24);
	cfg.flags = 0;
	cfg.width = BE32(w);
	cfg.height = BE32(h);
	cfg.stride = BE32(w*4);
	if(fwcfgdma(DMAselect|DMAwrite, f.select, &cfg, RAMFBCFGLEN) < 0){
		print("ramfb: config write failed\n");
		return nil;
	}

	print("ramfb: %dx%dx32 at %#p\n", w, h, fb);
	*width = w;
	*height = h;
	return fb;
}
