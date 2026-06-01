	.file	"aarch64-tas.S"
	.text
	.align 	2
	.global _tas
	.type	_tas, %function
_tas:
	// x0 = pointer to lock word (int*)
	// Returns: 0 = lock acquired, non-zero = already locked

	dmb	ish                  // Data Memory Barrier (isolation = full system)
	mov	x1, x0                 // save pointer in x1
	mov	w2, #0xaa              // value to store when acquiring (matches ARM v7's 0xaa)
tas1:
	ldxr	w0, [x1]             // load exclusive (32-bit word)
	cbnz	w0, lockbusy         // branch if non-zero (already locked)
	stxr	w3, w2, [x1]         // try store exclusive
	cbnz	w3, tas1             // if failed (w3=1), retry
	dmb	ish                  // barrier before successful return
	ret
lockbusy:
	clrex                        // clear the exclusive monitor
	ret
	.size	_tas, .-_tas
