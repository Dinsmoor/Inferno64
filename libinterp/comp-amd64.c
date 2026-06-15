/*
 * Dis JIT compiler back-end for x86-64 (amd64) — LP64.
 *
 * This is the second LP64 Dis JIT for Inferno, modelled directly on the
 * AArch64 back-end (comp-aarch64.c), which is the reference for "what correct
 * LP64 codegen looks like".  The 32-bit x86 back-end (comp-386.c) conflates
 * Dis word == Dis pointer == native register width (4 bytes); that assumption
 * breaks under LP64, where a Dis word is 4 bytes (IBY2WD) but a Dis pointer is
 * 8 bytes (IBY2PTR).  The earlier ILP64 amd64 back-end went the other way and
 * widened *everything* to 8 bytes (rex + movabs everywhere); that is equally
 * wrong on LP64.  This file splits the two:
 *
 *   - int / word fields  -> 32-bit operations (movl, no REX.W).
 *   - pointer / big(int64) / real(double) fields -> 64-bit (movq, REX.W).
 *
 * The width is chosen per opcode by mirroring comp-aarch64.c's Ldw/Stw (4-byte)
 * vs Ldp/Stp (8-byte) split exactly.  See ON_JIT.md / ON_C_IN_DIS.md.
 *
 * Strategy (mirrors comp-aarch64.c): natively compile the hot integer + control
 * path (data moves, add/sub/and/or/xor, shifts, conversions, indexing,
 * conditional branches, IJMP, the cross-module IMCALL) and PUNT the rest to the
 * interpreter.  Punting is always semantics-correct because the interpreter
 * reads operands through R.s/R.d/R.m (which punt sets up) and honours native
 * PCs via the NEWPC path.  In particular this back-end PUNTS, exactly like the
 * aarch64 one, IALT/INBALT/ISEND/IRECV, every refcounted pointer move
 * (IMOVP, IHEADP, ITAIL, the ICONS family), allocation, IGOTO/ICASE/ICASEL/ICASEC (after
 * relocating their dst slots from Dis PC to native address), IRET, IFRAME and
 * IMFRAME.  Floating point (scalar double via SSE2), the integer
 * multiply/divide/modulo group and the long/logical shifts are compiled
 * natively (see the FP and muls/divs/shiftl helpers); the fixed-point (IMULX
 * etc.), IEXP*, and IADDC ops still run interpreted.  Punting the channel ops
 * means the array-of-channels alt LP64 offset bug class (libinterp/alt.c)
 * cannot recur here.
 *
 * Register state across native code: RFP (rsi) = Dis frame pointer, RMP (rdi) =
 * Dis module data pointer; both are saved by comvec's prologue and reloaded
 * from R.FP/R.MP after every C call (they are caller-saved on SysV).  &R is
 * materialised into RTMP (rbx) on demand.  comvec's prologue pushes the five
 * registers the JIT clobbers; every path back to the C caller (xec) pops them
 * and returns.
 *
 * Like comp-aarch64.c, native code addresses are stored truncated to 32 bits in
 * the module's WORD jump tables (IGOTO/ICASE/ICASEL) and read back sign-extended
 * by the interpreter (xec.c: R.PC=(Inst*)t[0]).  The code buffer must therefore
 * live in the low 32 bits of the address space; jitcode() carves it from a
 * MAP_32BIT mmap arena.  xec()'s native-PC test is the single range
 * [jitlo, jithi).
 *
 * Activated only with `emu -c1` (cflag>0); default cflag==0 keeps every module
 * interpreted, so this back-end has no effect on default behaviour.
 */
#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"

#define DOT		((uintptr)code)

#define	RESCHED 1	/* check for interpreter reschedule on backward branches */

enum
{
	RAX	= 0,
	RCX	= 1,
	RDX	= 2,
	RBX	= 3,
	RSP	= 4,
	RBP	= 5,
	RSI	= 6,
	RDI	= 7,

	RFP	= RSI,		/* Dis frame pointer  (saved/reloaded across C calls) */
	RMP	= RDI,		/* Dis module pointer (saved/reloaded across C calls) */
	RTA	= RDX,		/* indirect-addressing temp */
	RTMP	= RBX,		/* holds &R after con(&R, RTMP) */

	/* opcodes / opcode-bytes used below (x86-64) */
	Omovzxb	= 0xb6,
	Omovzxw	= 0xb7,
	Ocall	= 0xe8,
	Ocallrm	= 0xff,
	Ocdq	= 0x99,
	Ocld	= 0xfc,
	Ocmpb	= 0x38,
	Ocmpw	= 0x39,
	Ocmpi	= 0x81,
	Odecrm	= 0xff,
	Oincrm	= 0xff,
	/* short (rel8) conditional jumps */
	Ojbb	= 0x72,		/* JB  (unsigned <) */
	Ojaeb	= 0x73,		/* JAE (unsigned >=) */
	Ojeqb	= 0x74,
	Ojneb	= 0x75,
	Ojpb	= 0x7a,		/* JP  (parity/unordered), rel8 */
	Ojgeb	= 0x7d,
	Ojleb	= 0x7e,
	Ojgtb	= 0x7f,
	Ojeql	= 0x84,		/* 0f-prefixed near jcc (rel32) */
	Ojnel	= 0x85,
	Ojltl	= 0x8c,
	Ojgel	= 0x8d,
	Ojlel	= 0x8e,
	Ojgtl	= 0x8f,
	Ojbl	= 0x82,
	Ojael	= 0x83,
	Ojbel	= 0x86,
	Ojhil	= 0x87,
	Ojpl	= 0x8a,		/* near JP (parity/unordered), rel32 */
	Ojmp	= 0xe9,
	Ojmpb	= 0xeb,
	Ojmprm	= 0xff,
	Oldb	= 0x8a,
	Oldw	= 0x8b,		/* mov reg, r/m */
	Olea	= 0x8d,
	Omov	= 0xc7,		/* mov r/m, imm32 (/0) */
	Omovimm	= 0xb8,		/* mov reg, imm (movabs with REX.W) */
	Oret	= 0xc3,
	Ostb	= 0x88,
	Ostw	= 0x89,		/* mov r/m, reg */
	Oxor	= 0x31,
	Opopl	= 0x58,
	Opushl	= 0x50,
	Oneg	= 0xf7,

	SRCOP	= (1<<0),
	DSTOP	= (1<<1),
	WRTPC	= (1<<2),
	TCHECK	= (1<<3),
	NEWPC	= (1<<4),
	DBRAN	= (1<<5),
	THREOP	= (1<<6),

	MacMCAL	= 0,
	MacRELQ,
	NMACRO
};

static	uchar*	code;
static	uchar*	base;
static	uintptr*	patch;		/* patch[disidx] = native BYTE offset */
static	int	pass;
static	Module*	mod;
static	uintptr*	litpool;
static	int	nlit;
static	void	macmcal(void);
static	void	macrelq(void);
static	uintptr	macro[NMACRO];
	void	(*comvec)(void);
extern	void	das(uchar*, int);

static struct { int idx; void (*gen)(void); char *name; } mactab[] = {
	{ MacMCAL, macmcal, "MCAL" },
	{ MacRELQ, macrelq, "RELQ" },
};

#define T(r)	*((void**)(R.r))

/*
 * JIT code must live in the low 2GB: the module's WORD jump tables
 * (IGOTO/ICASE/ICASEL) store native code addresses in 32-bit slots and the
 * interpreter reads them back sign-extended.  Pool/heap allocations land far
 * above 4GB on Linux, so carve code buffers out of a MAP_32BIT mmap arena.
 */
