#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "virtio.h"

/*
 * modern (virtio 1.0) virtio-mmio transport for qemu -M virt.
 *
 * qemu's mmio transports default to force-legacy (version 1); boot with
 *     -global virtio-mmio.force-legacy=false
 * and every transport speaks version 2: 64-bit split queue addresses
 * (QueueDescLow/High etc.), QueueReady instead of QueuePFN, and a
 * feature handshake that must accept VIRTIO_F_VERSION_1.
 *
 * 32 transports at VIRTIO_PHYS + slot*0x200, interrupt 48+slot; qemu
 * assigns -device virtio-*-device instances from the LAST slot down.
 */

enum {
	Vmagic		= 0x000,	/* "virt" */
	Vversion	= 0x004,	/* 2 = modern */
	Vdevid		= 0x008,
	Vdevfeat	= 0x010,
	Vdevfeatsel	= 0x014,
	Vdrvfeat	= 0x020,
	Vdrvfeatsel	= 0x024,
	Vqsel		= 0x030,
	Vqnummax	= 0x034,
	Vqnum		= 0x038,
	Vqready		= 0x044,
	Vqnotify	= 0x050,
	Vintstatus	= 0x060,
	Vintack		= 0x064,
	Vstatus		= 0x070,
	Vqdesclo	= 0x080,
	Vqdeschi	= 0x084,
	Vqdrvlo		= 0x090,	/* avail ring */
	Vqdrvhi		= 0x094,
	Vqdevlo		= 0x0a0,	/* used ring */
	Vqdevhi		= 0x0a4,
	Vconfig		= 0x100,

	Sack		= 1,
	Sdriver		= 2,
	Sdriverok	= 4,
	Sfeatok		= 8,
	Sfailed		= 0x80,

	Fversion1	= 1<<0,		/* bit 32, i.e. bit 0 of feature word 1 */

	Nslots		= 32,
};

#define REG(d, r)	IOREG32((d)->base, (r))

Vdev*
virtioprobe(int devid, int nth)
{
	uintptr base;
	Vdev *d;
	int i;

	for(i = 0; i < Nslots; i++){
		base = VIRTIO_PHYS + i*0x200;
		if(IOREG32(base, Vmagic) != 0x74726976)
			continue;
		if(IOREG32(base, Vversion) != 2 || IOREG32(base, Vdevid) != devid)
			continue;
		if(nth-- > 0)
			continue;
		d = malloc(sizeof(Vdev));
		if(d == nil)
			return nil;
		d->base = base;
		d->slot = i;
		d->devid = devid;
		d->irq = VIRTIOIRQ0 + i;
		return d;
	}
	return nil;
}

int
virtiodevinit(Vdev *d)
{
	REG(d, Vstatus) = 0;			/* reset */
	while(REG(d, Vstatus) != 0)
		;
	REG(d, Vstatus) = Sack;
	REG(d, Vstatus) = Sack|Sdriver;

	REG(d, Vdevfeatsel) = 1;
	if((REG(d, Vdevfeat) & Fversion1) == 0){
		print("virtio%d slot %d: no VERSION_1 feature\n", d->devid, d->slot);
		REG(d, Vstatus) = Sfailed;
		return -1;
	}
	/* accept VERSION_1 and nothing else: every driver here is that simple */
	REG(d, Vdrvfeatsel) = 0;
	REG(d, Vdrvfeat) = 0;
	REG(d, Vdrvfeatsel) = 1;
	REG(d, Vdrvfeat) = Fversion1;

	REG(d, Vstatus) = Sack|Sdriver|Sfeatok;
	if((REG(d, Vstatus) & Sfeatok) == 0){
		print("virtio%d slot %d: features rejected\n", d->devid, d->slot);
		REG(d, Vstatus) = Sfailed;
		return -1;
	}
	return 0;
}

Vqueue*
virtioqalloc(Vdev *d, int qidx, int num)
{
	Vqueue *q;
	uchar *p;
	ulong descsz, availsz, usedsz;

	REG(d, Vqsel) = qidx;
	if(REG(d, Vqnummax) < num)
		return nil;

	descsz = num*sizeof(Vdesc);
	availsz = sizeof(Vavail) + num*sizeof(u16int);
	usedsz = sizeof(Vused) + num*sizeof(Vusedelem);
	p = xspanalloc(descsz + availsz + ROUND(usedsz, 4), BY2PG, 0);
	if(p == nil)
		return nil;
	memset(p, 0, descsz + availsz + usedsz);

	q = malloc(sizeof(Vqueue));
	if(q == nil)
		return nil;
	q->desc = (Vdesc*)p;
	q->avail = (Vavail*)(p + descsz);
	q->used = (Vused*)(p + descsz + availsz);
	q->num = num;
	q->lastused = 0;
	q->idx = qidx;
	q->dev = d;

	REG(d, Vqnum) = num;
	REG(d, Vqdesclo) = (uintptr)q->desc;
	REG(d, Vqdeschi) = (uintptr)q->desc >> 32;
	REG(d, Vqdrvlo) = (uintptr)q->avail;
	REG(d, Vqdrvhi) = (uintptr)q->avail >> 32;
	REG(d, Vqdevlo) = (uintptr)q->used;
	REG(d, Vqdevhi) = (uintptr)q->used >> 32;
	coherence();
	REG(d, Vqready) = 1;
	return q;
}

void
virtioready(Vdev *d)
{
	coherence();
	REG(d, Vstatus) = Sack|Sdriver|Sfeatok|Sdriverok;
}

void
virtionotify(Vdev *d, int qidx)
{
	coherence();
	REG(d, Vqnotify) = qidx;
}

static void
virtiointr(Ureg *ur, void *a)
{
	Vdev *d;

	USED(ur);
	d = a;
	REG(d, Vintack) = REG(d, Vintstatus);
	if(d->intr != nil)
		d->intr(d);
}

void
virtiointrenable(Vdev *d, void (*f)(Vdev*), char *name)
{
	d->intr = f;
	intrenable(d->irq, virtiointr, d, BusCPU, name);
}

int
virtiocfgr8(Vdev *d, int off)
{
	return *(volatile uchar*)(d->base + Vconfig + off);
}

void
virtiocfgw8(Vdev *d, int off, int val)
{
	*(volatile uchar*)(d->base + Vconfig + off) = val;
}
