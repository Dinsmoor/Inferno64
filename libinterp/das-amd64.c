/*
 * Native-code disassembler for x86-64 — stub.
 *
 * das() is only reachable with cflag>4 (disassemble JIT output), and the
 * x86-64 JIT is stubbed (comp-amd64.c), so a no-op is sufficient.  Mirrors
 * das-stub.c.
 */
#include <lib9.h>
#include <kernel.h>

void
das(uchar *x, int n)
{
	USED(x);
	USED(n);
}
