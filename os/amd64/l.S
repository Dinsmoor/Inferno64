/*
 * amd64 (x86-64) low-level support: multiboot entry, the 32-bit→long-mode
 * trampoline, IDT vector stubs, setlabel/gotolabel, spl*, _tas, FP state,
 * and the port-I/O / MSR / cpuid primitives.  GNU as (AT&T), via gcc -c.
 *
 * Boot model: qemu -kernel reads the multiboot1 header below and enters
 * _start in 32-bit protected mode (paging off, ints off).  We build a GDT
 * and identity page tables for the low 4GB, enable PAE+LME+PG, far-jump to
 * 64-bit code, and call main().  Everything runs at CPL0 on one stack;
 * long-mode same-privilege interrupts need no TSS/IST.
 */

#include "board.h"

#define KSTACKSIZE	16384

/* ---- multiboot1 header (must lie in the first 8KB of the image) ---- */
	.section .multiboot, "a"
	.align 4
	.long	MULTIBOOT_MAGIC
	.long	MULTIBOOT_FLAGS
	.long	-(MULTIBOOT_MAGIC + MULTIBOOT_FLAGS)

/* ---- 32-bit entry / long-mode trampoline ---- */
	.section .text.boot, "ax"
	.code32
	.globl _start
_start:
	cli
	cld
	movl	$(bootstack + KSTACKSIZE), %esp

	/* clear BSS (edata..end); page tables live here, filled next */
	movl	$edata, %edi
	movl	$end, %ecx
	subl	%edi, %ecx
	xorl	%eax, %eax
	rep stosb

	/* page directories: 2048 entries (4 PDs) map [0,4GB) as 2MB pages */
	movl	$pd, %edi
	movl	$0x83, %eax		/* present|rw|PS, phys base 0 */
	xorl	%ebx, %ebx
1:	movl	%eax, 0(%edi)
	movl	$0, 4(%edi)
	addl	$0x200000, %eax
	addl	$8, %edi
	incl	%ebx
	cmpl	$2048, %ebx
	jb	1b

	/* PDPT[0..3] -> the four PDs */
	movl	$pdpt, %edi
	movl	$pd, %eax
	orl	$0x3, %eax
	xorl	%ebx, %ebx
2:	movl	%eax, 0(%edi)
	movl	$0, 4(%edi)
	addl	$4096, %eax
	addl	$8, %edi
	incl	%ebx
	cmpl	$4, %ebx
	jb	2b

	/* PML4[0] -> PDPT */
	movl	$pml4, %edi
	movl	$pdpt, %eax
	orl	$0x3, %eax
	movl	%eax, 0(%edi)
	movl	$0, 4(%edi)

	/* CR3 = PML4 */
	movl	$pml4, %eax
	movl	%eax, %cr3

	/* CR4.PAE */
	movl	%cr4, %eax
	orl	$0x20, %eax
	movl	%eax, %cr4

	/* EFER.LME (MSR 0xC0000080 bit 8) */
	movl	$0xC0000080, %ecx
	rdmsr
	orl	$0x100, %eax
	wrmsr

	/* CR0.PG | CR0.PE -> long mode active (compat until far jump) */
	movl	%cr0, %eax
	orl	$0x80000001, %eax
	movl	%eax, %cr0

	lgdt	gdtdesc
	ljmp	$SEL_KCODE, $start64

	.code64
start64:
	movw	$SEL_KDATA, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movw	%ax, %fs
	movw	%ax, %gs

	/* enable SSE: the amd64 codegen (and the trap-stub FXSAVE) need it */
	movq	%cr0, %rax
	andq	$~(1<<2), %rax		/* clear EM (no x87 emulation) */
	orq	$(1<<1), %rax		/* set MP */
	movq	%rax, %cr0
	movq	%cr4, %rax
	orq	$((1<<9)|(1<<10)), %rax	/* OSFXSR | OSXMMEXCPT */
	movq	%rax, %cr4

	movabsq	$(bootstack + KSTACKSIZE), %rsp
	andq	$~15, %rsp
	xorq	%rbp, %rbp
	call	main
1:	hlt
	jmp	1b

/* ---- GDT ---- */
	.section .rodata
	.align 16
