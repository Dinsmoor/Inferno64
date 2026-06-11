/*
 * aarch64 (qemu -M virt) low-level support: entry, exception vectors,
 * setlabel/gotolabel, spl*, _tas, FP state.  GNU as.
 *
 * We run everything at EL1 with SP_EL1 (EL1h), identity-mapped
 * (MMU + caches on; flat 1GB-block map built at boot below).
 */

#define DAIF_I		(1<<7)
#define KSTACKSIZE	16384

/* Ureg layout — must match Inferno/aarch64/include/ureg.h */
#define UREG_R0		(0*8)
#define UREG_SP		(31*8)
#define UREG_PC		(32*8)
#define UREG_PSR	(33*8)
#define UREG_TYPE	(34*8)
#define UREG_ESR	(35*8)
#define UREG_FAR	(36*8)
#define UREG_SIZE	(38*8)

/* full FP context saved below the Ureg on trap entry */
#define FPCTX_SIZE	(64*8+16)
#define FRAME_SIZE	(UREG_SIZE+FPCTX_SIZE)

/* Label layout — must match struct Label in dat.h */
#define LABEL_SP	0
#define LABEL_PC	8
#define LABEL_REGS	16		/* x19-x29 */
#define LABEL_FPREGS	(16+11*8)	/* d8-d15 */

	.section ".text.boot", "ax"
	.balign 4
	.globl _start
_start:
	/* mask all interrupts */
	msr	daifset, #0xf

	/* if entered at EL2, drop to EL1h */
	mrs	x1, CurrentEL
	lsr	x1, x1, #2
	cmp	x1, #2
	b.ne	1f
	mov	x1, #(1<<31)		/* HCR_EL2.RW: EL1 is aarch64 */
	msr	hcr_el2, x1
	mov	x1, #0x3c5		/* DAIF masked, EL1h */
	msr	spsr_el2, x1
	adr	x1, 1f
	msr	elr_el2, x1
	mov	x1, #0x33ff		/* CPTR_EL2: no traps */
	msr	cptr_el2, x1
	msr	hstr_el2, xzr
	eret
1:
	/* enable FP/SIMD at EL1 */
	mov	x1, #(3<<20)		/* CPACR_EL1.FPEN = no trap */
	msr	cpacr_el1, x1
	isb

	/* exception vectors */
	adrp	x1, vectortab
	add	x1, x1, :lo12:vectortab
	msr	vbar_el1, x1

	/* clear BSS (linker provides edata/end, both 16-aligned) */
	adrp	x1, edata
	add	x1, x1, :lo12:edata
	adrp	x2, end
	add	x2, x2, :lo12:end
1:	cmp	x1, x2
	b.hs	2f
	stp	xzr, xzr, [x1], #16
	b	1b
