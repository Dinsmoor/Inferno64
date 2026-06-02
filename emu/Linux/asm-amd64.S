	.file	"asm-Linux-amd64.S"
	.text

/*
 * x86-64 (AMD64 System V ABI): integer args in %rdi,%rsi,%rdx,...; return %rax.
 * The Dis VM is interpreter-only on this target; umult is here for the JIT
 * (stubbed) and for any caller needing a 64x64->128 multiply.
 */

/*
 * umult(ulong m1, ulong m2, ulong *hi)
 * returns low 64 bits of m1*m2 in %rax; stores high 64 bits at *hi.
 *   m1=%rdi  m2=%rsi  hi=%rdx
 * mulq multiplies %rax by the operand, leaving the 128-bit product in %rdx:%rax,
 * so save the *hi pointer first (mulq clobbers %rdx).
 */
	.type	umult,@function
	.global	umult
umult:
	movq	%rdx, %rcx
	movq	%rdi, %rax
	mulq	%rsi
	movq	%rdx, (%rcx)
	ret

/*
 * FPsave(void *envp) / FPrestore(void *envp)  (envp=%rdi)
 * Save/restore the x87 environment (fnstenv, 28 bytes) plus the SSE control/
 * status register MXCSR (offset 28).  The interpreter does double arithmetic
 * with SSE2, so MXCSR carries the live rounding/exception state; the x87 env is
 * preserved too, matching the 386 build.  Must agree with struct FPU in
 * Linux/amd64/include/emu.h (env[64]).
 */
	.type	FPsave,@function
	.global	FPsave
FPsave:
	fnstenv	(%rdi)
	stmxcsr	28(%rdi)
	ret

	.type	FPrestore,@function
	.global	FPrestore
FPrestore:
	fldenv	(%rdi)
	ldmxcsr	28(%rdi)
	ret

/*
 * _tas(int *l)  (l=%rdi)
 * Atomic test-and-set: store 1 into *l, return the previous value.
 * XCHG to memory is implicitly atomic (asserts LOCK) on x86.
 */
	.type	_tas,@function
	.globl	_tas
_tas:
	movl	$1, %eax
	xchgl	%eax, 0(%rdi)
	ret
