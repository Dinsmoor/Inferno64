#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * i8042 PS/2 controller: keyboard (IRQ1) + mouse/aux (IRQ12).  Always
 * present on qemu -M q35.  Scancode set 1; keys -> kbdq (devcons line
 * discipline), 3-byte mouse packets -> mousetrack (relative).  A compact
 * self-contained map: ASCII + shift/ctrl + the editing keys the shell and
 * wm need; extended (0xE0) keys other than the arrows are dropped.
 */

enum {
	Data	= 0x60,
	Status	= 0x64,		/* read: status */
	Cmd	= 0x64,		/* write: controller command */

	Sobuf	= 1<<0,		/* output buffer full (data to read) */
	Sibuf	= 1<<1,		/* input buffer full (don't write yet) */
	Saux	= 1<<5,		/* byte is from the aux (mouse) port */

	Ccfgrd	= 0x20,		/* read config byte */
	Ccfgwr	= 0x60,		/* write config byte */
	Cauxen	= 0xA8,		/* enable aux port */
	Cauxwr	= 0xD4,		/* next data write goes to the mouse */

	Cfgkbdint = 1<<0,
	Cfgauxint = 1<<1,
};

extern Queue *kbdq;

/* scancode set 1 -> Rune; index = make code (0x00..0x58) */
static char scan[] =
{
[0x00]	0,   033, '1', '2', '3', '4', '5', '6',
[0x08]	'7', '8', '9', '0', '-', '=', '\b','\t',
[0x10]	'q', 'w', 'e', 'r', 't', 'y', 'u', 'i',
[0x18]	'o', 'p', '[', ']', '\n', 0,  'a', 's',
[0x20]	'd', 'f', 'g', 'h', 'j', 'k', 'l', ';',
[0x28]	'\'','`', 0,   '\\','z', 'x', 'c', 'v',
[0x30]	'b', 'n', 'm', ',', '.', '/', 0,   '*',
[0x38]	0,   ' ', 0,
};
static char scanshift[] =
{
[0x00]	0,   033, '!', '@', '#', '$', '%', '^',
[0x08]	'&', '*', '(', ')', '_', '+', '\b','\t',
[0x10]	'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I',
[0x18]	'O', 'P', '{', '}', '\n', 0,  'A', 'S',
[0x20]	'D', 'F', 'G', 'H', 'J', 'K', 'L', ':',
[0x28]	'"', '~', 0,   '|', 'Z', 'X', 'C', 'V',
[0x30]	'B', 'N', 'M', '<', '>', '?', 0,   '*',
[0x38]	0,   ' ', 0,
};

static int shift, ctl, e0;

static void
kbdintr(Ureg *ur, void *a)
{
	int c, r;

	USED(ur); USED(a);
	if((inb(Status) & Sobuf) == 0)
		return;
	c = inb(Data);

	if(c == 0xE0){			/* extended-key prefix */
		e0 = 1;
		return;
	}
	if(c & 0x80){			/* break (release) */
		c &= 0x7f;
		if(!e0 && (c == 0x2a || c == 0x36))
			shift = 0;
		else if(c == 0x1d)
			ctl = 0;
		e0 = 0;
		return;
	}
	if(!e0 && (c == 0x2a || c == 0x36)){
		shift = 1;
		return;
	}
	if(c == 0x1d){
		ctl = 1;
		return;
	}
	if(e0){				/* extended make: drop (arrows TODO) */
		e0 = 0;
		return;
	}
	if(c >= nelem(scan))
		return;
	r = shift ? scanshift[c] : scan[c];
	if(r == 0)
		return;
	if(ctl && r < 0x80 && ((r|0x20) >= 'a' && (r|0x20) <= 'z'))
		r &= 0x1f;		/* control char */
	if(kbdq != nil)
		kbdputc(kbdq, r);
}

static void
mouseintr(Ureg *ur, void *a)
{
	static uchar pkt[3];
	static int n;
	int b, dx, dy, s;

	USED(ur); USED(a);
	s = inb(Status);
	if((s & Sobuf) == 0 || (s & Saux) == 0)
		return;
	pkt[n++] = inb(Data);
	if(n == 1 && (pkt[0] & 0x08) == 0){	/* resync: bit3 always 1 in byte0 */
		n = 0;
		return;
	}
	if(n < 3)
		return;
	n = 0;

	/* PS/2 buttons (L=1,R=2,M=4) -> Inferno mask (L=1,M=2,R=4) */
	b = 0;
	if(pkt[0] & 0x01) b |= 1;
	if(pkt[0] & 0x04) b |= 2;
	if(pkt[0] & 0x02) b |= 4;

	dx = pkt[1];
	dy = pkt[2];
	if(pkt[0] & 0x10) dx -= 256;	/* X sign */
	if(pkt[0] & 0x20) dy -= 256;	/* Y sign */

	mousetrack(b, dx, -dy, 1);	/* PS/2 Y grows up; screen Y grows down */
}

static void
ctlwait(void)
{
	int i;
	for(i = 0; i < 100000 && (inb(Status) & Sibuf); i++)
		;
}

static void
auxcmd(int c)
{
	ctlwait(); outb(Cmd, Cauxwr);
	ctlwait(); outb(Data, c);
	delay(2);
	inb(Data);			/* eat the 0xFA ack */
}

static void
cfgset(int kbdint, int auxint)
{
	int cfg;

	ctlwait(); outb(Cmd, Ccfgrd);
	ctlwait(); cfg = inb(Data);
	cfg &= ~(Cfgkbdint | Cfgauxint);
	if(kbdint) cfg |= Cfgkbdint;
	if(auxint) cfg |= Cfgauxint;
	cfg |= (1<<6);			/* keep set2->set1 translation on */
	ctlwait(); outb(Cmd, Ccfgwr);
	ctlwait(); outb(Data, cfg);
}

void
i8042init(void)
{
	/* flush any stale output */
	while(inb(Status) & Sobuf)
		inb(Data);

	/* enable the aux (mouse) port; interrupts OFF while we configure */
	ctlwait(); outb(Cmd, Cauxen);
	cfgset(0, 0);

	/* mouse: defaults + enable reporting (polled; ACKs eaten synchronously
	 * so a lone 0xFA can't desync the packet handler later) */
	auxcmd(0xF6);
	auxcmd(0xF4);
	while(inb(Status) & Sobuf)
		inb(Data);

	/* handlers + IOAPIC unmask first, then turn controller interrupts on */
	intrenable(1, kbdintr, nil, BusCPU, "kbd");
	intrenable(12, mouseintr, nil, BusCPU, "mouse");
	cfgset(1, 1);
	print("i8042: keyboard + mouse enabled\n");
}
