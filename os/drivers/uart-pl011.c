#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ureg.h"

/*
 * PL011 console (board.h: UART0_PHYS, UARTIRQ): polled output,
 * interrupt-driven input into kbdq (devcons does the line discipline).
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

extern Queue *kbdq;

void
uartputc(int c)
{
	while(IOREG32(UART0_PHYS, UARTFR) & TXFF)
		;
	IOREG32(UART0_PHYS, UARTDR) = c & 0xff;
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

int
uartgetc(void)
{
	if(IOREG32(UART0_PHYS, UARTFR) & RXFE)
		return -1;
	return IOREG32(UART0_PHYS, UARTDR) & 0xff;
}

ulong uartrxcount;	/* debug: chars taken from the rx fifo */
ulong uartrxerr;	/* debug: DR error bits / overrun seen */

static void
uartintr(Ureg *ur, void *a)
{
	int c;

	USED(ur); USED(a);
	IOREG32(UART0_PHYS, UARTICR) = RXINTR|RTINTR;
	while(!(IOREG32(UART0_PHYS, UARTFR) & RXFE)){
		c = IOREG32(UART0_PHYS, UARTDR);
		if(c & 0xf00)		/* OE|BE|PE|FE in DR[11:8] */
			uartrxerr++;
		c &= 0xff;
		uartrxcount++;
		if(c == '\r')
			c = '\n';	/* serial sends CR for Enter; line discipline wants NL */
		if(kbdq != nil)
			kbdputc(kbdq, c);
	}
}

void
uartinit(void)
{
	/* no firmware ran before us: enable the uart ourselves */
	IOREG32(UART0_PHYS, UARTCR) = 0;
	IOREG32(UART0_PHYS, UARTLCR_H) = 0x70;		/* 8n1, FEN: 16-byte FIFOs —
							 * with FIFO off qemu's pl011 is 1 char
							 * deep and drops pasted/scripted bursts */
	IOREG32(UART0_PHYS, UARTICR) = 0x7ff;
	IOREG32(UART0_PHYS, UARTIMSC) = RXINTR|RTINTR;
	IOREG32(UART0_PHYS, UARTIFLS) = 0;		/* rx irq at 1/8 full; RTINTR catches the tail */
	IOREG32(UART0_PHYS, UARTCR) = (1<<0)|(1<<8)|(1<<9);	/* UARTEN|TXE|RXE */
	while(uartgetc() >= 0)
		;					/* drain stale input */
	/* the board uart code owns kbdq on native kernels (devcons just reads it) */
	if(kbdq == nil)
		kbdq = qopen(16*1024, Qcoalesce, nil, nil);	/* coalesce: see qproduce */
	intrenable(UARTIRQ, uartintr, nil, BusCPU, "uart");
	serwrite = uartputs;
}