extern void*	mmap(void*, unsigned long, int, int, int, long);
extern int	munmap(void*, unsigned long);
#define	PROT_READ	0x1
#define	PROT_WRITE	0x2
#define	PROT_EXEC	0x4
#define	MAP_PRIVATE	0x2
#define	MAP_ANONYMOUS	0x20
#define	MAP_32BIT	0x40
#define	MAP_FIXED_NOREPLACE	0x100000
#define	MAP_FAILED	((void*)-1)
#define	JITLOWLIMIT	0x80000000UL	/* keep native code below 2GB (32-bit tables) */

static uchar*	jitarena;
extern uchar*	jitlo;		/* native-code bounds, used by xec() dispatch */
extern uchar*	jithi;
ulong	jitarenasize = 64*1024*1024;
int	jitsinglearena;

/*
 * Map one executable arena entirely below 2GB.  Real amd64 honours MAP_32BIT,
 * so the first attempt lands low.  qemu-user (the aarch64 cross-test host)
 * ignores MAP_32BIT and returns a high address, so fall back to walking a few
 * fixed low hints with MAP_FIXED_NOREPLACE (which fails rather than clobbering
 * an existing mapping).
 */
static void*
jitmap(ulong sz)
{
	static uintptr nexthint = 0x20000000UL;
	void *p;
	uintptr h;

	p = mmap(nil, sz, PROT_READ|PROT_WRITE|PROT_EXEC,
		MAP_PRIVATE|MAP_ANONYMOUS|MAP_32BIT, -1, 0);
	if(p != MAP_FAILED && (uintptr)p + sz <= JITLOWLIMIT)
		return p;
	if(p != MAP_FAILED)
		munmap(p, sz);
	for(h = nexthint; h + sz <= JITLOWLIMIT; h += sz) {
		p = mmap((void*)h, sz, PROT_READ|PROT_WRITE|PROT_EXEC,
			MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE, -1, 0);
		if(p != MAP_FAILED && (uintptr)p + sz <= JITLOWLIMIT) {
			nexthint = h + sz;
			return p;
		}
		if(p != MAP_FAILED)
			munmap(p, sz);
	}
	return MAP_FAILED;
}

static void*
jitcode(ulong n)
{
	void *p;
	ulong sz;

	n = (n + 15) & ~15UL;
	if(jitarena == nil || jitarena + n > jithi) {
		if(jitarena != nil && jitsinglearena)
			return nil;
		sz = jitarenasize;
		if(n > sz)
			sz = (n + 0xFFF) & ~0xFFFUL;
		p = jitmap(sz);
		if(p == MAP_FAILED)
			return nil;
		jitarena = p;
		if(jitlo == nil || (uchar*)p < jitlo)
			jitlo = p;
		if((uchar*)p + sz > jithi)
			jithi = (uchar*)p + sz;
	}
	p = jitarena;
	jitarena += n;
	return p;
}

/* ---------------------------------------------------------------------- *
 *  C helpers reachable from generated code.
 * ---------------------------------------------------------------------- */
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

/*
 * Runt (builtin C module) IMCALL path.  Like comp-aarch64.c, this does NOT set
 * R.M to the callee — R.M stays the compiled caller — and the runt function
 * pointer arrives in R.d (8 bytes; R.dt is only 4 on LP64, so it cannot carry a
 * pointer).
 */
