#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"ureg.h"

/*
 * GICv2 interrupt controller (board.h: GICD_PHYS distributor,
 * GICC_PHYS cpu interface).  Implements the intc* interface in fns.h;
 * trap.c owns the vector table and calls intcdispatch from the irq
 * trap, which claims/dispatches/EOIs until the controller runs dry.
 */

enum {
	GICD_CTLR	= 0x000,
	GICD_ISENABLER	= 0x100,	/* + 4*(n/32) */
	GICD_ICENABLER	= 0x180,
	GICD_ICPENDR	= 0x280,
	GICD_IPRIORITYR	= 0x400,	/* byte per irq */
	GICD_ITARGETSR	= 0x800,	/* byte per irq */
	GICD_ICFGR	= 0xc00,

	GICC_CTLR	= 0x000,
	GICC_PMR	= 0x004,
	GICC_IAR	= 0x00c,
	GICC_EOIR	= 0x010,

	GICSPURIOUS	= 1023,
};

void
intcenable(int irq)
{
	IOREG32(GICD_PHYS, GICD_ISENABLER + 4*(irq/32)) = 1u << (irq%32);
}

void
intcdisable(int irq)
{
	IOREG32(GICD_PHYS, GICD_ICENABLER + 4*(irq/32)) = 1u << (irq%32);
}

void
intcinit(void)
{
	int i;

	/* distributor: everything off, route to cpu0, lowest priority threshold */
	IOREG32(GICD_PHYS, GICD_CTLR) = 0;
	for(i = 0; i < NIRQ; i += 32){
		IOREG32(GICD_PHYS, GICD_ICENABLER + 4*(i/32)) = ~0u;
		IOREG32(GICD_PHYS, GICD_ICPENDR + 4*(i/32)) = ~0u;
	}
	for(i = 0; i < NIRQ; i += 4){
		IOREG32(GICD_PHYS, GICD_IPRIORITYR + i) = 0xa0a0a0a0;
		if(i >= 32)
			IOREG32(GICD_PHYS, GICD_ITARGETSR + i) = 0x01010101;
	}
	IOREG32(GICD_PHYS, GICD_CTLR) = 1;

	/* cpu interface */
	IOREG32(GICC_PHYS, GICC_PMR) = 0xff;
	IOREG32(GICC_PHYS, GICC_CTLR) = 1;
}

void
intcdispatch(Ureg *ur)
{
	u32int iar, v;

	for(;;){
		iar = IOREG32(GICC_PHYS, GICC_IAR);
		v = iar & 0x3ff;
		if(v == GICSPURIOUS)
			break;
		dispatchirq(ur, v);
		IOREG32(GICC_PHYS, GICC_EOIR) = iar;
	}
}
