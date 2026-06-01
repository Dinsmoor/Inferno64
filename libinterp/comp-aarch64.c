/*
 * aarch64 code generator for Inferno interpreter
 * Based on comp-arm.c for ARM32
 */

#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"

/*
 * to do:
 *	eliminate litpool?
 *	enable and check inline FP code (not much point with fpemu)
 */

#define	RESCHED 1	/* check for interpreter reschedule */
#define	SOFTFP	1

enum
{
	R0	= 0,
	R1	= 1,
	R2	= 2,
	R3	= 3,
	R4	= 4,
	R5	= 5,
	R6	= 6,
	R7	= 7,
	R8	= 8,
	R9	= 9,
	R10	= 10,
	R11	= 11,
	R12	= 12,
	R13	= 13,
	R14	= 14,
	R15	= 15,

	RLINK	= 14,

	RFP	= R9,		/* Frame Pointer */
	RMP	= R8,		/* Module Pointer */
	RTA	= R7,		/* Intermediate address for double indirect */
	RCON	= R6,		/* Constant builder */
	RREG	= R5,		/* Pointer to REG */
	RA3	= R4,		/* gpr 3 */
	RA2	= R3,		/* gpr 2 2+3 = L */
	RA1	= R2,		/* gpr 1 */
	RA0	= R1,		/* gpr 0 0+1 = L */


	FA2	= 2,		/* Floating */
	FA3	= 3,
	FA4	= 4,
	FA5	= 5,

	EQ	= 0,
	NE	= 1,
	CS	= 2,
	CC	= 3,
	MI	= 4,
	PL	= 5,
	VS	= 6,
	VC	= 7,
	HI	= 8,
	LS	= 9,
	GE	= 10,
	LT	= 11,
	GT	= 12,
	LE	= 13,
	AL	= 14,
	NV	= 15,

	HS	= CS,
	LO	= CC,

	/* AArch64 opcode classes */
	Add	= 0,
	Sub	= 1,
	Mul	= 4,
	Udiv	= 5,
	Lsl	= 6,
	Lsr	= 7,
	Asr	= 8,

	Eor	= 0,
	Orr1	= 1,
	Orn	= 3,
	Eor2	= 3,	/* Uadv, also used as Orn */

	And	= 0,
	Bic	= 2,
	Mvn	= 3,

	Adf	= 0,		/* FP add */
	Muf	= 1,		/* FP mul */
	Suf	= 2,		/* FP sub */
	Rsf	= 3,		/* FP sub with negated src */
	Dvf	= 4,		/* FP div */
	Rdf	= 5,		/* FP div with negated src */
	Rmf	= 8,		/* FP recp */

	Flt	= 0,		/* FP compare -> flags */
	Fix	= 1,		/* FP int convert */
	Flr	= 3,		/* FP round */
	Cmp	= 4,		/* FP compare */
	Nop	= 16,

	Lea	= 100,		/* macro memory ops */
	Ldw,
	Ldb,
	Ldh,
	Stw,
	Stb,
	Stf,
	Ldf,

	/* ARM32-style operation codes (for compatibility macros) */
	Cmp	= 10,
	Cmn	= 11,

	Blo	= 0,	/* offset of low word in big */
	Bhi	= 4,	/* offset of high word in big */

	Lg2Rune	= 2,

	NCON	= (0xFFC-8)/8,

	SRCOP	= (1<<0),
	DSTOP	= (1<<1),
	WRTPC	= (1<<2),
	TCHECK	= (1<<3),
	NEWPC	= (1<<4),
	DBRAN	= (1<<5),
	THREOP	= (1<<6),

	ANDAND	= 1,
	OROR	= 2,
	EQAND	= 3,

	MacFRP	= 0,
	MacRET,
	MacCASE,
	MacCOLR,
	MacMCAL,
	MacFRAM,
	MacMFRA,
	MacRELQ,
	NMACRO
};

#define BITS(B)				(1ULL<<(B))
#define FITS12(v)	(((long)(v)>=0)&&(((long)(v))<BITS(12)))
#define FITS19(v)	(((long)(v)>=0)&&(((long)(v))<BITS(19)))
#define FITS24(v)	(((long)(v)>=0)&&(((long)(v))<BITS(24)))
#define FITS26(v)	(((long)(v)>=0)&&(((long)(v))<BITS(26)))

/* AArch64 instruction encoding helpers */
#define I32(op, sh0, sh1, sh2, sh3, reg0, reg1, reg2, reg3) \
	(((unsigned long long)(op)<<(sh0)) | \
	 ((unsigned long long)(reg0)<<(sh1)) | \
	 ((unsigned long long)(reg1)<<(sh2)) | \
	 ((unsigned long long)(reg2)<<(sh3)) | \
	 (0ULL))

#define R(op, Rn, Rd, Rm) I32(op, 28, 21, 16, 5, Rn, Rd, 0, Rm)
#define RI(op, Rn, Rd, immlo, Rt, immhi) \
	I32(op, 28, 21, 16, 5, Rn, Rd, (immlo)<<(10) | (Rt)<<(0), (immhi))

/* Data processing (register) */
#define DPR(cond, op, Rn, Rd, Rm) \
	((0xD5032300)|(Rn<<16)|(Rd<<5)|(Rm<<0)|(op<<21))
#define DP(cond, op, Rn, Rd, Rm) DPR(cond, op, Rn, Rd, Rm)

/* Data processing (immediate) */
#define DPI(cond, op, Rn, Rd, immlo, immhi) \
	((0x90000000)|(Rn<<16)|(Rd<<5)|(immlo<<10)|(immhi<<29))
/* ADD (shifted register) */
#define DSR(cond, op, Rn, Rd, Rm, sh) \
	((0x13000000)|(Rn<<16)|(Rd<<5)|(Rm<<0)|(sh<<22)|(op<<30))

/* Move wide */
#define MWW(cond, op, Rd, immn, imm16) \
	((0x12800000)|(Rd<<(5))|(imm16<<(10))|(immn<<(21))|(cond<<29))
/* Simplified MOVZ/MOVK */
#define MOVZ(Rd, imm16, shift) \
	(0x52800000|(Rd<<5)|(imm16<<10)|((shift)<<21))
#define MOVK(Rd, imm16, shift) \
	(0x72800000|(Rd<<5)|(imm16<<10)|((shift)<<21))

/* Load/store single */
#define LSB(cond, sz, V, L, offset, Rt, Rn) \
	((0x38000000|(L<<22)|(Rn<<16)|(Rt<<5))|(offset&0xfff)|(sz<<22))
#define LSW(cond, sz, V, L, offset, Rt, Rn) \
	((0x3C000000|(L<<22)|(Rn<<16)|(Rt<<5))|(offset&0xfff)|(sz<<22))
#define SSW(cond, sz, V, L, offset, Rt, Rn) \
	((0x3C000000|(L<<22)|(Rn<<16)|(Rt<<5))|(offset&0xfff)|(sz<<22))

/* Load/store unsigned immediate */
#define LUI(cond, sz, L, Rt, Rn, imm9) \
	((0x18000000|(L<<22)|(Rn<<16)|(Rt<<5))|(imm9<<10)|(sz<<30))
#define SUI(cond, sz, L, Rt, Rn, imm9) \
	((0x18000000|(L<<22)|(Rn<<16)|(Rt<<5))|(imm9<<10)|(sz<<30))

/* Load/store pair */
#define LSP(cond, L, At, Rt, Rn, imm7) \
	((0x28000000|(L<<22)|(Rn<<16)|(Rt<<5))|(imm7<<15)|(At<<26))
#define SSP(cond, L, At, Rt, Rn, imm7) \
	((0x28000000|(L<<22)|(Rn<<16)|(Rt<<5))|(imm7<<15)|(At<<26))

/* Load register */
#define LR(cond, sz, V, L, Rt, Rn, imm19) \
	((0x18000000|(L<<22)|(Rn<<16)|(Rt<<5))|(imm19<<5)|(sz<<30))

/* Branch */
#define B(cond, imm26) \
	((0x14000000)|(((cond) & 0xF) << 29)|((imm26) & 0x03FFFFFF))
#define CBZ(cond, Rt, label) \
	((0x54000000)|((label) & 0x7FFFF)|((Rt) << 5)|(((cond) & 0xF) << 29))
#define CBNZ(cond, Rt, label) \
	((0x34000000)|((label) & 0x7FFFF)|((Rt) << 5)|(((cond) & 0xF) << 29))

