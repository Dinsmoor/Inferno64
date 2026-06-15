/*
 * Native-code disassembler for x86-64 (amd64) -- a debug aid for the Dis JIT.
 *
 * das() is reachable only with `emu -c5` and up (cflag>4): compile() in
 * comp-amd64.c prints each Dis instruction, then das() of the x86-64 bytes the
 * back-end emitted for it.  This is therefore NOT a general x86 disassembler --
 * it decodes exactly the instruction forms comp-amd64.c emits.  What matters
 * most is correct length decoding so the listing walks instruction by
 * instruction without desyncing; anything unrecognised prints as `.byte` and
 * advances one byte, so a stray opcode degrades the listing locally.
 *
 * Intel operand order (dst, src).  Memory operands print as [base+index*s+disp].
 */
#include <lib9.h>
#include <kernel.h>

static char *reg64[16] = {
	"rax","rcx","rdx","rbx","rsp","rbp","rsi","rdi",
	"r8","r9","r10","r11","r12","r13","r14","r15",
};
static char *reg32[16] = {
	"eax","ecx","edx","ebx","esp","ebp","esi","edi",
	"r8d","r9d","r10d","r11d","r12d","r13d","r14d","r15d",
};
static char *reg8[16] = {
	"al","cl","dl","bl","spl","bpl","sil","dil",
	"r8b","r9b","r10b","r11b","r12b","r13b","r14b","r15b",
};

typedef struct Dec Dec;
struct Dec
{
	uchar	*p;		/* cursor */
	uchar	*end;
	int	rex;		/* REX byte (0x40..0x4F), or 0 */
	int	o16;		/* 0x66 operand-size prefix seen */
	int	rep;		/* 0xF2 / 0xF3 mandatory prefix, or 0 */
	char	*c;		/* output fill point */
	char	*e;
};

#define REXW(d)	((d)->rex & 8)
#define REXR(d)	(((d)->rex & 4) ? 8 : 0)
#define REXX(d)	(((d)->rex & 2) ? 8 : 0)
#define REXB(d)	(((d)->rex & 1) ? 8 : 0)

/* width codes for a register operand */
enum { Wbyte, Wgp, Wxmm };

static void
emit(Dec *d, char *fmt, ...)
{
	va_list a;

	va_start(a, fmt);
	d->c = vseprint(d->c, d->e, fmt, a);
	va_end(a);
}

/* signed little-endian fetch of w bytes (1, 4 or 8) */
static vlong
imm(Dec *d, int w)
{
	uvlong v;
	int i;

	v = 0;
	for(i = 0; i < w && d->p < d->end; i++)
		v |= (uvlong)*d->p++ << (8*i);
	switch(w){
	case 1: return (vlong)(schar)v;
	case 4: return (vlong)(int)v;
	}
	return (vlong)v;
}

static char *
rname(Dec *d, char *buf, int idx, int wcode)
{
	idx &= 15;
	switch(wcode){
	case Wxmm:  seprint(buf, buf+16, "xmm%d", idx); break;
	case Wbyte: seprint(buf, buf+16, "%s", reg8[idx]); break;
	default:    seprint(buf, buf+16, "%s", REXW(d) ? reg64[idx] : reg32[idx]); break;
	}
	return buf;
}

/*
 * Decode the ModRM (+SIB +disp) at d->p: set *reg to the reg-field index (with
 * REX.R), and fill rm[] with the r/m operand -- a register name at width rmw,
 * or a memory reference.  Advances d->p past the whole addressing form.
 */
static void
getmodrm(Dec *d, int *reg, char *rm, int rmsz, int rmw)
{
	int mod, r, base, idx, scale;
	vlong disp;
	char *b;

	mod = *d->p >> 6;
	*reg = ((*d->p >> 3) & 7) + REXR(d);
	r = *d->p & 7;
	d->p++;

	if(mod == 3){
		rname(d, rm, r + REXB(d), rmw);
		return;
	}
	b = rm;
	if(r == 4){				/* SIB */
		scale = 1 << (*d->p >> 6);
		idx = ((*d->p >> 3) & 7) + REXX(d);
		base = (*d->p & 7) + REXB(d);
		d->p++;
		disp = 0;
		if(mod == 1) disp = imm(d, 1);
		else if(mod == 2) disp = imm(d, 4);
		else if((base & 7) == 5) disp = imm(d, 4);
		b = seprint(b, rm+rmsz, "[%s", reg64[base & 15]);
		if((idx & 7) != 4)		/* index==rsp means "no index" */
			b = seprint(b, rm+rmsz, "+%s*%d", reg64[idx & 15], scale);
		if(disp)
			b = seprint(b, rm+rmsz, "%+lld", disp);
		seprint(b, rm+rmsz, "]");
	} else if(mod == 0 && r == 5){		/* RIP-relative disp32 */
		disp = imm(d, 4);
		seprint(b, rm+rmsz, "[rip%+lld]", disp);
	} else {
		base = r + REXB(d);
		disp = 0;
		if(mod == 1) disp = imm(d, 1);
		else if(mod == 2) disp = imm(d, 4);
		if(disp)
			seprint(b, rm+rmsz, "[%s%+lld]", reg64[base & 15], disp);
		else
			seprint(b, rm+rmsz, "[%s]", reg64[base & 15]);
	}
}

