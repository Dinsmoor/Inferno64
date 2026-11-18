/*
 * int _tas(int *x): test-and-set spinlock primitive (Mach-O form of
 * emu/Linux/aarch64-tas.S).  Returns 0 if the lock was acquired.
 */
	.text
	.p2align 2
	.globl __tas
__tas:
	dmb	ish
	mov	x1, x0
	mov	w2, #0xaa
1:
	ldxr	w0, [x1]
	cbnz	w0, 2f
	stxr	w3, w2, [x1]
	cbnz	w3, 1b
	dmb	ish
	ret
2:
	clrex
	ret