/* Compare and branch */
#define CBRZ(cond, Rt, label) \
	((0x34000000)|((label) & 0x7FFFF)|((Rt) << 5)|(((cond) & 0xF) << 29))

/* TST (branch on register) */
#define TBRZ(cond, V, Rt, Rn, label) \
	((0x32000000)|((label) & 0x7FFFF)|((Rn) << 16)|((Rt) << 5)|(((V) & 3) << 31)|(((cond) & 0xF) << 29))

/* Conditional return */
#define RET(cond) \
	((0xD63F03C0)|(((cond) & 0xF) << 29))

/* Conditional compare */
#define CC(cond, imm5, Rn, Rm) \
	((0x5A000000)|((Rn) << 16)|((Rm) << 0)|((imm5) << 19)|(((cond) & 0xF) << 29))

/* FP operations */
#define FPSADDF(Rn, Rm, Rd) \
	((0x1E201000)|(Rn<<16)|(Rm<<0)|(Rd<<5))
#define FPSUBF(Rn, Rm, Rd) \
	((0x1E201800)|(Rn<<16)|(Rm<<0)|(Rd<<5))
#define FMULF(Rn, Rm, Rd) \
	((0x1E201800)|(Rn<<16)|(Rm<<0)|(Rd<<5))
#define FDIVF(Rn, Rm, Rd) \
	((0x1E202800)|(Rn<<16)|(Rm<<0)|(Rd<<5))
#define FADDF(Rn, Rm, Rd) \
	((0x1E200800)|(Rn<<16)|(Rm<<0)|(Rd<<5))
#define FNEGF(Rd, Rn) \
	((0x1E201000)|(Rn<<16)|(Rd<<5)|0x40000000)
#define FCMPF(Rn, Rm) \
	((0x1E202000)|(Rn<<16)|(Rm<<5))
#define FCSEL(Rn, Rm, Rd, cond) \
	((0x1E202000)|(Rn<<16)|(Rm<<0)|(Rd<<5)|(((cond) & 0xF) << 29))

/* 64-bit doubleword load/store */
#define LDWD(cond, L, Rt, Rn, imm9) \
	((0x18000000|(L<<22)|(Rn<<16)|(Rt<<5))|(imm9<<10)|(6<<30))
#define SDWD(cond, Rt, Rn, imm9) \
	((0x18000000|(1<<22)|(Rn<<16)|(Rt<<5))|(imm9<<10)|(6<<30))

/* Helper macros for AArch64 instruction encoding */
#define BRAW(C, o)	((uint32_t)(((o) & 0x03FFFFFF) | (((uint32_t)(C) & 0xF) << 29)))
#define BRA(C, o)	gen(BRAW((C), (o)))
#define IA(s, o)	(base + (s)[(o)])
#define BRADIS(C, o)	BRA(C, (int32_t)(IA(patch, o) - (uint32_t*)code - 2))
#define BRAMAC(r, o)	BRA(r, (int32_t)(IA(macro, o) - (uint32_t*)code - 2))
#define CALL(o)		gen(BRAW(AL, (uint32_t)(o)-(uint32_t*)code-2) | 0x80000000U)
#define CALLMAC(C,o)	gen(BRAW((C), (int32_t)(IA(macro, o)-(uint32_t*)code-2)) | 0x80000000U)
#define RELPC(pc)	(uint32_t)(base+(pc))
#define BRANCH(C, o)	gen(BRAW(C, ((uint32_t)(o)-(uint32_t*)code-8)>>2))
#define RETURN		DPI(AL, Add, RLINK, R15, 0, 0)
#define CRETURN(C)	DPI(C, Add, RLINK, R15, 0, 0)
#define PATCH(ptr)	*(ptr) = (*(ptr) & ~0x03FFFFFF) | (((uint32_t)code - (uint32_t)(ptr) - 2) & 0x03FFFFFF)

/* Conditional compare/branch helper for ARM-style condition setting */
#define CMP(C, Rn, Rd, ...) \
	gen(DPI(C, 0, (Rn), (Rd), __VA_ARGS__))
#define CMN(C, Rn, Rd, ...) \
	gen(DPI(C, 1<<21, (Rn), (Rd), __VA_ARGS__))
#define CMPI(C, Rn, ...) \
	gen(DPI(C, 0, (Rn), 0, __VA_ARGS__))

#define MOV(src, dst)	DPI(AL, Add, 0, (dst), 0, (src))

/* Branch on immediate - for conditional immediate compare in cbra */
static void
cbrai(int cond, int Rt, int shift, uint32_t label)
{
	/* CMP Wd, #imm12 */
	uint32_t w;
	w = 0x71000000U | (((cond) & 0xF) << 29) | ((Rt) << 5) | (label & 0x3FF);
	gen(w);
}

/*
 * AArch64 doesn't have ARM's rotate-immediate encoding.
 * Instead we use MOVZ/MOVK to load constants into registers.
 */

static	uint32_t*	code;
static	uint32_t*	base;
static	uint32_t*	patch;
static	uint32_t	codeoff;
	static	int	pass;
static	int	puntpc = 1;
static	Module*	mod;
static	uchar*	tinit;
static	uint32_t*	litpool;
static	int	nlit;
static	uint32_t	macro[NMACRO];
	void	(*comvec)(void);
static	void	macfrp(void);
static	void	macret(void);
static	void	maccase(void);
static	void	maccolr(void);
static	void	macmcal(void);
static	void	macfram(void);
static	void	macmfra(void);
static	void	macrelq(void);
static	void movmem(Inst*);
static	void mid(Inst*, int, int);
extern	void	das(ulong*, int);

#define T(r)	*((void**)(R.r))

struct
{
	int	idx;
	void	(*gen)(void);
	char*	name;
} mactab[] =
{
	MacFRP,		macfrp,		"FRP",	/* decrement and free pointer */
	MacRET,		macret,		"RET",	/* return instruction */
	MacCASE,	maccase,	"CASE",	/* case instruction */
	MacCOLR,	maccolr,	"COLR",	/* increment and color pointer */
	MacMCAL,	macmcal,	"MCAL",	/* mcall bottom half */
	MacFRAM,	macfram,	"FRAM",	/* frame instruction */
	MacMFRA,	macmfra,	"MFRA",	/* punt mframe because t->initialize==0 */
	MacRELQ,	macrelq,	"RELQ",	/* reschedule */
};

typedef struct Const Const;
struct Const
{
	ulong	o;
	ulong*	code;
	ulong*	pc;
};

typedef struct Con Con;
struct Con
{
	int	ptr;
	Const	table[NCON];
};
static Con rcon;

static void
rdestroy(void)
{
	destroy(R.s);
}

static void
rmcall(void)
{
	Frame *f;
	Prog *p;

	if((void*)R.dt == H)
		error(exModule);

	f = (Frame*)R.FP;
	if(f == H)
		error(exModule);

	f->mr = nil;
	((void(*)(Frame*))R.dt)(f);
	R.SP = (uchar*)f;
	R.FP = f->fp;
	if(f->t == nil)
		unextend(f);
	else
		freeptrs(f, f->t);
	p = currun();
	if(p->kill != nil)
		error(p->kill);
}

static void
rmfram(void)
{
	Type *t;
	Frame *f;
	uchar *nsp;

	if(R.d == H)
		error(exModule);
	t = (Type*)R.d;
	if(t == H)
		error(exModule);
	nsp = R.SP + t->size;
	if(nsp >= R.TS) {
		R.s = t;
		extend();
		T(d) = R.s;
		return;
	}
	f = (Frame*)R.SP;
	R.SP = nsp;
	f->t = t;
	f->mr = nil;
	initmem(t, f);
	T(d) = f;
}

static void
urk(char *s)
{
	USED(s);
	error(exCompile);	/* production */
	/* panic("compile failed: urk: %s\n", s);	*/ /* debugging */
}

static void
gen(uint32_t w)
{
	*code++ = w;
}

static long
immrot(ulong v)
{
	/* Not used in aarch64 - always use MOVZ/MOVK */
	USED(v);
	return 0;
}

