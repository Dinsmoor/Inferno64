#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"

/*
 * Minimal virtio-mmio entropy driver (device id 4), legacy interface
 * (version 1 — qemu's virtio-mmio transports default to force-legacy).
 * Polled, no interrupt: an entropy request is one device-writable
 * descriptor, and qemu's rng-builtin backend answers immediately, so
 * spinning on used->idx is simpler than wiring intid 48+slot through
 * the GIC for a device this slow-path.
 *
 * genrandom() (stubs.c) pulls from here and falls back to its xorshift
 * when no device was found, so `-device virtio-rng-device` is optional
 * on the qemu command line.
 */

enum {
	/* virtio-mmio registers (legacy layout) */
	Vmagic		= 0x000,	/* 0x74726976 "virt" */
	Vversion	= 0x004,	/* 1 = legacy */
	Vdevid		= 0x008,	/* 4 = entropy */
	Vdevfeat	= 0x010,
	Vdrvfeat	= 0x020,
	Vguestpgsize	= 0x028,
	Vqsel		= 0x030,
	Vqnummax	= 0x034,
	Vqnum		= 0x038,
	Vqalign		= 0x03c,
	Vqpfn		= 0x040,
	Vqnotify	= 0x050,
	Vintstatus	= 0x060,
	Vintack		= 0x064,
	Vstatus		= 0x070,

	Magic		= 0x74726976,
	Devrng		= 4,
	Nslot		= 32,		/* qemu -M virt transports, 0x200 apart */

	/* Vstatus bits */
	Sack		= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfailed		= 0x80,

	Descwrite	= 2,		/* descriptor flags: device writes */

	Qsize		= 8,		/* must be power of 2, <= Vqnummax */
	Pgsize		= 4096,
};

typedef struct Vdesc Vdesc;
struct Vdesc
{
	u64int	addr;
	u32int	len;
	u16int	flags;
	u16int	next;
};

typedef struct Vavail Vavail;
struct Vavail
{
	u16int	flags;
	u16int	idx;
	u16int	ring[Qsize];
};

typedef struct Vusedelem Vusedelem;
struct Vusedelem
{
	u32int	id;
	u32int	len;
};

typedef struct Vused Vused;
struct Vused
{
	u16int	flags;
	u16int	idx;
	Vusedelem ring[Qsize];
};

static struct
{
	Lock;
	uintptr	base;
	Vdesc	*desc;
	Vavail	*avail;
	Vused	*used;
	u16int	lastused;
	int	ok;
	uchar	buf[64];	/* DMA bounce buffer (identity-mapped) */
} rng;

void
virtiornginit(void)
{
	int slot;
	uintptr base;
	uchar *p;
	ulong dasz, usz;

	base = 0;
	for(slot = 0; slot < Nslot; slot++){
		base = VIRTIO_PHYS + slot*0x200;
		if(IOREG32(base, Vmagic) != Magic)
			continue;
		if(IOREG32(base, Vversion) != 1)
			continue;
		if(IOREG32(base, Vdevid) == Devrng)
			break;
	}
	if(slot == Nslot)
		return;

	IOREG32(base, Vstatus) = 0;		/* reset */
	IOREG32(base, Vstatus) = Sack;
	IOREG32(base, Vstatus) = Sack|Sdriver;
	IOREG32(base, Vdrvfeat) = 0;		/* entropy device: no features needed */
	IOREG32(base, Vguestpgsize) = Pgsize;	/* must precede Vqpfn */

	IOREG32(base, Vqsel) = 0;
	if(IOREG32(base, Vqnummax) < Qsize){
		IOREG32(base, Vstatus) = Sfailed;
		return;
	}

	/* legacy vring: desc table + avail ring, then used ring on the next page */
	dasz = ROUND(Qsize*sizeof(Vdesc) + sizeof(Vavail), Pgsize);
	usz = ROUND(sizeof(Vused), Pgsize);
	p = xspanalloc(dasz+usz, Pgsize, 0);
	if(p == nil){
		IOREG32(base, Vstatus) = Sfailed;
		return;
	}
	memset(p, 0, dasz+usz);
	rng.desc = (Vdesc*)p;
	rng.avail = (Vavail*)(p + Qsize*sizeof(Vdesc));
	rng.used = (Vused*)(p + dasz);

	IOREG32(base, Vqnum) = Qsize;
	IOREG32(base, Vqalign) = Pgsize;
	coherence();
	IOREG32(base, Vqpfn) = (uintptr)p / Pgsize;
	IOREG32(base, Vstatus) = Sack|Sdriver|Sdriverok;

	rng.base = base;
	rng.ok = 1;
	print("virtio-rng at %#p (slot %d)\n", base, slot);
}

/*
 * Pull up to n bytes of device entropy; returns how many were got
 * (0 if no device or it stopped answering).  Safe from process or
 * init context; not from interrupt (uses lock + a bounded spin).
 */
int
virtiorngread(uchar *buf, int n)
{
	int got, want, timo;
	u32int len;
	Vusedelem *e;

	if(!rng.ok)
		return 0;

	got = 0;
	lock(&rng);
	while(got < n){
		want = n - got;
		if(want > sizeof(rng.buf))
			want = sizeof(rng.buf);

		rng.desc[0].addr = (uintptr)rng.buf;
		rng.desc[0].len = want;
		rng.desc[0].flags = Descwrite;
		rng.desc[0].next = 0;
		rng.avail->ring[rng.avail->idx % Qsize] = 0;
		coherence();
		rng.avail->idx++;
		coherence();
		IOREG32(rng.base, Vqnotify) = 0;

		for(timo = 1000000; timo > 0; timo--){
			coherence();
			if(rng.used->idx != rng.lastused)
				break;
		}
		if(timo == 0){
			rng.ok = 0;	/* device wedged; fall back to PRNG */
			break;
		}

		e = &rng.used->ring[rng.lastused % Qsize];
		len = e->len;
		rng.lastused++;
		IOREG32(rng.base, Vintack) = IOREG32(rng.base, Vintstatus);
		if(len == 0 || len > want)
			break;
		memmove(buf+got, rng.buf, len);
		got += len;
	}
	unlock(&rng);
	return got;
}
