/*
 * PCI Express, generic ECAM host bridge (qemu -M virt "pcie"/GPEX, and
 * the same MMIO config layout on real arm64 SoCs).  This is the portable
 * face the in-tree PCI drivers (ether*, sd*) link against — the canonical
 * Plan 9 Pcidev/pcimatch API, with an ECAM config-space backend in pci.c
 * instead of the x86 CF8/CFC ports.
 *
 * A driver's reset() walks the bus with pcimatch(), finds its controller
 * by vendor/device id, reads its BARs out of p->mem[], its interrupt out
 * of p->intl (already a GIC SPI — see pci.c INTx swizzle), and calls
 * pcisetbme() to become a bus master.
 */

typedef struct Pcidev Pcidev;

struct Pcidev
{
	int	tbdf;			/* type+bus+device+function */
	ushort	vid;			/* vendor ID */
	ushort	did;			/* device ID */

	ushort	pcr;			/* command register (shadow) */

	uchar	rid;
	uchar	ccrp;			/* programming interface class */
	uchar	ccru;			/* sub-class */
	uchar	ccrb;			/* base class */
	uchar	cls;			/* cache line size */
	uchar	ltr;			/* latency timer */

	struct {
		uvlong	bar;		/* base address (assigned by pci.c) */
		int	size;
	} mem[6];

	struct {
		uvlong	bar;
		int	size;
	} rom;
	uchar	intl;			/* interrupt line == GIC SPI (INTx) */

	Pcidev*	list;			/* flat list, scan order */
	Pcidev*	link;			/* next device on this bus */
	Pcidev*	bridge;			/* type-1: devices behind this bridge */
};

enum {					/* type+bus+device+function */
	BusPCI	= 1,
};

#define MKBUS(t,b,d,f)	(((t)<<24)|(((b)&0xFF)<<16)|(((d)&0x1F)<<11)|(((f)&0x07)<<8))
#define BUSFNO(tbdf)	(((tbdf)>>8)&0x07)
#define BUSDNO(tbdf)	(((tbdf)>>11)&0x1F)
#define BUSBNO(tbdf)	(((tbdf)>>16)&0xFF)
#define BUSTYPE(tbdf)	((tbdf)>>24)
#define BUSBDF(tbdf)	((tbdf)&0x00FFFF00)

enum {					/* type 0/1 pre-defined header */
	PciVID		= 0x00,		/* vendor ID */
	PciDID		= 0x02,		/* device ID */
	PciPCR		= 0x04,		/* command */
	PciPSR		= 0x06,		/* status */
	PciRID		= 0x08,		/* revision ID */
	PciCCRp		= 0x09,		/* programming interface class code */
	PciCCRu		= 0x0A,		/* sub-class code */
	PciCCRb		= 0x0B,		/* base class code */
	PciCLS		= 0x0C,		/* cache line size */
	PciLTR		= 0x0D,		/* latency timer */
	PciHDT		= 0x0E,		/* header type */
	PciBST		= 0x0F,		/* BIST */

	PciBAR0		= 0x10,		/* base address[0..5] */
	PciSVID		= 0x2C,		/* subsystem vendor ID */
	PciSID		= 0x2E,		/* subsystem ID */
	PciCAP		= 0x34,		/* capabilities list pointer */
	PciINTL		= 0x3C,		/* interrupt line */
	PciINTP		= 0x3D,		/* interrupt pin */

	PciSBN		= 0x19,		/* type 1: secondary bus number */
	PciUBN		= 0x1A,		/* type 1: subordinate bus number */

	PciCapMSI	= 0x05,		/* capability ids */
	PciCapMSIX	= 0x11,
	PciStatusCAP	= 1<<4,		/* PciPSR: capability list present */
};

enum {					/* command register (PciPCR) bits */
	IOen		= 1<<0,
	MEMen		= 1<<1,
	MASen		= 1<<2,		/* bus master enable */
	SErrEn		= 1<<8,
};

extern void	pciscan(void);				/* enumerate, once, at boot */
extern Pcidev*	pcimatch(Pcidev*, int vid, int did);	/* 0 == wildcard */
extern Pcidev*	pcimatchtbdf(int tbdf);

extern int	pcicfgr8(Pcidev*, int rno);
extern int	pcicfgr16(Pcidev*, int rno);
extern int	pcicfgr32(Pcidev*, int rno);
extern void	pcicfgw8(Pcidev*, int rno, int data);
extern void	pcicfgw16(Pcidev*, int rno, int data);
extern void	pcicfgw32(Pcidev*, int rno, int data);

extern void	pcisetbme(Pcidev*);
extern void	pciclrbme(Pcidev*);

/*
 * Route this device's interrupt through MSI-X (one vector) instead of INTx.
 * On success the handler f is wired to a GICv3 LPI and 0 is returned; -1 means
 * MSI is unavailable (no GICv3 ITS, or no MSI-X capability) and the caller
 * should fall back to intrenable(p->intl, ...).
 */
extern int	pcimsienable(Pcidev*, void (*f)(Ureg*, void*), void *a, char *name);