static void
rmcall(void)
{
	Prog *p;
	Frame *f;

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
 *  Low-level emitters.
 * ---------------------------------------------------------------------- */
static int
bc(int o)
{
	return o < 127 && o > -128;
}

static void
urk(char *s)
{
	USED(s);
	error(exCompile);
}

static void
genb(uchar o)
{
	*code++ = o;
}

static void
gen2(uchar o1, uchar o2)
{
	code[0] = o1;
	code[1] = o2;
	code += 2;
}

static void
gen4(uintptr o)
{
	*(u32int*)code = (u32int)o;
	code += 4;
}

static void
gen8(uintptr o)
{
	*(uintptr*)code = o;
	code += 8;
}

#define genw(o)	gen4(o)		/* in-instruction immediates are 32-bit on x86 */

static void
rex(void)
{
	*code++ = 0x48;			/* REX.W: 64-bit operand */
}

/*
 * modrmw: emit `inst` then a ModRM byte addressing [rm + disp] with reg field r.
 * rm/r must be one of RAX..RDI other than RSP/RBP (no SIB/RIP special-casing);
 * the back-end only uses RAX/RCX/RDX/RBX/RSI/RDI as memory bases, so this holds.
 */
static void
modrmw(int inst, uintptr disp, int rm, int r)
{
	*code++ = inst;
	if(disp == 0) {
		*code++ = (0<<6)|(r<<3)|rm;
		return;
	}
	if(bc(disp)) {
		code[0] = (1<<6)|(r<<3)|rm;
		code[1] = disp;
		code += 2;
		return;
	}
	*code++ = (2<<6)|(r<<3)|rm;
	*(u32int*)code = (u32int)disp;
	code += 4;			/* 64-bit mode: displacement is 32-bit */
}

static void
modrm(int inst, uintptr disp, int rm, int r)	/* 64-bit operand */
{
	rex();
	modrmw(inst, disp, rm, r);
}

static void
modrmn(int inst, uintptr disp, int rm, int r, int sz)	/* sz!=0 -> 64-bit */
{
	if(sz)
		rex();
	modrmw(inst, disp, rm, r);
}

/*
 * Load a 64-bit constant into r.  ALWAYS the fixed 10-byte movabs (never a
 * shorter encoding for 0): the two compile passes must emit identical byte counts,
 * and base-relative addresses are 0 in pass 0 (base==nil, forward patch[]==0)
 * but nonzero in pass 1 — a value-dependent length would desync the passes.
 */
static void
con(uintptr o, int r)
{
	rex();
	genb(Omovimm+r);
	gen8(o);
}

/* 32-bit compare reg,imm (no REX.W) */
static void
cmpl(int r, uintptr v)
{
	if(bc(v)) {
		gen2(0x83, (3<<6)|(7<<3)|r);
		genb(v);
		return;
	}
	gen2(Ocmpi, (3<<6)|(7<<3)|r);
	genw(v);
}

/* 64-bit compare reg, $-1  (the is-H test) */
static void
cmpqH(int r)
{
	rex();
	gen2(0x83, (3<<6)|(7<<3)|r);
	genb(0xff);
}

/* ---------------------------------------------------------------------- *
 *  Operand addressing.  `sz` selects 32-bit (0) vs 64-bit (1) operand.
 * ---------------------------------------------------------------------- */
static void
opwldn(Inst *i, int mi, int r, int sz)
{
	int ir, rta;

	switch(UXSRC(i->add)) {
	default:
		urk("opwld");
	case SRC(AFP):
		modrmn(mi, i->s.ind, RFP, r, sz);
		return;
	case SRC(AMP):
		modrmn(mi, i->s.ind, RMP, r, sz);
		return;
	case SRC(AIMM):
		con((uintptr)(WORD)i->s.imm, r);	/* sign-extended word immediate */
		return;
	case SRC(AIND|AFP):
		ir = RFP;
		break;
	case SRC(AIND|AMP):
		ir = RMP;
		break;
	}
	rta = RTA;
	if(mi == Olea)
		rta = r;
	modrm(Oldw, i->s.i.f, ir, rta);		/* indirection base: 8-byte pointer */
	modrmn(mi, i->s.i.s, rta, r, sz);
}

static void	opwldw(Inst *i, int mi, int r){ opwldn(i, mi, r, 0); }	/* 32-bit */
static void	opwld(Inst *i, int mi, int r){ opwldn(i, mi, r, 1); }	/* 64-bit */

static void
opwstn(Inst *i, int mi, int r, int sz)
{
	int ir, rta;

	switch(UXDST(i->add)) {
	default:
		urk("opwst");
	case DST(AIMM):
		con((uintptr)(WORD)i->d.imm, r);
		return;
	case DST(AFP):
		modrmn(mi, i->d.ind, RFP, r, sz);
		return;
	case DST(AMP):
		modrmn(mi, i->d.ind, RMP, r, sz);
		return;
	case DST(AIND|AFP):
		ir = RFP;
		break;
	case DST(AIND|AMP):
		ir = RMP;
		break;
	}
	rta = RTA;
	if(mi == Olea)
		rta = r;
	modrm(Oldw, i->d.i.f, ir, rta);
	modrmn(mi, i->d.i.s, rta, r, sz);
}

static void	opwstw(Inst *i, int mi, int r){ opwstn(i, mi, r, 0); }
static void	opwst(Inst *i, int mi, int r){ opwstn(i, mi, r, 1); }

static void
midn(Inst *i, uchar mi, int r, int sz)
{
	int ir;

	switch(i->add&ARM) {
	default:
		opwstn(i, mi, r, sz);
		return;
	case AXIMM:
		con((uintptr)(WORD)(short)i->reg, r);
		return;
	case AXINF:
		ir = RFP;
		break;
	case AXINM:
		ir = RMP;
		break;
	}
	modrmn(mi, i->reg, ir, r, sz);
}

static void	midw(Inst *i, uchar mi, int r){ midn(i, mi, r, 0); }
static void	mid(Inst *i, uchar mi, int r){ midn(i, mi, r, 1); }

/* ---------------------------------------------------------------------- *
 *  Branch / call helpers.
 * ---------------------------------------------------------------------- */

/* indirect call/jmp to absolute C address dst (out of rel32 range otherwise) */
static void
bra(uintptr dst, int op)		/* op is Ocall or Ojmp intent; we use call* */
{
	USED(op);
	con(dst, RAX);
	gen2(Ocallrm, (3<<6)|(2<<3)|RAX);	/* call *rax */
}

/* relative (rel32) call/jmp to native offset dst (within the code buffer) */
static void
rbra(uintptr dst, int op)
{
	dst += (uintptr)base;
	dst -= DOT+5;
	genb(op);
	genw(dst);
}

/* store an immediate (or native address) into a litpool slot; point REG.roff at it */
static void
literal(uintptr imm, int roff)
{
	nlit++;
	rex();
	genb(Omovimm+RAX);
	gen8((uintptr)litpool);
	modrm(Ostw, roff, RTMP, RAX);		/* REG.s/d/m are pointers (8 bytes) */
	if(pass == 0)
		return;
	*litpool = imm;
	litpool++;
}

/*
 * Call a C helper if short condition `cc` holds; helper never returns
 * (bounds/nullity).  Emits `j(!cc) over; call fn; over:` — cc is a rel8 jcc
 * opcode for the TRUE condition; cc^1 is its negation (the 0x70-0x7f block).
 */
static void
trapif(int cc, void (*fn)(void))
{
	uchar *cp;

	gen2(cc^1, 0);				/* j(!cc) rel8 over the call */
	cp = code - 1;
	bra((uintptr)fn, Ocall);
	*cp = code - cp - 1;
}

/* ---------------------------------------------------------------------- *
 *  Reschedule check on backward branches.
 * ---------------------------------------------------------------------- */
static void
schedcheck(Inst *i)
{
	if(RESCHED && i->d.ins <= i) {
		con((uintptr)&R, RTMP);
		modrmw(0x83, O(REG, IC), RTMP, 5);	/* sub dword [R.IC], 1 (int) */
		genb(1);
		gen2(Ojgtb, 5);				/* JG +5 (skip the call) */
		rbra(macro[MacRELQ], Ocall);
	}
}

static void
macrelq(void)
{
	modrm(Ostw, O(REG, FP), RTMP, RFP);	/* R.FP = rsi  (RTMP=&R from schedcheck) */
	genb(Opopl+RAX);			/* rax = post-schedcheck return addr */
	modrm(Ostw, O(REG, PC), RTMP, RAX);	/* R.PC = resume point */
	genb(Opopl+RDI);
	genb(Opopl+RSI);
	genb(Opopl+RDX);
	genb(Opopl+RCX);
	genb(Opopl+RBX);
	genb(Oret);
}

/* ---------------------------------------------------------------------- *
 *  Punt: fall back to the interpreter for instruction i.
 * ---------------------------------------------------------------------- */
static void
punt(Inst *i, int m, void (*fn)(void))
{
	uintptr pc;

	con((uintptr)&R, RTMP);

	if(m & SRCOP) {
		if(UXSRC(i->add) == SRC(AIMM))
			literal((uintptr)(WORD)i->s.imm, O(REG, s));
		else {
			opwld(i, Olea, RAX);
			modrm(Ostw, O(REG, s), RTMP, RAX);
		}
	}
	if(m & DSTOP) {
		opwst(i, Olea, RAX);
		modrm(Ostw, O(REG, d), RTMP, RAX);
	}
	if(m & WRTPC) {
		pc = patch[i-mod->prog+1];
		con((uintptr)base + pc, RAX);
		modrm(Ostw, O(REG, PC), RTMP, RAX);
	}
	if(m & DBRAN) {
		pc = patch[i->d.ins-mod->prog];
		literal((uintptr)base+pc, O(REG, d));
	}

	switch(i->add&ARM) {
	case AXNON:
		if(m & THREOP) {
			modrm(Oldw, O(REG, d), RTMP, RAX);
			modrm(Ostw, O(REG, m), RTMP, RAX);
		}
		break;
	case AXIMM:
		literal((uintptr)(WORD)(short)i->reg, O(REG, m));
		break;
	case AXINF:
		modrm(Olea, i->reg, RFP, RAX);
		modrm(Ostw, O(REG, m), RTMP, RAX);
		break;
	case AXINM:
		modrm(Olea, i->reg, RMP, RAX);
		modrm(Ostw, O(REG, m), RTMP, RAX);
		break;
	}
	modrm(Ostw, O(REG, FP), RTMP, RFP);

	bra((uintptr)fn, Ocall);

	con((uintptr)&R, RTMP);
	if(m & TCHECK) {
		modrmw(Ocmpi, O(REG, t), RTMP, 7);	/* cmp dword [R.t], 0 (R.t is int) */
		genw(0);
		gen2(Ojeqb, 0x06);			/* JEQ .+6 */
		genb(Opopl+RDI);
		genb(Opopl+RSI);
		genb(Opopl+RDX);
		genb(Opopl+RCX);
		genb(Opopl+RBX);
		genb(Oret);
	}

	modrm(Oldw, O(REG, FP), RTMP, RFP);
	modrm(Oldw, O(REG, MP), RTMP, RMP);

	if(m & NEWPC) {
		modrm(Oldw, O(REG, PC), RTMP, RAX);
		gen2(Ojmprm, (3<<6)|(4<<3)|RAX);	/* jmp *rax */
	}
}

/* ---------------------------------------------------------------------- *
 *  Jump-table relocation (mirrors comp-aarch64.c; tables hold 32-bit WORDs).
 * ---------------------------------------------------------------------- */
#define RELPC(pc)	((uintptr)base + (pc))

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
 * String case (ICASEC).  LP64 table layout (see xec.c OP(casec)):
 *   [count : IBY2PTR slot][entry: String* low; String* high; WORD dst]*[wild dst]
 * Each entry is 3*IBY2PTR = 24 bytes (6 WORDs); dst WORD at byte offset 2*IBY2PTR.
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
			*cnt = -n-1;
		return;
	}
	if(n >= 0)
		return;
	n = -n-1;
	*cnt = n;
	t = (WORD*)(mod->origmp + i->d.ind + IBY2PTR);
	e = t + n*6;
	while(t < e) {
		t[4] = (WORD)RELPC(patch[t[4]]);
		t += 6;
	}
	t[0] = (WORD)RELPC(patch[t[0]]);
}

/*
 * compile() failed after pass 0: undo the negated case-table counts left by
 * comcase/comcasel/comcasec so the module runs interpreted with intact tables.
 */
