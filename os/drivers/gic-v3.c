#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"ureg.h"

/*
 * GICv3 interrupt controller (qemu -M virt,gic-version=3).
 *
 * Three pieces, vs GICv2's two:
 *   - Distributor (board.h GICD_PHYS): SPIs (intid >= 32).  Affinity
 *     routing (ARE) is on, so SPI targeting is GICD_IROUTER, not the v2
 *     byte-per-irq ITARGETSR.
 *   - Redistributor (board.h GICR_PHYS), one per cpu: SGIs/PPIs (intid <
 *     32) live here now, not in the distributor.  Must be woken before use.
 *   - CPU interface: ICC_* system registers (mrs/msr), not the v2 MMIO
 *     GICC.  EL1 reaches them only because l.S sets ICC_SRE_EL2.Enable on
 *     the EL2->EL1 drop.
 *
 * Implements the same intc* interface (fns.h) as gic-v2.c; the board picks
 * exactly one of the two (board.mk GIC=v2|v3).  trap.c owns the vectors and
 * calls intcdispatch from the irq trap to claim/dispatch/EOI until dry.
 */

enum {
	/* distributor */
	GICD_CTLR	= 0x0000,
	GICD_TYPER	= 0x0004,	/* ITLinesNumber in [4:0] */
	GICD_IGROUPR	= 0x0080,	/* + 4*(n/32) */
	GICD_ISENABLER	= 0x0100,
	GICD_ICENABLER	= 0x0180,
	GICD_ICPENDR	= 0x0280,
	GICD_IPRIORITYR	= 0x0400,	/* byte per irq */
	GICD_IROUTER	= 0x6000,	/* 64-bit per intid, intid >= 32 */

	GICD_CTLR_ENGRP1 = 1<<1,	/* (single security state: DS=1 layout) */
	GICD_CTLR_ARE	 = 1<<4,
	GICD_CTLR_RWP	 = 1u<<31,	/* register write pending */

	/* redistributor: RD_base frame, then SGI_base 64KB further on */
	GICR_CTLR	= 0x0000,
	GICR_WAKER	= 0x0014,
	GICR_SGI_OFF	= 0x10000,	/* SGI_base = GICR_PHYS + this */
	GICR_IGROUPR0	= 0x0080,
	GICR_ISENABLER0	= 0x0100,
	GICR_ICENABLER0	= 0x0180,
	GICR_ICPENDR0	= 0x0280,
	GICR_IPRIORITYR	= 0x0400,

	WAKER_PS	= 1<<1,		/* ProcessorSleep */
	WAKER_CA	= 1<<2,		/* ChildrenAsleep */

	GICSPECIAL	= 1020,		/* 1020..1023 are special/spurious intids */
	GICSPECIALTOP	= 1023,		/* LPIs (>=8192) are above this and ARE real */
};

#define GICR_SGI	(GICR_PHYS + GICR_SGI_OFF)
#define GICD64(off)	(*(volatile u64int*)((uintptr)GICD_PHYS + (off)))

#define isb()		asm volatile("isb" ::: "memory")
#define dsb()		asm volatile("dsb sy" ::: "memory")
#define rdsysr(r)	({ u64int _v; asm volatile("mrs %0, " #r : "=r"(_v)); _v; })
#define wrsysr(r, v)	asm volatile("msr " #r ", %0" :: "r"((u64int)(v)))

static void itsinit(void);	/* defined below; called at the end of intcinit */

static void
rwpwait(void)
{
	while(IOREG32(GICD_PHYS, GICD_CTLR) & GICD_CTLR_RWP)
		;
}

void
intcenable(int irq)
{
	if(irq < 32)
		IOREG32(GICR_SGI, GICR_ISENABLER0) = 1u << irq;
	else
		IOREG32(GICD_PHYS, GICD_ISENABLER + 4*(irq/32)) = 1u << (irq%32);
}

void
intcdisable(int irq)
{
	if(irq < 32)
		IOREG32(GICR_SGI, GICR_ICENABLER0) = 1u << irq;
	else
		IOREG32(GICD_PHYS, GICD_ICENABLER + 4*(irq/32)) = 1u << (irq%32);
	rwpwait();
}

static void
redistwake(void)
{
	u32int w;

	/* clear ProcessorSleep, then wait for the children to wake */
	w = IOREG32(GICR_PHYS, GICR_WAKER) & ~WAKER_PS;
	IOREG32(GICR_PHYS, GICR_WAKER) = w;
	while(IOREG32(GICR_PHYS, GICR_WAKER) & WAKER_CA)
		;
}

