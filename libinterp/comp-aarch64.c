/*
 * Dis JIT compiler back-end for AArch64 (A64) — ILP64.
 *
 * Originally written as the LP64 dual-ABI back-end (Dis word 4 bytes, Dis
 * pointer 8); ported to ILP64, where a Dis word (Limbo int) == pointer == big
 * == real == 8 bytes.  The Ldw/Stw pseudo-ops therefore now emit 8-byte
 * X-register loads/stores (a Dis word is 64-bit); the only things still 4 bytes
 * are native C int struct fields (REG.IC, Modlink.compiled, Type.size,
 * String.len), addressed via the dedicated Ldi/Sti pseudo-ops.  Int arithmetic,
 * shifts, compares and conversions use the 64-bit (X-register) encoders.
 * See AGENTS_JIT.md and AGENTS_AARCH64.md.
 *
 * STATUS: passes the full headless tests/lp64 battery under -c1 (178/178).
 * KNOWN BUG: wm/Tk under -c1 corrupts a TkTop.ctxt (crashes in lockctxt) — a
 * heap-corrupting store somewhere in the Tk/draw startup path not covered by
 * the headless suite; the GUI is interpreter-only (-c0) until that is fixed.
 *
 * comp-arm.c is the structural reference.  Two things differ fundamentally on
 * A64: (1) the LP64 width split above, and (2) the PC is not a general
 * register, so every ARM "mov pc,reg / mov pc,lr / load-into-pc" becomes
 * BR/BLR/RET.
 *
 * Strategy: natively compile the hot integer + control path (data moves,
 * arithmetic, conversions, indexing, conditional branches, IJMP, and the
 * cross-module IMCALL) and PUNT the rest to the interpreter.  Punting is always
 * semantics-correct because the interpreter reads operands through R.s/R.d/R.m
 * (which punt sets up) and honours native PCs via the NEWPC path.  IRET, IFRAME,
 * IMFRAME, ICALL, IGOTO/ICASE/ICASEC table-bearing ops, allocation, list/string
 * ops and FP are punted (the jump-table ops first relocate their dst slots from
 * Dis PC to native address via comgoto/comcase/comcasel/comcasec).
 *
 * Native code freely clobbers the AAPCS64 callee-saved registers it claims
 * (RREG/RFP/RMP/RLR2); comvec saves them on entry and schedret() restores them
 * on every path back to xec (see schedret).  Backward branches emit an inline
 * reschedule check (schedcheck) so compiled loops yield to the scheduler.
 *
 * Activated only with `emu -c1` (cflag>0); default cflag==0 keeps every module
 * interpreted, so this back-end has no effect on default behaviour.  Runs the
 * full headless test battery under -c1, sh included.  KNOWN LIMITATION: the
 * $Loader reflection builtins (ifetch/newmod) cannot introspect a JIT-compiled
 * module, because compile() replaces m->prog (Dis bytecode) with the native
 * code buffer and frees the original — the same trade-off every Inferno JIT
 * back-end makes.
 *
 * NOTE: like the existing interpreter's compiled-module goto/case handling
 * (xec.c: R.PC = (Inst*)t[0], reading a WORD table slot), native code addresses
 * are stored truncated to 32 bits in the module's WORD jump tables.  The code
 * buffer must therefore be reachable in the low 32 bits of the address space.
 */
#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"

#include <stdint.h>

#define	RESCHED 1	/* check for interpreter reschedule on backward branches */

typedef uint32_t u32;
typedef uint64_t u64;

/*
 * JIT code must live in the low 2GB of the address space: the module's WORD
 * jump tables (IGOTO/ICASE/ICASEL) store native code addresses in 32-bit slots
 * and the interpreter reads them back sign-extended (xec.c: R.PC=(Inst*)t[0]).
 * Pool/heap allocations land at ~0xaaaa........ (well above 4GB) on Linux, so we
 * carve code buffers out of a low, executable mmap arena instead.  (libc ABI
 * declarations; avoids dragging system headers into the interp build.)
 */
extern void*	mmap(void*, unsigned long, int, int, int, long);
extern int	munmap(void*, unsigned long);
#define	PROT_READ	0x1
#define	PROT_WRITE	0x2
#define	PROT_EXEC	0x4
#define	MAP_PRIVATE	0x2
#define	MAP_ANONYMOUS	0x20
#define	MAP_FAILED	((void*)-1)
#define	JITLOWHINT	((void*)0x20000000UL)
#define	JITLOWLIMIT	0x80000000UL		/* keep code below 2GB */

static uchar*	jitarena;
extern uchar*	jitlo;		/* native-code bounds, used by xec() dispatch */
extern uchar*	jithi;