/* two-operand reg/rm form.  dir=1: reg is dst ("mn reg, rm").  dir=0: rm is dst. */
static void
two(Dec *d, char *mn, int dir, int regw, int rmw)
{
	int reg;
	char rm[64], rg[16];

	getmodrm(d, &reg, rm, sizeof rm, rmw);
	rname(d, rg, reg, regw);
	if(dir)
		emit(d, "%s\t%s,%s", mn, rg, rm);
	else
		emit(d, "%s\t%s,%s", mn, rm, rg);
}

/* /digit group form: mnemonic chosen by the reg field; optional immediate/tail */
static void
grp(Dec *d, char *mn[8], int rmw, int immw, char *tail)
{
	int reg;
	vlong k;
	char rm[64];

	getmodrm(d, &reg, rm, sizeof rm, rmw);
	emit(d, "%s\t%s", mn[reg & 7] ? mn[reg & 7] : "?", rm);
	if(immw){
		k = imm(d, immw);
		emit(d, ",%#llx", k);
	}
	if(tail)
		emit(d, "%s", tail);
}

static char *alu[8]  = {"add","or","adc","sbb","and","sub","xor","cmp"};
static char *grpff[8]= {"inc","dec","call","callf","jmp","jmpf","push","?"};
static char *grpf7[8]= {"test","?","not","neg","mul","imul","div","idiv"};
static char *grpd3[8]= {"rol","ror","rcl","rcr","shl","shr","sal","sar"};
static char *jcc[16] = {"jo","jno","jb","jae","je","jne","jbe","ja",
			"js","jns","jp","jnp","jl","jge","jle","jg"};

/* two-byte (0F xx) opcode map */
static void
decode0f(Dec *d)
{
	int op, reg;
	vlong k;
	char rm[64], rg[16];

	op = *d->p++;
	switch(op){
	case 0xB6: case 0xB7:			/* movzx reg, r/m8|16 */
		getmodrm(d, &reg, rm, sizeof rm, op == 0xB6 ? Wbyte : Wgp);
		rname(d, rg, reg, Wgp);
		emit(d, "%s\t%s,%s", op == 0xB6 ? "movzbl" : "movzwl", rg, rm);
		break;
	case 0xAF: two(d, "imul", 1, Wgp, Wgp); break;
	case 0x80: case 0x81: case 0x82: case 0x83:
	case 0x84: case 0x85: case 0x86: case 0x87:
	case 0x88: case 0x89: case 0x8A: case 0x8B:
	case 0x8C: case 0x8D: case 0x8E: case 0x8F:
		k = imm(d, 4);
		emit(d, "%s\t.%+lld", jcc[op - 0x80], k);
		break;
	case 0x10: two(d, "movsd", 1, Wxmm, Wxmm); break;	/* load  xmm<-xmm/m */
	case 0x11: two(d, "movsd", 0, Wxmm, Wxmm); break;	/* store xmm/m<-xmm */
	case 0x2A: two(d, "cvtsi2sd", 1, Wxmm, Wgp);  break;
	case 0x2C: two(d, "cvttsd2si", 1, Wgp, Wxmm); break;
	case 0x2D: two(d, "cvtsd2si", 1, Wgp, Wxmm);  break;
	case 0x2E: two(d, d->o16 ? "ucomisd" : "ucomiss", 1, Wxmm, Wxmm); break;
	case 0x2F: two(d, d->o16 ? "comisd" : "comiss", 1, Wxmm, Wxmm); break;
	case 0x54: two(d, d->o16 ? "andpd" : "andps", 1, Wxmm, Wxmm); break;
	case 0x56: two(d, d->o16 ? "orpd"  : "orps",  1, Wxmm, Wxmm); break;
	case 0x57: two(d, d->o16 ? "xorpd" : "xorps", 1, Wxmm, Wxmm); break;
	case 0x58: two(d, "addsd", 1, Wxmm, Wxmm); break;
	case 0x59: two(d, "mulsd", 1, Wxmm, Wxmm); break;
	case 0x5C: two(d, "subsd", 1, Wxmm, Wxmm); break;
	case 0x5E: two(d, "divsd", 1, Wxmm, Wxmm); break;
	case 0x6E: two(d, REXW(d) ? "movq" : "movd", 1, Wxmm, Wgp); break;
	case 0x7E: two(d, REXW(d) ? "movq" : "movd", 0, Wxmm, Wgp); break;
	default:
		emit(d, ".byte\t0x0f,%#x", op);
		break;
	}
}