static void
uncase(Module *m, int size)
{
	Inst *i;
	WORD *t;
	int k;

	if(m->origmp == H || m->origmp == nil)
		return;
	for(k = 0, i = m->prog; k < size; k++, i++){
		switch(i->op){
		case ICASE:
			t = (WORD*)(m->origmp + i->d.ind + IBY2WD);
			if(t[-1] < 0)
				t[-1] = -t[-1]-1;
			break;
		case ICASEL:
			t = (WORD*)(m->origmp + i->d.ind + 2*IBY2WD);
			if(t[-2] < 0)
				t[-2] = -t[-2]-1;
			break;
		case ICASEC:
			t = (WORD*)(m->origmp + i->d.ind);
			if(t[0] < 0)
				t[0] = -t[0]-1;
			break;
		}
	}
}

/* ---------------------------------------------------------------------- *
 *  Native cross-module call (IMCALL).
 * ---------------------------------------------------------------------- */
static void
commcall(Inst *i)
{
	uchar *mlnil;

	con((uintptr)&R, RTMP);
	opwld(i, Oldw, RCX);				/* f = T(s) (8-byte frame ptr) */
	con((uintptr)base+patch[i-mod->prog+1], RAX);	/* native return address */
	modrm(Ostw, O(Frame, lr), RCX, RAX);		/* f->lr = retaddr */
	modrm(Ostw, O(Frame, fp), RCX, RFP);		/* f->fp = R.FP */
	modrm(Oldw, O(REG, M), RTMP, RTA);		/* rta = R.M */
	modrm(Ostw, O(Frame, mr), RCX, RTA);		/* f->mr = caller */
	opwst(i, Oldw, RTA);				/* rta = ml = T(d) */
	cmpqH(RTA);
	gen2(Ojeqb, 0);
	mlnil = code - 1;
	if((i->add&ARM) == AXIMM)
		modrm(Oldw, OA(Modlink, links)+i->reg*sizeof(Modl)+O(Modl, u.pc), RTA, RAX);
	else {
		midw(i, Oldw, RAX);			/* idx (int) */
		gen2(0x6b, (3<<6)|(RAX<<3)|RAX);	/* imul eax, eax, sizeof(Modl) */
		genb(sizeof(Modl));
		/* rax = [rta + rax*1 + (links + u.pc)] */
		rex();
		gen2(Oldw, (2<<6)|(RAX<<3)|4);		/* mov rax, [SIB + disp32] */
		genb((0<<6)|(RAX<<3)|RTA);		/* SIB: scale1, index=rax, base=rta */
		gen4(OA(Modlink, links)+O(Modl, u.pc));
	}
	*mlnil = code-mlnil-1;
	rbra(macro[MacMCAL], Ocall);
}

static void
macmcal(void)
{
	uchar *mlnil, *label, *interp;

	cmpqH(RAX);				/* runt fn / native pc / dis pc == H ? */
	gen2(Ojeqb, 0);
	mlnil = code - 1;
	modrm(0x83, O(Modlink, prog), RTA, 7);	/* cmp qword [ml->prog], 0 */
	genb(0x00);
	gen2(Ojneb, 0);				/* prog != 0 -> compiled/interp prog */
	label = code-1;

	*mlnil = code-mlnil-1;
	/* runt: keep R.M = caller; rmcall(R.d = fn) */
	genb(Opushl+RBP);			/* 16-byte stack align for the C call */
	modrm(Ostw, O(REG, FP), RTMP, RCX);	/* R.FP = f */
	modrm(Ostw, O(REG, d), RTMP, RAX);	/* R.d = runt fn pointer (8 bytes) */
	bra((uintptr)rmcall, Ocall);
	con((uintptr)&R, RTMP);
	modrm(Oldw, O(REG, FP), RTMP, RFP);
	modrm(Oldw, O(REG, MP), RTMP, RMP);
	genb(Opopl+RBP);
	genb(Oret);

	*label = code-label-1;			/* prog: */
	rex();
	gen2(Oldw, (3<<6)|(RFP<<3)|RCX);	/* mov rsi, rcx  (R.FP register = f) */
	modrm(Ostw, O(REG, M), RTMP, RTA);	/* R.M = ml */
	modrm(Oincrm, O(Heap, ref)-sizeof(Heap), RTA, 0);	/* ml->ref++ (ulong) */
	modrm(Oldw, O(Modlink, MP), RTA, RMP);	/* R.MP = ml->MP */
	modrm(Ostw, O(REG, MP), RTMP, RMP);
	modrm(Ostw, O(REG, FP), RTMP, RFP);
	modrmw(Ocmpi, O(Modlink, compiled), RTA, 7);	/* cmp dword [ml->compiled], 0 (int) */
	genw(0);
	genb(Opopl+RTA);			/* balance the `call macmcal`: neither the
						 * compiled (jmp) nor interp (ret-to-sched)
						 * path returns to commcall, so drop the
						 * pushed return address here */
	gen2(Ojeqb, 0);				/* !compiled -> interp */
	interp = code-1;
	gen2(Ojmprm, (3<<6)|(4<<3)|RAX);	/* jmp *rax  (enter native callee) */
	*interp = code-interp-1;		/* interp: */
	modrm(Ostw, O(REG, FP), RTMP, RFP);
	modrm(Ostw, O(REG, PC), RTMP, RAX);	/* R.PC = ml->u.pc (dis) */
	genb(Opopl+RDI);			/* return to scheduler */
	genb(Opopl+RSI);
	genb(Opopl+RDX);
	genb(Opopl+RCX);
	genb(Opopl+RBX);
	genb(Oret);
}

/* ---------------------------------------------------------------------- *
 *  Arithmetic helpers.   op2 = x86 "r/m,reg" opcode; rm = /digit for imm form.
 * ---------------------------------------------------------------------- */

/* word (32-bit): dst = mid OP src, mid defaults to dst */
static void
arithw(Inst *i, int op2, int rm)
{
	if(UXSRC(i->add) != SRC(AIMM)) {
		if(i->add&ARM) {
			midw(i, Oldw, RAX);
			opwldw(i, op2|2, RAX);		/* OP eax, [src] */
			opwstw(i, Ostw, RAX);
			return;
		}
		opwldw(i, Oldw, RAX);
		opwstw(i, op2, RAX);			/* OP [dst], eax */
		return;
	}
	if(i->add&ARM) {
		midw(i, Oldw, RAX);
		if(bc(i->s.imm)) {
			gen2(0x83, (3<<6)|(rm<<3)|RAX);
			genb(i->s.imm);
		} else {
			gen2(0x81, (3<<6)|(rm<<3)|RAX);
			genw(i->s.imm);
		}
		opwstw(i, Ostw, RAX);
		return;
	}
	if(bc(i->s.imm)) {
		opwstw(i, 0x83, rm);
		genb(i->s.imm);
		return;
	}
	opwstw(i, 0x81, rm);
	genw(i->s.imm);
}

/* long/big (64-bit): dst = mid OP src */
static void
arithl(Inst *i, int op2, int rm)
{
	if(UXSRC(i->add) != SRC(AIMM)) {
		if(i->add&ARM) {
			mid(i, Oldw, RAX);
			opwld(i, op2|2, RAX);
			opwst(i, Ostw, RAX);
			return;
		}
		opwld(i, Oldw, RAX);
		opwst(i, op2, RAX);
		return;
	}
	if(i->add&ARM) {
		mid(i, Oldw, RAX);
		rex();
		if(bc(i->s.imm)) {
			gen2(0x83, (3<<6)|(rm<<3)|RAX);
			genb(i->s.imm);
		} else {
			gen2(0x81, (3<<6)|(rm<<3)|RAX);
			genw(i->s.imm);
		}
		opwst(i, Ostw, RAX);
		return;
	}
	if(bc(i->s.imm)) {
		opwst(i, 0x83, rm);
		genb(i->s.imm);
		return;
	}
	opwst(i, 0x81, rm);
	genw(i->s.imm);
}

