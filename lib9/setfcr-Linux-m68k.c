/*
 * FP control/status for the m68k cross-canary target (tests/cunit/cross.sh).
 * The canary exists to keep the portable libs honest under big-endian ILP32;
 * mapping Plan 9 FCR bits onto the 68881 FPCR is not part of that, so these
 * are no-ops.  Do the real mapping if m68k ever becomes a hosted emu target.
 */
#include "lib9.h"

void
setfcr(ulong fcr)
{
	USED(fcr);
}

ulong
getfcr(void)
{
	return 0;
}

void
setfsr(ulong fsr)
{
	USED(fsr);
}

ulong
getfsr(void)
{
	return 0;
}