static void
flushcon(int genbr)
{
	int i;
	Const *c;
	ulong disp;

	if(rcon.ptr == 0)
		return;
	if(genbr){
		if(0)print("BR %d(PC)=%8.8lx (len=%d)\n", (rcon.ptr*8+8-8)>>3, code+rcon.ptr+1, rcon.ptr);
		B(AL, (rcon.ptr*8+8-8)>>3);
	}
	c = &rcon.table[0];
	for(i = 0; i < rcon.ptr; i++) {
		if(pass){
			disp = (code - c->code) * sizeof(*code) - 8;
			if(disp >= BITS(24))
				print("INVALID constant range %lud", disp);
			if(0)print("data %8.8lx (%8.8lx, ins=%8.8lx cpc=%8.8lx)\n", code, c->o, *c->code, c->pc);
			/* patch relocated branches */
		}
		*code++ = c->o;
		c++;
	}
	rcon.ptr = 0;
}

static void
flushchk(void)
{
	if(rcon.ptr >= NCON || rcon.ptr > 0 && (code+codeoff+2-rcon.table[0].pc)*sizeof(*code) >= BITS(12)-256){
		if(0)print("flushed constant table: len %ux disp %ld\n", rcon.ptr, (code+codeoff-rcon.table[0].pc)*sizeof(*code)-8);
		flushcon(1);
	}
}

static void
ccon(int cc, ulong o, int r, int opt)
{
	ulong u;
	Const *c;

	/* Try to optimize: MOVZ/MOVK for 16-bit immediate */
	u = o & 0xFFFF;
	if(u == o) {
		DPI(cc, 0, R15, r, 0, 0) | MOVZ(r, u, 0);
		return;
	}
	u = (o >> 16) & 0xFFFF;
	if(u == 0) {
		/* Already handled above */
		return;
	}
	u = o & 0xFFFF;
	if(u == 0) {
		DPI(cc, 0, R15, r, 0, 0) | MOVZ(r, o>>16, 1);
		return;
	}
	/* Need MOVZ + MOVK for 32-bit value */
	flushchk();
	c = &rcon.table[rcon.ptr++];
	c->o = o;
	c->code = code;
	c->pc = code+codeoff;

	/* Emit MOVZ + MOVK for full 32-bit value */
	*code++ = MOVZ(r, o & 0xFFFF, 0);
	*code++ = MOVK(r, (o >> 16) & 0xFFFF, 1);
}

static void
memc(int c, int inst, ulong disp, int rm, int r)
{
	int bit;

	if(inst == Lea) {
		if(FITS12(disp) && disp >= 0) {
			if(disp != 0 || rm != r)
				DPI(c, 0, rm, r, 0, 0) |= (0 << 22) | (disp & 0x3FF) | (rm << 16) | (r << 5);
			/* ADD Rd, Rn, #imm12 encoded as ADD with 32-bit immediate */
			return;
		}
		if(FITS12(-disp) && -disp >= 0) {
			/* SUB */
			/* Need to handle properly */
			return;
		}
		bit = 0;
		ccon(c, disp, RCON, 1);
		DP(c, Add, RCON, r, rm);
		return;
	}

	/* Direct load/store with small offset */
	if(FITS12(disp) && disp >= 0) {
		switch(inst) {
		case Ldw:
			/* LDUR Wd, [Rn, #imm9] */
			*code++ = (0x3C000000 | (disp&0x1FF) | (rm << 16) | (r << 5) | (0 << 30));
			break;
		case Ldb:
			/* LDUR Bb, [Rn, #imm9] */
			*code++ = (0x3A000000 | (disp&0x1FF) | (rm << 16) | (r << 5));
			break;
		case Stw:
			/* STUR Ws, [Rn, #imm9] */
			*code++ = (0x3C000000 | (disp&0x1FF) | (rm << 16) | (r << 5) | (0 << 30));
			break;
		case Stb:
			/* STUR Bs, [Rn, #imm9] */
			*code++ = (0x3A000000 | (disp&0x1FF) | (rm << 16) | (r << 5));
			break;
		}
		return;
	}

	ccon(c, disp, RCON, 1);
	switch(inst) {
	case Ldw:
		/* LDUR Wd, [RCON] */
		*code++ = (0x3C000000 | (r << 16) | (RCON << 5) | (0 << 30));
		break;
	case Ldb:
		/* LDUR Bb, [RCON] */
		*code++ = (0x3A000000 | (r << 16) | (RCON << 5));
		break;
	case Stw:
		/* STUR Ws, [RCON] */
		*code++ = (0x3C000000 | (r << 16) | (RCON << 5) | (0 << 30));
		break;
	case Stb:
		/* STUR Bs, [RCON] */
		*code++ = (0x3A000000 | (r << 16) | (RCON << 5));
		break;
	}
}

static void
con(ulong o, int r, int opt)
{
	ccon(AL, o, r, opt);
}

static void
mem(int inst, ulong disp, int rm, int r)
{
	memc(AL, inst, disp, rm, r);
}

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
		con(a->imm, r, 1);
		if(mi == Lea) {
			mem(Stw, li, RREG, r);
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
	mem(Ldw, a->i.f, ir, rta);
	mem(mi, a->i.s, rta, r);
}

static void
opwld(Inst *i, int op, int r)
{
	opx(USRC(i->add), &i->s, op, r, O(REG, st));
}

static void
opwst(Inst *i, int op, int r)
{
	opx(UDST(i->add), &i->d, op, r, O(REG, dt));
}

static void
memfl(int cc, int inst, ulong disp, int rm, int r)
{
	int wd;

	wd = (disp&07)==0;
	if(wd && disp < BITS(11)) {
		/* direct load with aligned offset */
		disp >>= 2;
	} else if(wd && -disp < BITS(11)){
		disp = -disp >> 2;
	} else {
		ccon(cc, disp, RCON, 1);
		DP(cc, Add, RCON, RCON, rm);
		rm = RCON;
		disp = 0;
	}
	switch(inst) {
	case Ldf:
		/* FLDR Fs, [Rn, #imm9] */
		*code++ = (0x3C200800 | ((disp&0x7F)<<15) | (rm<<16) | (r<<5));
		break;
	case Stf:
		/* FSTR Fs, [Rn, #imm9] */
		*code++ = (0x3C400800 | ((disp&0x7F)<<15) | (rm<<16) | (r<<5));
		break;
	}
}

static void
opfl(int am, int mi, int r)
{
	int ir;

	switch(am) {
	default:
		urk("opfl");
	case AFP:
		memfl(AL, mi, a->ind, RFP, r);
		return;
	case AMP:
		memfl(AL, mi, a->ind, RMP, r);
		return;
	case AIND|AFP:
		ir = RFP;
		break;
	case AIND|AMP:
		ir = RMP;
		break;
	}
	mem(Ldw, a->i.f, ir, RTA);
	memfl(AL, mi, a->i.s, RTA, r);
}

static void
opflld(Inst *i, int mi, int r)
{
	opfl(&i->s, USRC(i->add), mi, r);
}

static void
opflst(Inst *i, int mi, int r)
{
	opfl(&i->d, UDST(i->add), mi, r);
}

static void
literal(ulong imm, int roff)
{
	nlit++;

	con((ulong)litpool, RTA, 0);
	mem(Stw, roff, RREG, RTA);

	if(pass == 0)
		return;

	*litpool = imm;
	litpool++;
}