/* byte (8-bit): dst = mid OP src; op2 is the byte "r/m,reg" opcode */
static void
arithb(Inst *i, int op2)
{
	if(UXSRC(i->add) == SRC(AIMM))
		urk("arithb/imm");
	if(i->add&ARM) {
		midw(i, Oldb, RAX);
		opwldw(i, op2|2, RAX);
		opwstw(i, Ostb, RAX);
		return;
	}
	opwldw(i, Oldb, RAX);
	opwstw(i, op2, RAX);
}

/* shift word (32-bit): value=mid, count=src (CL); op = 0xd3 /digit */
static void
shiftw(Inst *i, int digit)
{
	midw(i, Oldw, RAX);
	opwldw(i, Oldw, RCX);			/* count -> ecx (CL) */
	gen2(0xd3, (3<<6)|(digit<<3)|RAX);
	opwstw(i, Ostw, RAX);
}

/* shift byte (8-bit): op = 0xd2 /digit */
static void
shiftb(Inst *i, int digit)
{
	midw(i, Oldb, RAX);
	opwldw(i, Oldw, RCX);
	gen2(0xd2, (3<<6)|(digit<<3)|RAX);
	opwstw(i, Ostb, RAX);
}

static int
swapbraop(int b)
{
	switch(b) {
	case Ojgel: return Ojlel;
	case Ojlel: return Ojgel;
	case Ojgtl: return Ojltl;
	case Ojltl: return Ojgtl;
	case Ojael: return Ojbel;
	case Ojbel: return Ojael;
	case Ojhil: return Ojbl;
	case Ojbl:  return Ojhil;
	}
	return b;
}

/* word conditional branch: flags = S - M, branch jmp to d.ins */
static void
cbra(Inst *i, int jmp)
{
	schedcheck(i);
	midw(i, Oldw, RAX);			/* m -> eax */
	if(UXSRC(i->add) == SRC(AIMM)) {
		cmpl(RAX, i->s.imm);		/* eax(m) - imm(s) -> swap */
		jmp = swapbraop(jmp);
	} else
		opwldw(i, Ocmpw, RAX);		/* cmp [s], eax  -> s - m */
	genb(0x0f);
	rbra(patch[i->d.ins-mod->prog], jmp);
}

static void
cbrab(Inst *i, int jmp)
{
	schedcheck(i);
	midw(i, Oldb, RAX);
	if(UXSRC(i->add) == SRC(AIMM))
		urk("cbrab/imm");
	opwldw(i, Ocmpb, RAX);
	genb(0x0f);
	rbra(patch[i->d.ins-mod->prog], jmp);
}

/* big (64-bit) conditional branch */
static void
cbral(Inst *i, int jmp)
{
	schedcheck(i);
	mid(i, Oldw, RAX);
	if(UXSRC(i->add) == SRC(AIMM)) {
		rex();				/* 64-bit cmp rax, imm32 (sign-extended) */
		if(bc(i->s.imm)) {
			gen2(0x83, (3<<6)|(7<<3)|RAX);
			genb(i->s.imm);
		} else {
			gen2(Ocmpi, (3<<6)|(7<<3)|RAX);
			genw(i->s.imm);
		}
		jmp = swapbraop(jmp);
	} else
		opwld(i, Ocmpw, RAX);		/* cmp [s], rax (64-bit) */
	genb(0x0f);
	rbra(patch[i->d.ins-mod->prog], jmp);
}

/*
 * Block copy via `rep movsb`.  Source address arrives in RAX.  rep movsb uses
 * RSI/RDI/RCX, and RSI/RDI are RFP/RMP (live Dis state), so reload them from R
 * afterwards.  Count is the word middle operand (or none for a fixed copy).
 */
static void
movmem(Inst *i)
{
	opwst(i, Olea, RBX);			/* dst addr -> rbx (uses RTA, not RAX/RCX) */
	midw(i, Oldw, RCX);			/* byte count (word) -> ecx */
	rex(); gen2(0x89, (3<<6)|(RAX<<3)|RSI);	/* mov rsi, rax (src) */
	rex(); gen2(0x89, (3<<6)|(RBX<<3)|RDI);	/* mov rdi, rbx (dst) */
	genb(Ocld);
	genb(0xf3); genb(0xa4);			/* rep movsb */
	con((uintptr)&R, RTMP);			/* restore RFP/RMP from R */
	modrm(Oldw, O(REG, FP), RTMP, RFP);
	modrm(Oldw, O(REG, MP), RTMP, RMP);
}

/* array indexing: shift = log2(elemsize) for fixed sizes; dynsize uses Type.size */
static void
indarr(Inst *i, int shift, int dynsize)
{
	opwld(i, Oldw, RAX);			/* array pointer A(s) -> rax (8-byte) */
	cmpqH(RAX);
	trapif(Ojeqb, bounds);			/* a == H -> exBounds */
	opwstw(i, Oldw, RCX);			/* index W(d) -> ecx */
	modrmw(Oldw, O(Array, len), RAX, RDX);	/* len (int) -> edx */
	gen2(0x39, (3<<6)|(RDX<<3)|RCX);	/* cmp ecx, edx  (index - len) */
	trapif(Ojaeb, bounds);			/* index >= len (unsigned) -> exBounds */
	if(dynsize) {
		modrm(Oldw, O(Array, t), RAX, RDX);	/* type ptr (8-byte) */
		modrmw(Oldw, O(Type, size), RDX, RDX);	/* size (int) -> edx */
		rex(); genb(0x0f); gen2(0xaf, (3<<6)|(RCX<<3)|RDX);	/* imul rcx, rdx */
		modrm(Oldw, O(Array, data), RAX, RAX);	/* data ptr (8-byte) */
		rex(); gen2(0x01, (3<<6)|(RCX<<3)|RAX);	/* add rax, rcx */
	} else {
		modrm(Oldw, O(Array, data), RAX, RAX);	/* data ptr (8-byte) */
		rex();
		gen2(Olea, (0<<6)|(RAX<<3)|4);		/* lea rax, [SIB] */
		genb((shift<<6)|(RCX<<3)|RAX);		/* scale=2^shift, index=rcx, base=rax */
	}
	mid(i, Ostw, RAX);			/* T(m) = element address (8-byte) */
}

/* ---------------------------------------------------------------------- *
 *  Integer multiply / divide / modulo and the long/logical shifts.
 *  x86 imul/idiv mirror the interpreter's C `*` `/` `%` exactly (truncating
 *  division toward zero, and — like the interpreter on this host — a SIGFPE on
 *  divide-by-zero or INT_MIN/-1, since xec.c divides with raw C too).  aarch64
 *  punts the divides (sdiv can't trap), so there is no aarch64 reference for
 *  these; the reference is the x86 interpreter, which these match bit-for-bit.
 * ---------------------------------------------------------------------- */

/* D = M * S (signed).  sz: 0 = 32-bit word, 1 = 64-bit big. */
static void
muls(Inst *i, int sz)
{
	midn(i, Oldw, RAX, sz);			/* M -> rax/eax */
	opwldn(i, Oldw, RCX, sz);		/* S -> rcx/ecx (con() for AIMM) */
	if(sz)
		rex();
	genb(0x0f); gen2(0xaf, (3<<6)|(RAX<<3)|RCX);	/* imul rax, rcx */
	opwstn(i, Ostw, RAX, sz);
}

/* byte multiply: low 8 bits of the product depend only on the low bytes, so a
 * 32-bit imul of the byte-loaded operands and an 8-bit store is exact. */
static void
mulb(Inst *i)
{
	midw(i, Oldb, RAX);
	opwldw(i, Oldb, RCX);
	genb(0x0f); gen2(0xaf, (3<<6)|(RAX<<3)|RCX);
	opwstw(i, Ostb, RAX);
}

