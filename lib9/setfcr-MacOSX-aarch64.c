#include "lib9.h"

/* FP control/status register access (Apple clang inline asm; no Mach-O .S needed). */
void
setfcr(ulong fcr)
{
	__asm__ volatile("msr fpcr, %0" :: "r"((uvlong)fcr));
}

ulong
getfcr(void)
{
	uvlong v;
	__asm__ volatile("mrs %0, fpcr" : "=r"(v));
	return v;
}

void
setfsr(ulong fsr)
{
	__asm__ volatile("msr fpsr, %0" :: "r"((uvlong)fsr));
}

ulong
getfsr(void)
{
	uvlong v;
	__asm__ volatile("mrs %0, fpsr" : "=r"(v));
	return v;
}
