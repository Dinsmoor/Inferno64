#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * qemu ramfb display via fw_cfg, x86 port-I/O flavour (boot with
 * -device ramfb).  Same DMA descriptor protocol as the MMIO ramfb on
 * -M virt (see drivers/ramfb.c) — only the way the DMA register is
 * kicked differs: on the PC fw_cfg lives at I/O port 0x510, with the
 * 64-bit big-endian DMA address register at 0x514.  Writing the low
 * half (0x518) starts the synchronous transfer.
 *
 * The descriptor and data buffers are big-endian; everything below 4GB
 * (identity-mapped guest RAM), so the high address dword is always 0.
 */

enum {
	FWselport	= 0x510,	/* selector (write 16-bit) */
	FWdmahi		= 0x514,	/* DMA address, high 32 bits (BE) */
	FWdmalo		= 0x518,	/* DMA address, low 32 bits (BE); write kicks */

	FWSIGNATURE	= 0x0000,	/* "QEMU" */
	FWFILEDIR	= 0x0019,	/* directory of named blobs */

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
#define RAMFBCFGLEN 28		/* device wants exactly 28, not the padded 32 */

static void
fwcfgkick(uintptr desc)
{
	outl(FWdmahi, BE32((u32int)(desc >> 32)));
	outl(FWdmalo, BE32((u32int)desc));	/* low write starts the DMA */
}

static int
fwcfgdma(int ctl, int select, void *data, ulong len)
{
	static FWCfgDma dma;
	int i;

	dma.control = BE32(((u32int)select<<16) | ctl);
	dma.len = BE32(len);
	dma.addr = BE64((uintptr)data);
	coherence();
	fwcfgkick((uintptr)&dma);
	coherence();
	for(i = 0; i < 1000000; i++){
		if(BE32(dma.control) == 0)
			return 0;
		if(BE32(dma.control) & DMAerror)
			return -1;
	}
	return -1;
}

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
	if(n > 256)
		return -1;
	for(i = 0; i < n; i++){
		if(fwcfgread(f, sizeof *f) < 0)
			return -1;
		if(strncmp(f->name, name, sizeof f->name) == 0){
			f->select = BE16(f->select);
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
