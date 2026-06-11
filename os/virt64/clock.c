#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "ureg.h"

/*
 * ARM generic timer (CNTP, EL1 physical).  Frequency from CNTFRQ_EL0;
 * qemu -M virt gives 62.5MHz (TCG) or the host's (KVM).
 */

uvlong	rdcntvct(void);
uvlong	rdcntfrq(void);
void	wrcntptval(uvlong);
void	wrcntpctl(uvlong);

static uvlong tickdiv;	/* timer counts per HZ tick */

typedef struct Clock0link Clock0link;
typedef struct Clock0link {
	void		(*clock)(void);
	Clock0link*	link;
} Clock0link;

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

static void
clockintr(Ureg *ur, void *a)
{
	Clock0link *lp;

	USED(ur); USED(a);
	m->ticks++;
	wrcntptval(tickdiv);	/* re-arm; also clears the interrupt */

	checkalarms();

	if(canlock(&clock0lock)){
		for(lp = clock0link; lp; lp = lp->link)
			if(lp->clock)
				lp->clock();
		unlock(&clock0lock);
	}
}

void
clockinit(void)
{
	m->ticks = 0;
	m->timerfreq = rdcntfrq();
	tickdiv = m->timerfreq / HZ;
	intrenable(TIMERIRQ, clockintr, nil, BusCPU, "clock");
	wrcntptval(tickdiv);
	wrcntpctl(1);		/* enable, not masked */
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
		*hz = m->timerfreq;
	return rdcntvct();
}

ulong
tk2ms(ulong tk)
{
	return tk * MS2HZ;
}

void
microdelay(int us)
{
	uvlong now, end;

	now = rdcntvct();
	end = now + ((uvlong)us * m->timerfreq) / 1000000;
	while(rdcntvct() < end)
		;
}

void
delay(int ms)
{
	while(ms-- > 0)
		microdelay(1000);
}

/* (seconds() lives in devcons.c) */

/*
 * for devbench.c and friends
 */
vlong
archrdtsc(void)
{
	return rdcntvct();
}

ulong
archrdtsc32(void)
{
	return rdcntvct();
}