gdt:
	.quad	0x0000000000000000	/* null */
	.quad	0x00CF9A000000FFFF	/* 0x08 32-bit code */
	.quad	0x00CF92000000FFFF	/* 0x10 data */
	.quad	0x00AF9A000000FFFF	/* 0x18 64-bit code (L=1) */
	.quad	0x00AF92000000FFFF	/* 0x20 64-bit data */
gdtend:
	.align 16
gdtdesc:
	.word	gdtend - gdt - 1
	.long	gdt

/* ---- IDT vector stubs ---- */
	.section .text
	.code64
	.align 16
	.globl vectortab
vectortab:
	vecno = 0
	.rept 256
	.align 16
	.if (vecno==8)||(vecno==10)||(vecno==11)||(vecno==12)||(vecno==13)||(vecno==14)||(vecno==17)||(vecno==21)
	pushq	$vecno			/* CPU already pushed an error code */
	.else
	pushq	$0			/* dummy error code */
	pushq	$vecno
	.endif
	jmp	trapcommon
	vecno = vecno + 1
	.endr

trapcommon:
	/* stack: vecno, error, rip, cs, rflags, rsp, ss (low->high) */
	pushq	%r15
	pushq	%r14
	pushq	%r13
	pushq	%r12
	pushq	%r11
	pushq	%r10
	pushq	%r9
	pushq	%r8
	pushq	%rbp
	pushq	%rdi
	pushq	%rsi
	pushq	%rdx
	pushq	%rcx
	pushq	%rbx
	pushq	%rax			/* rsp -> Ureg base (.ax) */

	movq	%rsp, %rdi		/* Ureg* */
	movq	%rsp, %rbp		/* remember Ureg base */
	subq	$512, %rsp
	andq	$~15, %rsp		/* 16-aligned FXSAVE area + call alignment */
	fxsave	(%rsp)
	call	trap
	fxrstor	(%rsp)
	movq	%rbp, %rsp		/* discard FXSAVE area */

	popq	%rax
	popq	%rbx
	popq	%rcx
	popq	%rdx
	popq	%rsi
	popq	%rdi
	popq	%rbp
	popq	%r8
	popq	%r9
	popq	%r10
	popq	%r11
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	addq	$16, %rsp		/* skip vecno + error */
	iretq

/* void lidtload(void*) — load IDTR from a 10-byte descriptor */
	.globl lidtload
lidtload:
	lidt	(%rdi)
	ret

/*
 * int setlabel(Label*) — 0 now, 1 when gotolabel returns here.
 * Label = {sp, pc, bx, bp, r12, r13, r14, r15}.
 */
	.globl setlabel
setlabel:
	movq	(%rsp), %rax		/* return address */
	movq	%rax, 8(%rdi)		/* pc */
	leaq	8(%rsp), %rax		/* caller's sp */
	movq	%rax, 0(%rdi)		/* sp */
	movq	%rbx, 16(%rdi)
	movq	%rbp, 24(%rdi)
	movq	%r12, 32(%rdi)
	movq	%r13, 40(%rdi)
	movq	%r14, 48(%rdi)
	movq	%r15, 56(%rdi)
	xorl	%eax, %eax
	ret

	.globl gotolabel
gotolabel:
	movq	16(%rdi), %rbx
	movq	24(%rdi), %rbp
	movq	32(%rdi), %r12
	movq	40(%rdi), %r13
	movq	48(%rdi), %r14
	movq	56(%rdi), %r15
	movq	0(%rdi), %rsp
	movl	$1, %eax
	jmp	*8(%rdi)

/* interrupt priority: the IF flag in RFLAGS.  spl* return/accept RFLAGS. */
	.globl splhi
splhi:
	pushfq
	popq	%rax
	cli
	ret
	.globl spllo
spllo:
	pushfq
	popq	%rax
	sti
	ret
	.globl splx
	.globl splxpc
splx:
splxpc:
	testq	$0x200, %rdi		/* old IF */
	jnz	1f
	cli
	ret
1:	sti
	ret
	.globl islo
islo:
	pushfq
	popq	%rax
	shrq	$9, %rax		/* IF -> bit0 */
	andq	$1, %rax
	ret

