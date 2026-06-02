/*
 * Dis JIT compiler back-end for x86-64 (amd64) — interpreter-only stub.
 *
 * The Dis VM runs either interpreted (architecture-independent, the default
 * when cflag==0) or JIT-compiled to native code by an arch-specific back-end
 * in comp-OBJTYPE.c.  There is no x86-64 JIT yet, so this stub makes compile()
 * report "no native code generated", forcing every module onto the interpreter
 * path.  compile() never sets Module.compiled, so xec.c never dispatches
 * through comvec(); leaving comvec nil is therefore safe.
 *
 * comp-386.c is the nearest reference for a future x86-64 back-end; see also
 * AGENTS_JIT.md.
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