void
intcinit(void)
{
	int i, max;

	/* distributor off while we configure it */
	IOREG32(GICD_PHYS, GICD_CTLR) = 0;
	rwpwait();

	max = (((IOREG32(GICD_PHYS, GICD_TYPER) & 0x1f) + 1) * 32);
	if(max > NIRQ)
		max = NIRQ;

	/* SPIs: group1, disabled, mid priority */
	for(i = 32; i < max; i += 32){
		IOREG32(GICD_PHYS, GICD_IGROUPR + 4*(i/32)) = ~0u;
		IOREG32(GICD_PHYS, GICD_ICENABLER + 4*(i/32)) = ~0u;
		IOREG32(GICD_PHYS, GICD_ICPENDR + 4*(i/32)) = ~0u;
	}
	for(i = 32; i < max; i += 4)
		IOREG32(GICD_PHYS, GICD_IPRIORITYR + i) = 0xa0a0a0a0;

	/* turn on affinity routing, then route every SPI to this cpu (aff 0) */
	IOREG32(GICD_PHYS, GICD_CTLR) = GICD_CTLR_ARE;
	rwpwait();
	for(i = 32; i < max; i++)
		GICD64(GICD_IROUTER + 8*i) = 0;
	IOREG32(GICD_PHYS, GICD_CTLR) = GICD_CTLR_ARE | GICD_CTLR_ENGRP1;
	rwpwait();

	/* redistributor for this cpu: wake it, then set up SGIs/PPIs */
	redistwake();
	IOREG32(GICR_SGI, GICR_IGROUPR0) = ~0u;		/* all group1 */
	IOREG32(GICR_SGI, GICR_ICENABLER0) = ~0u;	/* all disabled */
	IOREG32(GICR_SGI, GICR_ICPENDR0) = ~0u;
	for(i = 0; i < 32; i += 4)
		IOREG32(GICR_SGI, GICR_IPRIORITYR + i) = 0xa0a0a0a0;

	/* cpu interface: enable the system-register interface, then group1 */
	wrsysr(ICC_SRE_EL1, rdsysr(ICC_SRE_EL1) | 1);
	isb();
	wrsysr(ICC_PMR_EL1, 0xff);	/* unmask all priorities */
	wrsysr(ICC_BPR1_EL1, 0);	/* no preemption grouping */
	wrsysr(ICC_IGRPEN1_EL1, 1);	/* signal group1 interrupts */
	isb();

	itsinit();			/* LPIs + ITS for PCI MSI/MSI-X (best-effort) */
}

void
intcdispatch(Ureg *ur)
{
	u32int iar, v;

	for(;;){
		iar = rdsysr(ICC_IAR1_EL1);
		v = iar & 0xffffff;		/* intid is 24 bits in v3 */
		if(v >= GICSPECIAL && v <= GICSPECIALTOP)
			break;			/* 1020..1023 special; LPIs (>=8192) are real */
		dispatchirq(ur, v);
		wrsysr(ICC_EOIR1_EL1, iar);
	}
}

/*
 * LPIs and the ITS — the path that turns a PCI MSI/MSI-X memory write into a
 * delivered interrupt.  GICv2 has none of this; gic-v2.c stubs intcmsialloc to
 * return -1 so a driver falls back to INTx.
 *
 * Shape: every LPI's enable+priority lives in a per-redistributor
 * Configuration table in normal memory; the redistributor also needs a Pending
 * table.  The ITS owns a command queue and two in-memory tables (Devices,
 * Collections).  To deliver an MSI a device writes its EventID to
 * GITS_TRANSLATER; the ITS uses the writer's DeviceID (its PCI requester id) to
 * look up the ITT, translates (DeviceID,EventID) -> (LPI INTID, Collection),
 * and the collection's target redistributor signals the LPI through ICC_IAR1.
 *
 * Single-cpu: one redistributor, one collection (ICID 0).  One EventID (0) per
 * device — enough for one completion vector per controller, which is what the
 * storage drivers need.  SMP and multi-vector MSI-X extend this, they don't
 * change it.
 */
