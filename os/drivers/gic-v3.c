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
};

#define GICR_SGI	(GICR_PHYS + GICR_SGI_OFF)
#define GICD64(off)	(*(volatile u64int*)((uintptr)GICD_PHYS + (off)))

#define isb()		asm volatile("isb" ::: "memory")
#define dsb()		asm volatile("dsb sy" ::: "memory")
#define rdsysr(r)	({ u64int _v; asm volatile("mrs %0, " #r : "=r"(_v)); _v; })
#define wrsysr(r, v)	asm volatile("msr " #r ", %0" :: "r"((u64int)(v)))

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
}

void
intcdispatch(Ureg *ur)
{
	u32int iar, v;

	for(;;){
		iar = rdsysr(ICC_IAR1_EL1);
		v = iar & 0xffffff;		/* intid is 24 bits in v3 */
		if(v >= GICSPECIAL)
			break;
		dispatchirq(ur, v);
		wrsysr(ICC_EOIR1_EL1, iar);
	}
}
