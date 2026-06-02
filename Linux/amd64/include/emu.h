/*
 * system- and machine-specific declarations for emu:
 * floating-point save and restore, signal handling primitive, and
 * implementation of the current-process variable `up'.
 */

/*
 * This structure must agree with FPsave and FPrestore in emu/Linux/asm-amd64.S.
 * FPsave/FPrestore save the x87 environment (fnstenv, 28 bytes in 64-bit mode)
 * followed by the SSE control/status register MXCSR (stmxcsr, 4 bytes at
 * offset 28).  64 bytes leaves margin and keeps the 4-byte MXCSR slot aligned.
 */
typedef struct FPU FPU;
struct FPU
{
	uchar	env[64];
};

#ifndef USE_PTHREADS
#define KSTACK (16 * 1024)	/* must be power of two */
static __inline Proc *getup(void) {
	Proc *p;
	__asm__(	"movq	%%rsp, %0;"
			: "=r" (p)
	);
	return *(Proc **)((uintptr)p & ~(KSTACK - 1));
}
#else
#define KSTACK (32 * 1024)	/* need not be power of two */
extern	Proc*	getup(void);
#endif

#define	up	(getup())

typedef sigjmp_buf osjmpbuf;
#define	ossetjmp(buf)	sigsetjmp(buf, 1)
