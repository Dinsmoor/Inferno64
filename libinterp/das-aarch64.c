/*
 * AArch64 instruction disassembler for Inferno interpreter.
 * Based on das-arm.c for ARM32.
 */

#include <lib9.h>

typedef struct Instr Instr;
struct Instr
{
	uint32_t w;		/* instruction word value */
	uint32_t addr;		/* address of start of instruction */
	uchar op;		/* super opcode / instruction class */
	uchar cond;		/* condition bits 29-30 */
	uchar sz;		/* size bit (31 for dword) */
	uchar rd;		/* bits 0-4: Rd (first reg) */
	uchar rn;		/* bits 5-9: Rn (second reg) */
	uchar rm;		/* bits 16-20: Rm (third reg) */
	uint16_t imm12;		/* 12-bit immediate */
	uint16_t imm16;		/* 16-bit immediate */
	uint16_t imm7;		/* 7-bit offset */
	uint32_t imm9;		/* 9-bit immediate */
	long imm19;		/* 19-bit branch offset */
	long imm26;		/* 26-bit branch offset */
	char *curr;		/* fill point in output buffer */
	char *end;		/* end of buffer */
	char *err;		/* error message */
};

typedef struct Opcode Opcode;
struct Opcode
{
	char *o;
	void (*f)(Opcode *, Instr *);
	char *a;
};

static char *regname[] = {
	"x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
	"x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
	"x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23",
	"x24", "x25", "x26", "x27", "x28", "x29", "x30", "x31"
};
#define REG(r) regname[r]

static char *shname[] = {
	"<<", ">>", "->", ">>>"
};

static char *condname[] = {
	"EQ", "NE", "CS", "CC",
	"MI", "PL", "VS", "VC",
	"HI", "LS", "GE", "LT",
	"GT", "LE", "AL", "NV"
};

static void format(char *, Instr *, char *);

/*
 * Classify the instruction for dispatch to the correct decoder function.
 * Bits 28-24 encode the super-opcode in the AArch64 ARM mapping.
 */
static int
aarch64class(uint32_t w)
{
	int op;

	op = (w >> 24) & 0x1f;

	/* A64 encoding: bit 31 = 0 for most ALU, bit 31 = 1 for branches */
	if (w & (1 << 31)) {
		/* Branch / special */
		if (w & (1 << 24)) {
			/* B, BL, BR, BLR, RET */
			return 90;
		}
		/* A64 system / special */
		return 95;
	}

	switch (op) {
	case 0x00: case 0x01: case 0x02: case 0x03: case 0x04:
	case 0x05: case 0x06: case 0x07: case 0x08:
	case 0x09: case 0x0a: case 0x0b: case 0x0c:
	case 0x0d: case 0x0e: case 0x0f:
		/* Data processing — register (10xxxxxx) */
		return 10;
	case 0x10: case 0x11: case 0x12: case 0x13:
	case 0x14: case 0x15: case 0x16: case 0x17:
	case 0x18: case 0x19: case 0x1a: case 0x1b:
	case 0x1c: case 0x1d: case 0x1e: case 0x1f:
		/* Data processing — immediate or move wide */
		if (w & (1 << 22) && !(w & (1 << 30))) {
			/* Move wide: MOVZ/MOVK */
			return 20;
		}
		/* Data processing — immediate (ADD/SUB/AND/ORR/BIC with imm12) */
		return 21;
	case 0x20: case 0x28:
		/* Load/store pair */
		return 30;
	case 0x30: case 0x34: case 0x38: case 0x3C:
		/* Load/store single */
		return 40;
	case 0x50: case 0x54:
		/* Compare and branch (CBZ/CBNZ) */
		return 50;
	case 0x32: case 0x52:
		/* Test and branch (TBZ/TBNZ) */
		return 52;
	case 0x1E:
		/* Floating point */
		return 60;
	case 0x5A:
		/* Conditional compare */
		return 65;
	default:
		break;
	}
	return 99;
}