/* one instruction: fills d->c.., returns bytes consumed (>=1) */
static int
decode1(Dec *d)
{
	uchar *start;
	int op, reg, w;
	vlong k;
	char rm[64], rg[16];

	start = d->p;
	d->rex = d->o16 = d->rep = 0;

	for(;;){				/* prefixes */
		if(d->p >= d->end)
			return d->p - start ? d->p - start : 1;
		op = *d->p;
		if(op == 0x66){ d->o16 = 1; d->p++; continue; }
		if(op == 0xF2 || op == 0xF3){ d->rep = op; d->p++; continue; }
		if(op == 0x67 || op == 0xF0){ d->p++; continue; }
		if((op & 0xF0) == 0x40){ d->rex = op; d->p++; continue; }
		break;
	}
	op = *d->p++;

	/* ALU grid: add/or/adc/sbb/and/sub/xor/cmp, r/m forms (low 3 bits 0..3) */
	if(op < 0x40 && (op & 7) < 4 && op != 0x0F){
		int width = (op & 1) ? Wgp : Wbyte;
		two(d, alu[(op >> 3) & 7], (op & 2) ? 1 : 0, width, width);
		return d->p - start;
	}

	switch(op){
	case 0x0F:
		decode0f(d);
		break;
	case 0x50: case 0x51: case 0x52: case 0x53:
	case 0x54: case 0x55: case 0x56: case 0x57:
		emit(d, "push\t%s", reg64[(op - 0x50) + REXB(d)]);
		break;
	case 0x58: case 0x59: case 0x5A: case 0x5B:
	case 0x5C: case 0x5D: case 0x5E: case 0x5F:
		emit(d, "pop\t%s", reg64[(op - 0x58) + REXB(d)]);
		break;
	case 0xB8: case 0xB9: case 0xBA: case 0xBB:
	case 0xBC: case 0xBD: case 0xBE: case 0xBF:
		w = REXW(d) ? 8 : 4;
		k = imm(d, w);
		emit(d, "%s\t%s,%#llx", REXW(d) ? "movabs" : "mov",
			REXW(d) ? reg64[(op-0xB8)+REXB(d)] : reg32[(op-0xB8)+REXB(d)], k);
		break;
	case 0x88: two(d, "mov", 0, Wbyte, Wbyte); break;
	case 0x8A: two(d, "mov", 1, Wbyte, Wbyte); break;
	case 0x89: two(d, "mov", 0, Wgp, Wgp); break;
	case 0x8B: two(d, "mov", 1, Wgp, Wgp); break;
	case 0x8D: two(d, "lea", 1, Wgp, Wgp); break;
	case 0x63: two(d, "movsxd", 1, Wgp, Wgp); break;
	case 0x69: case 0x6B:			/* imul reg, r/m, imm */
		getmodrm(d, &reg, rm, sizeof rm, Wgp);
		rname(d, rg, reg, Wgp);
		k = imm(d, op == 0x69 ? 4 : 1);
		emit(d, "imul\t%s,%s,%#llx", rg, rm, k);
		break;
	case 0xC7: { static char *m[8] = {"mov",0,0,0,0,0,0,0}; grp(d, m, Wgp, 4, nil); break; }
	case 0x81: grp(d, alu, Wgp, 4, nil); break;
	case 0x83: grp(d, alu, Wgp, 1, nil); break;
	case 0xD2: grp(d, grpd3, Wbyte, 0, ",cl"); break;
	case 0xD3: grp(d, grpd3, Wgp, 0, ",cl"); break;
	case 0xF7: grp(d, grpf7, Wgp, 0, nil); break;
	case 0xFF: grp(d, grpff, Wgp, 0, nil); break;
	case 0xC3: emit(d, "ret"); break;
	case 0x99: emit(d, REXW(d) ? "cqo" : "cdq"); break;
	case 0xFC: emit(d, "cld"); break;
	case 0xA4: emit(d, "movsb"); break;
	case 0xE8: k = imm(d, 4); emit(d, "call\t.%+lld", k); break;
	case 0xE9: k = imm(d, 4); emit(d, "jmp\t.%+lld", k); break;
	case 0xEB: k = imm(d, 1); emit(d, "jmp\t.%+lld", k); break;
	case 0x70: case 0x71: case 0x72: case 0x73:
	case 0x74: case 0x75: case 0x76: case 0x77:
	case 0x78: case 0x79: case 0x7A: case 0x7B:
	case 0x7C: case 0x7D: case 0x7E: case 0x7F:
		k = imm(d, 1);
		emit(d, "%s\t.%+lld", jcc[op - 0x70], k);
		break;
	default:
		emit(d, ".byte\t%#x", op);
		break;
	}
	return d->p - start;
}

void
das(uchar *x, int n)
{
	Dec d;
	char buf[160];
	uchar *base, *start;
	int len, i;

	base = x;
	d.end = x + n;
	while(base < d.end){
		d.p = base;
		d.c = buf;
		d.e = buf + sizeof buf;
		start = base;
		len = decode1(&d);
		if(len <= 0)
			len = 1;
		if(start + len > d.end)		/* don't run past the supplied range */
			len = d.end - start;
		print("%.12llux ", (uvlong)(uintptr)start);
		for(i = 0; i < len && i < 10; i++)
			print("%.2ux", start[i]);
		for(; i < 10; i++)
			print("  ");
		print(" %s\n", buf);
		base += len;
	}
}
