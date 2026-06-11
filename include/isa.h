/*
 * VM instruction set
 */
enum
{
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
	/* Fix MAXDIS if you add opcodes */
};

enum
{
	MAXDIS	= ISELF+1,

	XMAGIC	= 819248,	/* base magic: 32-bit pointer, 32-bit word (classic Dis) */
	SMAGIC	= 923426,	/* signed module, classic */
	/*
	 * ABI width tags OR'd onto the base magic.  A module's binary layout
	 * (register/pointer slot sizes, GC-map granularity, frame sizes, the
	 * width of a Dis word / Limbo int) is a pure function of two widths:
	 * IBY2PTR (the pointer slot) and IBY2WD (the Dis word).  The
	 * instruction/data stream still *parses* regardless of either, so the
	 * magic is the only safe discriminator.  Two bits encode the two
	 * widths so that any ABI mismatch -- not just pointer-width skew --
	 * is rejected rather than silently mis-run (see libinterp/load.c):
	 *
	 *   IBY2PTR IBY2WD  flags                 ABI
	 *      4      4     -                     classic 32-bit  (XMAGIC)
	 *      8      4     DISptr64              LP64            (XMAGIC8)
	 *      8      8     DISptr64|DISword64    ILP64
	 *
	 * DISptr64 keeps its historical value, so existing XMAGIC8 binaries
	 * (LP64 = ptr64, word32, DISword64 clear) load unchanged.
	 */
	DISptr64   = 0x100000,	/* set: IBY2PTR == 8 (64-bit pointer slots) */
	DISword64  = 0x200000,	/* set: IBY2WD  == 8 (64-bit Dis word / Limbo int) */
	DISabimask = DISptr64 | DISword64,
	XMAGIC8	= XMAGIC | DISptr64,	/* grandfathered alias: LP64 (ptr64, word32) = 1867824 */
	SMAGIC8	= SMAGIC | DISptr64,	/* grandfathered alias: signed LP64 = 1972002 */

	AMP	= 0x00,		/* Src/Dst op addressing */
	AFP	= 0x01,
	AIMM	= 0x02,
	AXXX	= 0x03,
	AIND	= 0x04,
	AMASK	= 0x07,
	AOFF	= 0x08,
	AVAL	= 0x10,

	ARM	= 0xC0,		/* Middle op addressing */
	AXNON	= 0x00,
	AXIMM	= 0x40,
	AXINF	= 0x80,
	AXINM	= 0xC0,

	DEFZ	= 0,
	DEFB	= 1,		/* Byte */
	DEFW	= 2,		/* Word */
	DEFS	= 3,		/* Utf-string */
	DEFF	= 4,		/* Real value */
	DEFA	= 5,		/* Array */
	DIND	= 6,		/* Set index */
	DAPOP	= 7,		/* Restore address register */
	DEFL	= 8,		/* BIG */
	DEFSS = 9,	/* String share - not used yet */

	DADEPTH = 4,		/* Array address stack size */

	REGLINK	= 0,
	REGFRAME= 1,
	REGMOD	= 2,
	REGTYP	= 3,
	REGRET	= 4,
	NREG	= 5,

	IBY2WD	= 4,
	IBY2FT	= 8,
	IBY2LG	= 8,
	/*
	 * IBY2PTR is the size of a Dis pointer/register slot in bytes.  It MUST
	 * equal the host's sizeof(void*): the interpreter stores native C
	 * pointers in frame register slots and pointer-typed fields and strides
	 * its GC pointer-maps by sizeof(WORD*), so any mismatch corrupts memory
	 * (enforced by a static assert in libinterp/xec.c).  The .dis ABI thus
	 * follows the build's pointer width automatically: a 32-bit build gets
	 * IBY2PTR==4 (== IBY2WD) and stamps/accepts XMAGIC; a 64-bit build gets
	 * 8 and uses XMAGIC8.  See limbo/com.c (stamp) and libinterp/load.c
	 * (accept).  sizeof() is an integer constant expression, so this is a
	 * compile-time constant the magic-selection branches fold away.
	 */
	IBY2PTR	= sizeof(void*),

	MUSTCOMPILE	= (1<<0),
	DONTCOMPILE	= (1<<1),
	SHAREMP		= (1<<2),
	DYNMOD		= (1<<3),
	HASLDT0	= (1<<4),
	HASEXCEPT	= (1<<5),
	HASLDT	= (1<<6),
};

#define DTYPE(x)	(x>>4)
#define DBYTE(x, l)	((x<<4)|l)
#define DMAX		(1<<4)
#define DLEN(x)		(x& (DMAX-1))

#define SRC(x)		((x)<<3)
#define DST(x)		((x)<<0)
#define USRC(x)		(((x)>>3)&AMASK)
#define UDST(x)		((x)&AMASK)
#define UXSRC(x)	((x)&(AMASK<<3))
#define UXDST(x)	((x)&(AMASK<<0))
