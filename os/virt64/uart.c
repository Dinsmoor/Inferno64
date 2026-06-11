#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

/*
 * PL011 console: polled output, interrupt-driven input into kbdq
 * (devcons does the line discipline).
 */

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

static void
uartintr(Ureg *ur, void *a)
{
	int c;

	USED(ur); USED(a);
	IOREG32(UART0_PHYS, UARTICR) = RXINTR|RTINTR;
	while((c = uartgetc()) >= 0){
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
	IOREG32(UART0_PHYS, UARTLCR_H) = 0x60;		/* 8n1, FIFO off (per-char rx irq) */
	IOREG32(UART0_PHYS, UARTICR) = 0x7ff;
	IOREG32(UART0_PHYS, UARTIMSC) = RXINTR|RTINTR;
	IOREG32(UART0_PHYS, UARTIFLS) = 0;
	IOREG32(UART0_PHYS, UARTCR) = (1<<0)|(1<<8)|(1<<9);	/* UARTEN|TXE|RXE */
	while(uartgetc() >= 0)
		;					/* drain stale input */
	/* the board uart code owns kbdq on native kernels (devcons just reads it) */
	if(kbdq == nil)
		kbdq = qopen(4*1024, 0, nil, nil);
	intrenable(UARTIRQ, uartintr, nil, BusCPU, "uart");
	serwrite = uartputs;
}