/* signed divide.  rem: 0 -> quotient (rax), 1 -> remainder (rdx, moved to rax
 * before the store so an indirect dst — which uses RTA=rdx as its base — can't
 * clobber it). */
static void
divs(Inst *i, int sz, int rem)
{
	midn(i, Oldw, RAX, sz);			/* dividend -> rax/eax */
	opwldn(i, Oldw, RCX, sz);		/* divisor  -> rcx/ecx */
	if(sz)
		rex();
	genb(Ocdq);				/* cdq/cqo: sign-extend rax into rdx */
	if(sz)
		rex();
	gen2(0xf7, (3<<6)|(7<<3)|RCX);		/* idiv rcx/ecx (/7) */
	if(rem) {
		if(sz)
			rex();
		gen2(0x89, (3<<6)|(RDX<<3)|RAX);	/* mov rax, rdx */
	}
	opwstn(i, Ostw, RAX, sz);
}

/* byte divide/modulo.  Limbo `byte` is unsigned 0..255, so zero-extend both
 * operands; a 32-bit idiv of two non-negative values is the unsigned result. */
static void
divb(Inst *i, int rem)
{
	midw(i, Oldb, RAX);
	genb(0x0f); gen2(Omovzxb, (3<<6)|(RAX<<3)|RAX);	/* movzbl eax, al */
	opwldw(i, Oldb, RCX);
	genb(0x0f); gen2(Omovzxb, (3<<6)|(RCX<<3)|RCX);	/* movzbl ecx, cl */
	genb(Ocdq);					/* edx = 0 (eax >= 0) */
	gen2(0xf7, (3<<6)|(7<<3)|RCX);			/* idiv ecx */
	if(rem)
		gen2(0x89, (3<<6)|(RDX<<3)|RAX);	/* mov eax, edx */
	opwstw(i, Ostb, RAX);
}

/* 64-bit shift: value V(m) -> rax, count W(s) -> cl.  digit picks shl(4)/shr(5)/
 * sar(7).  The CPU masks the count to 6 bits exactly as C `<<`/`>>` do here. */
static void
shiftl(Inst *i, int digit)
{
	mid(i, Oldw, RAX);
	opwldw(i, Oldw, RCX);			/* count is a word */
	rex(); gen2(0xd3, (3<<6)|(digit<<3)|RAX);
	opwst(i, Ostw, RAX);
}

/* ---------------------------------------------------------------------- *
 *  Floating point (SSE2 scalar double).  REAL is an 8-byte host double, so the
 *  generated SSE matches the interpreter's C double arithmetic bit-for-bit
 *  (same rounding, same NaN propagation).  xmm0/xmm1/xmm2 are scratch (volatile
 *  on SysV) and hold no value across Dis instructions.
 * ---------------------------------------------------------------------- */
#define	FSIGNBIT	((uintptr)0x8000000000000000ULL)
#define	FHALF		((uintptr)0x3FE0000000000000ULL)	/* 0.5 */

/* movsd between xmm `xr` and [base+disp]: op 0x10 loads xmm<-mem, 0x11 stores. */
static void
fmem(int op, uintptr disp, int base, int xr)
{
	genb(0xf2); genb(0x0f);
	modrmw(op, disp, base, xr);
}

static void
fopwld(Inst *i, int xr)				/* F(s) -> xmm xr */
{
	switch(UXSRC(i->add)) {
	default:
		urk("fopwld");
	case SRC(AFP):
		fmem(0x10, i->s.ind, RFP, xr); return;
	case SRC(AMP):
		fmem(0x10, i->s.ind, RMP, xr); return;
	case SRC(AIND|AFP):
		modrm(Oldw, i->s.i.f, RFP, RTA);
		fmem(0x10, i->s.i.s, RTA, xr); return;
	case SRC(AIND|AMP):
		modrm(Oldw, i->s.i.f, RMP, RTA);
		fmem(0x10, i->s.i.s, RTA, xr); return;
	}
}

static void
fopwst(Inst *i, int xr)				/* xmm xr -> F(d) */
{
	switch(UXDST(i->add)) {
	default:
		urk("fopwst");
	case DST(AFP):
		fmem(0x11, i->d.ind, RFP, xr); return;
	case DST(AMP):
		fmem(0x11, i->d.ind, RMP, xr); return;
	case DST(AIND|AFP):
		modrm(Oldw, i->d.i.f, RFP, RTA);
		fmem(0x11, i->d.i.s, RTA, xr); return;
	case DST(AIND|AMP):
		modrm(Oldw, i->d.i.f, RMP, RTA);
		fmem(0x11, i->d.i.s, RTA, xr); return;
	}
}

static void
fmid(Inst *i, int xr)				/* F(m) -> xmm xr (defaults to dst) */
{
	switch(i->add&ARM) {
	case AXINF:
		fmem(0x10, i->reg, RFP, xr); return;
	case AXINM:
		fmem(0x10, i->reg, RMP, xr); return;
	case AXIMM:
		urk("fmid/imm"); return;
	default:
		switch(UXDST(i->add)) {
		default:
			urk("fmid");
		case DST(AFP):
			fmem(0x10, i->d.ind, RFP, xr); return;
		case DST(AMP):
			fmem(0x10, i->d.ind, RMP, xr); return;
		case DST(AIND|AFP):
			modrm(Oldw, i->d.i.f, RFP, RTA);
			fmem(0x10, i->d.i.s, RTA, xr); return;
		case DST(AIND|AMP):
			modrm(Oldw, i->d.i.f, RMP, RTA);
			fmem(0x10, i->d.i.s, RTA, xr); return;
		}
	}
}

static void
fmovq(uintptr v, int xr)			/* movq xmm xr, imm64 (via rax) */
{
	con(v, RAX);
	genb(0x66); rex(); genb(0x0f); gen2(0x6e, (3<<6)|(xr<<3)|RAX);
}

/* xmm dst OP= xmm src; op is an F2-prefixed scalar-double opcode byte. */
static void
fsse(int op, int dst, int src)
{
	genb(0xf2); genb(0x0f); gen2(op, (3<<6)|(dst<<3)|src);
}

static void
arithf(Inst *i, int op)				/* F(d) = F(m) OP F(s) */
{
	fmid(i, 1);				/* xmm1 = F(m) */
	fopwld(i, 0);				/* xmm0 = F(s) */
	fsse(op, 1, 0);				/* xmm1 OP= xmm0 */
	fopwst(i, 1);
}

/*
 * real -> integer: replicate the interpreter's round-half-away-from-zero
 * (f<0 ? f-.5 : f+.5) then truncate toward zero.  bias = copysign(0.5, f) =
 * (f & signbit) | 0.5, computed branchlessly; cvttsd2si truncates.  sz: 0 ->
 * W(d) (32-bit), 1 -> V(d) (64-bit).
 */
static void
cvtfi(Inst *i, int sz)
{
	fopwld(i, 0);				/* xmm0 = f */
	fmovq(FSIGNBIT, 1);			/* xmm1 = signbit */
	genb(0x66); genb(0x0f); gen2(0x54, (3<<6)|(1<<3)|0);	/* andpd xmm1, xmm0 */
	fmovq(FHALF, 2);			/* xmm2 = 0.5 */
	genb(0x66); genb(0x0f); gen2(0x56, (3<<6)|(1<<3)|2);	/* orpd  xmm1, xmm2 */
	fsse(0x58, 0, 1);			/* addsd xmm0, xmm1 (f + bias) */
	genb(0xf2); if(sz) rex(); genb(0x0f);
	gen2(0x2c, (3<<6)|(RAX<<3)|0);		/* cvttsd2si rax/eax, xmm0 */
	opwstn(i, Ostw, RAX, sz);
}

