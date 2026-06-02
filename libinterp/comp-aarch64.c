/*
 * Dis JIT compiler back-end for AArch64 — interpreter-only stub.
 *
 * The Dis VM runs either interpreted (architecture-independent, the default
 * when cflag==0) or JIT-compiled to native code by an arch-specific back-end
 * in comp-OBJTYPE.c.  This file is the AArch64 back-end.
 *
 * A native JIT for AArch64 is not yet complete; a work-in-progress attempt is
 * preserved alongside this file as comp-aarch64.c.jit-wip.  Until it is
 * finished and verified, this stub makes compile() report "no native code
 * generated", which forces every module onto the interpreter path.  Because
 * compile() never sets Module.compiled, xec.c never dispatches through
 * comvec(), so leaving comvec nil here is safe.
 *
 * See AGENTS_JIT.md (compilation pipeline) and AGENTS_AARCH64.md (the encoding
 * details a real back-end needs) before reviving the JIT.
 */
#include "lib9.h"
#include "isa.h"
#include "interp.h"

void (*comvec)(void);

int
compile(Module *m, int size, Modlink *ml)
{
	USED(m);
	USED(size);
	USED(ml);
	return 0;	/* not compiled: run this module interpreted */
}
