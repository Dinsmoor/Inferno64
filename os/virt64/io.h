/*
 * qemu -M virt memory map (hw/arm/virt.c) — the bits we use.
 * Everything below 1GB is device space; we run identity-mapped.
 */
enum {
	GICD_PHYS	= 0x08000000,	/* GICv2 distributor */
	GICC_PHYS	= 0x08010000,	/* GICv2 cpu interface */
	UART0_PHYS	= 0x09000000,	/* PL011 */
	RTC_PHYS	= 0x09010000,	/* PL031 */
	FWCFG_PHYS	= 0x09020000,
	VIRTIO_PHYS	= 0x0a000000,	/* 32 transports, 0x200 apart */

	/* GIC interrupt ids */
	TIMERIRQ	= 30,		/* EL1 physical timer PPI */
	UARTIRQ		= 32+1,		/* SPI 1 */
	VIRTIOIRQ0	= 32+16,	/* SPI 16..47 */

	NIRQ		= 256,

	/* intrenable bus types */
	BUSUNKNOWN	= -1,
	BusCPU		= 0,
};

/*
 * PSCI 0.2+ function ids (hvc conduit on qemu -M virt; see psci_call in l.S)
 */
enum {
	PSCI_VERSION		= 0x84000000,
	PSCI_SYSTEM_OFF		= 0x84000008,
	PSCI_SYSTEM_RESET	= 0x84000009,
	PSCI_CPU_ON		= 0xC4000003,	/* SMP secondary bring-up (unused) */
};

/*
 * PL011 registers (byte offsets)
 */
enum {
	UARTDR		= 0x00,
	UARTFR		= 0x18,
	UARTIBRD	= 0x24,
	UARTFBRD	= 0x28,
	UARTLCR_H	= 0x2c,
	UARTCR		= 0x30,
	UARTIFLS	= 0x34,
	UARTIMSC	= 0x38,
	UARTMIS		= 0x40,
	UARTICR		= 0x44,

	/* UARTFR bits */
	TXFF		= 1<<5,		/* tx fifo full */
	RXFE		= 1<<4,		/* rx fifo empty */

	/* interrupt bits (IMSC/MIS/ICR) */
	RXINTR		= 1<<4,
	RTINTR		= 1<<6,
};

/*
 * GICv2 registers (byte offsets)
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

#define IOREG32(base, off)	(*(volatile u32int*)((uintptr)(base)+(off)))
