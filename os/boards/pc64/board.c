#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * qemu-system-x86_64 board hooks (see fns.h).  During bring-up the board
 * is serial-only: the display/input/rng entry points are stubs that report
 * "no device", which screen.c and stubs.c already degrade against.  ramfb
 * (fw_cfg) and i8042 PS/2 fill these in for the GUI milestone.
 */

/* CMOS/RTC read for epoch seconds */
static int
cmos(int reg)
{
	outb(0x70, reg);
	return inb(0x71);
}

static int
bcd(int b)
{
	return (b & 0xf) + 10*(b >> 4);
}

ulong
rtctime(void)
{
	int sec, min, hr, mday, mon, yr, statusb;
	static int mdays[] = {0,31,59,90,120,151,181,212,243,273,304,334};
	long t;

	statusb = cmos(0x0b);
	sec = cmos(0x00); min = cmos(0x02); hr = cmos(0x04);
	mday = cmos(0x07); mon = cmos(0x08); yr = cmos(0x09);
	if(!(statusb & 0x04)){	/* values are BCD */
		sec = bcd(sec); min = bcd(min); hr = bcd(hr);
		mday = bcd(mday); mon = bcd(mon); yr = bcd(yr);
	}
	yr += 2000;
	if(mon < 1 || mon > 12)
		return 0;
	/* days since the epoch */
	t = (yr-1970)*365 + (yr-1969)/4;	/* leap years since 1970 */
	t += mdays[mon-1];
	if(mon > 2 && (yr%4)==0 && (yr%100)!=0)
		t += 1;
	t += mday-1;
	return ((t*24 + hr)*60 + min)*60 + sec;
}

void
boardinit(void)
{
	screeninit();		/* ramfb if present, else headless (serial only) */
}

void
boardready(void)
{
	uartconsole();		/* interrupt-driven COM1 input -> console */
	i8042init();		/* PS/2 keyboard + mouse (GUI input) */
	pciscan();		/* enumerate the PCI host bridge, if present */
}

/* ---- display/input/rng stubs until the real drivers land ---- */
/* (ramfbinit is the real qemu ramfb driver, drivers/ramfb-pc.c) */

uchar*
vgpuinit(int *w, int *h)
{
	USED(w); USED(h);
	return nil;		/* no virtio-gpu on this board */
}

void	vgpustart(void)		{ }
void	virtioinputinit(void)	{ }
void	virtiornginit(void)	{ }

int
virtiorngread(uchar *buf, int n)
{
	USED(buf); USED(n);
	return -1;		/* no hardware rng; jitter pool / PRNG takes over */
}

void
pciscan(void)
{
}

/*
 * devsd (always linked) walks a nil-terminated sdifc[].  mkdevc only
 * emits the array when the config names sd drivers (a `misc' section);
 * this board names none, so define an empty one here.  Remove this when
 * a real sd driver + misc section land.
 */
typedef struct SDifc SDifc;
SDifc* sdifc[] = { nil };