static int
decode(uint32_t addr, Instr *i)
{
	uint32_t w;

	w = *(uint32_t *)addr;
	i->w = w;
	i->addr = addr;
	i->cond = (w >> 29) & 0x3;
	i->sz = (w >> 31) & 0x1;
	i->op = aarch64class(w);

	/* Common fields */
	i->rd = (w >> 0) & 0x1f;
	i->rn = (w >> 5) & 0x1f;
	i->rm = (w >> 16) & 0x1f;

	switch (i->op) {
	/* A: Data Processing — Register (bit 31=0, bits 28-24 = 0) */
	case 10: {
		int opclass;
		opclass = (w >> 21) & 0xf;
		/* Bit 31 = 0 for 32-bit, 1 for 64-bit in some encodings */
		if (w & (1 << 31)) {
			/* These are already flagged */
		}
		/* Determine the precise op from bits 21-24 and bit 31 */
		if ((w & 0x1f200000) == 0x0b200000) {
			/* 32-bit variant: ADDW/SUBW */
			opclass = (w >> 21) & 0xf;
		} else {
			/* 64-bit variant */
			opclass = (w >> 21) & 0xf;
		}
		i->op = 10 + (opclass & 0x7);
		break;
	}

	/* B: Data Processing — Immediate */
	case 21: {
		int opclass;
		if (w & (1 << 29)) {
			/* ADD with shift (shift register) */
			i->imm12 = (w >> 10) & 0xfff;
			/* check for shift type */
			i->op = 21;
			break;
		}
		/* Shifted register or immediate */
		opclass = (w >> 22) & 0xf;
		if (opclass == 0x0a) {
			/* ADD (shifted register) */
			i->op = 22;
			break;
		}
		/* Immediate form */
		if ((w & 0x9f000000) == 0x90000000) {
			/* ADD, SUB, AND, ORR, BIC with imm12 */
			i->imm12 = (w >> 10) & 0xfff;
			i->op = 21 + ((w >> 29) & 0x7);
			break;
		}
		i->imm12 = (w >> 10) & 0xfff;
		i->op = 21;
		break;
	}

	/* C: Move Wide */
	case 20: {
		if ((w & 0xff000010) == 0x52000000) {
			/* MOVZ / ORR (with neg) */
			i->op = 20;
		} else {
			/* MOVK */
			i->op = 20 + 1;
		}
		i->imm16 = (w >> 10) & 0xffff;
		break;
	}

	/* D: Load/Store — Single */
	case 40: {
		/* Determine sub-class: LDUR/STUR vs LDR/STR vs LDR literal */
		if ((w & 0x38000000) == 0x18000000) {
			/* LDR/STR with PC (literal) - bits 30-31 = 10 */
			i->op = 40;
			i->imm9 = (w >> 10) & 0x1ff;
			break;
		}
		if ((w & 0x38000000) == 0x38000000) {
			/* STUR */
			i->op = 41;
			i->imm9 = (w >> 10) & 0x1ff;
			i->rn = (w >> 5) & 0x1f;
			i->rd = (w >> 0) & 0x1f;
			break;
		}
		if ((w & 0x3c000000) == 0x38000000) {
			/* LDUR */
			i->op = 42;
			i->imm9 = (w >> 10) & 0x1ff;
			i->rn = (w >> 5) & 0x1f;
			i->rd = (w >> 0) & 0x1f;
			break;
		}
		if ((w & 0x3c000000) == 0x3c000000) {
			/* LDR/STR register offset */
			i->op = 43;
			i->imm12 = (w >> 10) & 0xfff;
			i->rn = (w >> 5) & 0x1f;
			i->rd = (w >> 0) & 0x1f;
			break;
		}
		/* STUR */
		if ((w & 0x38000000) == 0x38000000) {
			i->op = 44;
			i->imm9 = (w >> 10) & 0x1ff;
			i->rn = (w >> 5) & 0x1f;
			i->rd = (w >> 0) & 0x1f;
			break;
		}
		break;
	}

	/* E: Load/Store Pair */
	case 30:
		break;

	/* F: Branch — Unconditional */
	case 90: {
		/* B / BL: 26-bit offset, bits 31=1, 30=0 */
		if ((w & 0xc0000000) == 0x80000000) {
			/* B or BL */
			i->imm26 = (int32_t)(w & 0x03ffffff) << 2;
			i->op = (w & (1 << 24)) ? 91 : 90;
			break;
		}
		/* BR/BLR */
		i->op = 92;
		break;
	}

	/* G: Compare/Branch */
	case 50: {
		/* CBZ / CBNZ: 19-bit offset */
		i->imm19 = (long)((int32_t)(w & 0x7ffff) << 2);
		i->op = (w & (1 << 24)) ? 51 : 50;
		break;
	}

	/* G2: Test/Branch */
	case 52: {
		/* TBZ/TBNZ */
		i->imm3 = (w >> 19) & 0x7;
		i->imm16 = (w >> 5) & 0xffff;
		i->op = (w & (1 << 24)) ? 53 : 52;
		break;
	}

	/* H: System / Special */
	case 95: {
		/* MRS, MSR, RET, DSB, ISB */
		if ((w & 0x7b1f0000) == 0x1b000000) {
			/* MRS */
			i->op = 96;
			break;
		}
		if ((w & 0x7f1f0000) == 0x1b000000) {
			/* MSR */
			i->op = 97;
			break;
		}
		if ((w & 0xffc00000) == 0xd65f0000) {
			/* RET */
			i->op = 98;
			break;
		}
		if ((w & 0xff000000) == 0xd5000000) {
			/* DSB / ISB */
			i->op = (w & (1 << 10)) ? 99 : 98;
			break;
		}
		/* BR/BLR (bit 31=1, but not in B/BL range) */
		i->op = 92;
		break;
	}

	/* I: Floating Point */
	case 60:
		break;

	/* NOPS: bit pattern 11011001 00011010 */
	default:
		if (w == 0xd503201f || w == 0xd503205f || w == 0xd503209f ||
		    w == 0xd50320df) {
			i->op = 70;
		} else if (w == 0xd503201f) {
			i->op = 70;
		}
		break;
	}
	return 1;
}

