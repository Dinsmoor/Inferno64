#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ureg.h"
#include "virtio.h"

/*
 * virtio-gpu (device id 16) 2D scanout on the modern virtio-mmio
 * transport (virtio.c).  Boot qemu with
 *     -device virtio-gpu-device
 * (and -global virtio-mmio.force-legacy=false, already required by the
 * other virtio drivers).  This is the alternative to ramfb: it gives a
 * real host-side scanout resource instead of a buffer qemu rescans for
 * free, at the cost of an explicit TRANSFER_TO_HOST_2D + RESOURCE_FLUSH
 * after every change.  screen.c prefers it and falls back to ramfb.
 *
 * The framebuffer is ordinary guest RAM (XRGB8888 = b,g,r,x in memory,
 * matching Inferno's XRGB32 and DRM XR24); we hand its identity-mapped
 * address to the device as the resource backing.  Because virtio-gpu
 * never rescans on its own, a 30Hz refresh kproc (vgpustart, kicked off
 * from boardready once the scheduler is up) transfers+flushes the whole
 * screen — so kernel-console text and devdraw output both appear without
 * any per-draw hook.  flushmemscreen stays a no-op, exactly as for ramfb.
 *
 * 2D only: no VIRGL, no EDID — Inferno composites in software and just
 * needs the pixels scanned out.  Commands go on the control queue and we
 * poll the used ring synchronously (no interrupt handler); one command
 * at a time under cmdlock.
 */

enum {
	Gpudevid	= 16,

	/* control commands (2D subset) */
	CmdGetDisplayInfo	= 0x0100,
	CmdResourceCreate2d	= 0x0101,
	CmdSetScanout		= 0x0103,
	CmdResourceFlush	= 0x0104,
	CmdTransferToHost2d	= 0x0105,
	CmdResourceAttachBacking= 0x0106,

	/* responses */
	RespOkNodata		= 0x1100,

	FormatXrgb		= 2,	/* B8G8R8X8_UNORM: b,g,r,x in memory */

	Resid			= 1,	/* our single scanout resource */
	Scanout			= 0,

	Nq			= 8,	/* control-queue descriptors */
	Refreshms		= 33,	/* ~30Hz scanout refresh */

	Width			= 1024,
	Height			= 768,
};

typedef struct Ctrlhdr Ctrlhdr;
struct Ctrlhdr {		/* prefixes every request and response */
	u32int	type;
	u32int	flags;
	u64int	fenceid;
	u32int	ctxid;
	u32int	padding;
};

typedef struct Grect Grect;
struct Grect {
	u32int	x;
	u32int	y;
	u32int	width;
	u32int	height;
};

typedef struct Create2d Create2d;
struct Create2d {
	Ctrlhdr	hdr;
	u32int	resource_id;
	u32int	format;
	u32int	width;
	u32int	height;
};

typedef struct Attachbacking Attachbacking;
struct Attachbacking {		/* with a single inline memory entry */
	Ctrlhdr	hdr;
	u32int	resource_id;
	u32int	nr_entries;
	u64int	addr;
	u32int	length;
	u32int	padding;
};

typedef struct Setscanout Setscanout;
struct Setscanout {
	Ctrlhdr	hdr;
	Grect	r;
	u32int	scanout_id;
	u32int	resource_id;
};

typedef struct Transfer2d Transfer2d;
struct Transfer2d {
	Ctrlhdr	hdr;
	Grect	r;
	u64int	offset;
	u32int	resource_id;
	u32int	padding;
};

typedef struct Resflush Resflush;
struct Resflush {
	Ctrlhdr	hdr;
	Grect	r;
	u32int	resource_id;
	u32int	padding;
};

static Vdev	*gpu;
static Vqueue	*ctlq;
static uchar	*fb;
static int	fbw, fbh;
static Lock	cmdlock;
static uchar	*cmdbuf;	/* DMA scratch: request copied here */
static uchar	*respbuf;	/* DMA scratch: response header */
static Rendez	refreshr;

/*
 * Submit one request on the control queue and wait for its response.
 * Two-descriptor chain: request (device-read) then a response header
 * (device-write).  Synchronous poll of the used ring; serialized by
 * cmdlock so the static descriptors and scratch buffers are reusable.
 */
