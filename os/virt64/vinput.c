#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "virtio.h"
#include <keyboard.h>

/*
 * virtio-input (device id 18): qemu -device virtio-keyboard-device and
 * -device virtio-tablet-device (needs the modern transport — see
 * virtio.c).  Each device has an eventq the device fills with 8-byte
 * evdev-style events; keys go to kbdq via kbdputc, the tablet's
 * absolute coordinates (0..32767 scaled to the screen) and buttons go
 * to devpointer via mousetrack.  The tablet is the right pointer for
 * qemu: absolute positioning means no pointer grab and no drift.
 */

enum {
	/* evdev event types */
	EVsyn		= 0,
	EVkey		= 1,
	EVrel		= 2,
	EVabs		= 3,

	/* codes */
	BTNleft		= 0x110,
	BTNright	= 0x111,
	BTNmiddle	= 0x112,
	ABSx		= 0,
	ABSy		= 1,

	/* config space selectors */
	Cfgidname	= 0x01,
	Cfgevbits	= 0x11,
	Cfgselect	= 0,	/* config offsets */
	Cfgsubsel	= 1,
	Cfgsize		= 2,

	Nevents		= 64,
	Ninputdevs	= 4,
};

typedef struct Vinevent Vinevent;
struct Vinevent {		/* virtio_input_event, little-endian */
	u16int	type;
	u16int	code;
	u32int	value;
};

typedef struct Vinput Vinput;
struct Vinput {
	Vdev	*dev;
	Vqueue	*eventq;
	Vinevent *ev;		/* Nevents DMA buffers */
	int	abs;		/* it's the tablet */
	/* pointer state */
	int	x, y, b;
	/* keyboard state */
	int	shift;
	int	ctrl;
	int	caps;
};

static Vinput vinputs[Ninputdevs];

/*
 * evdev keycode -> rune, US layout.  View/Spec values from keyboard.h.
 */
static Rune keymap[128] = {
	[1]	Esc,
	[2]	'1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\b',
	[15]	'\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n',
	[30]	'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`',
	[43]	'\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
	[55]	'*',
	[57]	' ',
	[74]	'-', '+',
	[96]	'\n',
	[98]	'/',
	[102]	Home, Up, Pgup, Left, No, Right, End, Down, Pgdown, Ins, Del,
};

static Rune keymapshift[128] = {
	[1]	Esc,
	[2]	'!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', '\b',
	[15]	BackTab, 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n',
	[30]	'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~',
	[43]	'|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?',
	[55]	'*',
	[57]	' ',
	[74]	'-', '+',
	[96]	'\n',
	[98]	'/',
	[102]	Home, Up, Pgup, Left, No, Right, End, Down, Pgdown, Ins, Del,
};

extern Queue *kbdq;	/* devcons input; the uart owns its creation */

static void
vinputkey(Vinput *in, int code, int value)
{
	Rune r;

	/* modifiers: 42/54 shift, 29/97 ctrl, 58 caps lock */
	switch(code){
	case 42:
	case 54:
		in->shift = value != 0;
		return;
	case 29:
	case 97:
		in->ctrl = value != 0;
		return;
	case 58:
		if(value == 1)
			in->caps ^= 1;
		return;
	}
	if(value == 0)		/* key up */
		return;
	if(code >= nelem(keymap))
		return;
	r = in->shift ? keymapshift[code] : keymap[code];
	if(r == 0 || r == No)
		return;
	if(in->caps && r >= 'a' && r <= 'z')
		r += 'A'-'a';
	if(in->ctrl && (r|0x20) >= 'a' && (r|0x20) <= 'z')
		r &= 0x1f;
	if(kbdq != nil)
		kbdputc(kbdq, r);
}

static void
vinputevent(Vinput *in, Vinevent *e)
{
	int w, h;

	switch(e->type){
	case EVkey:
		if(e->code >= BTNleft && e->code <= BTNmiddle){
			int bit;
			switch(e->code){
			case BTNleft:	bit = 1; break;
			case BTNmiddle:	bit = 2; break;
			default:	bit = 4; break;
			}
			if(e->value)
				in->b |= bit;
			else
				in->b &= ~bit;
		}else
			vinputkey(in, e->code, e->value);
		break;
	case EVabs:
		screensize(&w, &h);
		if(e->code == ABSx)
			in->x = (vlong)e->value * w / 32768;
		else if(e->code == ABSy)
			in->y = (vlong)e->value * h / 32768;
		break;
	case EVsyn:
		if(in->abs)
			mousetrack(in->b, in->x, in->y, 0);
		break;
	}
}

static void
vinputintr(Vdev *d)
{
	Vinput *in;
	Vqueue *q;
	Vusedelem *e;
	int id;

	in = d->aux;
	q = in->eventq;
	while(q->lastused != q->used->idx){
		e = &q->used->ring[q->lastused % q->num];
		id = e->id;
		if(id >= 0 && id < Nevents)
			vinputevent(in, &in->ev[id]);
		/* hand the buffer straight back */
		q->avail->ring[q->avail->idx % q->num] = id;
		coherence();
		q->avail->idx++;
		q->lastused++;
	}
	virtionotify(d, q->idx);
}

static int
vinputsetup(Vinput *in, Vdev *d)
{
	Vqueue *q;
	int i;

	if(virtiodevinit(d) < 0)
		return -1;

	/* does it do absolute axes?  then it's the tablet */
	virtiocfgw8(d, Cfgselect, Cfgevbits);
	virtiocfgw8(d, Cfgsubsel, EVabs);
	in->abs = virtiocfgr8(d, Cfgsize) > 0;

	q = virtioqalloc(d, 0, Nevents);
	if(q == nil)
		return -1;
	in->eventq = q;
	in->dev = d;
	d->aux = in;

	in->ev = xspanalloc(Nevents*sizeof(Vinevent), 64, 0);
	if(in->ev == nil)
		return -1;
	for(i = 0; i < Nevents; i++){
		q->desc[i].addr = (uintptr)&in->ev[i];
		q->desc[i].len = sizeof(Vinevent);
		q->desc[i].flags = Descwrite;
		q->avail->ring[i] = i;
	}
	coherence();
	q->avail->idx = Nevents;

	virtiointrenable(d, vinputintr, in->abs ? "vtablet" : "vkbd");
	virtioready(d);
	virtionotify(d, 0);
	return 0;
}

void
virtioinputinit(void)
{
	Vdev *d;
	int nth, ndev;

	ndev = 0;
	for(nth = 0; ndev < Ninputdevs; nth++){
		d = virtioprobe(18, nth);
		if(d == nil)
			break;
		if(vinputsetup(&vinputs[ndev], d) < 0){
			free(d);
			continue;
		}
		print("virtio-input %s at slot %d\n",
			vinputs[ndev].abs ? "tablet" : "keyboard", d->slot);
		ndev++;
	}
}
