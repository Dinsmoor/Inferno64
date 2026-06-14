#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ureg.h"

/*
 * Clock: the local APIC timer, periodic on VEC_TIMER at HZ.  Both the
 * LAPIC timer rate and the TSC frequency are calibrated against a 10ms
 * PIT (channel 2) window at boot.  delay/microdelay use the TSC.
 */

void	lapictimerstartcal(void);
u32int	lapictimerelapsed(void);

static uvlong tickdiv;	/* LAPIC timer counts per HZ tick */

typedef struct Clock0link Clock0link;
struct Clock0link {
	void		(*clock)(void);
	Clock0link*	link;
};

static Clock0link *clock0link;
static Lock clock0lock;

Timer*
addclock0link(void (*clock)(void), int ms)
{
	Clock0link *lp;

	USED(ms);
	if((lp = malloc(sizeof(Clock0link))) == 0){
		print("addclock0link: too many links\n");
		return nil;
	}
	ilock(&clock0lock);
	lp->clock = clock;
	lp->link = clock0link;
	clock0link = lp;
	iunlock(&clock0lock);
	return nil;
}

void
clockintr(Ureg *ur)
{
	Clock0link *lp;

	USED(ur);
	m->ticks++;			/* LAPIC periodic re-arms itself */

	checkalarms();

	if(canlock(&clock0lock)){
		for(lp = clock0link; lp; lp = lp->link)
			if(lp->clock)
				lp->clock();
		unlock(&clock0lock);
	}
}

/* one-shot 10ms PIT channel-2 gate; poll OUT2 (port 0x61 bit 5) */
static void
pitwait10ms(void)
{
	enum { Count = 11932 };		/* 1193182Hz / 100 = ~10ms */

	outb(0x61, (inb(0x61) & 0xFC) | 0x01);	/* gate2 on, speaker off */
	outb(0x43, 0xB0);			/* ch2, lo/hi, mode0, binary */
	outb(0x42, Count & 0xFF);
	outb(0x42, (Count >> 8) & 0xFF);
	while((inb(0x61) & 0x20) == 0)
		;
}

void
clockinit(void)
{
	uvlong t0, t1;
	u32int lt;

	m->ticks = 0;

	lapicinit();
	i8259init();
	ioapicinit();

	/* calibrate the LAPIC timer and the TSC against one PIT window */
	lapictimerstartcal();
	t0 = rdtsc();
	pitwait10ms();
	lt = lapictimerelapsed();
	t1 = rdtsc();

	m->timerfreq = (uvlong)lt * 100;	/* LAPIC ticks per second */
	m->cpuhz = (t1 - t0) * 100;		/* TSC ticks per second */
	tickdiv = m->timerfreq / HZ;
	if(tickdiv == 0)
		tickdiv = 1000000;		/* implausible calibration; limp */

	lapictimerset(tickdiv);			/* periodic on VEC_TIMER */
}

void
clockpoll(void)
{
}

void
clockcheck(void)
{
}

uvlong
fastticks(uvlong *hz)
{
	if(hz)
		*hz = m->cpuhz ? m->cpuhz : 1000000000ULL;
	return rdtsc();
}

ulong
tk2ms(ulong tk)
{
	return tk * MS2HZ;
}

void
microdelay(int us)
{
	uvlong now, end, hz;

	hz = m->cpuhz ? m->cpuhz : 1000000000ULL;
	now = rdtsc();
	end = now + (hz/1000000) * (uvlong)us;
	while(rdtsc() < end)
		;
}

void
delay(int ms)
{
	while(ms-- > 0)
		microdelay(1000);
}

/* (seconds() lives in devcons.c) */

vlong
archrdtsc(void)
{
	return rdtsc();
}

ulong
archrdtsc32(void)
{
	return (ulong)rdtsc();
}