static int
vgpucmd(void *req, int reqlen)
{
	Vqueue *q;
	Ctrlhdr *rh;
	int i, t;

	lock(&cmdlock);
	q = ctlq;
	memmove(cmdbuf, req, reqlen);
	rh = (Ctrlhdr*)respbuf;
	rh->type = 0;

	q->desc[0].addr = (uintptr)cmdbuf;
	q->desc[0].len = reqlen;
	q->desc[0].flags = Descnext;
	q->desc[0].next = 1;
	q->desc[1].addr = (uintptr)respbuf;
	q->desc[1].len = sizeof(Ctrlhdr);
	q->desc[1].flags = Descwrite;
	q->desc[1].next = 0;

	q->avail->ring[q->avail->idx % q->num] = 0;
	coherence();
	q->avail->idx++;
	virtionotify(gpu, q->idx);

	for(i = 0; i < 100000000; i++){
		coherence();
		if(q->used->idx != q->lastused)
			break;
	}
	q->lastused = q->used->idx;
	t = rh->type;
	unlock(&cmdlock);

	if(t != RespOkNodata){
		print("vgpu: command 0x%ux -> response 0x%ux\n",
			((Ctrlhdr*)req)->type, t);
		return -1;
	}
	return 0;
}

/* push a rectangle of the framebuffer to the host and flash it onto the scanout */
void
vgpuflush(int x, int y, int w, int h)
{
	Transfer2d xfer;
	Resflush fl;

	if(gpu == nil)
		return;

	memset(&xfer, 0, sizeof xfer);
	xfer.hdr.type = CmdTransferToHost2d;
	xfer.r.x = x;
	xfer.r.y = y;
	xfer.r.width = w;
	xfer.r.height = h;
	xfer.offset = (uvlong)(y*fbw + x) * 4;
	xfer.resource_id = Resid;
	if(vgpucmd(&xfer, sizeof xfer) < 0)
		return;

	memset(&fl, 0, sizeof fl);
	fl.hdr.type = CmdResourceFlush;
	fl.r.x = x;
	fl.r.y = y;
	fl.r.width = w;
	fl.r.height = h;
	fl.resource_id = Resid;
	vgpucmd(&fl, sizeof fl);
}

static void
vgporefresh(void *)
{
	for(;;){
		tsleep(&refreshr, return0, nil, Refreshms);
		vgpuflush(0, 0, fbw, fbh);
	}
}

/* started from boardready, once kproc is usable */
void
vgpustart(void)
{
	if(gpu != nil)
		kproc("vgpu", vgporefresh, nil, 0);
}

uchar*
vgpuinit(int *width, int *height)
{
	Vdev *d;
	Create2d cr;
	Attachbacking ab;
	Setscanout ss;
	uchar *p;

	d = virtioprobe(Gpudevid, 0);
	if(d == nil)
		return nil;
	if(virtiodevinit(d, 0) < 0){		/* no VIRGL/EDID needed for 2D */
		free(d);
		return nil;
	}
	ctlq = virtioqalloc(d, 0, Nq);		/* controlq */
	p = xspanalloc(256, 64, 0);		/* cmd + resp DMA scratch */
	if(ctlq == nil || p == nil){
		print("vgpu: out of memory\n");
		return nil;
	}
	cmdbuf = p;
	respbuf = p + 128;
	gpu = d;
	virtioready(d);

	fbw = Width;
	fbh = Height;
	fb = xspanalloc(fbw*fbh*4, BY2PG, 0);
	if(fb == nil){
		print("vgpu: framebuffer alloc failed\n");
		gpu = nil;
		return nil;
	}
	memset(fb, 0, fbw*fbh*4);

	/* host-side 2D resource matching the framebuffer */
	memset(&cr, 0, sizeof cr);
	cr.hdr.type = CmdResourceCreate2d;
	cr.resource_id = Resid;
	cr.format = FormatXrgb;
	cr.width = fbw;
	cr.height = fbh;
	if(vgpucmd(&cr, sizeof cr) < 0)
		goto fail;

	/* back it with our guest-RAM framebuffer (identity-mapped, contiguous) */
	memset(&ab, 0, sizeof ab);
	ab.hdr.type = CmdResourceAttachBacking;
	ab.resource_id = Resid;
	ab.nr_entries = 1;
	ab.addr = (uintptr)fb;
	ab.length = fbw*fbh*4;
	if(vgpucmd(&ab, sizeof ab) < 0)
		goto fail;

	/* point scanout 0 at the resource */
	memset(&ss, 0, sizeof ss);
	ss.hdr.type = CmdSetScanout;
	ss.r.width = fbw;
	ss.r.height = fbh;
	ss.scanout_id = Scanout;
	ss.resource_id = Resid;
	if(vgpucmd(&ss, sizeof ss) < 0)
		goto fail;

	vgpuflush(0, 0, fbw, fbh);		/* show the cleared screen */

	print("vgpu: %dx%dx32 scanout at slot %d, fb %#p\n", fbw, fbh, d->slot, fb);
	*width = fbw;
	*height = fbh;
	return fb;

fail:
	print("vgpu: scanout setup failed; falling back\n");
	gpu = nil;
	return nil;
}
