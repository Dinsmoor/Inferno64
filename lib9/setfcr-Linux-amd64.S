/*
 * Floating-point control/status for Linux/amd64.
 *
 * Adapted from setfcr-Linux-386.S.  The Inferno FCR uses the x87 control-word
 * bit layout with the low 6 mask bits complemented (the xorb $0x3f), so this
 * keeps that ABI by driving the x87 control/status words (fldcw/fnstcw/fnstsw).
 * AMD64 SysV passes the argument in %edi (not on the stack as in the 386 cdecl
 * version) and returns in %eax.
 *
 * Note: the interpreter's double arithmetic runs on SSE2, whose rounding/
 * exception state lives in MXCSR, not the x87 control word.  FP *results* are
 * therefore correct regardless; only explicit rounding-mode changes made via
 * Math->FPcontrol are not reflected into SSE here.  Revisit (drive MXCSR too)
 * if a program depends on non-default FP rounding.  This target is currently
 * built but untested.
 */

#define	FN(x)	.type x,@function; .global x; x
#define	ENT	subq $16, %rsp
#define	RET	addq $16, %rsp; ret

	.file	"setfcr-Linux-amd64.S"
	.text

FN(setfcr):
	ENT
	movl	%edi, %eax
	xorb	$0x3f, %al
	movl	%eax, (%rsp)
	fwait
	fldcw	(%rsp)
	RET

FN(getfcr):
	ENT
	fwait
	fstcw	(%rsp)
	movl	(%rsp), %eax
	andl	$0xffff, %eax
	xorb	$0x3f, %al
	RET

FN(getfsr):
	ENT
	fwait
	fnstsw	(%rsp)
	movl	(%rsp), %eax
	andl	$0xffff, %eax
	RET

FN(setfsr):
	fclex
	ret