/* ulong _tas(ulong*) — atomic test-and-set, returns old value */
	.globl _tas
_tas:
	movq	$1, %rax
	xchgq	%rax, (%rdi)
	ret

/*
 * FP state for Dis prog switches: void FPsave(FPenv*), void FPrestore(FPenv*).
 * FPenv = {ulong status; ulong control}.  Only the control/status words
 * cross a timeslice; live xmm/x87 values are caller-saved at the xec(r)
 * boundary and the trap stubs FXSAVE/FXRSTOR the full file across interrupts.
 */
	.globl FPsave
FPsave:
	fnstsw	%ax
	movl	%eax, 0(%rdi)		/* status (x87 SW) */
	stmxcsr	8(%rdi)			/* control (MXCSR) */
	ret
	.globl FPrestore
FPrestore:
	ldmxcsr	8(%rdi)
	ret

/* uintptr getcallerpc(void*) — for lib objects that don't see the macro */
	.globl getcallerpc
getcallerpc:
	movq	(%rsp), %rax
	ret

/* FP control/status for libmath/libinterp (MXCSR) */
	.globl getfcr
getfcr:
	subq	$8, %rsp
	stmxcsr	(%rsp)
	movl	(%rsp), %eax
	addq	$8, %rsp
	ret
	.globl setfcr
setfcr:
	subq	$8, %rsp
	movl	%edi, (%rsp)
	ldmxcsr	(%rsp)
	addq	$8, %rsp
	ret
	.globl getfsr
getfsr:
	subq	$8, %rsp
	stmxcsr	(%rsp)
	movl	(%rsp), %eax
	addq	$8, %rsp
	ret
	.globl setfsr
setfsr:
	ret

/* ---- port I/O ---- */
	.globl inb
inb:	movl %edi, %edx; xorl %eax, %eax; inb %dx, %al; ret
	.globl ins
ins:	movl %edi, %edx; xorl %eax, %eax; inw %dx, %ax; ret
	.globl inl
inl:	movl %edi, %edx; inl %dx, %eax; ret
	.globl outb
outb:	movl %edi, %edx; movl %esi, %eax; outb %al, %dx; ret
	.globl outs
outs:	movl %edi, %edx; movl %esi, %eax; outw %ax, %dx; ret
	.globl outl
outl:	movl %edi, %edx; movl %esi, %eax; outl %eax, %dx; ret

/* void insb(int port, void *buf, int n) — DS:RDI <- port, n bytes */
	.globl insb
insb:
	movl	%edx, %ecx
	movzwl	%di, %edx
	movq	%rsi, %rdi
	cld
	rep insb
	ret
/* void outsb(int port, void *buf, int n) — port <- DS:RSI, n bytes */
	.globl outsb
outsb:
	movl	%edx, %ecx
	movzwl	%di, %edx
	cld
	rep outsb
	ret

/* ---- MSR / cpuid / TSC ---- */
	.globl rdmsr
rdmsr:
	movl	%edi, %ecx
	rdmsr
	shlq	$32, %rdx
	movl	%eax, %eax
	orq	%rdx, %rax
	ret
	.globl wrmsr
wrmsr:
	movl	%edi, %ecx
	movq	%rsi, %rax
	movq	%rsi, %rdx
	shrq	$32, %rdx
	wrmsr
	ret
	.globl cpuid
cpuid:
	movq	%rdx, %r8		/* regs[4] */
	movl	%edi, %eax
	movl	%esi, %ecx
	pushq	%rbx
	cpuid
	movl	%eax, 0(%r8)
	movl	%ebx, 4(%r8)
	movl	%ecx, 8(%r8)
	movl	%edx, 12(%r8)
	popq	%rbx
	ret
	.globl rdtsc
rdtsc:
	rdtsc
	shlq	$32, %rdx
	movl	%eax, %eax
	orq	%rdx, %rax
	ret

/* ---- BSS: boot stack and the boot page tables ---- */
	.section .bss
	.balign 4096
	.globl bootstack
bootstack:
	.space	KSTACKSIZE
	.balign 4096
pml4:	.space	4096
pdpt:	.space	4096
pd:	.space	4096*4
