#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * amd64 PC chipset glue: 16550 serial console, local APIC (+timer LVT),
 * I/O APIC, and the legacy 8259 PICs (remapped and masked, since we run
 * on the APICs).  MMIO at the APIC physical addresses is reached through
 * the identity map l.S installs for the low 4GB.
 */

/* ---- 16550 UART (COM1) ---- */

enum {
	Thr = 0,	/* THR/RBR (DLAB=0), DLL (DLAB=1) */
	Ier = 1,	/* DLM (DLAB=1) */
	Iir = 2,	/* FCR (write) */
	Lcr = 3,
	Mcr = 4,
	Lsr = 5,
};

extern Queue *kbdq;	/* devcons console input (we own it; devcons reads it) */

extern void (*serwrite)(char*, int);

void
uartinit(void)
{
	outb(COM1+Ier, 0x00);		/* no interrupts (polled) */
	outb(COM1+Lcr, 0x80);		/* DLAB */
	outb(COM1+Thr, 0x01);		/* divisor lo: 115200 baud */
	outb(COM1+Ier, 0x00);		/* divisor hi */
	outb(COM1+Lcr, 0x03);		/* 8N1, DLAB off */
	outb(COM1+Iir, 0xC7);		/* enable+clear FIFOs */
	outb(COM1+Mcr, 0x0B);		/* DTR|RTS|OUT2 */

	/* route kernel print()/console output to COM1 (no uart driver yet) */
	serwrite = uartputs;
}

/*
 * Interrupt-driven console input: COM1 RX -> kbdq, devcons does the line
 * discipline.  Called from boardready (queues + IDT + IOAPIC are up).
 * Mirrors the uart-pl011 driver: the board uart owns kbdq.
 */
static void
uartintr(Ureg *ur, void *a)
{
	USED(ur); USED(a);
	while(inb(COM1+Lsr) & 0x01){		/* data ready */
		if(kbdq != nil)
			kbdputc(kbdq, inb(COM1+Thr));
		else
			inb(COM1+Thr);
	}
}

void
uartconsole(void)
{
	if(kbdq == nil)
		kbdq = qopen(16*1024, Qcoalesce, nil, nil);
	intrenable(UARTIRQ, uartintr, nil, BusCPU, "uart");
	outb(COM1+Ier, 0x01);			/* enable received-data interrupt */
}

void
uartputc(int c)
{
	int i;

	for(i = 0; i < 100000 && (inb(COM1+Lsr) & 0x20) == 0; i++)
		;
	outb(COM1+Thr, c);
}

void
uartputs(char *s, int n)
{
	while(n-- > 0){
		if(*s == '\n')
			uartputc('\r');
		uartputc(*s++);
	}
}

/* ---- local APIC ---- */

enum {
	Lapicid		= 0x020,
	Lapicsvr	= 0x0F0,	/* spurious vector */
	Lapiceoireg	= 0x0B0,
	Lapictpr	= 0x080,
	Lapiclvtt	= 0x320,	/* LVT timer */
	Lapicticr	= 0x380,	/* timer initial count */
	Lapictccr	= 0x390,	/* timer current count */
	Lapictdcr	= 0x3E0,	/* timer divide config */
};

static volatile u32int *lapic = (u32int*)LAPIC_PHYS;

static void
lapicw(int r, u32int v)
{
	lapic[r/4] = v;
	(void)lapic[Lapicid/4];		/* serialize */
}

static u32int
lapicrd(int r)
{
	return lapic[r/4];
}

void
lapicinit(void)
{
	uvlong base;

	/* IA32_APIC_BASE: ensure the xAPIC is globally enabled */
	base = rdmsr(0x1B);
	wrmsr(0x1B, base | (1<<11));

	lapicw(Lapicsvr, 0x100 | VEC_SPURIOUS);	/* enable + spurious vector */
	lapicw(Lapictpr, 0);			/* accept all priorities */
}

void
lapiceoi(void)
{
	lapicw(Lapiceoireg, 0);
}

ulong
lapicid(void)
{
	return lapicrd(Lapicid) >> 24;
}

/*
 * Program the LAPIC timer for periodic interrupts on VEC_TIMER.
 * count = timer ticks per HZ tick (from clock.c's calibration).
 */
void
lapictimerset(uvlong count)
{
	lapicw(Lapictdcr, 0x3);			/* divide by 16 */
	lapicw(Lapiclvtt, VEC_TIMER | (1<<17));	/* periodic */
	lapicw(Lapicticr, (u32int)count);
}

/* free-running calibration helpers (clock.c) */
void
lapictimerstartcal(void)
{
	lapicw(Lapictdcr, 0x3);			/* divide by 16 */
	lapicw(Lapiclvtt, (1<<16));		/* masked, one-shot */
	lapicw(Lapicticr, 0xFFFFFFFF);
}

u32int
lapictimerelapsed(void)
{
	return 0xFFFFFFFFU - lapicrd(Lapictccr);
}

/* ---- 8259 PICs: remap to 0x20 and mask all (we use the APICs) ---- */

void
i8259init(void)
{
	outb(0x20, 0x11); outb(0xA0, 0x11);	/* ICW1: init, cascade, edge */
	outb(0x21, 0x20); outb(0xA1, 0x28);	/* ICW2: vector offsets */
	outb(0x21, 0x04); outb(0xA1, 0x02);	/* ICW3: cascade on IR2 */
	outb(0x21, 0x01); outb(0xA1, 0x01);	/* ICW4: 8086 mode */
	outb(0x21, 0xFF); outb(0xA1, 0xFF);	/* mask everything */
}

/* ---- I/O APIC ---- */

static volatile u32int *ioapic = (u32int*)IOAPIC_PHYS;

static u32int
ioapicrd(int reg)
{
	ioapic[0] = reg;
	return ioapic[4];			/* IOWIN at +0x10 */
}

static void
ioapicwr(int reg, u32int v)
{
	ioapic[0] = reg;
	ioapic[4] = v;
}

void
ioapicinit(void)
{
	int i, max;

	max = (ioapicrd(0x01) >> 16) & 0xFF;	/* max redirection entry */
	for(i = 0; i <= max; i++){
		ioapicwr(0x10 + i*2, (1<<16) | (VEC_IRQ0 + i));	/* masked */
		ioapicwr(0x11 + i*2, 0);			/* dest apic 0 */
	}
}

void
ioapicenable(int irq, int vec)
{
	ioapicwr(0x11 + irq*2, (lapicid() & 0xFF) << 24);
	ioapicwr(0x10 + irq*2, vec);		/* fixed, phys, active-hi, edge, unmasked */
}

void
ioapicdisable(int irq)
{
	ioapicwr(0x10 + irq*2, (1<<16) | (VEC_IRQ0 + irq));
}