static void*
jitcode(ulong n)
{
	void *p;
	ulong sz;

	n = (n + 15) & ~15UL;
	if(jitarena == nil || jitarena + n > jithi) {
		sz = 64*1024*1024;
		if(n > sz)
			sz = (n + 0xFFF) & ~0xFFFUL;
		p = mmap(JITLOWHINT, sz, PROT_READ|PROT_WRITE|PROT_EXEC,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
		if(p == MAP_FAILED)
			return nil;
		if((uintptr_t)p + sz > JITLOWLIMIT) {	/* landed too high */
			munmap(p, sz);
			return nil;
		}
		jitarena = p;
		jitlo = p;			/* first arena: record low bound */
		jithi = (uchar*)p + sz;
	}
	p = jitarena;
	jitarena += n;
	return p;
}

enum
{
	/* general registers (X/W) */
	RA0	= 0,		/* scratch / C arg+return */
	RA1	= 1,
	RA2	= 2,
	RA3	= 3,
	RCON	= 4,		/* constant / address builder */
	RTA	= 5,		/* indirect-addressing temp */
	RIP	= 16,		/* x16: branch-through-register temp (IP0) */
	RREG	= 19,		/* &R (callee-saved) */
	RFP	= 20,		/* Dis frame pointer (callee-saved) */
	RMP	= 21,		/* Dis module pointer (callee-saved) */
	RLR2	= 24,		/* callee-saved link save inside macros (survives C calls) */
	RLINK	= 30,		/* link register */
	ZR	= 31,

	/*
	 * FP scratch (SIMD&FP register file, d0..d2).  Generated code never
	 * holds a live FP value across a C call or reschedule, so these need no
	 * save/restore (FPsave/FPrestore are unnecessary for the partial JIT).
	 * Distinct register file: DF0==d0 does not alias RA0==x0.
	 */
	DF0	= 0,
	DF1	= 1,
	DF2	= 2,

	/* condition codes (A64) */
	EQ=0, NE=1, CS=2, CC=3, MI=4, PL=5, VS=6, VC=7,
	HI=8, LS=9, GE=10, LT=11, GT=12, LE=13, AL=14, NV=15,
	HS=CS, LO=CC,

	/* mem() pseudo-ops */
	Lea = 1,		/* compute address rm+disp */
	Ldw, Stw,		/* 8-byte word/int (ILP64: a Dis word is 64-bit) */
	Ldp, Stp,		/* 8-byte pointer/big/real */
	Ldb, Stb,		/* 1-byte */
	Ldf, Stf,		/* 8-byte double, in/out of an FP (d) register */
	Ldi, Sti,		/* 4-byte native C int (REG.IC, Modlink.compiled,
				 * Type.size, String.len) - still 32-bit under ILP64 */

	/* punt operand flags */
	SRCOP	= (1<<0),
	DSTOP	= (1<<1),
	WRTPC	= (1<<2),
	TCHECK	= (1<<3),
	NEWPC	= (1<<4),
	DBRAN	= (1<<5),
	THREOP	= (1<<6),
};

#define T(r)	*((void**)(R.r))

static	u32*	code;
static	u32*	base;
static	ulong*	patch;		/* patch[disidx] = native instruction offset */
static	int	pass;
static	Module*	mod;
static	u32*	litpool;
static	int	nlit;
	void	(*comvec)(void);

extern	void	das(ulong*, int);

/* per-module macro routines, generated once into each module's code buffer */
enum { MacMCAL = 0, MacRELQ, NMACRO };
static	u32	macro[NMACRO];
static	void	macmcal(void);
static	void	macrelq(void);
static	struct { int idx; void (*gen)(void); char *name; } mactab[] = {
	{ MacMCAL, macmcal, "MCAL" },
	{ MacRELQ, macrelq, "RELQ" },
};

/*
 * Helper called from generated code for the runt (builtin C module) IMCALL
 * path.  Crucially this does NOT set R.M to the callee: R.M stays the compiled
 * caller throughout the builtin call, so if the builtin yields (isave/irestore)
 * the saved R.M/R.PC pair is consistent (caller module, caller native PC).
 * The runt function pointer is passed in R.d (8 bytes; R.dt is only 4 on LP64).
 */
static void
rmcall(void)
{
	Frame *f;
	Prog *p;

	if(R.d == H)
		error(exModule);
	f = (Frame*)R.FP;
	if(f == H)
		error(exModule);
	f->mr = nil;
	((void(*)(Frame*))R.d)(f);
	R.SP = (uchar*)f;
	R.FP = f->fp;
	if(f->t == nil)
		unextend(f);
	else if(f->t->np)
		freeptrs(f, f->t);
	p = currun();
	if(p->kill != nil)
		error(p->kill);
}

/* ---------------------------------------------------------------------- *
 *  Verified A64 instruction encoders (validated bit-exact vs objdump).
 * ---------------------------------------------------------------------- */
static u32 movz(int rd,u32 imm,int sh){ return 0xD2800000u|((u32)(sh/16)<<21)|((imm&0xFFFF)<<5)|(rd&31); }
static u32 movk(int rd,u32 imm,int sh){ return 0xF2800000u|((u32)(sh/16)<<21)|((imm&0xFFFF)<<5)|(rd&31); }

static u32 addix(int rd,int rn,u32 i12){ return 0x91000000u|((i12&0xFFF)<<10)|((rn&31)<<5)|(rd&31); }
static u32 subix(int rd,int rn,u32 i12){ return 0xD1000000u|((i12&0xFFF)<<10)|((rn&31)<<5)|(rd&31); }
static u32 addiw(int rd,int rn,u32 i12){ return 0x11000000u|((i12&0xFFF)<<10)|((rn&31)<<5)|(rd&31); }
static u32 subsiw(int rd,int rn,u32 i12){ return 0x71000000u|((i12&0xFFF)<<10)|((rn&31)<<5)|(rd&31); }
static u32 cmpiw(int rn,u32 i12){ return subsiw(ZR,rn,i12); }
static u32 cmnix(int rn){ return 0xB100041Fu|((rn&31)<<5); }	/* adds xzr,xn,#1  (is-H test) */

static u32 addx(int rd,int rn,int rm){ return 0x8B000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 subx(int rd,int rn,int rm){ return 0xCB000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 addw(int rd,int rn,int rm){ return 0x0B000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 subw(int rd,int rn,int rm){ return 0x4B000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 subsw(int rd,int rn,int rm){ return 0x6B000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 cmpw(int rn,int rm){ return subsw(ZR,rn,rm); }
static u32 cmpx(int rn,int rm){ return 0xEB00001Fu|((rm&31)<<16)|((rn&31)<<5); }
static u32 addxsh(int rd,int rn,int rm,int s){ return 0x8B000000u|((rm&31)<<16)|((s&63)<<10)|((rn&31)<<5)|(rd&31); }

static u32 andw(int rd,int rn,int rm){ return 0x0A000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 orrw(int rd,int rn,int rm){ return 0x2A000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 eorw(int rd,int rn,int rm){ return 0x4A000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 andx(int rd,int rn,int rm){ return 0x8A000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 orrx(int rd,int rn,int rm){ return 0xAA000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 eorx(int rd,int rn,int rm){ return 0xCA000000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 movrx(int rd,int rm){ return orrx(rd,ZR,rm); }

static u32 mulw(int rd,int rn,int rm){ return 0x1B007C00u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 mulx(int rd,int rn,int rm){ return 0x9B007C00u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }

static u32 lslvw(int rd,int rn,int rm){ return 0x1AC02000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 lsrvw(int rd,int rn,int rm){ return 0x1AC02400u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 asrvw(int rd,int rn,int rm){ return 0x1AC02800u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 lslvx(int rd,int rn,int rm){ return 0x9AC02000u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 lsrvx(int rd,int rn,int rm){ return 0x9AC02400u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 asrvx(int rd,int rn,int rm){ return 0x9AC02800u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 sxtw(int rd,int rn){ return 0x93407C00u|((rn&31)<<5)|(rd&31); }

static u32 ldrx(int rt,int rn,u32 off){ return 0xF9400000u|(((off>>3)&0xFFF)<<10)|((rn&31)<<5)|(rt&31); }
static u32 strx(int rt,int rn,u32 off){ return 0xF9000000u|(((off>>3)&0xFFF)<<10)|((rn&31)<<5)|(rt&31); }
static u32 ldrw(int rt,int rn,u32 off){ return 0xB9400000u|(((off>>2)&0xFFF)<<10)|((rn&31)<<5)|(rt&31); }
static u32 strw(int rt,int rn,u32 off){ return 0xB9000000u|(((off>>2)&0xFFF)<<10)|((rn&31)<<5)|(rt&31); }
static u32 ldrb(int rt,int rn,u32 off){ return 0x39400000u|((off&0xFFF)<<10)|((rn&31)<<5)|(rt&31); }
static u32 strb(int rt,int rn,u32 off){ return 0x39000000u|((off&0xFFF)<<10)|((rn&31)<<5)|(rt&31); }

static u32 ldurx(int rt,int rn,int off){ return 0xF8400000u|(((u32)off&0x1FF)<<12)|((rn&31)<<5)|(rt&31); }
static u32 sturx(int rt,int rn,int off){ return 0xF8000000u|(((u32)off&0x1FF)<<12)|((rn&31)<<5)|(rt&31); }
static u32 ldurw(int rt,int rn,int off){ return 0xB8400000u|(((u32)off&0x1FF)<<12)|((rn&31)<<5)|(rt&31); }
static u32 sturw(int rt,int rn,int off){ return 0xB8000000u|(((u32)off&0x1FF)<<12)|((rn&31)<<5)|(rt&31); }

static u32 ldrx_r(int rt,int rn,int rm){ return 0xF8606800u|((rm&31)<<16)|((rn&31)<<5)|(rt&31); }
static u32 strx_r(int rt,int rn,int rm){ return 0xF8206800u|((rm&31)<<16)|((rn&31)<<5)|(rt&31); }
static u32 ldrw_r(int rt,int rn,int rm){ return 0xB8606800u|((rm&31)<<16)|((rn&31)<<5)|(rt&31); }
static u32 strw_r(int rt,int rn,int rm){ return 0xB8206800u|((rm&31)<<16)|((rn&31)<<5)|(rt&31); }
static u32 ldrb_r(int rt,int rn,int rm){ return 0x38606800u|((rm&31)<<16)|((rn&31)<<5)|(rt&31); }
static u32 strb_r(int rt,int rn,int rm){ return 0x38206800u|((rm&31)<<16)|((rn&31)<<5)|(rt&31); }

/*
 * Scalar double FP (SIMD&FP register file).  Every encoding below was
 * validated bit-exact against aarch64-linux-gnu-objdump before use; do not
 * edit by eye (the abandoned jit-wip used single-precision bases and mislaid
 * register fields).  Rd[4:0], Rn[9:5], Rm[20:16].
 */
static u32 faddd(int rd,int rn,int rm){ return 0x1E602800u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 fsubd(int rd,int rn,int rm){ return 0x1E603800u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 fmuld(int rd,int rn,int rm){ return 0x1E600800u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 fdivd(int rd,int rn,int rm){ return 0x1E601800u|((rm&31)<<16)|((rn&31)<<5)|(rd&31); }
static u32 fnegd(int rd,int rn){ return 0x1E614000u|((rn&31)<<5)|(rd&31); }
static u32 fcmpd(int rn,int rm){ return 0x1E602000u|((rm&31)<<16)|((rn&31)<<5); }	/* fcmp dn,dm */
static u32 fcmpz(int rn){ return 0x1E602008u|((rn&31)<<5); }				/* fcmp dn,#0.0 */
static u32 fcsel(int rd,int rn,int rm,int cc){ return 0x1E600C00u|((rm&31)<<16)|((cc&15)<<12)|((rn&31)<<5)|(rd&31); }
static u32 fmovihalf(int rd){ return 0x1E6C1000u|(rd&31); }	/* fmov dd,#0.5  */
static u32 fmovinhalf(int rd){ return 0x1E7C1000u|(rd&31); }	/* fmov dd,#-0.5 */
static u32 scvtfwd(int rd,int rn){ return 0x1E620000u|((rn&31)<<5)|(rd&31); }	/* s32 -> double */
static u32 scvtfxd(int rd,int rn){ return 0x9E620000u|((rn&31)<<5)|(rd&31); }	/* s64 -> double */
static u32 fcvtzsdw(int rd,int rn){ return 0x1E780000u|((rn&31)<<5)|(rd&31); }	/* double -> s32, trunc */
static u32 fcvtzsdx(int rd,int rn){ return 0x9E780000u|((rn&31)<<5)|(rd&31); }	/* double -> s64, trunc */
static u32 ldrd(int rt,int rn,u32 off){ return 0xFD400000u|(((off>>3)&0xFFF)<<10)|((rn&31)<<5)|(rt&31); }
static u32 strd(int rt,int rn,u32 off){ return 0xFD000000u|(((off>>3)&0xFFF)<<10)|((rn&31)<<5)|(rt&31); }
static u32 ldurd(int rt,int rn,int off){ return 0xFC400000u|(((u32)off&0x1FF)<<12)|((rn&31)<<5)|(rt&31); }
static u32 sturd(int rt,int rn,int off){ return 0xFC000000u|(((u32)off&0x1FF)<<12)|((rn&31)<<5)|(rt&31); }
static u32 ldrd_r(int rt,int rn,int rm){ return 0xFC606800u|((rm&31)<<16)|((rn&31)<<5)|(rt&31); }
static u32 strd_r(int rt,int rn,int rm){ return 0xFC206800u|((rm&31)<<16)|((rn&31)<<5)|(rt&31); }

/* load/store pair, 64-bit (for saving callee-saved regs across the C boundary) */
static u32 stppre(int t1,int t2,int rn,int imm){ return 0xA9800000u|(((u32)(imm/8)&0x7f)<<15)|((t2&31)<<10)|((rn&31)<<5)|(t1&31); }
static u32 stpoff(int t1,int t2,int rn,int imm){ return 0xA9000000u|(((u32)(imm/8)&0x7f)<<15)|((t2&31)<<10)|((rn&31)<<5)|(t1&31); }
static u32 ldpoff(int t1,int t2,int rn,int imm){ return 0xA9400000u|(((u32)(imm/8)&0x7f)<<15)|((t2&31)<<10)|((rn&31)<<5)|(t1&31); }
static u32 ldppost(int t1,int t2,int rn,int imm){ return 0xA8C00000u|(((u32)(imm/8)&0x7f)<<15)|((t2&31)<<10)|((rn&31)<<5)|(t1&31); }

static u32 b_(int off){ return 0x14000000u|(((u32)(off>>2))&0x3FFFFFF); }
static u32 bcond(int cc,int off){ return 0x54000000u|((((u32)(off>>2))&0x7FFFF)<<5)|(cc&15); }
static u32 br_(int rn){ return 0xD61F0000u|((rn&31)<<5); }
static u32 blr_(int rn){ return 0xD63F0000u|((rn&31)<<5); }
static u32 ret_(int rn){ return 0xD65F0000u|((rn&31)<<5); }

/* ---------------------------------------------------------------------- */

static void
urk(char *s)
{
	USED(s);
	error(exCompile);
}

static void
gen(u32 w)
{
	*code++ = w;
}

/* load a full 64-bit constant: fixed 4-instruction sequence (pass-stable). */
static void
con(u64 o, int r)
{
	gen(movz(r, o & 0xFFFF, 0));
	gen(movk(r, (o>>16) & 0xFFFF, 16));
	gen(movk(r, (o>>32) & 0xFFFF, 32));
	gen(movk(r, (o>>48) & 0xFFFF, 48));
}

#define RELPC(pc)	((u64)(base + (pc)))

/* patch a previously-emitted forward branch/b.cond at loc to target `code`. */
static void
patchbra(u32 *loc)
{
	u32 ins = *loc;
	int rel = (int)((char*)code - (char*)loc);

	if((ins & 0xFF000000u) == 0x54000000u)		/* b.cond: imm19 at [23:5] */
		*loc = (ins & 0xFF00001Fu) | ((((u32)(rel>>2)) & 0x7FFFF) << 5);
	else						/* b / bl: imm26 */
		*loc = (ins & 0xFC000000u) | (((u32)(rel>>2)) & 0x3FFFFFF);
}

/* emit a single load/store/lea of the given width. */
static void
emitmem(int inst, long disp, int rm, int r)
{
	switch(inst) {
	case Lea:
		if(disp == 0) {
			if(rm != r)
				gen(addix(r, rm, 0));
			return;
		}
		if(disp > 0 && disp < 4096) { gen(addix(r, rm, disp)); return; }
		if(disp < 0 && -disp < 4096) { gen(subix(r, rm, -disp)); return; }
		con(disp, RCON); gen(addx(r, rm, RCON));
		return;
	case Ldw: case Stw:		/* ILP64: a Dis word is 8 bytes -> X-register */
		if(disp >= 0 && (disp&7)==0 && (disp>>3) < 4096) {
			gen(inst==Ldw ? ldrx(r,rm,disp) : strx(r,rm,disp)); return;
		}
		if(disp >= -256 && disp < 256) {
			gen(inst==Ldw ? ldurx(r,rm,disp) : sturx(r,rm,disp)); return;
		}
		con(disp, RCON);
		gen(inst==Ldw ? ldrx_r(r,rm,RCON) : strx_r(r,rm,RCON));
		return;
	case Ldi: case Sti:		/* native C int: 4 bytes */
		if(disp >= 0 && (disp&3)==0 && (disp>>2) < 4096) {
			gen(inst==Ldi ? ldrw(r,rm,disp) : strw(r,rm,disp)); return;
		}
		if(disp >= -256 && disp < 256) {
			gen(inst==Ldi ? ldurw(r,rm,disp) : sturw(r,rm,disp)); return;
		}
		con(disp, RCON);
		gen(inst==Ldi ? ldrw_r(r,rm,RCON) : strw_r(r,rm,RCON));
		return;
	case Ldp: case Stp:
		if(disp >= 0 && (disp&7)==0 && (disp>>3) < 4096) {
			gen(inst==Ldp ? ldrx(r,rm,disp) : strx(r,rm,disp)); return;
		}
		if(disp >= -256 && disp < 256) {
			gen(inst==Ldp ? ldurx(r,rm,disp) : sturx(r,rm,disp)); return;
		}
		con(disp, RCON);
		gen(inst==Ldp ? ldrx_r(r,rm,RCON) : strx_r(r,rm,RCON));
		return;
	case Ldb: case Stb:
		if(disp >= 0 && disp < 4096) {
			gen(inst==Ldb ? ldrb(r,rm,disp) : strb(r,rm,disp)); return;
		}
		con(disp, RCON);
		gen(inst==Ldb ? ldrb_r(r,rm,RCON) : strb_r(r,rm,RCON));
		return;
	case Ldf: case Stf:		/* r is an FP (d) register */
		if(disp >= 0 && (disp&7)==0 && (disp>>3) < 4096) {
			gen(inst==Ldf ? ldrd(r,rm,disp) : strd(r,rm,disp)); return;
		}
		if(disp >= -256 && disp < 256) {
			gen(inst==Ldf ? ldurd(r,rm,disp) : sturd(r,rm,disp)); return;
		}
		con(disp, RCON);
		gen(inst==Ldf ? ldrd_r(r,rm,RCON) : strd_r(r,rm,RCON));
		return;
	}
}

static void
mem(int inst, long disp, int rm, int r)
{
	emitmem(inst, disp, rm, r);
}

/* conditional single-instruction mem: emulate via a skip branch. */
static void
memc(int cc, int inst, long disp, int rm, int r)
{
	u32 *cp;

	if(cc == AL) { emitmem(inst, disp, rm, r); return; }
	cp = code;
	gen(0);				/* placeholder b.cond(!cc) */
	emitmem(inst, disp, rm, r);
	*cp = bcond(cc^1, (int)((char*)code - (char*)cp));
}

/*
 * Address an operand with mode `mode` and addressing `a`, performing pseudo-op
 * `mi` into register `r`.  `li` is the REG word slot used to materialise an
 * immediate operand's address (REG.st / REG.dt).
 */
static void
opx(int mode, Adr *a, int mi, int r, int li)
{
	int ir, rta;

	switch(mode) {
	default:
		urk("opx");
	case AFP:
		mem(mi, a->ind, RFP, r);
		return;
	case AMP:
		mem(mi, a->ind, RMP, r);
		return;
	case AIMM:
		con((u64)(WORD)a->imm, r);		/* sign-extended word immediate */
		if(mi == Lea) {
			mem(Stw, li, RREG, r);		/* REG.st/dt is int (4 bytes) */
			mem(Lea, li, RREG, r);
		}
		return;
	case AIND|AFP:
		ir = RFP;
		break;
	case AIND|AMP:
		ir = RMP;
		break;
	}
	rta = RTA;
	if(mi == Lea)
		rta = r;
	mem(Ldp, a->i.f, ir, rta);		/* indirection: load 8-byte pointer */
	mem(mi, a->i.s, rta, r);
}

static void
opwld(Inst *i, int mi, int r)
{
	opx(USRC(i->add), &i->s, mi, r, O(REG, st));
}

static void
opwst(Inst *i, int mi, int r)
{
	opx(UDST(i->add), &i->d, mi, r, O(REG, dt));
}

/* middle operand */
static void
mid(Inst *i, int mi, int r)
{
	int ir;

	switch(i->add & ARM) {
	default:
		opwst(i, mi, r);
		return;
	case AXIMM:
		if(mi == Lea)
			urk("mid/lea");
		con((u64)(WORD)(short)i->reg, r);
		return;
	case AXINF:
		ir = RFP;
		break;
	case AXINM:
		ir = RMP;
		break;
	}
	mem(mi, i->reg, ir, r);
}

/* store an immediate (or native address) into a litpool slot, point REG.roff at it. */
static void
literal(u64 imm, int roff)
{
	nlit++;
	con((u64)litpool, RTA);
	mem(Stp, roff, RREG, RTA);		/* REG.s/d/m are pointers (8 bytes) */
	if(pass == 0)
		return;
	*(u64*)litpool = imm;
	litpool += 2;				/* 8-byte slots */
}

/* ---------------------------------------------------------------------- *
 *  Branch / call helpers.
 * ---------------------------------------------------------------------- */

/* branch (cc, or AL) to the native code for Dis instruction index `diss` */
static void
bradis(int cc, long diss)
{
	u32 *t = base + patch[diss];
	int rel = (int)((char*)t - (char*)code);
	gen(cc==AL ? b_(rel) : bcond(cc, rel));
}

/* call a C function at absolute address fn (out of BL range): blr through x16 */
static void
ccall(void (*fn)(void))
{
	con((u64)fn, RIP);
	gen(blr_(RIP));
}

/* branch-and-link to a per-module macro routine (within the code buffer) */
static void
callmac(int cc, int idx)
{
	u32 *t = base + macro[idx];
	if(cc != AL) {
		gen(bcond(cc^1, 8));		/* skip the bl if !cc */
		t = base + macro[idx];
	}
	gen(0x94000000u | (((u32)(((char*)t - (char*)code) >> 2)) & 0x3FFFFFF));	/* bl t */
}

/*
 * Emit the return-to-scheduler tail.  comvec's prologue saved the AAPCS64
 * callee-saved registers the JIT clobbers (RREG/RFP/RMP/RLR2 = x19/x20/x21/x24)
 * on the C stack; every path that leaves native code back to comvec's C caller
 * (xec) must restore them, otherwise xec (and its callers) see corrupted
 * callee-saved registers — e.g. xec's `p` argument, held in a callee-saved
 * register, becomes garbage and the wrong Prog's state is saved.  R.xpc holds
 * comvec's real return address.  Native code never moves SP, so SP here equals
 * comvec's post-prologue SP and the saved-register frame is at a fixed offset.
 */
static void
schedret(void)
{
	mem(Ldp, O(REG, xpc), RREG, RLINK);	/* RLINK = comvec's return addr (RREG still &R) */
	gen(ldpoff(RMP, RLR2, 31, 16));		/* restore x21, x24 */
	gen(ldppost(RREG, RFP, 31, 32));	/* restore x19, x20; pop frame */
	gen(ret_(RLINK));
}

static void
bounds(void)
{
	error(exBounds);
}

static void
nullity(void)
{
	error(exNilref);
}

/* call helper `fn` if condition cc holds (fn never returns) */
static void
trapif(int cc, void (*fn)(void))
{
	u32 *cp = code;
	gen(0);					/* b.cond(!cc) over the call */
	ccall(fn);
	*cp = bcond(cc^1, (int)((char*)code - (char*)cp));
}

/* nil check: if r == H, raise exNilref */
static void
notnil(int r)
{
	gen(cmnix(r));				/* EQ if r == H((void*)-1) */
	trapif(EQ, nullity);
}

/* ---------------------------------------------------------------------- *
 *  Reschedule check on backward branches.
 * ---------------------------------------------------------------------- */
static void
schedcheck(Inst *i)
{
	if(!RESCHED || i->d.ins > i)		/* only backward branches */
		return;
	mem(Ldi, O(REG, IC), RREG, RA0);	/* REG.IC is a C int (4 bytes) */
	gen(subsiw(RA0, RA0, 1));		/* --IC, set flags */
	mem(Sti, O(REG, IC), RREG, RA0);
	callmac(LE, MacRELQ);			/* if IC<=0, reschedule (resumes past here) */
}

/*
 * Reschedule: save FP and the post-schedcheck return PC (in RLINK, set by the
 * bl from callmac), then return to the scheduler via R.xpc.  On resume the
 * proc re-enters at RLINK (the compare), not the schedcheck, so it makes
 * forward progress even when the scheduler hands back a single-instruction
 * quantum (irestore sets R.IC=1).
 */
static void
macrelq(void)
{
	mem(Stp, O(REG, FP), RREG, RFP);
	mem(Stp, O(REG, PC), RREG, RLINK);	/* R.PC = caller's post-schedcheck addr */
	schedret();
}

/* ---------------------------------------------------------------------- *
 *  Punt: fall back to the interpreter for instruction i.
 * ---------------------------------------------------------------------- */
static void
punt(Inst *i, int m, void (*fn)(void))
{
	ulong pc;
	u32 *cp;

	if(m & SRCOP) {
		if(UXSRC(i->add) == SRC(AIMM))
			literal((u64)(WORD)i->s.imm, O(REG, s));
		else {
			opwld(i, Lea, RA0);
			mem(Stp, O(REG, s), RREG, RA0);
		}
	}
	if(m & DSTOP) {
		opwst(i, Lea, RA0);
		mem(Stp, O(REG, d), RREG, RA0);
	}
	if(m & WRTPC) {
		con(RELPC(patch[i - mod->prog + 1]), RA0);
		mem(Stp, O(REG, PC), RREG, RA0);
	}
	if(m & DBRAN) {
		pc = patch[i->d.ins - mod->prog];
		literal(RELPC(pc), O(REG, d));
	}

	switch(i->add & ARM) {
	case AXNON:
		if(m & THREOP) {
			mem(Ldp, O(REG, d), RREG, RA0);
			mem(Stp, O(REG, m), RREG, RA0);
		}
		break;
	case AXIMM:
		literal((u64)(WORD)(short)i->reg, O(REG, m));
		break;
	case AXINF:
		mem(Lea, i->reg, RFP, RA2);
		mem(Stp, O(REG, m), RREG, RA2);
		break;
	case AXINM:
		mem(Lea, i->reg, RMP, RA2);
		mem(Stp, O(REG, m), RREG, RA2);
		break;
	}
	mem(Stp, O(REG, FP), RREG, RFP);

	ccall(fn);

	con((u64)&R, RREG);
	if(m & TCHECK) {
		/* if(R.t) { x30 = R.xpc; return to scheduler } */
		mem(Ldw, O(REG, t), RREG, RA0);
		gen(cmpiw(RA0, 0));
		cp = code;
		gen(bcond(EQ, 0));			/* R.t == 0 ? skip */
		schedret();
		patchbra(cp);
	}
	mem(Ldp, O(REG, FP), RREG, RFP);
	mem(Ldp, O(REG, MP), RREG, RMP);
	if(m & NEWPC) {
		mem(Ldp, O(REG, PC), RREG, RIP);
		gen(br_(RIP));
	}
}

/* ---------------------------------------------------------------------- *
 *  Conditional branches (native).  cmp s,m then branch on natural condition.
 * ---------------------------------------------------------------------- */
static void
cbra(Inst *i, int cc)
{
	schedcheck(i);
	opwld(i, Ldw, RA0);		/* s (8 bytes) */
	mid(i, Ldw, RA1);		/* m (8 bytes) */
	gen(cmpx(RA0, RA1));		/* s - m (64-bit) */
	bradis(cc, i->d.ins - mod->prog);
}

static void
cbrab(Inst *i, int cc)
{
	schedcheck(i);
	opwld(i, Ldb, RA0);
	mid(i, Ldb, RA1);
	gen(cmpw(RA0, RA1));
	bradis(cc, i->d.ins - mod->prog);
}

static void
cbral(Inst *i, int cc)
{
	schedcheck(i);
	opwld(i, Ldp, RA0);		/* 8-byte big */
	mid(i, Ldp, RA1);
	gen(cmpx(RA0, RA1));
	bradis(cc, i->d.ins - mod->prog);
}

/* ---------------------------------------------------------------------- *
 *  Jump-table patching for punted IGOTO / ICASE / ICASEL.
 *  Stored native addresses are truncated to 32 bits in the WORD tables,
 *  matching the interpreter's compiled-module table reads in xec.c.
 * ---------------------------------------------------------------------- */
static void
comgoto(Inst *i)
{
	WORD *t, *e;

	if(pass == 0)
		return;
	t = (WORD*)(mod->origmp + i->d.ind);
	e = t + t[-1];
	t[-1] = 0;
	while(t < e) {
		t[0] = (WORD)RELPC(patch[t[0]]);
		t++;
	}
}

static void
comcase(Inst *i)
{
	int l;
	WORD *t, *e;

	t = (WORD*)(mod->origmp + i->d.ind + IBY2WD);
	l = t[-1];
	if(pass == 0) {
		if(l >= 0)
			t[-1] = -l-1;			/* mark not done */
		return;
	}
	if(l >= 0)
		return;
	t[-1] = -l-1;					/* restore count */
	e = t + t[-1]*3;
	while(t < e) {
		t[2] = (WORD)RELPC(patch[t[2]]);
		t += 3;
	}
	t[0] = (WORD)RELPC(patch[t[0]]);		/* default */
}

static void
comcasel(Inst *i)
{
	int l;
	WORD *t, *e;

	t = (WORD*)(mod->origmp + i->d.ind + 2*IBY2WD);
	l = t[-2];
	if(pass == 0) {
		if(l >= 0)
			t[-2] = -l-1;
		return;
	}
	if(l >= 0)
		return;
	t[-2] = -l-1;
	e = t + t[-2]*6;
	while(t < e) {
		t[4] = (WORD)RELPC(patch[t[4]]);
		t += 6;
	}
	t[0] = (WORD)RELPC(patch[t[0]]);
}

/*
 * String case (ICASEC).  ILP64 table layout (see xec.c OP(casec)):
 *   [count : IBY2PTR slot][entry: String* low; String* high; WORD dst]*[wild dst]
 * Each entry is sizeof(struct{String*,String*,WORD}) = 3*IBY2PTR = 24 bytes
 * (3 WORDs under ILP64), with the dst WORD at byte offset 2*IBY2PTR (word 2).
 * Compiled modules need
 * the dst slots relocated from Dis PC to native code address (read back via
 * R.PC = (Inst*)*dest), so this must run like comcase/comcasel — without it the
 * interpreter's casec jumps to raw Dis offsets and the program wanders off (the
 * sh command dispatcher is built entirely on string case).
 */
static void
comcasec(Inst *i)
{
	int n;
	WORD *cnt, *t, *e;

	cnt = (WORD*)(mod->origmp + i->d.ind);
	n = *cnt;
	if(pass == 0) {
		if(n >= 0)
			*cnt = -n-1;			/* mark not done */
		return;
	}
	if(n >= 0)
		return;
	n = -n-1;
	*cnt = n;					/* restore count */
	t = (WORD*)(mod->origmp + i->d.ind + IBY2PTR);	/* entries: {String* l, h; WORD dst} */
	e = t + n*3;					/* ILP64: 3 WORDs/entry (24 bytes) */
	while(t < e) {
		t[2] = (WORD)RELPC(patch[t[2]]);	/* dst at word 2 (byte 2*IBY2PTR==16) */
		t += 3;
	}
	t[0] = (WORD)RELPC(patch[t[0]]);		/* wild dest */
}

/* ---------------------------------------------------------------------- *
 *  Native cross-module call (IMCALL): commcall sets up the frame and tail-
 *  calls macmcal, which dispatches the runt / compiled-prog / interp-prog
 *  cases.  Unlike the punt path, the runt case keeps R.M = caller, so a
 *  builtin that yields (isave/irestore) saves a consistent R.M/R.PC pair.
 * ---------------------------------------------------------------------- */
static void
commcall(Inst *i)
{
	u32 *mlnil;

	opwld(i, Ldp, RA2);				/* frame f = T(s) */
	con(RELPC(patch[i - mod->prog + 1]), RA0);	/* native return address */
	mem(Stp, O(Frame, lr), RA2, RA0);
	mem(Stp, O(REG, PC), RREG, RA0);		/* R.PC = return addr: valid resume point
							 * if a runt builtin yields (isave/irestore),
							 * mirroring the interpreter advancing R.PC
							 * before invoking the builtin. */
	mem(Stp, O(Frame, fp), RA2, RFP);
	mem(Ldp, O(REG, M), RREG, RA3);
	mem(Stp, O(Frame, mr), RA2, RA3);		/* f->mr = caller */
	opwst(i, Ldp, RA3);				/* RA3 = callee modlink ml */
	gen(cmnix(RA3));				/* ml == H ? */
	mlnil = code;
	gen(bcond(EQ, 0));
	if((i->add & ARM) == AXIMM) {
		mem(Ldp, OA(Modlink, links) + i->reg*sizeof(Modl) + O(Modl, u.pc), RA3, RA0);
	} else {
		mid(i, Ldw, RA1);
		gen(addxsh(RA1, RA3, RA1, 4));		/* RA1 = ml + idx*sizeof(Modl)(16) */
		mem(Ldp, OA(Modlink, links) + O(Modl, u.pc), RA1, RA0);
	}
	patchbra(mlnil);
	callmac(AL, MacMCAL);
}

static void
macmcal(void)
{
	u32 *torunt, *toprog, *cp;

	/* RA3 = ml, RA0 = links[o].u.pc (runt fn / native pc / dis pc), RA2 = f */
	gen(cmnix(RA0));				/* RA0 == H ? */
	torunt = code;
	gen(bcond(EQ, 0));
	mem(Ldp, O(Modlink, prog), RA3, RA1);
	gen(cmpx(RA1, ZR));				/* ml->prog == 0 ? */
	toprog = code;
	gen(bcond(NE, 0));				/* prog != 0 -> compiled/interp prog */

	patchbra(torunt);
	/* runt (builtin C module): keep R.M = caller; call rmcall(R.d=fn) */
	gen(movrx(RLR2, RLINK));			/* save macro return across C call */
	mem(Stp, O(REG, FP), RREG, RA2);		/* R.FP = f */
	mem(Stp, O(REG, d), RREG, RA0);			/* R.d = runt fn pointer (8 bytes) */
	ccall(rmcall);
	con((u64)&R, RREG);
	gen(movrx(RLINK, RLR2));
	mem(Ldp, O(REG, FP), RREG, RFP);
	mem(Ldp, O(REG, MP), RREG, RMP);
	gen(ret_(RLINK));				/* back to commcall -> next instr */

	patchbra(toprog);
	gen(movrx(RFP, RA2));				/* R.FP register = f */
	mem(Stp, O(REG, M), RREG, RA3);			/* R.M = ml */
	mem(Ldp, O(Heap, ref)-sizeof(Heap), RA3, RA1);
	gen(addix(RA1, RA1, 1));
	mem(Stp, O(Heap, ref)-sizeof(Heap), RA3, RA1);	/* ml->ref++ */
	mem(Ldp, O(Modlink, MP), RA3, RMP);
	mem(Stp, O(REG, MP), RREG, RMP);		/* R.MP = ml->MP */
	mem(Stp, O(REG, FP), RREG, RFP);		/* R.FP = f */
	mem(Ldi, O(Modlink, compiled), RA3, RA1);	/* C int (4 bytes) */
	gen(cmpiw(RA1, 0));
	cp = code;
	gen(bcond(EQ, 0));				/* !compiled -> interp */
	gen(br_(RA0));					/* compiled: enter native callee */
	patchbra(cp);
	mem(Stp, O(REG, PC), RREG, RA0);		/* interp: R.PC = ml->u.pc (dis) */
	schedret();					/* return to scheduler -> xec */
}

/* ---------------------------------------------------------------------- *
 *  Arithmetic helpers (result computed as RA1 op RA0 -> RA0).
 * ---------------------------------------------------------------------- */
static void
arithw(Inst *i, u32 (*op)(int,int,int))
{
	mid(i, Ldw, RA1);
	opwld(i, Ldw, RA0);
	gen(op(RA0, RA1, RA0));
	opwst(i, Stw, RA0);
}

static void
arithb(Inst *i, u32 (*op)(int,int,int))
{
	mid(i, Ldb, RA1);
	opwld(i, Ldb, RA0);
	gen(op(RA0, RA1, RA0));
	opwst(i, Stb, RA0);
}

static void
arithl(Inst *i, u32 (*op)(int,int,int))
{
	mid(i, Ldp, RA1);
	opwld(i, Ldp, RA0);
	gen(op(RA0, RA1, RA0));
	opwst(i, Stp, RA0);
}

/* ---------------------------------------------------------------------- *
 *  Floating point (native, scalar double).  Reals are 8-byte doubles in
 *  frame/MP memory; load into a d-register, operate, store back.  Reals
 *  never appear as AIMM (Inst.imm is a 32-bit WORD), so those modes urk.
 * ---------------------------------------------------------------------- */

/* address operand `a` (mode) and load/store its real value to/from d-reg r. */
static void
fopx(int mode, Adr *a, int ldf, int r)
{
	int w = ldf ? Ldf : Stf;
	int ir;

	switch(mode) {
	case AFP: mem(w, a->ind, RFP, r); return;
	case AMP: mem(w, a->ind, RMP, r); return;
	case AIND|AFP: ir = RFP; break;
	case AIND|AMP: ir = RMP; break;
	default: urk("fopx"); return;
	}
	mem(Ldp, a->i.f, ir, RTA);		/* 8-byte indirection pointer */
	mem(w, a->i.s, RTA, r);
}

static void
fopwld(Inst *i, int r)			/* F(s) -> d-reg r */
{
	fopx(USRC(i->add), &i->s, 1, r);
}

static void
fopwst(Inst *i, int r)			/* d-reg r -> F(d) */
{
	fopx(UDST(i->add), &i->d, 0, r);
}

static void
fmid(Inst *i, int r)			/* F(m) -> d-reg r (defaults to dst operand) */
{
	switch(i->add & ARM) {
	case AXINF: mem(Ldf, i->reg, RFP, r); return;
	case AXINM: mem(Ldf, i->reg, RMP, r); return;
	case AXIMM: urk("fmid/imm"); return;
	default:    fopx(UDST(i->add), &i->d, 1, r); return;
	}
}

/* three-operand FP arithmetic: F(d) = F(m) OP F(s) */
static void
arithf(Inst *i, u32 (*op)(int,int,int))
{
	fmid(i, DF1);			/* F(m) -> d1 */
	fopwld(i, DF0);			/* F(s) -> d0 */
	gen(op(DF0, DF1, DF0));		/* d0 = d1 OP d0 */
	fopwst(i, DF0);
}

/* conditional FP branch: compare F(s) ? F(m), branch on cc (cc chosen so the
 * unordered/NaN case takes the IEEE-correct edge — see comp()). */
static void
cbraf(Inst *i, int cc)
{
	schedcheck(i);
	fopwld(i, DF0);			/* F(s) -> d0 */
	fmid(i, DF1);			/* F(m) -> d1 */
	gen(fcmpd(DF0, DF1));
	bradis(cc, i->d.ins - mod->prog);
}

/* real -> integer: replicate the interpreter's round-half-away-from-zero
 * (f<0 ? f-0.5 : f+0.5) then truncate toward zero.  cvt is fcvtzsdw/fcvtzsdx;
 * st is Stw/Stp.  Result lands in RA0. */
static void
cvtfi(Inst *i, u32 (*cvt)(int,int), int st)
{
	fopwld(i, DF0);			/* f -> d0 */
	gen(fmovihalf(DF1));		/* d1 = +0.5 */
	gen(fmovinhalf(DF2));		/* d2 = -0.5 */
	gen(fcmpz(DF0));		/* flags from f - 0.0 */
	gen(fcsel(DF1, DF2, DF1, MI));	/* d1 = (f<0) ? -0.5 : +0.5 */
	gen(faddd(DF0, DF0, DF1));	/* f += bias */
	gen(cvt(RA0, DF0));		/* truncate toward zero -> RA0 */
	opwst(i, st, RA0);		/* W(d) (Stw) or V(d) (Stp) */
}

/* shift: count is W(s); value is W(m) -> RA0 */
static void
shiftw(Inst *i, u32 (*op)(int,int,int))
{
	mid(i, Ldw, RA1);		/* value */
	opwld(i, Ldw, RA0);		/* count */
	gen(op(RA0, RA1, RA0));
	opwst(i, Stw, RA0);
}

static void
shiftb(Inst *i, u32 (*op)(int,int,int))
{
	mid(i, Ldb, RA1);
	opwld(i, Ldw, RA0);
	gen(op(RA0, RA1, RA0));
	opwst(i, Stb, RA0);
}

/* movm / headm: copy memory.  src address in RA1. */
static void
movmem(Inst *i)
{
	u32 *cp, *loop;

	if((i->add & ARM) == AXIMM) {
		if(i->reg == 0)
			return;
		con(i->reg, RA3);		/* byte count */
	} else
		mid(i, Ldw, RA3);		/* dynamic count W(m) */

	opwst(i, Lea, RA2);			/* dst address */

	cp = nil;
	if((i->add & ARM) != AXIMM) {
		gen(cmpiw(RA3, 0));
		cp = code;
		gen(bcond(LE, 0));		/* count <= 0 ? skip */
	}
	loop = code;
	gen(ldrb(RA0, RA1, 0));
	gen(strb(RA0, RA2, 0));
	gen(addix(RA1, RA1, 1));
	gen(addix(RA2, RA2, 1));
	gen(subsiw(RA3, RA3, 1));
	gen(bcond(NE, (int)((char*)loop - (char*)code)));
	if(cp != nil)
		patchbra(cp);
}

/* indexing: array in RA0, bounds, element address -> middle operand */
static void
indarr(Inst *i, int shift, int dynsize)
{
	opwld(i, Ldp, RA0);			/* array pointer A(s) */
	gen(cmnix(RA0));
	trapif(EQ, bounds);			/* a == H -> exBounds */
	mem(Ldw, O(Array, len), RA0, RA2);	/* Array.len is WORD (8 bytes) */
	opwst(i, Ldw, RA1);			/* index W(d) (8 bytes) */
	gen(cmpx(RA1, RA2));			/* cmp index,len (64-bit unsigned) */
	trapif(HS, bounds);			/* index >= len -> exBounds */
	if(dynsize) {
		mem(Ldp, O(Array, t), RA0, RA3);
		mem(Ldi, O(Type, size), RA3, RA3);	/* Type.size is a C int (4 bytes) */
		gen(mulx(RA1, RA1, RA3));	/* index * size (64-bit) */
		mem(Ldp, O(Array, data), RA0, RA0);
		gen(addx(RA0, RA0, RA1));
	} else {
		mem(Ldp, O(Array, data), RA0, RA0);
		if(shift)
			gen(addxsh(RA0, RA0, RA1, shift));
		else
			gen(addx(RA0, RA0, RA1));
	}
	mid(i, Stp, RA0);			/* T(m) = element address */
}

/* ---------------------------------------------------------------------- *
 *  The big translation switch.
 * ---------------------------------------------------------------------- */
static void
comp(Inst *i)
{
	char buf[ERRMAX];

	switch(i->op) {
	default:
		snprint(buf, sizeof buf, "%s compile, no '%D'", mod->name, i);
		error(buf);
		break;

	/* ---- data moves ---- */
	case IMOVW:
		opwld(i, Ldw, RA0); opwst(i, Stw, RA0); break;
	case IMOVB:
		opwld(i, Ldb, RA0); opwst(i, Stb, RA0); break;
	case IMOVL:
	case IMOVF:
		opwld(i, Ldp, RA0); opwst(i, Stp, RA0); break;	/* 8-byte */
	case ILEA:
		opwld(i, Lea, RA0); opwst(i, Stp, RA0); break;	/* address: 8-byte */
	case IMOVM:
		opwld(i, Lea, RA1); movmem(i); break;
	case IHEADM:
		opwld(i, Ldp, RA1); notnil(RA1);
		if(OA(List, data) != 0)
			gen(addix(RA1, RA1, OA(List, data)));
		movmem(i);
		break;

	/* ---- conversions ---- */
	case ICVTBW:
		opwld(i, Ldb, RA0); opwst(i, Stw, RA0); break;		/* zero-extend */
	case ICVTWB:
		opwld(i, Ldw, RA0); opwst(i, Stb, RA0); break;
	case ICVTWL:
		/* ILP64: int and big are both 64-bit, so this is a plain 8-byte move */
		opwld(i, Ldw, RA0); opwst(i, Stp, RA0); break;
	case ICVTLW:
		opwld(i, Ldp, RA0); opwst(i, Stw, RA0); break;

	/* ---- word (int) arithmetic: 64-bit native under ILP64 ---- */
	case IADDW: arithw(i, addx); break;
	case ISUBW: arithw(i, subx); break;
	case IANDW: arithw(i, andx); break;
	case IORW:  arithw(i, orrx); break;
	case IXORW: arithw(i, eorx); break;
	case IMULW: arithw(i, mulx); break;
	case ISHLW: shiftw(i, lslvx); break;
	case ISHRW: shiftw(i, asrvx); break;	/* W signed -> arithmetic */

	/* ---- byte arithmetic ---- */
	case IADDB: arithb(i, addw); break;
	case ISUBB: arithb(i, subw); break;
	case IANDB: arithb(i, andw); break;
	case IORB:  arithb(i, orrw); break;
	case IXORB: arithb(i, eorw); break;
	case IMULB: arithb(i, mulw); break;
	case ISHLB: shiftb(i, lslvw); break;
	case ISHRB: shiftb(i, lsrvw); break;	/* B unsigned -> logical */

	/* ---- long (big) arithmetic, 64-bit native ---- */
	case IADDL: arithl(i, addx); break;
	case ISUBL: arithl(i, subx); break;
	case IANDL: arithl(i, andx); break;
	case IORL:  arithl(i, orrx); break;
	case IXORL: arithl(i, eorx); break;

	/* ---- length ---- */
	case ILENA:
		opwld(i, Ldp, RA1);
		con(0, RA0);
		gen(cmnix(RA1));
		memc(NE, Ldw, O(Array, len), RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ILENC: {
		u32 *cp;
		opwld(i, Ldp, RA1);
		con(0, RA0);
		gen(cmnix(RA1));
		memc(NE, Ldi, O(String, len), RA1, RA0);	/* String.len is a C int (4 bytes) */
		gen(cmpiw(RA0, 0));
		cp = code; gen(bcond(GE, 0));
		gen(subw(RA0, ZR, RA0));		/* abs: negate if <0 */
		patchbra(cp);
		opwst(i, Stw, RA0);
		break;
	}
	case ILENL: {
		u32 *cp, *loop;
		con(0, RA0);
		opwld(i, Ldp, RA1);
		loop = code;
		gen(cmnix(RA1));
		cp = code; gen(bcond(EQ, 0));		/* == H ? done */
		gen(addiw(RA0, RA0, 1));
		mem(Ldp, O(List, tail), RA1, RA1);
		gen(b_((int)((char*)loop - (char*)code)));
		patchbra(cp);
		opwst(i, Stw, RA0);
		break;
	}

	/* ---- array indexing ---- */
	case IINDW: indarr(i, 3, 0); break;	/* ILP64: int element is 8 bytes (1<<3) */
	case IINDL:
	case IINDF: indarr(i, 3, 0); break;
	case IINDB: indarr(i, 0, 0); break;
	case IINDX: indarr(i, 0, 1); break;

	/*
	 * Conditional branches and IJMP are compiled natively (cbra/cbrab/cbral +
	 * bradis); backward branches carry an inline schedcheck so compiled loops
	 * yield to the cooperative scheduler.  ICALL is punted (correct, just not
	 * inlined).  This path is exercised by the full -c1 test battery, including
	 * sh running every suite.
	 */
	case IBEQW: cbra(i, EQ); break;
	case IBNEW: cbra(i, NE); break;
	case IBLTW: cbra(i, LT); break;
	case IBLEW: cbra(i, LE); break;
	case IBGTW: cbra(i, GT); break;
	case IBGEW: cbra(i, GE); break;
	case IBEQB: cbrab(i, EQ); break;
	case IBNEB: cbrab(i, NE); break;
	case IBLTB: cbrab(i, LT); break;
	case IBLEB: cbrab(i, LE); break;
	case IBGTB: cbrab(i, GT); break;
	case IBGEB: cbrab(i, GE); break;
	case IBEQL: cbral(i, EQ); break;
	case IBNEL: cbral(i, NE); break;
	case IBLTL: cbral(i, LT); break;
	case IBLEL: cbral(i, LE); break;
	case IBGTL: cbral(i, GT); break;
	case IBGEL: cbral(i, GE); break;
	case IJMP:
		schedcheck(i);
		bradis(AL, i->d.ins - mod->prog);
		break;
	case ICALL:
		punt(i, SRCOP|DBRAN|WRTPC|NEWPC, optab[i->op]); break;

	/* ---- punted control flow (table fixups first) ---- */
	case IGOTO:
		comgoto(i);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case ICASE:
		comcase(i);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case ICASEL:
		comcasel(i);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case IRET:
		punt(i, TCHECK|NEWPC, optab[i->op]);
		break;

	/* ---- everything else: punt with interpreter-matching flags ---- */
	case IMCALL:
		commcall(i);
		break;
	case IFRAME:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;
	case IMFRAME:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case ISEND:
	case IRECV:
	case IALT:
	case INBALT:
		punt(i, SRCOP|DSTOP|TCHECK|WRTPC, optab[i->op]);
		break;
	case ISPAWN:
		punt(i, SRCOP|DBRAN, optab[i->op]);
		break;
	case IMSPAWN:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;
	case IBNEC: case IBEQC: case IBLTC: case IBLEC: case IBGTC: case IBGEC:
		punt(i, SRCOP|DBRAN|NEWPC|WRTPC, optab[i->op]);
		break;
	case ICASEC:
		comcasec(i);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case IEXIT:
		punt(i, 0, optab[i->op]);
		break;
	case IRAISE:
		punt(i, SRCOP|WRTPC|NEWPC, optab[i->op]);
		break;

	/* pointer moves & list ops (refcounted) -> punt in v1 */
	case IMOVP: case IMOVMP: case IHEADP: case IHEADMP: case ITAIL:
	case IHEADB: case IHEADW: case IHEADL: case IHEADF:
	case ICONSB: case ICONSW: case ICONSL: case ICONSF:
	case ICONSM: case ICONSMP: case ICONSP:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;

	/* allocation, slices, loads, string/array conversions -> punt */
	case ILOAD:
	case INEWA: case INEWAZ: case INEW: case INEWZ:
	case ISLICEA: case ISLICELA: case ISLICEC:
	case IINSC: case IINDC:
	case ICVTAC: case ICVTCA: case ICVTCW: case ICVTWC:
	case ICVTLC: case ICVTCL: case ICVTFC: case ICVTCF:
	case ICVTRF: case ICVTFR: case ICVTWS: case ICVTSW:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;
	case INEWCB: case INEWCW: case INEWCF: case INEWCP: case INEWCL:
		punt(i, DSTOP|THREOP, optab[i->op]);
		break;
	case INEWCM: case INEWCMP:
	case IMNEWZ:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;

	/* three-operand ops we don't yet natively emit */
	case IADDC:
	case IMULL: case IDIVL: case IMODL:
	case ILSRW: case ILSRL:
	case IMODW: case IMODB: case IDIVW: case IDIVB:
	case ISHLL: case ISHRL:
	case IMULX: case IDIVX: case ICVTXX:
	case IMULX0: case IDIVX0: case ICVTXX0:
	case IMULX1: case IDIVX1: case ICVTXX1:
	case ICVTFX: case ICVTXF:
	case IEXPW: case IEXPL: case IEXPF:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;

	/* ---- floating point (native, scalar double) ---- */
	case IADDF: arithf(i, faddd); break;
	case ISUBF: arithf(i, fsubd); break;
	case IMULF: arithf(i, fmuld); break;
	case IDIVF: arithf(i, fdivd); break;
	case INEGF:				/* F(d) = -F(s) */
		fopwld(i, DF0);
		gen(fnegd(DF0, DF0));
		fopwst(i, DF0);
		break;
	case ICVTWF:				/* F(d) = (real) W(s)  (ILP64 int is 64-bit) */
		opwld(i, Ldw, RA0);
		gen(scvtfxd(DF0, RA0));
		fopwst(i, DF0);
		break;
	case ICVTLF:				/* F(d) = (real) V(s)  (int64 -> double) */
		opwld(i, Ldp, RA0);
		gen(scvtfxd(DF0, RA0));
		fopwst(i, DF0);
		break;
	case ICVTFW:				/* W(d) = round(F(s))  (ILP64 int is 64-bit) */
		cvtfi(i, fcvtzsdx, Stw);
		break;
	case ICVTFL:				/* V(d) = round(F(s))  (double -> int64) */
		cvtfi(i, fcvtzsdx, Stp);
		break;
	/* branch on F(s) rel F(m); cc picked so NaN/unordered takes the
	 * IEEE edge: ordered <,<=,>,>= are false on unordered (MI/LS/GT/GE),
	 * == is false (EQ), != is true (NE). */
	case IBEQF: cbraf(i, EQ); break;
	case IBNEF: cbraf(i, NE); break;
	case IBLTF: cbraf(i, MI); break;
	case IBLEF: cbraf(i, LS); break;
	case IBGTF: cbraf(i, GT); break;
	case IBGEF: cbraf(i, GE); break;

	case ISELF:
		punt(i, DSTOP, optab[i->op]);
		break;
	}
}

/* ---------------------------------------------------------------------- *
 *  Module entry stub.
 * ---------------------------------------------------------------------- */
static void
preamble(void)
{
	if(comvec)
		return;
	comvec = jitcode(16 * sizeof(*code));
	if(comvec == nil)
		error(exNomem);
	code = (u32*)comvec;

	/*
	 * Prologue: native code freely clobbers the AAPCS64 callee-saved registers
	 * RREG/RFP/RMP/RLR2 (x19/x20/x21/x24), but comvec is reached by an ordinary
	 * C call from xec(), whose caller expects them preserved.  Save them here;
	 * schedret() restores them on every path back to the C world.
	 */
	gen(stppre(RREG, RFP, 31, -32));	/* stp x19,x20,[sp,#-32]! */
	gen(stpoff(RMP, RLR2, 31, 16));		/* stp x21,x24,[sp,#16] */

	con((u64)&R, RREG);
	mem(Stp, O(REG, xpc), RREG, RLINK);	/* save scheduler return addr */
	mem(Ldp, O(REG, FP), RREG, RFP);
	mem(Ldp, O(REG, MP), RREG, RMP);
	mem(Ldp, O(REG, PC), RREG, RIP);
	gen(br_(RIP));				/* enter native code at R.PC */

	segflush(comvec, 16 * sizeof(*code));
}

/* ---------------------------------------------------------------------- *
 *  Exception-table fixups: convert Dis PCs to native instruction offsets.
 * ---------------------------------------------------------------------- */
static void
patchex(Module *m, ulong *p)
{
	Handler *h;
	Except *e;

	if((h = m->htab) == nil)
		return;
	/*
	 * handler() (emu/port/exception.c) treats compiled-module handler PCs as
	 * native BYTE offsets from m->prog (pc = (ulong)R.PC - (ulong)m->prog).
	 * patch[] is in native instruction units, so scale to bytes here.  The
	 * -1 "no handler" terminator must be left untouched (it is NOPC).
	 */
	for( ; h->etab != nil; h++) {
		h->pc1 = p[h->pc1] * sizeof(u32);
		h->pc2 = p[h->pc2] * sizeof(u32);
		for(e = h->etab; e->s != nil; e++)
			e->pc = p[e->pc] * sizeof(u32);
		if(e->pc != -1)
			e->pc = p[e->pc] * sizeof(u32);
	}
}

/* ---------------------------------------------------------------------- *
 *  Two-pass compile driver.
 * ---------------------------------------------------------------------- */
int
compile(Module *m, int size, Modlink *ml)
{
	Link *l;
	Modl *e;
	int i, n;
	u32 *s, *tmp;

	base = nil;
	patch = mallocz(size * sizeof(*patch), 0);
	tmp = malloc(4096 * sizeof(u32));
	if(patch == nil || tmp == nil)
		goto bad;

	preamble();

	mod = m;
	pass = 0;
	nlit = 0;
	n = 0;
	for(i = 0; i < size; i++) {
		code = tmp;
		comp(&m->prog[i]);
		patch[i] = n;
		n += code - tmp;
	}
	for(i = 0; i < nelem(mactab); i++) {	/* size the per-module macros */
		code = tmp;
		mactab[i].gen();
		macro[mactab[i].idx] = n;
		n += code - tmp;
	}

	base = jitcode((n + nlit*2) * sizeof(u32));
	if(base == nil)
		goto bad;

	if(cflag > 3)
		print("dis=%5d %5d asm=%p: %s\n", size, n, base, m->name);

	pass = 1;
	nlit = 0;
	litpool = base + n;
	code = base;
	for(i = 0; i < size; i++) {
		s = code;
		comp(&m->prog[i]);
		if(patch[i] != s - base) {
			print("%3d %D\n", i, &m->prog[i]);
			print("%lud != %ld\n", patch[i], (long)(s - base));
			urk("phase error");
		}
		if(cflag > 4) {
			print("%3d %D\n", i, &m->prog[i]);
			das((ulong*)s, code - s);
		}
	}
	for(i = 0; i < nelem(mactab); i++) {	/* emit the per-module macros */
		s = code;
		mactab[i].gen();
		if(macro[mactab[i].idx] != s - base)
			urk("mac phase error");
		if(cflag > 4) {
			print("%s:\n", mactab[i].name);
			das((ulong*)s, code - s);
		}
	}

	for(l = m->ext; l->name; l++)
		l->u.pc = (Inst*)RELPC(patch[l->u.pc - m->prog]);
	if(ml != nil) {
		e = &ml->links[0];
		for(i = 0; i < ml->nlinks; i++) {
			e->u.pc = (Inst*)RELPC(patch[e->u.pc - m->prog]);
			e++;
		}
	}
	patchex(m, patch);
	m->entry = (Inst*)RELPC(patch[m->entry - m->prog]);

	free(patch);
	free(tmp);
	free(m->prog);
	m->prog = (Inst*)base;
	m->compiled = 1;
	segflush(base, (n + nlit*2) * sizeof(u32));
	return 1;
bad:
	free(patch);
	free(tmp);
	free(base);
	return 0;
}
