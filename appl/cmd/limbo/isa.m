#
# VM instruction set
#
	INOP,
	IALT,
	INBALT,
	IGOTO,
	ICALL,
	IFRAME,
	ISPAWN,
	IRUNT,
	ILOAD,
	IMCALL,
	IMSPAWN,
	IMFRAME,
	IRET,
	IJMP,
	ICASE,
	IEXIT,
	INEW,
	INEWA,
	INEWCB,
	INEWCW,
	INEWCF,
	INEWCP,
	INEWCM,
	INEWCMP,
	ISEND,
	IRECV,
	ICONSB,
	ICONSW,
	ICONSP,
	ICONSF,
	ICONSM,
	ICONSMP,
	IHEADB,
	IHEADW,
	IHEADP,
	IHEADF,
	IHEADM,
	IHEADMP,
	ITAIL,
	ILEA,
	IINDX,
	IMOVP,
	IMOVM,
	IMOVMP,
	IMOVB,
	IMOVW,
	IMOVF,
	ICVTBW,
	ICVTWB,
	ICVTFW,
	ICVTWF,
	ICVTCA,
	ICVTAC,
	ICVTWC,
	ICVTCW,
	ICVTFC,
	ICVTCF,
	IADDB,
	IADDW,
	IADDF,
	ISUBB,
	ISUBW,
	ISUBF,
	IMULB,
	IMULW,
	IMULF,
	IDIVB,
	IDIVW,
	IDIVF,
	IMODW,
	IMODB,
	IANDB,
	IANDW,
	IORB,
	IORW,
	IXORB,
	IXORW,
	ISHLB,
	ISHLW,
	ISHRB,
	ISHRW,
	IINSC,
	IINDC,
	IADDC,
	ILENC,
	ILENA,
	ILENL,
	IBEQB,
	IBNEB,
	IBLTB,
	IBLEB,
	IBGTB,
	IBGEB,
	IBEQW,
	IBNEW,
	IBLTW,
	IBLEW,
	IBGTW,
	IBGEW,
	IBEQF,
	IBNEF,
	IBLTF,
	IBLEF,
	IBGTF,
	IBGEF,
	IBEQC,
	IBNEC,
	IBLTC,
	IBLEC,
	IBGTC,
	IBGEC,
	ISLICEA,
	ISLICELA,
	ISLICEC,
	IINDW,
	IINDF,
	IINDB,
	INEGF,
	IMOVL,
	IADDL,
	ISUBL,
	IDIVL,
	IMODL,
	IMULL,
	IANDL,
	IORL,
	IXORL,
	ISHLL,
	ISHRL,
	IBNEL,
	IBLTL,
	IBLEL,
	IBGTL,
	IBGEL,
	IBEQL,
	ICVTLF,
	ICVTFL,
	ICVTLW,
	ICVTWL,
	ICVTLC,
	ICVTCL,
	IHEADL,
	ICONSL,
	INEWCL,
	ICASEC,
	IINDL,
	IMOVPC,
	ITCMP,
	IMNEWZ,
	ICVTRF,
	ICVTFR,
	ICVTWS,
	ICVTSW,
	ILSRW,
	ILSRL,
	IECLR,
	INEWZ,
	INEWAZ,
	IRAISE,
	ICASEL,
	IMULX,
	IDIVX,
	ICVTXX,
	IMULX0,
	IDIVX0,
	ICVTXX0,
	IMULX1,
	IDIVX1,
	ICVTXX1,
	ICVTFX,
	ICVTXF,
	IEXPW,
	IEXPL,
	IEXPF,
	ISELF,
	# add new operators here
	MAXDIS: con iota;

XMAGIC:		con 819248;	# base magic: 32-bit pointer, 32-bit word (classic Dis)
SMAGIC:		con 923426;	# signed module, classic
# ABI width tags OR'd onto the base magic (see include/isa.h): DISptr64 for
# IBY2PTR==8, DISword64 for IBY2WD==8.  Two bits so a pointer-width *or*
# word-width mismatch is rejected (an ILP64 ptr64/word64 .dis vs this LP64
# ptr64/word32 one).  XMAGIC8/SMAGIC8 kept as the grandfathered LP64 aliases.
DISptr64:	con 16r100000;	# IBY2PTR == 8
DISword64:	con 16r200000;	# IBY2WD  == 8
XMAGIC8:	con 1867824;	# XMAGIC|DISptr64: normal magic, LP64 (ptr64, word32)
SMAGIC8:	con 1972002;	# SMAGIC|DISptr64: signed module, LP64

AMP:		con 16r00;	# Src/Dst op addressing 
AFP:		con 16r01;
AIMM:		con 16r2;
AXXX:		con 16r03;
AIND:		con 16r04;
AMASK:		con 16r07;
AOFF:		con 16r08;
AVAL:		con 16r10;

ARM:		con 16rC0;	# Middle op addressing 
AXNON:		con 16r00;
AXIMM:		con 16r40;
AXINF:		con 16r80;
AXINM:		con 16rC0;

DEFZ:		con 0;
DEFB:		con 1;		# Byte 
DEFW:		con 2;		# Word 
DEFS:		con 3;		# Utf-string 
DEFF:		con 4;		# Real value 
DEFA:		con 5;		# Array 
DIND:		con 6;		# Set index 
DAPOP:		con 7;		# Restore address register 
DEFL:		con 8;		# BIG 

DADEPTH:	con 4;		# Array address stack size 

REGLINK:	con 0;
REGFRAME:	con 1;
REGMOD:		con 2;
REGTYP:		con 3;
REGRET:		con 4;
NREG:		con 5;

IBY2WD:		con 4;
IBY2FT:		con 8;
IBY2LG:		con 8;
# IBY2PTR: size of a Dis pointer/register slot in bytes; it selects the .dis
# magic this compiler stamps (XMAGIC if 4, XMAGIC8 if 8 -- see com.b).
#
# Derived with the compile-time `sizeof` operator from a reference type: every
# heap reference (string, array, list, ref) occupies exactly one pointer slot,
# so sizeof(string) == the Dis pointer width.  This auto-tracks the pointer
# width of whichever compiler builds this source -- mirroring include/isa.h's
# `IBY2PTR = sizeof(void*)` on the C side -- so no per-ABI edit is needed: a
# 64-bit build folds it to 8 (XMAGIC8), a 32-bit build to 4 (XMAGIC).
IBY2PTR:	con sizeof(string);

MUSTCOMPILE:	con 1<<0;
DONTCOMPILE:	con 1<<1;
SHAREMP:	con 1<<2;
DYNMOD:	con	1<<3;
HASLDT0:	con	1<<4;
HASEXCEPT:	con	1<<5;
HASLDT:	con	1<<6;

DMAX:		con 1 << 4;

#define DTYPE(x)	(x>>4)
#define DBYTE(x, l)	((x<<4)|l)
#define DMAX		(1<<4)
#define DLEN(x)		(x& (DMAX-1))

DBYTE:		con 4;
SRC:		con 3;
DST:		con 0;

#define SRC(x)		((x)<<3)
#define DST(x)		((x)<<0)
#define USRC(x)		(((x)>>3)&AMASK)
#define UDST(x)		((x)&AMASK)
#define UXSRC(x)	((x)&(AMASK<<3))
#define UXDST(x)	((x)&(AMASK<<0))
