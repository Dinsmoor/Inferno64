/*
 * modern (virtio 1.0+) virtio-mmio transport — see virtio.c.
 * Boot qemu with -global virtio-mmio.force-legacy=false: that flips
 * EVERY mmio transport to version 2, so all drivers here speak modern.
 */

typedef struct Vdesc Vdesc;
typedef struct Vavail Vavail;
typedef struct Vusedelem Vusedelem;
typedef struct Vused Vused;
typedef struct Vqueue Vqueue;
typedef struct Vdev Vdev;

enum {
	Descnext	= 1,
	Descwrite	= 2,
};

struct Vdesc {		/* all fields little-endian, as is aarch64 */
	u64int	addr;
	u32int	len;
	u16int	flags;
	u16int	next;
};

struct Vavail {
	u16int	flags;
	u16int	idx;
	u16int	ring[];
};

struct Vusedelem {
	u32int	id;
	u32int	len;
};

struct Vused {
	u16int	flags;
	u16int	idx;
	Vusedelem ring[];
};

struct Vqueue {
	Vdesc	*desc;
	Vavail	*avail;
	Vused	*used;
	int	num;
	u16int	lastused;
	int	idx;		/* queue index on the device */
	Vdev	*dev;
};

struct Vdev {
	uintptr	base;
	int	slot;
	int	devid;
	int	irq;
	u32int	feat0;		/* negotiated device-class features (word 0) */
	void	(*intr)(Vdev*);	/* called with InterruptStatus already acked */
	void	*aux;
};

Vdev*	virtioprobe(int devid, int nth);
int	virtiodevinit(Vdev*, u32int accept0);
Vqueue*	virtioqalloc(Vdev*, int qidx, int num);
void	virtioready(Vdev*);
void	virtionotify(Vdev*, int qidx);
void	virtiointrenable(Vdev*, void (*)(Vdev*), char*);
int	virtiocfgr8(Vdev*, int off);
void	virtiocfgw8(Vdev*, int off, int val);
