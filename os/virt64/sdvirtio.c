/*
 * virtio-blk (device id 2) for devsd, on the modern virtio-mmio
 * transport (virtio.c).  One SDev with a unit per disk qemu was given
 * (-drive if=none,id=hdN,file=... -device virtio-blk-device,drive=hdN);
 * units appear as /dev/sd0N once '#S' is bound.
 *
 * A request is the canonical three-descriptor chain: 16-byte header
 * (type/reserved/sector), the data buffer (pointed at the caller's —
 * kernel memory is identity-mapped), one device-written status byte.
 * One request in flight per unit (qlock), completion by interrupt.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"
#include "../port/error.h"

#include "../port/sd.h"
#include "virtio.h"

extern SDifc sdvirtioifc;

enum {
	Vread	= 0,	/* virtio-blk request types (T* taken by fcall.h) */
	Vwrite	= 1,

	Statusok	= 0,

	Nq	= 8,		/* descriptors: 2 chains' worth is plenty */
	Maxio	= 128*1024,	/* per-request cap; bio loops */

	Maxdisks = 4,
};

typedef struct Vblkhdr Vblkhdr;
struct Vblkhdr {		/* device-read request header */
	u32int	type;
	u32int	reserved;
	u64int	sector;
};

typedef struct Disk Disk;
struct Disk {
	Vdev	*d;
	Vqueue	*q;
	uvlong	sectors;
	QLock;			/* one request at a time */
	Rendez	r;
	Vblkhdr	*hdr;		/* DMA: request header */
	uchar	*status;	/* DMA: status byte */
};

static Disk *disks[Maxdisks];
static int ndisks;

static void
vblkintr(Vdev *d)
{
	Disk *disk;

	disk = d->aux;
	wakeup(&disk->r);
}

static int
vblkdone(void *a)
{
	Disk *disk;

	disk = a;
	coherence();
	return disk->q->used->idx != disk->q->lastused;
}

static long
vblkrw(Disk *disk, int write, uvlong sector, uchar *data, long len)
{
	Vqueue *q;
	int st;

	q = disk->q;
	qlock(disk);
	if(waserror()){
		qunlock(disk);
		nexterror();
	}

	disk->hdr->type = write ? Vwrite : Vread;
	disk->hdr->reserved = 0;
	disk->hdr->sector = sector;
	*disk->status = ~0;

	q->desc[0].addr = (uintptr)disk->hdr;
	q->desc[0].len = sizeof(Vblkhdr);
	q->desc[0].flags = Descnext;
	q->desc[0].next = 1;
	q->desc[1].addr = (uintptr)data;
	q->desc[1].len = len;
	q->desc[1].flags = Descnext | (write ? 0 : Descwrite);
	q->desc[1].next = 2;
	q->desc[2].addr = (uintptr)disk->status;
	q->desc[2].len = 1;
	q->desc[2].flags = Descwrite;
	q->desc[2].next = 0;

	q->avail->ring[q->avail->idx % q->num] = 0;
	coherence();
	q->avail->idx++;
	virtionotify(disk->d, q->idx);

	while(!vblkdone(disk))
		sleep(&disk->r, vblkdone, disk);
	q->lastused = q->used->idx;
	st = *disk->status;

	poperror();
	qunlock(disk);

	if(st != Statusok)
		error(Eio);
	return len;
}

static long
vblkbio(SDunit *unit, int lun, int write, void *data, long nb, long bno)
{
	Disk *disk;
	uchar *p;
	long n, max, done;

	USED(lun);
	disk = disks[unit->subno];
	if(disk == nil)
		error(Enodev);

	p = data;
	done = 0;
	max = Maxio / unit->secsize;
	while(done < nb){
		n = nb - done;
		if(n > max)
			n = max;
		vblkrw(disk, write, bno + done, p + done*unit->secsize, n*unit->secsize);
		done += n;
	}
	return done * unit->secsize;
}

static int
vblkrio(SDreq *r)
{
	USED(r);
	return SDeio;	/* no SCSI emulation; use ctl/data, not raw */
}

static int
vblkverify(SDunit *unit)
{
	if(unit->subno >= ndisks || disks[unit->subno] == nil)
		return 0;
	memset(unit->inquiry, 0, sizeof(unit->inquiry));
	unit->inquiry[2] = 2;
	unit->inquiry[3] = 2;
	unit->inquiry[4] = sizeof(unit->inquiry)-4;
	strcpy((char*)&unit->inquiry[8], "virtio-blk disk");
	return 1;
}

static int
vblkonline(SDunit *unit)
{
	Disk *disk;

	disk = disks[unit->subno];
	if(disk == nil)
		return 0;
	unit->sectors = disk->sectors;
	unit->secsize = 512;
	return 1;
}

static Disk*
vblkprobe(int nth)
{
	Disk *disk;
	Vdev *d;
	uchar *p;
	int i;

	d = virtioprobe(2, nth);
	if(d == nil)
		return nil;
	if(virtiodevinit(d, 0) < 0){
		free(d);
		return nil;
	}
	disk = malloc(sizeof(Disk));
	if(disk == nil)
		return nil;
	disk->q = virtioqalloc(d, 0, Nq);
	p = xspanalloc(sizeof(Vblkhdr) + 64, 64, 0);
	if(disk->q == nil || p == nil){
		print("sdvirtio: out of memory\n");
		return nil;
	}
	disk->hdr = (Vblkhdr*)p;
	disk->status = p + sizeof(Vblkhdr);

	/* config space: u64 capacity in 512-byte sectors at offset 0 */
	disk->sectors = 0;
	for(i = 7; i >= 0; i--)
		disk->sectors = disk->sectors<<8 | virtiocfgr8(d, i);

	disk->d = d;
	d->aux = disk;
	virtiointrenable(d, vblkintr, "sdvirtio");
	virtioready(d);
	print("sdvirtio: disk %d at slot %d, %llud sectors\n",
		nth, d->slot, disk->sectors);
	return disk;
}

static SDev*
vblkpnp(void)
{
	SDev *sdev;
	int i;

	for(i = 0; i < Maxdisks; i++){
		disks[ndisks] = vblkprobe(ndisks);
		if(disks[ndisks] == nil)
			break;
		ndisks++;
	}
	if(ndisks == 0)
		return nil;

	sdev = malloc(sizeof(SDev));
	if(sdev == nil)
		return nil;
	sdev->ifc = &sdvirtioifc;
	sdev->nunit = ndisks;
	return sdev;
}

static SDev*
vblkid(SDev *sdev)
{
	for(; sdev != nil; sdev = sdev->next){
		if(sdev->ifc == &sdvirtioifc){
			sdev->idno = '0';
			kstrdup(&sdev->name, "sd0");
		}
	}
	return nil;
}

SDifc sdvirtioifc = {
	"virtio",		/* name */

	vblkpnp,		/* pnp */
	nil,			/* legacy */
	vblkid,			/* id */
	nil,			/* enable */
	nil,			/* disable */

	vblkverify,		/* verify */
	vblkonline,		/* online */
	vblkrio,		/* rio */
	nil,			/* rctl */
	nil,			/* wctl */

	vblkbio,		/* bio */
	nil,			/* probe */
	nil,			/* clear */
	nil,			/* stat */
};
