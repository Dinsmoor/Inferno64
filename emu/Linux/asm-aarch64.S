	.file	"asm-aarch64.S"
	.text

/*
 * ulong umult(ulong m1, ulong m2, ulong *hi)
 *
 * ARMv8: result is 64-bit * 64-bit -> (64-bit low in x0, 64-bit high in x2)
 * On aarch64, ulong is 64-bit (unsigned long), so:
 *   - low 64 bits go in x0 (return value)
 *   - high 64 bits go in *x2 (the hi pointer)
 */

	.align 	2
	.global umult
	.type	umult, %function
umult:
	// x0 = m1, x1 = m2, x2 = *hi (pointer to hi register)
	umulh	x3, x0, x1     // x3 = m1 * m2 (high 64 bits)
	mul	x0, x0, x1     // x0 = m1 * m2 (low 64 bits, also return value)
	str	x3, [x2]       // store high part through pointer
	ret
	.size	umult, .-umult

/*
 * void FPsave(void *ptr);
 *
 * Saves all 32 double-precision (64-bit) floating-point registers.
 * Total: 32 * 8 bytes = 256 bytes.
 *
 * Must match the FPU struct in Linux/aarch64/include/emu.h:
 *   struct FPU { uchar env[256]; };
 */

	.align 	2
	.global FPsave
	.type	FPsave, %function
FPsave:
	// x0 = pointer to save buffer
	stp	d0, d1, [x0]         //  0: D0, D1
	stp	d2, d3, [x0, #16]    // 16: D2, D3
	stp	d4, d5, [x0, #32]    // 32: D4, D5
	stp	d6, d7, [x0, #48]    // 48: D6, D7
	stp	d8, d9, [x0, #64]    // 64: D8, D9
	stp	d10, d11, [x0, #80]  // 80: D10, D11
	stp	d12, d13, [x0, #96]  // 96: D12, D13
	stp	d14, d15, [x0, #112] // 112: D14, D15
	stp	d16, d17, [x0, #128] // 128: D16, D17
	stp	d18, d19, [x0, #144] // 144: D18, D19
	stp	d20, d21, [x0, #160] // 160: D20, D21
	stp	d22, d23, [x0, #176] // 176: D22, D23
	stp	d24, d25, [x0, #192] // 192: D24, D25
	stp	d26, d27, [x0, #208] // 208: D26, D27
	stp	d28, d29, [x0, #224] // 224: D28, D29
	stp	d30, d31, [x0, #240] // 240: D30, D31
	ret
	.size	FPsave, .-FPsave

/*
 * void FPrestore(void *ptr);
 *
 * Restores all 32 double-precision (64-bit) floating-point registers.
 * Must match FPsave layout exactly.
 */

	.align 	2
	.global FPrestore
	.type	FPrestore, %function
FPrestore:
	// x0 = pointer to restore buffer
	ldp	d0, d1, [x0]         //  0: D0, D1
	ldp	d2, d3, [x0, #16]    // 16: D2, D3
	ldp	d4, d5, [x0, #32]    // 32: D4, D5
	ldp	d6, d7, [x0, #48]    // 48: D6, D7
	ldp	d8, d9, [x0, #64]    // 64: D8, D9
	ldp	d10, d11, [x0, #80]  // 80: D10, D11
	ldp	d12, d13, [x0, #96]  // 96: D12, D13
	ldp	d14, d15, [x0, #112] // 112: D14, D15
	ldp	d16, d17, [x0, #128] // 128: D16, D17
	ldp	d18, d19, [x0, #144] // 144: D18, D19
	ldp	d20, d21, [x0, #160] // 160: D20, D21
	ldp	d22, d23, [x0, #176] // 176: D22, D23
	ldp	d24, d25, [x0, #192] // 192: D24, D25
	ldp	d26, d27, [x0, #208] // 208: D26, D27
	ldp	d28, d29, [x0, #224] // 224: D28, D29
	ldp	d30, d31, [x0, #240] // 240: D30, D31
	ret
	.size	FPrestore, .-FPrestore