enum {
	/* redistributor RD_base frame: LPI enable + table pointers */
	GICR_TYPER	= 0x0008,	/* 64-bit; [23:8] = processor number */
	GICR_CTLR_EnableLPIs = 1<<0,
	GICR_PROPBASER	= 0x0070,
	GICR_PENDBASER	= 0x0078,

	/* ITS control frame (GITS_PHYS) */
	GITS_CTLR	= 0x0000,
	GITS_TYPER	= 0x0008,	/* PTA=bit19, ITTe size=[7:4] */
	GITS_CBASER	= 0x0080,
	GITS_CWRITER	= 0x0088,
	GITS_CREADR	= 0x0090,
	GITS_BASER0	= 0x0100,	/* 8 x 64-bit Device/Collection table descriptors */
	GITS_TRANSLATER	= 0x10040,	/* in the translation frame (+0x10000) */

	GITS_CTLR_Enabled = 1<<0,
	BASER_Valid	= 1ull<<63,
	BASER_TYPE_DEV	= 1,		/* GITS_BASER.Type: device table */
	BASER_TYPE_COL	= 4,		/* collection table */

	/* ITS command opcodes (byte 0 of the 32-byte command) */
	ITS_SYNC	= 0x05,
	ITS_MAPD	= 0x08,
	ITS_MAPC	= 0x09,
	ITS_MAPTI	= 0x0a,
	ITS_INV		= 0x0c,

	LPIBASE		= 8192,		/* INTIDs 0..8191 are SGI/PPI/SPI; LPIs start here */
	NMSI		= 64,		/* MSI vectors we hand out */
	LPI_IDBITS	= 14,		/* config table spans INTID 0..16383 */
};

#define GITS32(off)	(*(volatile u32int*)((uintptr)GITS_PHYS + (off)))
#define GITS64(off)	(*(volatile u64int*)((uintptr)GITS_PHYS + (off)))
#define GICR64(off)	(*(volatile u64int*)((uintptr)GICR_PHYS + (off)))

static uchar	*lpiconfig;		/* 1 byte per LPI, indexed by INTID-LPIBASE */
static u64int	*itscmd;		/* command queue base (also its phys addr) */
static u32int	itscmdsz;		/* queue size, bytes */
static u32int	itscwrite;		/* our running write offset, bytes */
static u64int	itstarget;		/* MAPC/SYNC target field (proc# or RDbase>>16) */
static int	itsittbits;		/* EventID-bits-1 for MAPD (from GITS_TYPER) */
static int	nextlpi = LPIBASE;
static int	lpisready;		/* itsinit succeeded; intcmsialloc may run */

/* push one 32-byte command and wait for the ITS to consume up to it */
static void
itscommand(u64int dw0, u64int dw1, u64int dw2, u64int dw3)
{
	volatile u64int *c;

	c = (volatile u64int*)((uintptr)itscmd + itscwrite);
	c[0] = dw0; c[1] = dw1; c[2] = dw2; c[3] = dw3;
	dsb();
	itscwrite = (itscwrite + 32) % itscmdsz;
	GITS64(GITS_CWRITER) = itscwrite;
	while((GITS64(GITS_CREADR) & 0xfffe0) != itscwrite)
		;
}

/* program one GITS_BASER<n> (Device or Collection table): flat, 4KB pages */
static void
itsbaser(int n, u64int baser)
{
	void *tab;
	u32int npg;

	npg = 16;				/* 64KB / 4KB: ample for our id ranges */
	tab = xspanalloc(npg*0x1000, 0x1000, 0);
	memset(tab, 0, npg*0x1000);
	dsb();
	baser &= 0xff00000000000000ull;		/* keep RO Type/Entry_Size, clear the rest */
	baser |= BASER_Valid
		| ((u64int)PADDR(tab) & 0x0000fffffffff000ull)	/* [47:12] */
		| (1ull<<59)			/* InnerCache: Normal WB RA WA */
		| (1ull<<10)			/* Shareability: Inner */
		| (0ull<<8)			/* Page_Size: 4KB */
		| (npg - 1);			/* Size: pages - 1 */
	GITS64(GITS_BASER0 + n*8) = baser;
}