static void
bprint(Instr *i, char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	i->curr = vseprint(i->curr, i->end, fmt, ap);
	va_end(ap);
}

static void
format(char *mnemonic, Instr *i, char *f)
{
	int j, k, m, n;
	long off;

	if (mnemonic)
		format(0, i, mnemonic);
	if (f == 0)
		return;
	if (mnemonic)
		if (i->curr < i->end)
			*i->curr++ = '\t';
	for (; *f && i->curr < i->end; f++) {
		if (*f != '%') {
			*i->curr++ = *f;
			continue;
		}
		switch (*++f) {

		case 'C':	/* .CONDITION */
			if (condname[i->cond])
				bprint(i, "%s", condname[i->cond]);
			break;

		case 'n':
			bprint(i, "%s", REG(i->rn));
			break;

		case 'd':
			bprint(i, "%s", REG(i->rd));
			break;

		case 's':
			bprint(i, "%s", REG(i->rm));
			break;

		case 'i':
			bprint(i, "$#%lx", i->imm12);
			break;

		case 'I':
			bprint(i, "#%lx", i->imm16);
			break;

		case 'b':
			/* branch target = addr + imm26 */
			off = (i->imm26 >> 2);
			bprint(i, "%lx", i->addr + off);
			break;

		case 'B':
			/* relative branch offset */
			off = (i->imm19 >> 2);
			bprint(i, "%lx", i->addr + off);
			break;

		case 'h':
			bprint(i, "%s", shname[0]);
			break;

		case 'H':
			/* shift type */
			j = (i->w >> 22) & 0x3;
			if (j < 4)
				bprint(i, "%s", shname[j]);
			break;

		case 'D':
			/* pre/post-index: bit 23 set = post, clear = pre */
			if (i->w & (1 << 23))
				bprint(i, ", +");
			else
				bprint(i, ", -");
			break;

		case 'r':
			/* register list for LDP/STP */
			n = i->rd;
			k = i->rn;
			bprint(i, "%s,%s", REG(n), REG(k));
			break;

		case '\0':
			*i->curr++ = '%';
			return;

		default:
			bprint(i, "%%%c", *f);
			break;
		}
	}
	*i->curr = 0;
}

/* Instruction decoder functions */