2:
	/*
	 * MMU + caches on, identity map.  T0SZ=32 → 4GB VA, walks start
	 * at level 1, so the whole map is two 1GB block entries:
	 *   [0] 0x00000000  device nGnRnE, AF, AttrIdx1, PXN|UXN
	 *       (flash, GIC @0x08000000, PL011 @0x09000000, virtio)
	 *   [1] 0x40000000  normal write-back inner-shareable, AF, AttrIdx0
	 * Remaining entries stay 0 (invalid) — kpgtbl is in just-cleared BSS.
	 * No set/way D-cache invalidate: TCG doesn't model caches; real
	 * hardware bring-up would need the 9front cache.v8.s dance.
	 */
	adrp	x1, kpgtbl
	add	x1, x1, :lo12:kpgtbl
	ldr	x2, =0x0060000000000405	/* device block: UXN|PXN|AF|AttrIdx1|block */
	str	x2, [x1]
	ldr	x2, =0x40000701		/* RAM block: AF|SH=ISH|AttrIdx0|block */
	str	x2, [x1, #8]
	dsb	ish
	msr	ttbr0_el1, x1
	mov	x2, #0xff		/* MAIR: Attr0=0xFF normal WB, Attr1=0x00 device-nGnRnE */
	msr	mair_el1, x2
	ldr	x2, =0x200803520	/* TCR: T0SZ=32, 4K, IRGN/ORGN=WB, SH=ISH, EPD1, IPS=40bit */
	msr	tcr_el1, x2
	isb
	tlbi	vmalle1
	ic	iallu
	dsb	nsh
	isb
	mrs	x2, sctlr_el1
	orr	x2, x2, #(1<<0)		/* M: MMU */
	orr	x2, x2, #(1<<2)		/* C: D-cache */
	orr	x2, x2, #(1<<12)	/* I: I-cache */
	msr	sctlr_el1, x2
	isb

	/* boot stack, then C */
	adrp	x1, bootstack
	add	x1, x1, :lo12:bootstack
	add	x1, x1, #KSTACKSIZE
	mov	sp, x1
	bl	main
3:	wfe
	b	3b

	.section ".bss"
	.balign	16
	.globl bootstack
bootstack:
	.space	KSTACKSIZE
	.balign	4096
kpgtbl:
	.space	4096

/*
 * Exception vectors.  Each entry is at most 32 instructions.
 * Types: 0 sync, 1 irq, 2 fiq, 3 serror.  Vectors from EL0 or with
 * SP_EL0 shouldn't happen — give them distinct types (+4, +8) so the
 * panic message says which.
 */
	.section ".text"

.macro	VEC type
	.balign	0x80
	sub	sp, sp, #FRAME_SIZE
	stp	x0, x1, [sp, #(UREG_R0+0*8)]
	mov	x0, #\type
	b	vcommon
.endm

	.balign	0x800
	.globl vectortab
vectortab:
	/* current EL, SP_EL0 — broken */
	VEC	8
	VEC	9
	VEC	10
	VEC	11
	/* current EL, SP_ELx — the real ones */
	VEC	0
	VEC	1
	VEC	2
	VEC	3
	/* lower EL, aarch64 — shouldn't happen */
	VEC	4
	VEC	5
	VEC	6
	VEC	7
	/* lower EL, aarch32 — shouldn't happen */
	VEC	4
	VEC	5
	VEC	6
	VEC	7

vcommon:
	/* x0 = type; x0/x1 already saved; sp = frame base */
	stp	x2, x3, [sp, #(UREG_R0+2*8)]
	stp	x4, x5, [sp, #(UREG_R0+4*8)]
	stp	x6, x7, [sp, #(UREG_R0+6*8)]
	stp	x8, x9, [sp, #(UREG_R0+8*8)]
	stp	x10, x11, [sp, #(UREG_R0+10*8)]
	stp	x12, x13, [sp, #(UREG_R0+12*8)]
	stp	x14, x15, [sp, #(UREG_R0+14*8)]
	stp	x16, x17, [sp, #(UREG_R0+16*8)]
	stp	x18, x19, [sp, #(UREG_R0+18*8)]
	stp	x20, x21, [sp, #(UREG_R0+20*8)]
	stp	x22, x23, [sp, #(UREG_R0+22*8)]
	stp	x24, x25, [sp, #(UREG_R0+24*8)]
	stp	x26, x27, [sp, #(UREG_R0+26*8)]
	stp	x28, x29, [sp, #(UREG_R0+28*8)]
	str	x30, [sp, #(UREG_R0+30*8)]
	add	x1, sp, #FRAME_SIZE		/* original sp */
	str	x1, [sp, #UREG_SP]
	mrs	x1, elr_el1
	str	x1, [sp, #UREG_PC]
	mrs	x1, spsr_el1
	str	x1, [sp, #UREG_PSR]
	str	x0, [sp, #UREG_TYPE]
	mrs	x1, esr_el1
	str	x1, [sp, #UREG_ESR]
	mrs	x1, far_el1
	str	x1, [sp, #UREG_FAR]

	/* full FP context: the interrupted code may hold live
	 * caller-saved FP registers (an IRQ is not a call boundary) */
	add	x1, sp, #UREG_SIZE
	stp	q0, q1, [x1, #(0*16)]
	stp	q2, q3, [x1, #(2*16)]
	stp	q4, q5, [x1, #(4*16)]
	stp	q6, q7, [x1, #(6*16)]
	stp	q8, q9, [x1, #(8*16)]
	stp	q10, q11, [x1, #(10*16)]
	stp	q12, q13, [x1, #(12*16)]
	stp	q14, q15, [x1, #(14*16)]
	stp	q16, q17, [x1, #(16*16)]
	stp	q18, q19, [x1, #(18*16)]
	stp	q20, q21, [x1, #(20*16)]
	stp	q22, q23, [x1, #(22*16)]
	stp	q24, q25, [x1, #(24*16)]
	stp	q26, q27, [x1, #(26*16)]
	stp	q28, q29, [x1, #(28*16)]
	stp	q30, q31, [x1, #(30*16)]
	mrs	x2, fpcr
	mrs	x3, fpsr
	add	x4, x1, #(32*16)
	stp	x2, x3, [x4]

	mov	x0, sp
	bl	trap

	/* restore FP context */
	add	x1, sp, #UREG_SIZE
	add	x4, x1, #(32*16)
	ldp	x2, x3, [x4]
	msr	fpcr, x2
	msr	fpsr, x3
	ldp	q0, q1, [x1, #(0*16)]
	ldp	q2, q3, [x1, #(2*16)]
	ldp	q4, q5, [x1, #(4*16)]
	ldp	q6, q7, [x1, #(6*16)]
	ldp	q8, q9, [x1, #(8*16)]
	ldp	q10, q11, [x1, #(10*16)]
	ldp	q12, q13, [x1, #(12*16)]
	ldp	q14, q15, [x1, #(14*16)]
	ldp	q16, q17, [x1, #(16*16)]
	ldp	q18, q19, [x1, #(18*16)]
	ldp	q20, q21, [x1, #(20*16)]
	ldp	q22, q23, [x1, #(22*16)]
	ldp	q24, q25, [x1, #(24*16)]
	ldp	q26, q27, [x1, #(26*16)]
	ldp	q28, q29, [x1, #(28*16)]
	ldp	q30, q31, [x1, #(30*16)]

	ldr	x1, [sp, #UREG_PC]
	msr	elr_el1, x1
	ldr	x1, [sp, #UREG_PSR]
	msr	spsr_el1, x1
	ldp	x2, x3, [sp, #(UREG_R0+2*8)]
	ldp	x4, x5, [sp, #(UREG_R0+4*8)]
	ldp	x6, x7, [sp, #(UREG_R0+6*8)]
	ldp	x8, x9, [sp, #(UREG_R0+8*8)]
	ldp	x10, x11, [sp, #(UREG_R0+10*8)]
	ldp	x12, x13, [sp, #(UREG_R0+12*8)]
	ldp	x14, x15, [sp, #(UREG_R0+14*8)]
	ldp	x16, x17, [sp, #(UREG_R0+16*8)]
	ldp	x18, x19, [sp, #(UREG_R0+18*8)]
	ldp	x20, x21, [sp, #(UREG_R0+20*8)]
	ldp	x22, x23, [sp, #(UREG_R0+22*8)]
	ldp	x24, x25, [sp, #(UREG_R0+24*8)]
	ldp	x26, x27, [sp, #(UREG_R0+26*8)]
	ldp	x28, x29, [sp, #(UREG_R0+28*8)]
	ldr	x30, [sp, #(UREG_R0+30*8)]
	ldp	x0, x1, [sp, #(UREG_R0+0*8)]
	add	sp, sp, #FRAME_SIZE
	eret

/*
 * int setlabel(Label*) — returns 0 now, 1 when gotolabel comes back.
 * Saves callee-saved state: sp, lr, x19-x29, d8-d15.
 */
	.globl setlabel
setlabel:
	mov	x1, sp
	str	x1, [x0, #LABEL_SP]
	str	x30, [x0, #LABEL_PC]
	stp	x19, x20, [x0, #(LABEL_REGS+0*8)]
	stp	x21, x22, [x0, #(LABEL_REGS+2*8)]
	stp	x23, x24, [x0, #(LABEL_REGS+4*8)]
	stp	x25, x26, [x0, #(LABEL_REGS+6*8)]
	stp	x27, x28, [x0, #(LABEL_REGS+8*8)]
	str	x29, [x0, #(LABEL_REGS+10*8)]
	stp	d8, d9, [x0, #(LABEL_FPREGS+0*8)]
	stp	d10, d11, [x0, #(LABEL_FPREGS+2*8)]
	stp	d12, d13, [x0, #(LABEL_FPREGS+4*8)]
	stp	d14, d15, [x0, #(LABEL_FPREGS+6*8)]
	mov	w0, #0
	ret

	.globl gotolabel
gotolabel:
	ldr	x1, [x0, #LABEL_SP]
	mov	sp, x1
	ldr	x30, [x0, #LABEL_PC]
	ldp	x19, x20, [x0, #(LABEL_REGS+0*8)]
	ldp	x21, x22, [x0, #(LABEL_REGS+2*8)]
	ldp	x23, x24, [x0, #(LABEL_REGS+4*8)]
	ldp	x25, x26, [x0, #(LABEL_REGS+6*8)]
	ldp	x27, x28, [x0, #(LABEL_REGS+8*8)]
	ldr	x29, [x0, #(LABEL_REGS+10*8)]
	ldp	d8, d9, [x0, #(LABEL_FPREGS+0*8)]
	ldp	d10, d11, [x0, #(LABEL_FPREGS+2*8)]
	ldp	d12, d13, [x0, #(LABEL_FPREGS+4*8)]
	ldp	d14, d15, [x0, #(LABEL_FPREGS+6*8)]
	mov	w0, #1
	ret

/*
 * interrupt priority: only the I bit matters to us.
 * splhi/spllo/splx return/accept the old DAIF value.
 */
	.globl splhi
splhi:
	mrs	x0, daif
	msr	daifset, #2
	ret

	.globl spllo
spllo:
	mrs	x0, daif
	msr	daifclr, #2
	ret

	.globl splx
splx:
	.globl splxpc
splxpc:
	tbnz	w0, #7, 1f
	msr	daifclr, #2
	ret
1:	msr	daifset, #2
	ret

	.globl islo
islo:
	mrs	x0, daif
	tst	x0, #DAIF_I
	cset	w0, eq
	ret

/*
 * ulong _tas(ulong*) — test and set, returns old value.
 */
	.globl _tas
_tas:
	mov	x2, #1
1:	ldxr	x1, [x0]
	stxr	w3, x2, [x0]
	cbnz	w3, 1b
	dmb	ish
	mov	x0, x1
	ret

/*
 * uvlong psci_call(ulong fid, uvlong a1, uvlong a2, uvlong a3)
 * qemu -M virt (no EL3) emulates PSCI firmware with the hvc conduit,
 * so an EL1 hvc lands in qemu, not in a hypervisor we don't have.
 * Used for VERSION/SYSTEM_RESET/SYSTEM_OFF; CPU_ON (0xC4000003) is the
 * SMP entry point if that day comes (see README "SMP").
 */
	.globl psci_call
psci_call:
	hvc	#0
	ret

/*
 * FP state for dis.c prog switches: void FPsave(FPenv*), void FPrestore(FPenv*).
 * The buffer is Osenv.fpu — struct FPenv{ulong status, control}, 16 BYTES.
 * Per-Dis-thread FP state is only fpsr/fpcr: live FP values sit in Dis
 * frames in memory at the r->xec(r) call boundary (q regs caller-saved),
 * and the trap stubs preserve q0-q31 across interrupts.  Saving the full
 * register file here once overflowed FPenv at the tail of Osenv and
 * scribbled the heap (stale free-tree parent corruption).
 */
	.globl FPsave
FPsave:
	mrs	x1, fpsr
	mrs	x2, fpcr
	str	x1, [x0, #0]	/* status */
	str	x2, [x0, #8]	/* control */
	ret

	.globl FPrestore
FPrestore:
	ldr	x1, [x0, #0]
	ldr	x2, [x0, #8]
	msr	fpsr, x1
	msr	fpcr, x2
	ret

/*
 * uintptr getcallerpc(void*) — return address of our caller.
 * (C code built with fns.h uses the __builtin macro; this covers
 * libinterp/libkern objects that only see the lib9 declaration.)
 */
	.globl getcallerpc
getcallerpc:
	mov	x0, x30
	ret

/*
 * FPCR/FPSR access for libmath/libinterp.
 */
	.globl getfcr
getfcr:
	mrs	x0, fpcr
	ret
	.globl setfcr
setfcr:
	msr	fpcr, x0
	ret
	.globl getfsr
getfsr:
	mrs	x0, fpsr
	ret
	.globl setfsr
setfsr:
	msr	fpsr, x0
	ret

/* generic timer access for clock.c */
	.globl rdcntvct
rdcntvct:
	isb
	mrs	x0, cntpct_el0
	ret
	.globl rdcntfrq
rdcntfrq:
	mrs	x0, cntfrq_el0
	ret
	.globl wrcntptval
wrcntptval:
	msr	cntp_tval_el0, x0
	ret
	.globl wrcntpctl
wrcntpctl:
	msr	cntp_ctl_el0, x0
	isb
	ret
