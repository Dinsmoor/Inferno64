/*
 * Board: qemu-system-aarch64 -M virt (hw/arm/virt.c memory map).
 * Everything the arch core and the drivers need to know about this
 * board lives here; the kernel config (./virt64) picks the drivers.
 * Included from C and from l.S — keep the assembler part #define-only.
 */
#ifndef BOARD_H
#define BOARD_H

/*
 * Memory.  Identity-mapped: virtual == physical.
 */
#define KZERO		0x40000000UL		/* base of RAM */
#define KTZERO		0x40200000UL		/* kernel text load address (kernel.ld) */
#define MEMSIZE		(512*_M_)		/* boot default; someday the DTB */

/*
 * MMU level-1 identity map: with T0SZ=32 the table has four 1GB slots.
 * l.S installs these four entries verbatim; 0 = invalid.
 */
#define L1MAPENT0	0x0060000000000405	/* [0,1G): device nGnRnE — UXN|PXN|AF|AttrIdx1|block */
#define L1MAPENT1	0x40000701		/* [1G,2G): RAM — AF|SH=ISH|AttrIdx0(WB)|block */
#define L1MAPENT2	0
#define L1MAPENT3	0

/*
 * PSCI conduit: qemu -M virt has no EL3; firmware expects hvc.
 * Boards with TF-A (real hardware) define BOARD_PSCI_SMC instead.
 */
#undef BOARD_PSCI_SMC

#ifndef __ASSEMBLER__

/*
 * MMIO map and GIC interrupt ids.
 */
enum {
	GICD_PHYS	= 0x08000000,	/* GICv2 distributor */
	GICC_PHYS	= 0x08010000,	/* GICv2 cpu interface */
	UART0_PHYS	= 0x09000000,	/* PL011 */
	RTC_PHYS	= 0x09010000,	/* PL031 */
	FWCFG_PHYS	= 0x09020000,
	VIRTIO_PHYS	= 0x0a000000,	/* 32 transports, 0x200 apart */

	TIMERIRQ	= 30,		/* EL1 physical timer PPI */
	UARTIRQ		= 32+1,		/* SPI 1 */
	VIRTIOIRQ0	= 32+16,	/* SPI 16..47 */

	NIRQ		= 256,

	/* intrenable bus types */
	BUSUNKNOWN	= -1,
	BusCPU		= 0,
};

#endif	/* __ASSEMBLER__ */
#endif	/* BOARD_H */
