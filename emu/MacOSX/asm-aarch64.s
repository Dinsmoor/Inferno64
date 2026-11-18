
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
	.globl _umult
_umult:
	
	umulh	x3, x0, x1     
	mul	x0, x0, x1     
	str	x3, [x2]       
	ret

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
	.globl _FPsave
_FPsave:
	
	stp	d0, d1, [x0]         
	stp	d2, d3, [x0, #16]    
	stp	d4, d5, [x0, #32]    
	stp	d6, d7, [x0, #48]    
	stp	d8, d9, [x0, #64]    
	stp	d10, d11, [x0, #80]  
	stp	d12, d13, [x0, #96]  
	stp	d14, d15, [x0, #112] 
	stp	d16, d17, [x0, #128] 
	stp	d18, d19, [x0, #144] 
	stp	d20, d21, [x0, #160] 
	stp	d22, d23, [x0, #176] 
	stp	d24, d25, [x0, #192] 
	stp	d26, d27, [x0, #208] 
	stp	d28, d29, [x0, #224] 
	stp	d30, d31, [x0, #240] 
	ret

/*
 * void FPrestore(void *ptr);
 *
 * Restores all 32 double-precision (64-bit) floating-point registers.
 * Must match FPsave layout exactly.
 */

	.align 	2
	.globl _FPrestore
_FPrestore:
	
	ldp	d0, d1, [x0]         
	ldp	d2, d3, [x0, #16]    
	ldp	d4, d5, [x0, #32]    
	ldp	d6, d7, [x0, #48]    
	ldp	d8, d9, [x0, #64]    
	ldp	d10, d11, [x0, #80]  
	ldp	d12, d13, [x0, #96]  
	ldp	d14, d15, [x0, #112] 
	ldp	d16, d17, [x0, #128] 
	ldp	d18, d19, [x0, #144] 
	ldp	d20, d21, [x0, #160] 
	ldp	d22, d23, [x0, #176] 
	ldp	d24, d25, [x0, #192] 
	ldp	d26, d27, [x0, #208] 
	ldp	d28, d29, [x0, #224] 
	ldp	d30, d31, [x0, #240] 
	ret