/* A: Data Processing — Register */
static void
dpr(Opcode *o, Instr *i)
{
	int addop;

	addop = (i->w >> 21) & 0x7;
	switch (addop) {
	case 0:	/* ADD */
		i->op = 10 + 0;
		format(o->o, i, o->a);
		break;
	case 1:	/* SUB */
		i->op = 10 + 1;
		format(o->o, i, o->a);
		break;
	default:
		format(o->o, i, o->a);
		break;
	}
}

/* B: Data Processing — Immediate */
static void
dpi(Opcode *o, Instr *i)
{
	int addop;

	addop = (i->w >> 29) & 0x7;
	switch (addop) {
	case 0:	/* ADD */
		i->op = 21;
		format(o->o, i, o->a);
		break;
	case 1:	/* SUB */
		i->op = 22;
		format(o->o, i, o->a);
		break;
	case 2:	/* AND */
		i->op = 23;
		format(o->o, i, o->a);
		break;
	case 3:	/* ORR */
		i->op = 24;
		format(o->o, i, o->a);
		break;
	case 4:	/* EOR */
		i->op = 25;
		format(o->o, i, o->a);
		break;
	case 5:	/* ADD (shifted reg) */
		i->op = 26;
		format(o->o, i, o->a);
		break;
	case 6:	/* BIC */
		i->op = 27;
		format(o->o, i, o->a);
		break;
	case 7:	/* NOT */
		i->op = 28;
		format(o->o, i, o->a);
		break;
	default:
		format(o->o, i, o->a);
		break;
	}
}

/* C: Move Wide */
static void
mwi(Opcode *o, Instr *i)
{
	if ((i->w & 0x60800000) == 0x52800000) {
		/* MOVZ: clear bits to zero */
		i->op = 20;
		format(o->o, i, o->a);
	} else {
		/* MOVK: keep existing bits */
		i->op = 21;
		format(o->o, i, o->a);
	}
}

/* D: Load/Store — Single */
static void
lss(Opcode *o, Instr *i)
{
	int lsb;

	/* Determine load vs store */
	lsb = (i->w >> 22) & 1;
	if (i->w & (1 << 22)) {
		/* LDR */
		i->op = 40;
		format(o->o, i, o->a);
	} else {
		/* STR */
		i->op = 41;
		format(o->o, i, o->a);
	}
}

/* E: Load/Store Pair */
static void
lsp(Opcode *o, Instr *i)
{
	int l, at;

	l = (i->w >> 22) & 1;
	at = (i->w >> 26) & 3;
	if (l) {
		i->op = 30;
	} else {
		i->op = 31;
	}
	format(o->o, i, o->a);
}

/* F: Branch — Unconditional */
static void
br(Opcode *o, Instr *i)
{
	if ((i->w & (1 << 24))) {
		/* BL */
		i->op = 91;
	} else {
		/* B */
		i->op = 90;
	}
	format(o->o, i, o->a);
}

/* G: Compare/Branch */
static void
cb(Opcode *o, Instr *i)
{
	if ((i->w & (1 << 24))) {
		/* CBNZ */
		i->op = 51;
	} else {
		/* CBZ */
		i->op = 50;
	}
	format(o->o, i, o->a);
}

/* G2: Test/Branch */
static void
tbr(Opcode *o, Instr *i)
{
	if ((i->w & (1 << 24))) {
		/* TBNZ */
		i->op = 53;
	} else {
		/* TBZ */
		i->op = 52;
	}
	format(o->o, i, o->a);
}

/* H: System / Special */
static void
sysop(Opcode *o, Instr *i)
{
	int subop;

	subop = (i->w >> 21) & 0x7;
	switch (subop) {
	case 0:	/* MRS */
		i->op = 96;
		break;
	case 1:	/* MSR */
		i->op = 97;
		break;
	case 2: case 3: case 4: case 5: case 6:
		/* RET */
		i->op = 98;
		break;
	case 7:
		/* DSB/ISB */
		i->op = (i->w & (1 << 10)) ? 99 : 98;
		break;
	}
	format(o->o, i, o->a);
}

