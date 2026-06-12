/*
 * virtio-net (device id 1) on the modern virtio-mmio transport
 * (virtio.c).  Split queues: 0 = receive, 1 = transmit.  Under
 * VERSION_1 every packet is prefixed by a 12-byte virtio_net_hdr
 * (flags/gso/csum fields plus num_buffers); we offload nothing, so
 * it is all-zeros outbound and skipped inbound.
 *
 * Buffers are copied: receive slots are reposted after the payload
 * moves into an iallocb Block for etheriq, transmit Blocks are copied
 * into per-descriptor slots and freed at once.  At qemu -M virt
 * speeds the copy is noise, and it keeps Block lifetimes out of the
 * device's hands.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ureg.h"
#include "../port/error.h"
#include "../port/netif.h"

#include "etherif.h"
#include "virtio.h"

void	genrandom(uchar*, int);	/* stubs.c (libsec.h wants mp.h; skip it) */

enum {
	Fmac	= 1<<5,		/* device has a MAC in config space */

	Nrx	= 64,
	Ntx	= 64,
	Vhdrsz	= 12,		/* virtio_net_hdr incl. num_buffers (VERSION_1) */
	Slotsz	= 1600,		/* >= Vhdrsz + ETHERMAXTU */
};

typedef struct Ctlr Ctlr;
struct Ctlr {
	Vdev	*d;
	Vqueue	*rx;
	Vqueue	*tx;
	uchar	*rxbuf;		/* Nrx contiguous slots */
	uchar	*txbuf;		/* Ntx contiguous slots */
	Lock	tlock;
	int	txfree[Ntx];
	int	ntxfree;
};

static void
rxpost(Ctlr *c, int id)
{
	Vqueue *q;

	q = c->rx;
	q->desc[id].addr = (uintptr)(c->rxbuf + id*Slotsz);
	q->desc[id].len = Slotsz;
	q->desc[id].flags = Descwrite;
	q->desc[id].next = 0;
	q->avail->ring[q->avail->idx % q->num] = id;
	coherence();
	q->avail->idx++;
}

/* called with c->tlock held */
static void
txstart(Ether *ether)
{
	Ctlr *c;
	Vqueue *q;
	Block *b;
	uchar *slot;
	int id, n, kick;

	c = ether->ctlr;
	q = c->tx;
	kick = 0;
	while(c->ntxfree > 0){
		b = qget(ether->oq);
		if(b == nil)
			break;
		id = c->txfree[--c->ntxfree];
		slot = c->txbuf + id*Slotsz;
		n = BLEN(b);
		if(n > Slotsz - Vhdrsz)
			n = Slotsz - Vhdrsz;
		memset(slot, 0, Vhdrsz);
		memmove(slot + Vhdrsz, b->rp, n);
		freeb(b);
		q->desc[id].addr = (uintptr)slot;
		q->desc[id].len = Vhdrsz + n;
		q->desc[id].flags = 0;
		q->desc[id].next = 0;
		q->avail->ring[q->avail->idx % q->num] = id;
		coherence();
		q->avail->idx++;
		kick = 1;
	}
	if(kick)
		virtionotify(c->d, q->idx);
}

static void
transmit(Ether *ether)
{
	Ctlr *c;

	c = ether->ctlr;
	ilock(&c->tlock);
	txstart(ether);
	iunlock(&c->tlock);
}

static void
interrupt(Vdev *d)
{
	Ether *ether;
	Ctlr *c;
	Vqueue *q;
	Vusedelem *e;
	Block *b;
	int id, n, posted;

	ether = d->aux;
	c = ether->ctlr;

	q = c->rx;
	posted = 0;
	while(q->lastused != q->used->idx){
		e = &q->used->ring[q->lastused % q->num];
		id = e->id;
		n = e->len - Vhdrsz;
		q->lastused++;
		if(id < 0 || id >= Nrx)
			continue;
		if(n > 0 && n <= Slotsz - Vhdrsz){
			b = iallocb(n);
			if(b != nil){
				memmove(b->wp, c->rxbuf + id*Slotsz + Vhdrsz, n);
				b->wp += n;
				etheriq(ether, b, 1);
			} else
				ether->soverflows++;
		}
		rxpost(c, id);
		posted = 1;
	}
	if(posted)
		virtionotify(d, q->idx);

	/* reclaim sent slots, then feed the queue anything that piled up */
	q = c->tx;
	ilock(&c->tlock);
	while(q->lastused != q->used->idx){
		e = &q->used->ring[q->lastused % q->num];
		if(c->ntxfree < Ntx)
			c->txfree[c->ntxfree++] = e->id;
		q->lastused++;
	}
	txstart(ether);
	iunlock(&c->tlock);
}

static int
reset(Ether *ether)
{
	Ctlr *c;
	Vdev *d;
	int i;

	d = virtioprobe(1, ether->ctlrno);
	if(d == nil)
		return -1;
	if(virtiodevinit(d, Fmac) < 0){
		free(d);
		return -1;
	}

	c = malloc(sizeof(Ctlr));
	if(c == nil)
		return -1;
	memset(c, 0, sizeof(Ctlr));
	c->rx = virtioqalloc(d, 0, Nrx);
	c->tx = virtioqalloc(d, 1, Ntx);
	c->rxbuf = xspanalloc(Nrx*Slotsz, 64, 0);
	c->txbuf = xspanalloc(Ntx*Slotsz, 64, 0);
	if(c->rx == nil || c->tx == nil || c->rxbuf == nil || c->txbuf == nil){
		print("ethervirtio: out of memory\n");
		return -1;
	}
	for(i = 0; i < Ntx; i++)
		c->txfree[i] = i;
	c->ntxfree = Ntx;
	c->d = d;

	if(d->feat0 & Fmac){
		for(i = 0; i < Eaddrlen; i++)
			ether->ea[i] = virtiocfgr8(d, i);
	} else {
		/* qemu always offers F_MAC; this is for other hypervisors */
		ether->ea[0] = 0x52;
		ether->ea[1] = 0x54;
		ether->ea[2] = 0x00;
		genrandom(ether->ea+3, 3);
	}

	ether->ctlr = c;
	ether->irq = -1;	/* the transport owns the interrupt */
	ether->transmit = transmit;
	d->aux = ether;
	virtiointrenable(d, interrupt, "ethervirtio");

	for(i = 0; i < Nrx; i++)
		rxpost(c, i);
	virtioready(d);
	virtionotify(d, c->rx->idx);
	return 0;
}

void
ethervirtiolink(void)
{
	addethercard("virtio", reset);
}