static void
schedcheck(Inst *i)
{
	if(RESCHED) {
		/* Load R.IC */
		/* subs x0, [xRREG], #1 */
		mem(Ldw, O(REG, IC), RREG, RA0);
		/* sub with compare */
		*code++ = 0x1A9F0000 | (RA0 << 5) | (RA0 << 16) | (1); /* subs Ra0, Ra0, #1 */
		mem(Stw, O(REG, IC), RREG, RA0);
		CALLMAC(LE, MacRELQ);
	}
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

static void
punt(Inst *i, int m, void (*fn)(void))
{
	ulong pc;

	if(m & SRCOP) {
		if(UXSRC(i->add) == SRC(AIMM))
			literal(i->s.imm, O(REG, s));
		else {
			opwld(i, Lea, RA0);
			mem(Stw, O(REG, s), RREG, RA0);
		}
	}

	if(m & DSTOP) {
		opwst(i, Lea, RA0);
		mem(Stw, O(REG, d), RREG, RA0);
	}
	if(m & WRTPC) {
		con(RELPC(patch[i-mod->prog+1]), RA0, 0);
		mem(Stw, O(REG, PC), RREG, RA0);
	}
	if(m & DBRAN) {
		pc = patch[i->d.ins-mod->prog];
		literal((ulong)(base+pc), O(REG, d));
	}

	switch(i->add&ARM) {
	case AXNON:
		if(m & THREOP) {
			mem(Ldw, O(REG, d), RREG, RA0);
			mem(Stw, O(REG, m), RREG, RA0);
		}
		break;
	case AXIMM:
		literal((short)i->reg, O(REG, m));
		break;
	case AXINF:
		/* ADD Ra0, RFP, #i->reg */
		*code++ = 0x11000000 | (RA0 << 5) | (RFP << 16) | (i->reg & 0x3FF);
		mem(Stw, O(REG, m), RREG, RA0);
		break;
	case AXINM:
		*code++ = 0x11000000 | (RA0 << 5) | (RMP << 16) | (i->reg & 0x3FF);
		mem(Stw, O(REG, m), RREG, RA0);
		break;
	}
	mem(Stw, O(REG, FP), RREG, RFP);

	CALL(fn);

	con((ulong)&R, RREG, 1);
	if(m & TCHECK) {
		mem(Ldw, O(REG, t), RREG, RA0);
		CBNZ(AL, RA0, 0);
		memc(NE, Ldw, O(REG, xpc), RREG, RLINK);
		/* if(R.t) goto(R.xpc) */
		*code++ = 0x58000070; /* LDR x16, [x0] */
		*code++ = 0xD61F0000; /* BR x16 */
	}
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);

	if(m & NEWPC){
		mem(Ldw, O(REG, PC), RREG, R15);
		flushcon(0);
	}
}

static void
midfl(Inst *i, int mi, int r)
{
	int ir;

	switch(i->add&ARM) {
	default:
		opflst(i, mi, r);
		return;
	case AXIMM:
		con((short)i->reg, r, 1);	/* BUG */
		return;
	case AXINF:
		ir = RFP;
		break;
	case AXINM:
		ir = RMP;
		break;
	}
	memfl(AL, mi, i->reg, ir, r);
}