/* I: Floating Point */
static void
fp(Opcode *o, Instr *i)
{
	int fpaddop;

	fpaddop = (i->w >> 22) & 0x7;
	switch (fpaddop) {
	case 0:	/* FADD */
		i->op = 60;
		break;
	case 1:	/* FMUL */
		i->op = 61;
		break;
	case 2:	/* FSUB */
		i->op = 62;
		break;
	case 4:	/* FDIV */
		i->op = 63;
		break;
	case 5:	/* FMOV */
		i->op = 64;
		break;
	case 6:	/* FCMP */
		i->op = 65;
		break;
	case 7:
		/* FCEQ/FCSG/FCSLE/FCVTS/FCVTN/FCSGT/FCVTLS/FCVTLS/FCVTNL/FCMPNS/FCNEN/FCGE/FCGT/FCMLE/FCMLT/FCNVLS */
		i->op = 65;
		break;
	default:
		i->op = 60;
		break;
	}
	format(o->o, i, o->a);
}

/* 70: NOP */
static void
nop(Opcode *o, Instr *i)
{
	format(o->o, i, o->a);
}

/* 92: BR/BLR */
static void
brlr(Opcode *o, Instr *i)
{
	if ((i->w & (1 << 24))) {
		/* BLR */
		i->op = 94;
	} else {
		/* BR */
		i->op = 93;
	}
	format(o->o, i, o->a);
}

/*
 * Opcode tables — organized by class.
 * The 'o' field is the mnemonic prefix (with % format codes).
 * The 'a' field is the argument string (with % format codes).
 */

/* A: Data Processing — Register */
static Opcode a_dpr[] = {
	{"ADD",	dpr,	"%d,%n,%s"},
	{"SUB",	dpr,	"%d,%n,%s"},
	{"AND",	dpr,	"%d,%n,%s"},
	{"ORR",	dpr,	"%d,%n,%s"},
	{"EOR",	dpr,	"%d,%n,%s"},
	{"ADDW",dpr,	"%w,%n,%s"},
	{"SUBW",dpr,	"%w,%n,%s"},
	{"BIC",	dpr,	"%d,%n,%s"},
	{"MVN",	dpr,	"%d,%n,%s"},
};

/* B: Data Processing — Immediate */
static Opcode a_dpi[] = {
	{"ADD",	dpi,	"%d,%n,#%i"},
	{"ADDW",dpi,	"%w,%n,#%i"},
	{"SUB",	dpi,	"%d,%n,#%i"},
	{"SUBW",dpi,	"%w,%n,#%i"},
	{"AND",	dpi,	"%d,%n,#%i"},
	{"ORR",	dpi,	"%d,%n,#%i"},
	{"EOR",	dpi,	"%d,%n,#%i"},
	{"BIC",	dpi,	"%d,%n,#%i"},
	{"MOV",	dpi,	"%d,#%i"},
	{"MOVW",dpi,	"%w,#%i"},
};

/* C: Move Wide */
static Opcode a_mwi[] = {
	{"MOVZ",mwi,	"%d,#%I"},
	{"MOVK",mwi,	"%d,#%I"},
};

/* D: Load/Store — Single (LDUR/STUR) */
static Opcode a_ldur[] = {
	{"LDUR",lss,	"%d,%n+#%i"},
	{"STUR",lss,	"%d,%n+#%i"},
};

/* D: Load/Store — Single (LDR/STR register offset) */
static Opcode a_ldr_str[] = {
	{"LDR",	lss,	"%d,%n+#%i"},
	{"STR",	lss,	"%d,%n+#%i"},
};

/* D: Load/Store — Single (literal) */
static Opcode a_ldrl[] = {
	{"LDR",	lss,	"%d,#%i(PC)"},
};

/* E: Load/Store Pair */
static Opcode a_ldstpair[] = {
	{"LDP",	lsp,	"%d,%n,%r"},
	{"STP",	lsp,	"%d,%n,%r"},
};

/* F: Branch */
static Opcode a_br[] = {
	{"B",	br,	"%b"},
	{"BL",	br,	"%b"},
};

/* G: Compare/Branch */
static Opcode a_cb[] = {
	{"CBZ",	cb,	"%n,%b"},
	{"CBNZ",cb,	"%n,%b"},
};

/* G2: Test/Branch */
static Opcode a_tbr[] = {
	{"TBZ",	tbr,	"%n,%i,#%i"},
	{"TBNZ",tbr,	"%n,%i,#%i"},
};

