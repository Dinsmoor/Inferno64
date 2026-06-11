/*
 * aarch64 native kernel u.h — gcc (LP64) flavor.
 * Unlike the legacy kencc per-arch u.h files, va_list is the compiler's
 * own; ulong/uintptr are 64-bit (LP64), matching the hosted emu ABI so
 * the same .dis files run on both.
 */
#define nil		((void*)0)

typedef	unsigned short	ushort;
typedef	unsigned char	uchar;
typedef	unsigned long	ulong;
typedef	unsigned int	uint;
typedef	signed char	schar;
typedef	long long	vlong;
typedef	unsigned long long uvlong;
typedef	uint		Rune;
typedef	union FPdbleword FPdbleword;

typedef unsigned char	u8int;
typedef unsigned short	u16int;
typedef unsigned int	u32int;
typedef unsigned long long u64int;
typedef unsigned long	uintptr;
typedef long		intptr;
typedef unsigned int	mpdigit;	/* for include/mp.h */

/* kencc compatibility */
#define	USED(...)
#define	SET(...)

typedef uintptr	jmp_buf[2];	/* unused in the kernel; Label is the real thing */
#define	JMPBUFSP	0
#define	JMPBUFPC	1
#define	JMPBUFDPC	0

/*
 * FPCR/FPSR (aarch64).  FCR = trap enables + rounding control (FPCR),
 * FSR = cumulative exception sticky bits (FPSR).
 */
/* FCR */
#define	FPINVAL	(1<<8)		/* IOE */
#define	FPZDIV	(1<<9)		/* DZE */
#define	FPOVFL	(1<<10)		/* OFE */
#define	FPUNFL	(1<<11)		/* UFE */
#define	FPINEX	(1<<12)		/* IXE */
#define	FPRNR	(0<<22)		/* round to nearest */
#define	FPRPINF	(1<<22)		/* round toward +inf */
#define	FPRNINF	(2<<22)		/* round toward -inf */
#define	FPRZ	(3<<22)		/* round toward zero */
#define	FPRMASK	(3<<22)
#define	FPPEXT	0
#define	FPPSGL	0
#define	FPPDBL	0
#define	FPPMASK	0
/* FSR */
#define	FPAINVAL	(1<<0)	/* IOC */
#define	FPAZDIV	(1<<1)		/* DZC */
#define	FPAOVFL	(1<<2)		/* OFC */
#define	FPAUNFL	(1<<3)		/* UFC */
#define	FPAINEX	(1<<4)		/* IXC */

union FPdbleword
{
	double	x;
	struct {	/* little endian */
		u32int	lo;
		u32int	hi;
	};
};

typedef __builtin_va_list va_list;
#define va_start(v,l)	__builtin_va_start(v,l)
#define va_end(v)	__builtin_va_end(v)
#define va_arg(v,l)	__builtin_va_arg(v,l)
#define va_copy(v,l)	__builtin_va_copy(v,l)
