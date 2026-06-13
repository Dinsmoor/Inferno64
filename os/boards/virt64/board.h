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
 * MMU level-1 identity map: with T0SZ=25 the VA is 39 bits, so the single
 * 512-entry table is a full level-1 (one 1GB block per slot, [0,512G)).
 * l.S installs the low entries verbatim; 0 = invalid; entries 2..511 stay 0.
 */
#define L1MAPENT0	0x0060000000000405	/* [0,1G): device nGnRnE — UXN|PXN|AF|AttrIdx1|block */
#define L1MAPENT1	0x40000701		/* [1G,2G): RAM — AF|SH=ISH|AttrIdx0(WB)|block */
#define L1MAPENT2	0
#define L1MAPENT3	0

/*
 * Default qemu -M virt puts PCIe ECAM config space high (0x40_10000000)
 * and the GICv3 redistributors just below it (0x40_00000000); both sit in
 * [256G,257G).  Map that 1GB slot as device memory at index 256 (256G>>30),
 * same attributes as L1MAPENT0.  l.S installs it whenever this is defined.
 */
#define L1MAP_HIECAM_IDX	256
#define L1MAP_HIECAM_ENT	0x0060004000000405

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

	/* PCIe generic host bridge (qemu -M virt / GPEX).  The 32-bit BAR
	 * window and the PIO window stay in the [0,1G) device map; ECAM config
	 * space is high (see PCIE_ECAM_PHYS below — too wide for this int enum). */
	PCIE_MMIO_PHYS	= 0x10000000,	/* 32-bit BAR window... */
	PCIE_MMIO_SIZE	= 0x2eff0000,	/* ...up to 0x3eff0000 */
	PCIE_PIO_PHYS	= 0x3eff0000,	/* I/O-space window, 64KB */
	PCIE_PIO_SIZE	= 0x00010000,

	TIMERIRQ	= 30,		/* EL1 physical timer PPI */
	UARTIRQ		= 32+1,		/* SPI 1 */
	VIRTIOIRQ0	= 32+16,	/* SPI 16..47 */
	PCIINTA		= 32+3,		/* INTA..INTD = SPI 3..6, slot-swizzled */

	NIRQ		= 256,

	/* intrenable bus types */
	BUSUNKNOWN	= -1,
	BusCPU		= 0,
};

/*
 * High PCIe ECAM (qemu -M virt default): 1MB/bus, 256 buses.  Mapped by the
 * arch MMU via board.h L1MAP_HIECAM_*.  Point this back at 0x3f000000 (and
 * size 0x01000000, 16 buses) to use the legacy -M virt,highmem-ecam=off
 * window, which lives in the [0,1G) device map.  Too wide for the int enum.
 */
#define PCIE_ECAM_PHYS	0x4010000000UL
#define PCIE_ECAM_SIZE	0x10000000UL

#endif	/* __ASSEMBLER__ */
#endif	/* BOARD_H */
