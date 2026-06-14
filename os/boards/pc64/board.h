/*
 * Board: qemu-system-x86_64 -M q35 (or -M pc), booted via multiboot1
 * (qemu -kernel reads the multiboot header in l.S).  Everything the arch
 * core and drivers need to know about this PC lives here; the kernel
 * config (./pc64) picks the drivers.  Included from C and from l.S —
 * keep the assembler part #define-only.
 */
#ifndef BOARD_H
#define BOARD_H

/*
 * Memory.  Identity-mapped: virtual == physical, KZERO = 0.  The kernel
 * loads at 1MB (above the legacy BIOS/VGA hole); l.S identity-maps the
 * low 4GB with 2MB pages so the LAPIC/IOAPIC MMIO near 4GB is reachable.
 */
#define KZERO		0x0UL
#define KTZERO		0x100000UL		/* kernel load address (kernel.ld) */
#define MEMSIZE		(512*_M_)		/* boot default (qemu -m 512) */

/*
 * GDT segment selectors built in l.S.  Index<<3.  64-bit code has L=1.
 */
#define SEL_KCODE32	0x08			/* 32-bit code (boot trampoline) */
#define SEL_KDATA	0x10			/* data (32 and 64 bit) */
#define SEL_KCODE	0x18			/* 64-bit code */

/*
 * Multiboot1 header constants (l.S).
 */
#define MULTIBOOT_MAGIC		0x1BADB002
#define MULTIBOOT_FLAGS		0x00000003	/* align modules, mem info */

#ifndef __ASSEMBLER__

enum {
	COM1		= 0x3f8,		/* 16550 serial console */

	LAPIC_PHYS	= 0xFEE00000,		/* local APIC registers */
	IOAPIC_PHYS	= 0xFEC00000,		/* I/O APIC registers */

	/* interrupt vector assignment (IDT).  0x20-0x2F is the masked 8259
	 * remap window; keep live vectors clear of it. */
	VEC_IRQ0	= 0x30,			/* IOAPIC GSI g -> vector VEC_IRQ0+g */
	VEC_TIMER	= 0xF0,			/* LAPIC timer (clock) */
	VEC_SPURIOUS	= 0xFF,			/* LAPIC spurious */

	UARTIRQ		= 4,			/* COM1 -> ISA IRQ4 -> IOAPIC GSI4 */

	NIRQ		= 224,			/* GSIs we track in irqvec[] */

	/* intrenable bus types */
	BUSUNKNOWN	= -1,
	BusCPU		= 0,
};

#endif	/* __ASSEMBLER__ */
#endif	/* BOARD_H */