static void
itsinit(void)
{
	int i, type;
	u64int typer, baser;
	uchar *pend;

	/* --- per-redistributor LPI tables --- */
	lpiconfig = xspanalloc((1<<LPI_IDBITS) - LPIBASE, 0x1000, 0);
	memset(lpiconfig, 0xa0, (1<<LPI_IDBITS) - LPIBASE);	/* priority 0xa0, disabled */
	dsb();
	pend = xspanalloc(64*1024, 64*1024, 0);
	memset(pend, 0, 64*1024);
	dsb();

	GICR64(GICR_PROPBASER) =
		((u64int)PADDR(lpiconfig) & 0x000ffffffffff000ull)	/* [51:12] */
		| (LPI_IDBITS - 1)		/* [4:0] IDbits - 1 */
		| (1ull<<7)			/* InnerCache: Normal WB */
		| (1ull<<10);			/* Shareability: Inner */
	GICR64(GICR_PENDBASER) =
		((u64int)PADDR(pend) & 0x000ffffffff00000ull)		/* [51:16] */
		| (1ull<<7) | (1ull<<10)
		| (1ull<<62);			/* PTZ: pending table is zeroed */
	dsb();
	IOREG32(GICR_PHYS, GICR_CTLR) |= GICR_CTLR_EnableLPIs;
	dsb();

	/* --- ITS command queue --- */
	itscmdsz = 64*1024;
	itscmd = xspanalloc(itscmdsz, 64*1024, 0);
	memset(itscmd, 0, itscmdsz);
	itscwrite = 0;
	dsb();
	GITS64(GITS_CBASER) =
		((u64int)PADDR(itscmd) & 0x000ffffffffff000ull)
		| (1ull<<63)			/* Valid */
		| (1ull<<59)			/* InnerCache: Normal WB */
		| (1ull<<10)			/* Shareability: Inner */
		| ((itscmdsz/0x1000) - 1);	/* Size: 4KB pages - 1 */
	GITS64(GITS_CWRITER) = 0;

	/* --- ITS Device + Collection tables --- */
	for(i = 0; i < 8; i++){
		baser = GITS64(GITS_BASER0 + i*8);
		type = (baser >> 56) & 7;
		if(type == BASER_TYPE_DEV || type == BASER_TYPE_COL)
			itsbaser(i, baser);
	}

	/* target encoding for MAPC/SYNC: processor number (PTA=0) or RDbase>>16 */
	typer = GITS64(GITS_TYPER);
	itsittbits = ((typer >> 4) & 0xf);	/* ITT entry: bits of ID supported */
	if((typer >> 19) & 1)
		itstarget = ((u64int)GICR_PHYS >> 16);
	else
		itstarget = (GICR64(GICR_TYPER) >> 8) & 0xffff;

	GITS32(GITS_CTLR) = GITS_CTLR_Enabled;
	dsb();

	/* map collection 0 -> this cpu's redistributor */
	itscommand(ITS_MAPC, 0, (itstarget<<16) | (1ull<<63), 0);

	lpisready = 1;
}

/*
 * Allocate an LPI and wire (DeviceID, EventID) -> that LPI on collection 0.
 * Returns the LPI INTID (>= LPIBASE) and the GITS_TRANSLATER physical address
 * the caller writes into the device's MSI/MSI-X message; -1 if MSI is
 * unavailable (then the caller uses INTx).
 */
int
intcmsialloc(int deviceid, int eventid, uvlong *translater)
{
	int intid;
	void *itt;
	u32int ittsz;

	if(!lpisready || nextlpi >= LPIBASE + NMSI)
		return -1;
	intid = nextlpi++;

	/* enable this LPI in the config table (priority 0xa0, enable bit) */
	lpiconfig[intid - LPIBASE] = 0xa0 | 1;
	dsb();

	/* one ITT per device; 256-byte aligned, sized for the device's EventIDs */
	ittsz = (1 << (itsittbits + 1)) * 16;
	if(ittsz < 256)
		ittsz = 256;
	itt = xspanalloc(ittsz, 256, 0);
	memset(itt, 0, ittsz);
	dsb();

	itscommand(ITS_MAPD | ((u64int)deviceid<<32), itsittbits,
		((u64int)PADDR(itt) & ~0xffull) | (1ull<<63), 0);
	itscommand(ITS_MAPTI | ((u64int)deviceid<<32),
		(u64int)(u32int)eventid | ((u64int)intid<<32), 0, 0);
	itscommand(ITS_INV | ((u64int)deviceid<<32), (u32int)eventid, 0, 0);
	itscommand(ITS_SYNC, 0, itstarget<<16, 0);

	*translater = (uvlong)GITS_PHYS + GITS_TRANSLATER;
	return intid;
}