/*
 * FP conditional branch.  ucomisd F(s), F(m) sets CF/ZF/PF (PF = unordered).
 * The ordered comparisons (<,<=,==) must be FALSE on a NaN, so they are guarded
 * by `jp` over the branch; > and >= are naturally false on unordered (CF=1);
 * != is TRUE on unordered (an extra `jp` to the target).
 */
static void
cbraf(Inst *i, int op)
{
	uintptr d;

	schedcheck(i);
	fopwld(i, 0);				/* F(s) -> xmm0 */
	fmid(i, 1);				/* F(m) -> xmm1 */
	genb(0x66); genb(0x0f); gen2(0x2e, (3<<6)|(0<<3)|1);	/* ucomisd xmm0, xmm1 */
	d = patch[i->d.ins-mod->prog];
	switch(op) {
	case IBEQF:
		gen2(Ojpb, 6); genb(0x0f); rbra(d, Ojeql); break;
	case IBLTF:
		gen2(Ojpb, 6); genb(0x0f); rbra(d, Ojbl); break;
	case IBLEF:
		gen2(Ojpb, 6); genb(0x0f); rbra(d, Ojbel); break;
	case IBGTF:
		genb(0x0f); rbra(d, Ojhil); break;
	case IBGEF:
		genb(0x0f); rbra(d, Ojael); break;
	case IBNEF:
		genb(0x0f); rbra(d, Ojpl);	/* unordered -> branch */
		genb(0x0f); rbra(d, Ojnel);	/* != -> branch */
		break;
	}
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
		if(UXSRC(i->add) == SRC(AIMM)) {
			opwstw(i, Omov, 0);		/* mov dword [d], imm32 */
			genw(i->s.imm);
			break;
		}
		opwldw(i, Oldw, RAX);
		opwstw(i, Ostw, RAX);
		break;
	case IMOVB:
		opwldw(i, Oldb, RAX);
		opwstw(i, Ostb, RAX);
		break;
	case IMOVL:
	case IMOVF:				/* 8-byte bit-copy (real or big) */
		opwld(i, Oldw, RAX);
		opwst(i, Ostw, RAX);
		break;
	case ILEA:
		opwld(i, Olea, RAX);
		opwst(i, Ostw, RAX);
		break;
	case IMOVM:
		opwld(i, Olea, RAX);			/* src addr -> rax */
		movmem(i);
		break;
	case IHEADM:
		opwld(i, Oldw, RAX);			/* list pointer */
		cmpqH(RAX);
		trapif(Ojeqb, nullity);
		modrm(Olea, OA(List, data), RAX, RAX);	/* &list->data */
		movmem(i);
		break;

	/* ---- conversions ---- */
	case ICVTBW:
		opwldw(i, Oldb, RAX);
		genb(0x0f); gen2(Omovzxb, (3<<6)|(RAX<<3)|RAX);	/* movzbl */
		opwstw(i, Ostw, RAX);
		break;
	case ICVTWB:
		opwldw(i, Oldw, RAX);
		opwstw(i, Ostb, RAX);
		break;
	case ICVTWL:				/* sign-extend int -> big */
		opwldw(i, Oldw, RAX);
		rex(); gen2(0x63, (3<<6)|(RAX<<3)|RAX);	/* movsxd rax, eax */
		opwst(i, Ostw, RAX);
		break;
	case ICVTLW:				/* truncate big -> int */
		opwld(i, Oldw, RAX);
		opwstw(i, Ostw, RAX);
		break;

	/* ---- word arithmetic ---- */
	case IADDW: arithw(i, 0x01, 0); break;
	case ISUBW: arithw(i, 0x29, 5); break;
	case IORW:  arithw(i, 0x09, 1); break;
	case IANDW: arithw(i, 0x21, 4); break;
	case IXORW: arithw(i, Oxor, 6); break;
	case ISHLW: shiftw(i, 4); break;
	case ISHRW: shiftw(i, 7); break;	/* arithmetic (signed) */

	/* ---- byte arithmetic ---- */
	case IADDB: arithb(i, 0x00); break;
	case ISUBB: arithb(i, 0x28); break;
	case IORB:  arithb(i, 0x08); break;
	case IANDB: arithb(i, 0x20); break;
	case IXORB: arithb(i, 0x30); break;
	case ISHLB: shiftb(i, 4); break;
	case ISHRB: shiftb(i, 5); break;	/* logical (unsigned) */

	/* ---- long (big) arithmetic, 64-bit ---- */
	case IADDL: arithl(i, 0x01, 0); break;
	case ISUBL: arithl(i, 0x29, 5); break;
	case IORL:  arithl(i, 0x09, 1); break;
	case IANDL: arithl(i, 0x21, 4); break;
	case IXORL: arithl(i, Oxor, 6); break;

	/* ---- length ---- */
	case ILENA: {
		uchar *cp;
		opwld(i, Oldw, RBX);
		con(0, RAX);
		cmpqH(RBX);
		gen2(Ojeqb, 0); cp = code - 1;
		modrmw(Oldw, O(Array, len), RBX, RAX);	/* len (int) */
		*cp = code - cp - 1;
		opwstw(i, Ostw, RAX);
		break;
	}
	case ILENC: {
		uchar *cp, *cp2;
		opwld(i, Oldw, RBX);
		con(0, RAX);
		cmpqH(RBX);
		gen2(Ojeqb, 0); cp = code - 1;
		modrmw(Oldw, O(String, len), RBX, RAX);	/* len (int) */
		cmpl(RAX, 0);
		gen2(Ojgeb, 0); cp2 = code - 1;
		gen2(Oneg, (3<<6)|(3<<3)|RAX);		/* neg eax (abs of rune-count) */
		*cp2 = code - cp2 - 1;
		*cp = code - cp - 1;
		opwstw(i, Ostw, RAX);
		break;
	}
	case ILENL: {
		uchar *loop, *cp;
		con(0, RAX);
		opwld(i, Oldw, RBX);
		loop = code;
		cmpqH(RBX);
		gen2(Ojeqb, 0); cp = code - 1;
		gen2(Oincrm, (3<<6)|(0<<3)|RAX);	/* inc eax */
		modrm(Oldw, O(List, tail), RBX, RBX);	/* rbx = list->tail (8-byte) */
		gen2(Ojmpb, loop - code - 2);
		*cp = code - cp - 1;
		opwstw(i, Ostw, RAX);
		break;
	}

	/* ---- array indexing ---- */
	case IINDW: indarr(i, 2, 0); break;	/* word = 4 bytes -> scale 4 */
	case IINDL:
	case IINDF: indarr(i, 3, 0); break;	/* big/real = 8 bytes -> scale 8 */
	case IINDB: indarr(i, 0, 0); break;
	case IINDX: indarr(i, 0, 1); break;

	/* ---- conditional branches (native) ---- */
	case IBEQW: cbra(i, Ojeql); break;
	case IBNEW: cbra(i, Ojnel); break;
	case IBLTW: cbra(i, Ojltl); break;
	case IBLEW: cbra(i, Ojlel); break;
	case IBGTW: cbra(i, Ojgtl); break;
	case IBGEW: cbra(i, Ojgel); break;
	case IBEQB: cbrab(i, Ojeql); break;
	case IBNEB: cbrab(i, Ojnel); break;
	case IBLTB: cbrab(i, Ojbl); break;	/* byte compares are unsigned */
	case IBLEB: cbrab(i, Ojbel); break;
	case IBGTB: cbrab(i, Ojhil); break;
	case IBGEB: cbrab(i, Ojael); break;
	case IBEQL: cbral(i, Ojeql); break;
	case IBNEL: cbral(i, Ojnel); break;
	case IBLTL: cbral(i, Ojltl); break;
	case IBLEL: cbral(i, Ojlel); break;
	case IBGTL: cbral(i, Ojgtl); break;
	case IBGEL: cbral(i, Ojgel); break;
	case IJMP:
		schedcheck(i);
		rbra(patch[i->d.ins-mod->prog], Ojmp);
		break;

	case IMCALL:
		if((i->add&ARM) == AXIMM)
			commcall(i);
		else
			punt(i, SRCOP|DSTOP|THREOP|WRTPC|NEWPC, optab[i->op]);
		break;

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
	case ICASEC:
		comcasec(i);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case IRET:
		punt(i, TCHECK|NEWPC, optab[i->op]);
		break;
	case ICALL:
		punt(i, SRCOP|DBRAN|WRTPC|NEWPC, optab[i->op]);
		break;

	/* ---- channel ops (punt; never hand-roll the alt value offset) ---- */
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
	case IEXIT:
		punt(i, 0, optab[i->op]);
		break;
	case IRAISE:
		punt(i, SRCOP|WRTPC|NEWPC, optab[i->op]);
		break;
	case IFRAME:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;
	case IMFRAME:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;

	/* ---- pointer moves & list ops (refcounted) -> punt ---- */
	case IMOVP: case IMOVMP: case IHEADP: case IHEADMP: case ITAIL:
	case IHEADB: case IHEADW: case IHEADL: case IHEADF:
	case ICONSB: case ICONSW: case ICONSL: case ICONSF:
	case ICONSM: case ICONSMP: case ICONSP:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;

	/* ---- allocation, slices, loads, string/array conversions -> punt ---- */
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

	/* ---- multiply/divide/modulo + long/logical shifts (native) ---- */
	case IMULW: muls(i, 0); break;
	case IMULL: muls(i, 1); break;
	case IMULB: mulb(i); break;
	case IDIVW: divs(i, 0, 0); break;
	case IMODW: divs(i, 0, 1); break;
	case IDIVL: divs(i, 1, 0); break;
	case IMODL: divs(i, 1, 1); break;
	case IDIVB: divb(i, 0); break;
	case IMODB: divb(i, 1); break;
	case ILSRW: shiftw(i, 5); break;	/* logical (unsigned) shift right, word */
	case ISHLL: shiftl(i, 4); break;
	case ISHRL: shiftl(i, 7); break;	/* V signed -> arithmetic */
	case ILSRL: shiftl(i, 5); break;	/* logical (unsigned) shift right, big */

	/* ---- floating point (native, scalar double) ---- */
	case IADDF: arithf(i, 0x58); break;	/* addsd */
	case ISUBF: arithf(i, 0x5c); break;	/* subsd */
	case IMULF: arithf(i, 0x59); break;	/* mulsd */
	case IDIVF: arithf(i, 0x5e); break;	/* divsd */
	case INEGF:				/* F(d) = -F(s) */
		fopwld(i, 0);
		fmovq(FSIGNBIT, 1);
		genb(0x66); genb(0x0f); gen2(0x57, (3<<6)|(0<<3)|1);	/* xorpd xmm0, xmm1 */
		fopwst(i, 0);
		break;
	case ICVTWF:				/* F(d) = (real) W(s)  int32 -> double */
		opwldw(i, Oldw, RAX);
		genb(0xf2); genb(0x0f); gen2(0x2a, (3<<6)|(0<<3)|RAX);	/* cvtsi2sd xmm0, eax */
		fopwst(i, 0);
		break;
	case ICVTLF:				/* F(d) = (real) V(s)  int64 -> double */
		opwld(i, Oldw, RAX);
		genb(0xf2); rex(); genb(0x0f); gen2(0x2a, (3<<6)|(0<<3)|RAX);	/* cvtsi2sd xmm0, rax */
		fopwst(i, 0);
		break;
	case ICVTFW: cvtfi(i, 0); break;	/* W(d) = round(F(s)) */
	case ICVTFL: cvtfi(i, 1); break;	/* V(d) = round(F(s)) */
	case IBEQF: case IBNEF: case IBLTF: case IBLEF: case IBGTF: case IBGEF:
		cbraf(i, i->op);
		break;

	/* ---- fixed point, exp, carry: still interpreted ---- */
	case IMOVPC:
		punt(i, DSTOP, optab[i->op]);
		break;
	case IADDC:
	case IMULX: case IDIVX: case ICVTXX:
	case IMULX0: case IDIVX0: case ICVTXX0:
	case IMULX1: case IDIVX1: case ICVTXX1:
	case ICVTFX: case ICVTXF:
	case IEXPW: case IEXPL: case IEXPF:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
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

	comvec = jitcode(32);
	if(comvec == nil)
		error(exNomem);
	code = (uchar*)comvec;

	genb(Opushl+RBX);
	genb(Opushl+RCX);
	genb(Opushl+RDX);
	genb(Opushl+RSI);
	genb(Opushl+RDI);
	con((uintptr)&R, RTMP);
	modrm(Oldw, O(REG, FP), RTMP, RFP);
	modrm(Oldw, O(REG, MP), RTMP, RMP);
	modrm(Ojmprm, O(REG, PC), RTMP, 4);	/* jmp *[R.PC] */

	segflush(comvec, 32);
}