/* H: System */
static Opcode a_sys[] = {
	{"MRS",	sysop,	"%d,%n"},
	{"MSR",	sysop,	"%d,%n"},
	{"RET",	sysop,	""},
	{"DSB",	sysop,	""},
	{"ISB",	sysop,	""},
};

/* I: Floating Point */
static Opcode a_fp[] = {
	{"FADD",fp,	"%d,%n,%s"},
	{"FMUL",fp,	"%d,%n,%s"},
	{"FSUB",fp,	"%d,%n,%s"},
	{"FDIV",fp,	"%d,%n,%s"},
	{"FMOV",fp,	"%d,%n,%s"},
	{"FCMP",fp,	"%n,%s"},
};

/* NOP */
static Opcode a_nop[] = {
	{"NOP",	nop,	""},
};

/* BR/BLR */
static Opcode a_br2[] = {
	{"BR",	brlr,	"%s"},
	{"BLR",	brlr,	"%s"},
	{"RET",	brlr,	""},
};

/*
 * Super-opcode dispatch table.
 * The index is computed by decode() into the "op" field of Instr.
 */

static struct Dispatcher {
	int minop;
	int maxop;
	Opcode *tbl;
	int ntbl;
	char *cls;
} dispatch[] = {
	/* 10-16: Data Processing — Register (ADD, SUB, AND, ORR, EOR, BIC, MVN) */
	{10, 16, a_dpr, 9, "dpr"},
	/* 20-28: Data Processing — Immediate (ADD, SUB, AND, ORR, EOR, ADDW, SUBW, BIC, MOV) */
	{20, 28, a_dpi, 11, "dpi"},
	/* 20, 21: Move Wide (MOVZ, MOVK) */
	{20, 21, a_mwi, 2, "mwi"},
	/* 30, 31: Load/Store Pair */
	{30, 31, a_ldstpair, 2, "ldstpair"},
	/* 40-44: Load/Store Single (LDR/STR) */
	{40, 44, a_ldr_str, 2, "ldrst"},
	/* 50, 51: CBZ/CBNZ */
	{50, 51, a_cb, 2, "cb"},
	/* 52, 53: TBZ/TBNZ */
	{52, 53, a_tbr, 2, "tbr"},
	/* 60-65: Floating Point */
	{60, 65, a_fp, 6, "fp"},
	/* 70: NOP */
	{70, 70, a_nop, 1, "nop"},
	/* 90-94: Branch/Branch Link */
	{90, 94, a_br2, 3, "br"},
	/* 96-99: System (MRS, MSR, RET, DSB, ISB) */
	{96, 99, a_sys, 5, "sys"},
	/* 40-43: LDUR/STUR (sub-class) */
	{40, 43, a_ldur, 2, "ldur"},
};

static int
ndispatch = sizeof(dispatch) / sizeof(dispatch[0]);

static void
demit(Opcode *o, Instr *i)
{
	char buf[128];
	Instr instr;

	buf[0] = 0;
	instr = *i;
	instr.curr = buf;
	instr.end = buf + sizeof(buf) - 1;

	format(0, &instr, o->o);
	if (o->a[0]) {
		format(0, &instr, o->a);
	}
	print("%.8lux %.8lux\t%s\n", instr.addr, instr.w, buf);
}

void
das(ulong *x, int n)
{
	uint32_t *addr;
	Instr i;
	int j, k;

	addr = (uint32_t *)x;
	while (n > 0) {
		if (decode((uint32_t)(uintptr)addr, &i) < 0) {
			print("%.8lux %.8lux\t???\n", (ulong)(uintptr)addr, i.w);
			addr++;
			n--;
			continue;
		}

		/* Find the right dispatch table and opcode */
		for (j = 0; j < ndispatch; j++) {
			if (i.op >= dispatch[j].minop && i.op <= dispatch[j].maxop) {
				/* Within range, find the exact opcode */
				for (k = 0; k < dispatch[j].ntbl; k++) {
					if (dispatch[j].tbl[k].f != 0) {
						demit(&dispatch[j].tbl[k], &i);
						goto next;
					}
				}
			}
		}
		/* Unknown instruction */
		print("%.8lux %.8lux\t???\n", (ulong)(uintptr)addr, i.w);

next:
		addr++;
		n--;
	}
}
