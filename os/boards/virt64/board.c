#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"

/*
 * qemu -M virt board hooks (see fns.h).  The heavier devices —
 * ether, sd, draw — are wired through the kernel config instead;
 * what's left here is what needs calling at a particular boot stage.
 */

ulong
rtctime(void)
{
	/* PL031 data register = epoch seconds; qemu -M virt always has one */
	return IOREG32(RTC_PHYS, 0x000);
}

void
boardinit(void)
{
	screeninit();		/* virtio-gpu if present, else ramfb */
}

void
boardready(void)
{
	vgpustart();		/* virtio-gpu scanout refresh, if that's the display */
	virtiornginit();	/* optional: -device virtio-rng-device */
	virtioinputinit();	/* optional: -device virtio-keyboard-device / virtio-tablet-device */
	pciscan();		/* enumerate the PCIe host bridge, if present */
}