static void
patchex(Module *m, uintptr *p)
{
	Handler *h;
	Except *e;

	if((h = m->htab) == nil)
		return;
	for( ; h->etab != nil; h++){
		h->pc1 = p[h->pc1];
		h->pc2 = p[h->pc2];
		for(e = h->etab; e->s != nil; e++)
			e->pc = p[e->pc];
		if(e->pc != -1)
			e->pc = p[e->pc];
	}
}

int
compile(Module *m, int size, Modlink *ml)
{
	uintptr v;
	Modl *e;
	Link *l;
	int i, n;
	uchar *s, *tmp;

	base = nil;
	patch = mallocz(size*sizeof(*patch), 0);
	tmp = mallocz(4096*sizeof(uchar), 0);
	if(patch == nil || tmp == nil)
		goto bad;

	preamble();

	mod = m;
	n = 0;
	pass = 0;
	nlit = 0;

	for(i = 0; i < size; i++) {
		code = tmp;
		comp(&m->prog[i]);
		patch[i] = n;
		n += code - tmp;
	}

	for(i = 0; i < nelem(mactab); i++) {
		code = tmp;
		mactab[i].gen();
		macro[mactab[i].idx] = n;
		n += code - tmp;
	}

	n = (n+7)&~7;

	base = jitcode(n + nlit*sizeof(uintptr));
	if(base == nil){
		static int warned;
		if(warned++ == 0)
			print("jit: arena full at %s; this and later modules run interpreted\n", m->name);
		goto bad;
	}

	if(cflag > 3)
		print("dis=%5d amd64=%5d asm=%.8zx lit=%d: %s\n",
			size, n, (uintptr)base, nlit, m->name);

	pass++;
	nlit = 0;
	litpool = (uintptr*)(base+n);
	code = base;

	for(i = 0; i < size; i++) {
		s = code;
		comp(&m->prog[i]);
		if(patch[i] != s - base)
			urk("phase error");
		if(cflag > 4) {
			print("%D\n", &m->prog[i]);
			das(s, code-s);
		}
	}

	for(i = 0; i < nelem(mactab); i++) {
		s = code;
		mactab[i].gen();
		if(macro[mactab[i].idx] != s - base)
			urk("mac phase error");
	}

	v = (uintptr)base;
	for(l = m->ext; l->name; l++)
		l->u.pc = (Inst*)(v+patch[l->u.pc-m->prog]);
	if(ml != nil) {
		e = &ml->links[0];
		for(i = 0; i < ml->nlinks; i++) {
			e->u.pc = (Inst*)(v+patch[e->u.pc-m->prog]);
			e++;
		}
	}
	patchex(m, patch);
	m->entry = (Inst*)(v+patch[mod->entry-mod->prog]);
	free(patch);
	free(tmp);
	free(m->prog);
	m->prog = (Inst*)base;
	m->compiled = 1;
	segflush(base, n);
	return 1;
bad:
	uncase(m, size);
	free(patch);
	free(tmp);
	free(base);
	return 0;
}