static void
mid(Inst *i, int mi, int r)
{
	int ir;

	switch(i->add&ARM) {
	default:
		opwst(i, mi, r);
		return;
	case AXIMM:
		if(mi == Lea)
			urk("mid/lea");
		con((short)i->reg, r, 1);
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

static int
swapbraop(int b)
{
	switch(b) {
	case GE:
		return LE;
	case LE:
		return GE;
	case GT:
		return LT;
	case LT:
		return GT;
	}
	return b;
}

static void
cbra(Inst *i, int r)
{
	if(RESCHED)
		schedcheck(i);
	if(UXSRC(i->add) == SRC(AIMM) && FITS12(i->s.imm)) {
		mid(i, Ldw, RA1);
		/* cmp x1, #imm */
		*code++ = 0x71000000 | (RA1 << 5) | (R15 << 16) | (i->s.imm & 0x3FF);
		CBRAI(swapbraop(r), RA1, 0, i->s.imm);
	} else if((i->add & ARM) == AXIMM && FITS12(i->reg)) {
		opwld(i, Ldw, RA1);
		*code++ = 0x71000000 | (RA1 << 5) | (R15 << 16) | (i->reg & 0x3FF);
		CBRAI(swapbraop(r), RA1, 0, i->reg);
	} else {
		opwld(i, Ldw, RA0);
		mid(i, Ldw, RA1);
		CMP(RA1, RA0, 0, 0);
	}
	BRADIS(r, i->d.ins-mod->prog);
}

static void
cbrab(Inst *i, int r)
{
	if(RESCHED)
		schedcheck(i);
	if(UXSRC(i->add) == SRC(AIMM)) {
		mid(i, Ldb, RA1);
		*code++ = 0x71000000 | (RA1 << 5) | (R15 << 16) | (i->s.imm & 0x3FF);
		CBRAI(swapbraop(r), RA1, 0, i->s.imm);
	} else if((i->add & ARM) == AXIMM) {
		opwld(i, Ldb, RA1);
		CBRAI(swapbraop(r), RA1, 0, i->reg);
	} else {
		opwld(i, Ldb, RA0);
		mid(i, Ldb, RA1);
		CMP(RA1, RA0, 0, 0);
	}
	BRADIS(r, i->d.ins-mod->prog);
}

static void
cbral(Inst *i, int jmsw, int jlsw, int mode)
{
	ulong dst, *label;

	if(RESCHED)
		schedcheck(i);
	opwld(i, Lea, RA1);
	mid(i, Lea, RA3);
	mem(Ldw, Bhi, RA1, RA2);
	mem(Ldw, Bhi, RA3, RA0);
	CMP(RA2, RA0, 0, 0);
	label = nil;
	dst = i->d.ins-mod->prog;
	switch(mode) {
	case ANDAND:
		label = code;
		BRA(jmsw, 0);
		break;
	case OROR:
		BRADIS(jmsw, dst);
		break;
	case EQAND:
		BRADIS(jmsw, dst);
		label = code;
		BRA(NE, 0);
		break;
	}
	mem(Ldw, Blo, RA3, RA0);
	mem(Ldw, Blo, RA1, RA2);
	CMP(RA2, RA0, 0, 0);
	BRADIS(jlsw, dst);
	if(label != nil)
		PATCH(label);
}

static void
cbraf(Inst *i, int r)
{
	if(RESCHED)
		schedcheck(i);
	if(!SOFTFP){
		ulong *s=code;
		opflld(i, Ldf, FA2);
		midfl(i, Ldf, FA4);
		FCMPF(FA4, FA2);
		BRADIS(r, i->d.ins-mod->prog);
	}else
		punt(i, SRCOP|THREOP|DBRAN|NEWPC|WRTPC, optab[i->op]);
}

static void
comcase(Inst *i, int w)
{
	int l;
	WORD *t, *e;

	if(w != 0) {
		opwld(i, Ldw, RA1);	/* v */
		opwst(i, Lea, RA3);	/* table */
		BRAMAC(AL, MacCASE);
	}

	t = (WORD*)(mod->origmp+i->d.ind+4);
	l = t[-1];

	if(pass == 0) {
		if(l >= 0)
			t[-1] = -l-1;	/* Mark it not done */
		return;
	}
	if(l >= 0)			/* Check pass 2 done */
		return;
	t[-1] = -l-1;			/* Set real count */
	e = t + t[-1]*3;
	while(t < e) {
		t[2] = RELPC(patch[t[2]]);
		t += 3;
	}
	t[0] = RELPC(patch[t[0]]);
}

static void
comcasel(Inst *i)
{
	int l;
	WORD *t, *e;

	t = (WORD*)(mod->origmp+i->d.ind+8);
	l = t[-2];
	if(pass == 0) {
		if(l >= 0)
			t[-2] = -l-1;	/* Mark it not done */
		return;
	}
	if(l >= 0)			/* Check pass 2 done */
		return;
	t[-2] = -l-1;			/* Set real count */
	e = t + t[-2]*6;
	while(t < e) {
		t[4] = RELPC(patch[t[4]]);
		t += 6;
	}
	t[0] = RELPC(patch[t[0]]);
}

static void
commframe(Inst *i)
{
	ulong *punt, *mlnil;

	opwld(i, Ldw, RA0);
	CMPH(RA0);
	mlnil = code;
	BRA(EQ, 0);

	if((i->add&ARM) == AXIMM) {
		mem(Ldw, OA(Modlink, links)+i->reg*sizeof(Modl)+O(Modl, frame), RA3, RA0);
	} else {
		mid(i, Ldw, RA1);
		DP(AL, Add, RA0, RA1, 1, RA1);	/* sizeof(Modl) == 8, shift 3 */
		mem(Ldw, OA(Modlink, links)+O(Modl, frame), RA1, RA3);
	}

	mem(Ldw, O(Type, initialize), RA3, RA1);
	CBNZ(AL, RA1, 0);
	punt = code;
	BRA(NE, 0);

	opwst(i, Lea, RA0);

	/* Type in RA3, destination in RA0 */
	PATCH(mlnil);
	con(RELPC(patch[i-mod->prog+1]), RLINK, 0);
	BRAMAC(AL, MacMFRA);

	/* Type in RA3 */
	PATCH(punt);
	CALLMAC(AL, MacFRAM);
	opwst(i, Stw, RA2);
}

static void
commcall(Inst *i)
{
	ulong *mlnil;

	opwld(i, Ldw, RA2);
	con(RELPC(patch[i-mod->prog+1]), RA0, 0);
	mem(Stw, O(Frame, lr), RA2, RA0);
	mem(Stw, O(Frame, fp), RA2, RFP);
	mem(Ldw, O(REG, M), RREG, RA3);
	mem(Stw, O(Frame, mr), RA2, RA3);
	opwst(i, Ldw, RA3);
	CBNZ(AL, RA3, 0);
	mlnil = code;
	BRA(EQ, 0);
	if((i->add&ARM) == AXIMM) {
		mem(Ldw, OA(Modlink, links)+i->reg*sizeof(Modl)+O(Modl, u.pc), RA3, RA0);
	} else {
		mid(i, Ldw, RA1);
		DP(AL, Add, RA3, RA1, 1, RA1);	/* sizeof(Modl) == 8, shift 3 */
		mem(Ldw, OA(Modlink, links)+O(Modl, u.pc), RA1, RA0);
	}
	PATCH(mlnil);
	CALLMAC(AL, MacMCAL);
}

static void
larith(Inst *i, int op, int opc)
{
	opwld(i, Lea, RA0);
	mid(i, Lea, RA3);
	mem(Ldw, Blo, RA0, RA1);	/* ls */
	mem(Ldw, Blo, RA3, RA2);
	/* sbb RA2, RA2, RA1, #0 -> RA2 = RA2 op RA1 with carry */
	DP(AL, op, RA2, RA2, 0) | (1 << 22); /* subtract with carry */
	mem(Ldw, Bhi, RA0, RA1);
	mem(Ldw, Bhi, RA3, RA0);
	DP(AL, opc, RA0, RA0, 0);	/* ms: RA0 = RA0 opc RA1 */
	if((i->add&ARM) != AXNON)
		opwst(i, Lea, RA3);
	mem(Stw, Blo, RA3, RA2);
	mem(Stw, Bhi, RA3, RA0);
}

static void
movloop(Inst *i, int s)
{
	USED(i);
	USED(s);
	/* Placeholder - will be refined */
}

static void
movmem(Inst *i)
{
	ulong *cp;

	/* source address already in RA1 */
	if((i->add&ARM) != AXIMM){
		mid(i, Ldw, RA3);
		CBNZ(AL, RA3, 0);
		cp = code;
		/* BRA(LE, 0); */
		movloop(i, 1);
		/* PATCH(cp); */
		return;
	}
	switch(i->reg){
	case 0:
		break;
	default:
		break;
	}
}

static
void
compdbg(void)
{
	print("%s:%lux@%lux\n", R.M->m->name, *(ulong*)R.m, *(ulong*)R.s);
}

static void
comgoto(Inst *i)
{
	WORD *t, *e;

	opwld(i, Ldw, RA1);
	opwst(i, Lea, RA0);
	/* LDR x15, [x0, x1] */
	flushcon(0);

	if(pass == 0)
		return;

	t = (WORD*)(mod->origmp+i->d.ind);
	e = t + t[-1];
	t[-1] = 0;
	while(t < e) {
		t[0] = RELPC(patch[t[0]]);
		t++;
	}
}

static void
comp(Inst *i)
{
	int r, imm;
	char buf[64];

	flushchk();

	switch(i->op) {
	default:
		snprint(buf, sizeof buf, "%s compile, no '%D'", mod->name, i);
		error(buf);
		break;
	case IMCALL:
		if((i->add&ARM) == AXIMM)
			commcall(i);
		else
			punt(i, SRCOP|DSTOP|THREOP|WRTPC|NEWPC, optab[i->op]);
		break;
	case ISEND:
	case IRECV:
	case IALT:
		punt(i, SRCOP|DSTOP|TCHECK|WRTPC, optab[i->op]);
		break;
	case ISPAWN:
		punt(i, SRCOP|DBRAN, optab[i->op]);
		break;
	case IBNEC:
	case IBEQC:
	case IBLTC:
	case IBLEC:
	case IBGTC:
	case IBGEC:
		punt(i, SRCOP|DBRAN|NEWPC|WRTPC, optab[i->op]);
		break;
	case ICASEC:
		comcase(i, 0);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case ICASEL:
		comcasel(i);
		punt(i, SRCOP|DSTOP|NEWPC, optab[i->op]);
		break;
	case IADDC:
	case IMULL:
	case IDIVL:
	case IMODL:
	case IMNEWZ:
	case ILSRW:
	case ILSRL:
	case IMODW:
	case IMODB:
	case IDIVW:
	case IDIVB:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case ILOAD:
	case INEWA:
	case INEWAZ:
	case INEW:
	case INEWZ:
	case ISLICEA:
	case ISLICELA:
	case ICONSB:
	case ICONSW:
	case ICONSL:
	case ICONSF:
	case ICONSM:
	case ICONSMP:
	case ICONSP:
	case IMOVMP:
	case IHEADMP:
	case IHEADB:
	case IHEADW:
	case IHEADL:
	case IINSC:
	case ICVTAC:
	case ICVTCW:
	case ICVTWC:
	case ICVTLC:
	case ICVTCL:
	case ICVTFC:
	case ICVTCF:
	case ICVTRF:
	case ICVTFR:
	case ICVTWS:
	case ICVTSW:
	case IMSPAWN:
	case ICVTCA:
	case ISLICEC:
	case INBALT:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;
	case INEWCM:
	case INEWCMP:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case IMFRAME:
		if((i->add&ARM) == AXIMM)
			commframe(i);
		else
			punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case ICASE:
		comcase(i, 1);
		break;
	case IGOTO:
		comgoto(i);
		break;
	case IMOVF:
		if(!SOFTFP){
			opflld(i, Ldf, FA2);
			opflst(i, Stf, FA2);
			break;
		}
	case IMOVL:
		opwld(i, Lea, RA1);
		mem(Ldw, Blo, RA1, RA2);
		mem(Ldw, Bhi, RA1, RA3);
		opwst(i, Lea, RA1);
		mem(Stw, Blo, RA1, RA2);
		mem(Stw, Bhi, RA1, RA3);
		break;
	case IHEADM:
		opwld(i, Ldw, RA1);
		CMPH(RA1);
		if(OA(List,data) != 0)
			DP(AL, Add, RA1, RA1, 0);
		movmem(i);
		break;
	case IMOVM:
		opwld(i, Lea, RA1);
		movmem(i);
		break;
	case IFRAME:
		if(UXSRC(i->add) != SRC(AIMM)) {
			punt(i, SRCOP|DSTOP, optab[i->op]);
			break;
		}
		tinit[i->s.imm] = 1;
		con((ulong)mod->type[i->s.imm], RA3, 1);
		CALL(base+macro[MacFRAM]);
		opwst(i, Stw, RA2);
		break;
	case INEWCB:
	case INEWCW:
	case INEWCF:
	case INEWCP:
	case INEWCL:
		punt(i, DSTOP|THREOP, optab[i->op]);
		break;
	case IEXIT:
		punt(i, 0, optab[i->op]);
		break;
	case ICVTBW:
		opwld(i, Ldb, RA0);
		opwst(i, Stw, RA0);
		break;
	case ICVTWB:
		opwld(i, Ldw, RA0);
		opwst(i, Stb, RA0);
		break;
	case ILEA:
		opwld(i, Ldw, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMOVW:
		opwld(i, Ldw, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMOVB:
		opwld(i, Ldb, RA0);
		opwst(i, Stb, RA0);
		break;
	case ITAIL:
		opwld(i, Ldw, RA0);
		CMPH(RA0);
		mem(Ldw, O(List, tail), RA0, RA1);
		goto movp;
	case IMOVP:
		opwld(i, Ldw, RA1);
		goto movp;
	case IHEADP:
		opwld(i, Ldw, RA0);
		CMPH(RA0);
		mem(Ldw, OA(List, data), RA0, RA1);
	movp:
		CBNZ(AL, RA1, 0);
		CALLMAC(NE, MacCOLR);
		opwst(i, Lea, RA2);
		mem(Ldw, 0, RA2, RA0);
		mem(Stw, 0, RA2, RA1);
		CALLMAC(AL, MacFRP);
		break;
	case ILENA:
		opwld(i, Ldw, RA1);
		con(0, RA0, 1);
		CBNZ(AL, RA1, 0);
		LDW(RA1, RA1, RA0, O(Array,len));
		opwst(i, Stw, RA0);
		break;
	case ILENC:
		opwld(i, Ldw, RA1);
		con(0, RA0, 1);
		CBNZ(AL, RA1, 0);
		memc(NE, Ldw, O(String,len), RA1, RA0);
		CMPI(AL, RA0, 0, 0, 0);
		DPI(LT, 0, RA0, RA0, 0, 0);
		opwst(i, Stw, RA0);
		break;
	case ILENL:
		con(0, RA0, 1);
		opwld(i, Ldw, RA1);
		CBNZ(AL, RA1, 0);
		mem(Ldw, O(List, tail), RA1, RA1);
		DPI(NE, 0, RA0, RA0, 0, 0);
		opwst(i, Stw, RA0);
		break;
	case ICALL:
		opwld(i, Ldw, RA0);
		con(RELPC(patch[i-mod->prog+1]), RA1, 0);
		mem(Stw, O(Frame, lr), RA0, RA1);
		mem(Stw, O(Frame, fp), RA0, RFP);
		MOV(RA0, RFP);
		BRADIS(AL, i->d.ins-mod->prog);
		flushcon(0);
		break;
	case IJMP:
		if(RESCHED)
			schedcheck(i);
		BRADIS(AL, i->d.ins-mod->prog);
		flushcon(0);
		break;
	case IBEQW:
		cbra(i, EQ);
		break;
	case IBNEW:
		cbra(i, NE);
		break;
	case IBLTW:
		cbra(i, LT);
		break;
	case IBLEW:
		cbra(i, LE);
		break;
	case IBGTW:
		cbra(i, GT);
		break;
	case IBGEW:
		cbra(i, GE);
		break;
	case IBEQB:
		cbrab(i, EQ);
		break;
	case IBNEB:
		cbrab(i, NE);
		break;
	case IBLTB:
		cbrab(i, LT);
		break;
	case IBLEB:
		cbrab(i, LE);
		break;
	case IBGTB:
		cbrab(i, GT);
		break;
	case IBGEB:
		cbrab(i, GE);
		break;
	case IBEQF:
		cbraf(i, EQ);
		break;
	case IBNEF:
		cbraf(i, NE);
		break;
	case IBLTF:
		cbraf(i, LT);
		break;
	case IBLEF:
		cbraf(i, LE);
		break;
	case IBGTF:
		cbraf(i, GT);
		break;
	case IBGEF:
		cbraf(i, GE);
		break;
	case IRET:
		mem(Ldw, O(Frame,t), RFP, RA1);
		BRAMAC(AL, MacRET);
		break;
	case IMULW:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		MUL(AL, RA1, RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMULB:
		opwld(i, Ldb, RA1);
		mid(i, Ldb, RA0);
		MUL(AL, RA1, RA0, RA0);
		opwst(i, Stb, RA0);
		break;
	case IORW:
		r = Orr;
		goto arithw;
	case IANDW:
		r = And;
		goto arithw;
	case IXORW:
		r = Eor;
		goto arithw;
	case ISUBW:
		r = Sub;
		goto arithw;
	case IADDW:
		r = Add;
	arithw:
		mid(i, Ldw, RA1);
		if(UXSRC(i->add) == SRC(AIMM) && FITS12(i->s.imm))
			DPI(AL, 0, RA1, RA0, 0, 0) |= (i->s.imm & 0x3FF);
		else {
			opwld(i, Ldw, RA0);
			DP(AL, r, RA1, RA0, 0);
		}
		opwst(i, Stw, RA0);
		break;
	case ISHRW:
		r = 2;
	shiftw:
		mid(i, Ldw, RA1);
		if(UXSRC(i->add) == SRC(AIMM) && FITS5(i->s.imm))
			DPI(AL, 0, RA0, RA1, 0, 0) |= ((i->s.imm & 0x3F) << 10) | (2 << 22);
		else {
			opwld(i, Ldw, RA0);
			DPI(AL, 0, RA0, RA1, 0, 0) |= (RA0 << 10) | (2 << 22);
		}
		opwst(i, Stw, RA0);
		break;
	case ISHLW:
		r = 0;
		goto shiftw;
	case IORB:
		r = Orr;
		goto arithb;
	case IANDB:
		r = And;
		goto arithb;
	case IXORB:
		r = Eor;
		goto arithb;
	case ISUBB:
		r = Sub;
		goto arithb;
	case IADDB:
		r = Add;
	arithb:
		mid(i, Ldb, RA1);
		if(UXSRC(i->add) == SRC(AIMM))
			DPI(AL, 0, RA1, RA0, 0, 0) |= (i->s.imm & 0x3F);
		else {
			opwld(i, Ldb, RA0);
			DP(AL, r, RA1, RA0, 0);
		}
		opwst(i, Stb, RA0);
		break;
	case ISHRB:
		r = 2;
	shiftb:
		mid(i, Ldb, RA1);
		if(UXSRC(i->add) == SRC(AIMM) && FITS5(i->s.imm))
			DPI(AL, 0, RA0, RA1, 0, 0) |= ((i->s.imm & 0x3F) << 10) | (2 << 22);
		else {
			opwld(i, Ldw, RA0);
			DPI(AL, 0, RA0, RA1, 0, 0) |= (RA0 << 10) | (2 << 22);
		}
		opwst(i, Stb, RA0);
		break;
	case IINDC:
		opwld(i, Ldw, RA1);
		CMPH(RA1);
		imm = 1;
		if((i->add&ARM) != AXIMM || !FITS12((short)i->reg<<Lg2Rune)){
			mid(i, Ldw, RA2);
			imm = 0;
		}
		mem(Ldw, O(String,len), RA1, RA0);
		DPI(AL, Orr, RA0, RA3, 0, 0);
		DPI(LT, Rsb, RA3, RA3, 0, 0);
		if(imm)
			BCKR(0, RA3);
		else
			BCK(RA2, RA3);
		DP(AL, Add, RA1, RA1, 0);
		CMPI(AL, RA0, 0, 0, 0);
		if(imm)
			LDB(GE, RA1, RA3, i->reg);
		else {
			LDRB(GE, RA1, RA3, 0, RA2);
		}
		opwst(i, Stw, RA3);
		break;
	case IINDL:
	case IINDF:
	case IINDW:
	case IINDB:
		opwld(i, Ldw, RA0);
		CMPH(RA0);
		if(bflag)
			mem(Ldw, O(Array, len), RA0, RA2);
		mem(Ldw, O(Array, data), RA0, RA0);
		r = 0;
		switch(i->op) {
		case IINDL:
		case IINDF:
			r = 3;
			break;
		case IINDW:
			r = 2;
			break;
		}
		if(UXDST(i->add) == DST(AIMM) && FITS12(i->d.imm)) {
			if(bflag)
				BCKR(0, RA2);
			if(i->d.imm != 0)
				DP(AL, Add, RA0, RA0, 0) |= (i->d.imm << 10);
		} else {
			opwst(i, Ldw, RA1);
			if(bflag)
				BCK(RA1, RA2);
			DP(AL, Add, RA0, RA0, RA1) |= (r << 10);
		}
		mid(i, Stw, RA0);
		break;
	case IINDX:
		opwld(i, Ldw, RA0);
		CMPH(RA0);
		opwst(i, Ldw, RA1);
		if(bflag){
			mem(Ldw, O(Array, len), RA0, RA2);
			BCK(RA1, RA2);
		}
		mem(Ldw, O(Array, t), RA0, RA2);
		mem(Ldw, O(Array, data), RA0, RA0);
		mem(Ldw, O(Type, size), RA2, RA2);
		MUL(AL, RA2, RA1, RA0);
		DP(AL, Add, RA0, RA0, 0);
		mid(i, Stw, RA0);
		break;
	case IADDL:
		larith(i, Add, Add);
		break;
	case ISUBL:
		larith(i, Sub, Sub);
		break;
	case IORL:
		larith(i, Orr, Orr);
		break;
	case IANDL:
		larith(i, And, And);
		break;
	case IXORL:
		larith(i, Eor, Eor);
		break;
	case ICVTWL:
		opwld(i, Ldw, RA1);
		opwst(i, Lea, RA2);
		DPI(AL, 0, RA0, RA1, 0, 0) |= (32 << 10) | (8 << 22); /* ASR */
		STW(AL, RA2, RA1, Blo);
		STW(AL, RA2, RA0, Bhi);
		break;
	case ICVTLW:
		opwld(i, Lea, RA0);
		mem(Ldw, Blo, RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case IBEQL:
		cbral(i, NE, EQ, ANDAND);
		break;
	case IBNEL:
		cbral(i, NE, NE, OROR);
		break;
	case IBLEL:
		cbral(i, LT, LS, EQAND);
		break;
	case IBGTL:
		cbral(i, GT, HI, EQAND);
		break;
	case IBLTL:
		cbral(i, LT, CC, EQAND);
		break;
	case IBGEL:
		cbral(i, GT, CS, EQAND);
		break;
	case ICVTFL:
	case ICVTLF:
		punt(i, SRCOP|DSTOP, optab[i->op]);
		break;
	case IDIVF:
		r = Dvf;
		goto arithf;
	case IMULF:
		r = Muf;
		goto arithf;
	case ISUBF:
		r = Suf;
		goto arithf;
	case IADDF:
		r = Adf;
	arithf:
		if(SOFTFP){
			USED(r);
			punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
			break;
		}
		opflld(i, Ldf, FA2);
		midfl(i, Ldf, FA4);
		/* FP operation */
		opflst(i, Stf, FA4);
		break;
	case INEGF:
		if(SOFTFP){
			punt(i, SRCOP|DSTOP, optab[i->op]);
			break;
		}
		opflld(i, Ldf, FA2);
		FNEGF(FA2, FA2);
		opflst(i, Stf, FA2);
		break;
	case ICVTWF:
		if(SOFTFP){
			punt(i, SRCOP|DSTOP, optab[i->op]);
			break;
		}
		opwld(i, Ldw, RA2);
		/* CVTF */
		opflst(i, Stf, FA2);
		break;
	case ICVTFW:
		if(SOFTFP){
			punt(i, SRCOP|DSTOP, optab[i->op]);
			break;
		}
		opflld(i, Ldf, FA2);
		/* CVTI */
		opwst(i, Stw, RA2);
		break;
	case ISHLL:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case ISHRL:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case IRAISE:
		punt(i, SRCOP|WRTPC|NEWPC, optab[i->op]);
		break;
	case IMULX:
	case IDIVX:
	case ICVTXX:
	case IMULX0:
	case IDIVX0:
	case ICVTXX0:
	case IMULX1:
	case IDIVX1:
	case ICVTXX1:
	case ICVTFX:
	case ICVTXF:
	case IEXPW:
	case IEXPL:
	case IEXPF:
		punt(i, SRCOP|DSTOP|THREOP, optab[i->op]);
		break;
	case ISELF:
		punt(i, DSTOP, optab[i->op]);
		break;
	}
}

static void
preamble(void)
{
	if(comvec)
		return;

	comvec = malloc(10 * sizeof(*code));
	if(comvec == nil)
		error(exNomem);
	code = (ulong*)comvec;

	con((ulong)&R, RREG, 0);
	mem(Stw, O(REG, xpc), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	mem(Ldw, O(REG, PC), RREG, R15);
	pass++;
	flushcon(0);
	pass--;

	segflush(comvec, 10 * sizeof(*code));
}

static void
maccase(void)
{
	ulong *cp1, *loop, *inner;

	LDW(AL, RA3, RA2, 0);	/* count from table */
	MOV(RA3, RLINK);	/* initial table pointer */

	loop = code;
	CMPI(AL, RA2, 0, 0, 0);
	cp1 = code;
	BRA(LE, 0);	/* n <= 0? goto out */

	inner = code;
	DP(AL, Lsr, RA0, RA2, 1);	/* n2 = n>>1 */
	DP(AL, Add, RA0, RCON, 1, RA0);	/* n2 += n2 << 1 */
	DP(AL, Add, RA3, RCON, 2, RCON);	/* l = t + n2*3 */

	LDW(AL, RCON, RTA, 4);
	CMP(AL, RA1, 0, 0, RTA);
	DP(LT, Mov, 0, RA2, 0, RA0);	/* v < l[1]? n=n2 */
	BRANCH(LT, loop);

	LDW(AL, RCON, RTA, 8);
	CMP(AL, RA1, 0, 0, RTA);
	LDW(LT, RCON, R15, 12);	/* v >= l[1] && v < l[2] => found */

	DPI(AL, Add, RCON, RA3, 0, 12);	/* t = l+3 */
	DPI(AL, Add, RA0, RTA, 0, 1);
	DP(AL, Sub, RA2, RA2, 0, RTA) | (1 << 22);	/* n -= n2+1 */
	BRANCH(GT, inner);

	PATCH(cp1);
	LDW(AL, RLINK, RA2, 0);
	DP(AL, Add, RA2, RA2, 1, RA2);
	DP(AL, Add, RLINK, RLINK, 2, RA2);
	LDW(AL, RLINK, R15, 4);
}

static void
macfrp(void)
{
	CMPH(AL, RA0);
	CRETURN(EQ);

	mem(Ldw, O(Heap, ref)-sizeof(Heap), RA0, RA2);
	DP(AL, Sub, RA2, RA2, 0) | (1 << 22);
	memc(NE, Stw, O(Heap, ref)-sizeof(Heap), RA0, RA2);
	CRETURN(NE);

	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, st), RREG, RLINK);
	mem(Stw, O(REG, s), RREG, RA0);
	CALL(rdestroy);
	con((ulong)&R, RREG, 1);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RETURN;
	flushcon(0);
}

static void
maccolr(void)
{
	mem(Ldw, O(Heap, ref)-sizeof(Heap), RA1, RA0);
	DP(AL, Add, RA0, RA0, 0);
	mem(Stw, O(Heap, ref)-sizeof(Heap), RA1, RA0);
	con((ulong)&mutator, RA2, 1);
	mem(Ldw, O(Heap, color)-sizeof(Heap), RA1, RA0);
	mem(Ldw, 0, RA2, RA2);
	CMP(AL, RA0, 0, 0, RA2);
	CRETURN(EQ);
	con(propagator, RA2, 1);
	mem(Stw, O(Heap, color)-sizeof(Heap), RA1, RA2);
	con((ulong)&nprop, RA2, 1);
	mem(Stw, 0, RA2, RA2);
	RETURN;
	flushcon(0);
}

static void
macret(void)
{
	Inst i;
	ulong *cp1, *cp2, *cp3, *cp4, *cp5, *linterp;

	CMPI(AL, RA1, 0, 0, 0);
	cp1 = code;
	BRA(EQ, 0);

	mem(Ldw, O(Type,destroy),RA1, RA0);
	CMPI(AL, RA0, 0, 0, 0);
	cp2 = code;
	BRA(EQ, 0);

	mem(Ldw, O(Frame,fp),RFP, RA2);
	CMPI(AL, RA2, 0, 0, 0);
	cp3 = code;
	BRA(EQ, 0);

	mem(Ldw, O(Frame,mr),RFP, RA3);
	CMPI(AL, RA3, 0, 0, 0);
	cp4 = code;
	BRA(EQ, 0);

	mem(Ldw, O(REG,M),RREG, RA2);
	mem(Ldw, O(Heap,ref)-sizeof(Heap),RA2, RA3);
	DP(AL, Sub, RA3, RA3, 0) | (1 << 22);
	cp5 = code;
	BRA(EQ, 0);
	mem(Stw, O(Heap,ref)-sizeof(Heap),RA2, RA3);

	mem(Ldw, O(Frame,mr),RFP, RA1);
	mem(Stw, O(REG,M),RREG, RA1);
	mem(Ldw, O(Modlink,MP),RA1, RMP);
	mem(Stw, O(REG,MP),RREG, RMP);
	mem(Ldw, O(Modlink,compiled), RA1, RA3);
	CMPI(AL, RA3, 0, 0, 0);
	linterp = code;
	BRA(EQ, 0);

	PATCH(cp4);
	MOV(R15, R14);
	MOV(RA0, R15);

	mem(Stw, O(REG,SP),RREG, RFP);
	mem(Ldw, O(Frame,lr),RFP, RA1);
	mem(Ldw, O(Frame,fp),RFP, RFP);
	mem(Stw, O(REG,PC),RREG, RA1);
	mem(Stw, O(REG,FP),RREG, RFP);
	mem(Ldw, O(REG, xpc), RREG, RLINK);
	RETURN;

	PATCH(linterp);
	MOV(R15, R14);
	MOV(RA0, R15);

	mem(Stw, O(REG,SP),RREG, RFP);
	mem(Ldw, O(Frame,lr),RFP, RA1);
	mem(Ldw, O(Frame,fp),RFP, RFP);
	mem(Stw, O(REG,PC),RREG, RA1);
	mem(Stw, O(REG,FP),RREG, RFP);
	mem(Ldw, O(REG, xpc), RREG, RLINK);
	RETURN;

	PATCH(cp1);
	PATCH(cp2);
	PATCH(cp3);
	PATCH(cp5);
	i.add = AXNON;
	punt(&i, TCHECK|NEWPC, optab[IRET]);
}

static void
macmcal(void)
{
	ulong *lab;

	CMPH(AL, RA0);
	memc(NE, Ldw, O(Modlink, prog), RA3, RA1);
	CMPI(NE, RA1, 0, 0, 0);
	lab = code;
	BRA(NE, 0);

	mem(Stw, O(REG, st), RREG, RLINK);
	mem(Stw, O(REG, FP), RREG, RA2);
	mem(Stw, O(REG, dt), RREG, RA0);
	CALL(rmcall);

	con((ulong)&R, RREG, 1);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RETURN;

	PATCH(lab);
	MOV(RFP, RA2);
	mem(Stw, O(REG, M), RREG, RA3);
	mem(Ldw, O(Heap, ref)-sizeof(Heap), RA3, RA1);
	DP(AL, Add, RA1, RA1, 0);
	mem(Stw, O(Heap, ref)-sizeof(Heap), RA3, RA1);
	mem(Ldw, O(Modlink, MP), RA3, RMP);
	mem(Stw, O(REG, MP), RREG, RMP);
	mem(Ldw, O(Modlink,compiled), RA3, RA1);
	CMPI(AL, RA1, 0, 0, 0);
	DP(NE, Mov, 0, R15, 0, RA0);
	mem(Stw, O(REG,FP),RREG, RFP);
	mem(Stw, O(REG,PC),RREG, RA0);
	mem(Ldw, O(REG, xpc), RREG, RLINK);
	RETURN;
	flushcon(0);
}

static void
macfram(void)
{
	ulong *lab1;

	mem(Ldw, O(REG, SP), RREG, RA0);
	mem(Ldw, O(Type, size), RA3, RA1);
	DP(AL, Add, RA0, RA0, 0, RA1);
	mem(Ldw, O(REG, TS), RREG, RA1);
	CMP(AL, RA0, 0, 0, RA1);
	lab1 = code;
	BRA(CS, 0);

	mem(Ldw, O(REG, SP), RREG, RA2);
	mem(Stw, O(REG, SP), RREG, RA0);
	mem(Stw, O(Frame, t), RA2, RA3);
	con(0, RA0, 1);
	mem(Stw, O(Frame,mr), RA2, RA0);
	mem(Ldw, O(Type, initialize), RA3, R15);

	PATCH(lab1);
	mem(Stw, O(REG, s), RREG, RA3);
	mem(Stw, O(REG, st), RREG, RLINK);
	mem(Stw, O(REG, FP), RREG, RFP);
	CALL(extend);

	con((ulong)&R, RREG, 1);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, s), RREG, RA2);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RETURN;
}

static void
macmfra(void)
{
	mem(Stw, O(REG, st), RREG, RLINK);
	mem(Stw, O(REG, s), RREG, RA3);
	mem(Stw, O(REG, d), RREG, RA0);
	mem(Stw, O(REG, FP), RREG, RFP);
	CALL(rmfram);

	con((ulong)&R, RREG, 1);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RETURN;
}

static void
macrelq(void)
{
	mem(Stw, O(REG,FP),RREG, RFP);
	mem(Stw, O(REG,PC),RREG, RLINK);
	mem(Ldw, O(REG, xpc), RREG, RLINK);
	RETURN;
}

void
comd(Type *t)
{
	int i, j, m, c;

	mem(Stw, O(REG, dt), RREG, RLINK);
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		j = i<<5;
		for(m = 0x80; m != 0; m >>= 1) {
			if(c & m) {
				mem(Ldw, j, RFP, RA0);
				CALL(base+macro[MacFRP]);
			}
			j += sizeof(WORD*);
		}
		flushchk();
	}
	mem(Ldw, O(REG, dt), RREG, RLINK);
	RETURN;
	flushcon(0);
}

void
comi(Type *t)
{
	int i, j, m, c;

	con((ulong)H, RA0, 1);
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		j = i<<5;
		for(m = 0x80; m != 0; m >>= 1) {
			if(c & m)
				mem(Stw, j, RA2, RA0);
			j += sizeof(WORD*);
		}
		flushchk();
	}
	RETURN;
	flushcon(0);
}

void
typecom(Type *t)
{
	int n;
	ulong *tmp, *start;

	if(t == nil || t->initialize != 0)
		return;

	tmp = mallocz(4096*sizeof(ulong), 0);
	if(tmp == nil)
		error(exNomem);

	code = tmp;
	comi(t);
	n = code - tmp;
	code = tmp;
	comd(t);
	n += code - tmp;
	free(tmp);

	n *= sizeof(*code);
	code = mallocz(n, 0);
	if(code == nil)
		return;

	start = code;
	t->initialize = code;
	comi(t);
	t->destroy = code;
	comd(t);

	segflush(start, n*sizeof(*start));

	if(cflag > 3)
		print("typ= %.8lx %4d i %.8lx d %.8lx asm=%d\n",
			t, t->size, t->initialize, t->destroy, n);
}

static void
patchex(Module *m, ulong *p)
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
	Link *l;
	Modl *e;
	int i, n;
	ulong *s, *tmp;

	base = nil;
	patch = mallocz(size*sizeof(*patch), 0);
	tinit = malloc(m->ntype*sizeof(*tinit));
	tmp = malloc(4096*sizeof(ulong));
	if(tinit == nil || patch == nil || tmp == nil)
		goto bad;

	preamble();

	mod = m;
	n = 0;
	pass = 0;
	nlit = 0;

	for(i = 0; i < size; i++) {
		codeoff = n;
		code = tmp;
		comp(&m->prog[i]);
		patch[i] = n;
		n += code - tmp;
	}

	for(i = 0; i < nelem(mactab); i++) {
		codeoff = n;
		code = tmp;
		mactab[i].gen();
		macro[mactab[i].idx] = n;
		n += code - tmp;
	}
	code = tmp;
	flushcon(0);
	n += code - tmp;

	base = mallocz((n+nlit)*sizeof(*code), 0);
	if(base == nil)
		goto bad;

	if(cflag > 3)
		print("dis=%5d %5d %d asm=%.8lx: %s\n",
			size, size*sizeof(Inst), n, base, m->name);

	pass++;
	nlit = 0;
	litpool = base+n;
	code = base;
	n = 0;
	codeoff = 0;
	for(i = 0; i < size; i++) {
		s = code;
		comp(&m->prog[i]);
		if(patch[i] != n) {
			print("%3d %D\n", i, &m->prog[i]);
			print("%lu != %d\n", patch[i], n);
			urk("phase error");
		}
		n += code - s;
		if(cflag > 4) {
			print("%3d %D\n", i, &m->prog[i]);
			das(s, code-s);
		}
	}

	for(i = 0; i < nelem(mactab); i++) {
		s = code;
		mactab[i].gen();
		if(macro[mactab[i].idx] != n){
			print("mac phase err: %lu != %d\n", macro[mactab[i].idx], n);
			urk("phase error");
		}
		n += code - s;
		if(cflag > 4) {
			print("%s:\n", mactab[i].name);
			das(s, code-s);
		}
	}
	s = code;
	flushcon(0);
	n += code - s;

	for(l = m->ext; l->name; l++) {
		l->u.pc = (Inst*)RELPC(patch[l->u.pc-m->prog]);
		typecom(l->frame);
	}
	if(ml != nil) {
		e = &ml->links[0];
		for(i = 0; i < ml->nlinks; i++) {
			e->u.pc = (Inst*)RELPC(patch[e->u.pc-m->prog]);
			typecom(e->frame);
			e++;
		}
	}
	for(i = 0; i < m->ntype; i++) {
		if(tinit[i] != 0)
			typecom(m->type[i]);
	}
	patchex(m, patch);
	m->entry = (Inst*)RELPC(patch[mod->entry-mod->prog]);
	free(patch);
	free(tinit);
	free(tmp);
	free(m->prog);
	m->prog = (Inst*)base;
	m->compiled = 1;
	segflush(base, n*sizeof(*base));
	return 1;
bad:
	free(patch);
	free(tinit);
	free(base);
	free(tmp);
	return 0;
}
