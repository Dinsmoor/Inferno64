#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "virtio.h"

/*
 * virtio entropy device (id 4) on the modern transport (virtio.c).
 * Polled, no interrupt: an entropy request is one device-writable
 * descriptor, and qemu's rng-builtin backend answers immediately, so
 * spinning on used->idx is simpler than taking the interrupt for a
 * device this slow-path.
 *
 * genrandom() (stubs.c) pulls from here and falls back to its xorshift
 * when no device was found, so `-device virtio-rng-device` is optional
 * on the qemu command line.
 */

enum {
	Qsize	= 8,
};

static struct {
	Lock;
	Vdev	*dev;
	Vqueue	*q;
	int	ok;
	uchar	buf[64];	/* DMA bounce buffer (identity-mapped) */
} rng;

void
virtiornginit(void)
{
	Vdev *d;

	d = virtioprobe(4, 0);
	if(d == nil)
		return;
	if(virtiodevinit(d) < 0){
		free(d);
		return;
	}
	rng.q = virtioqalloc(d, 0, Qsize);
	if(rng.q == nil){
		free(d);
		return;
	}
	virtioready(d);
	rng.dev = d;
	rng.ok = 1;
	print("virtio-rng at %#p (slot %d)\n", d->base, d->slot);
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
	Vqueue *q;

	if(!rng.ok)
		return 0;

	q = rng.q;
	got = 0;
	lock(&rng);
	while(got < n){
		want = n - got;
		if(want > sizeof(rng.buf))
			want = sizeof(rng.buf);

		q->desc[0].addr = (uintptr)rng.buf;
		q->desc[0].len = want;
		q->desc[0].flags = Descwrite;
		q->desc[0].next = 0;
		q->avail->ring[q->avail->idx % Qsize] = 0;
		coherence();
		q->avail->idx++;
		virtionotify(rng.dev, 0);

		for(timo = 1000000; timo > 0; timo--){
			coherence();
			if(q->used->idx != q->lastused)
				break;
		}
		if(timo == 0){
			rng.ok = 0;	/* device wedged; fall back to PRNG */
			break;
		}

		e = &q->used->ring[q->lastused % Qsize];
		len = e->len;
		q->lastused++;
		if(len == 0 || len > want)
			break;
		memmove(buf+got, rng.buf, len);
		got += len;
	}
	unlock(&rng);
	return got;
}
