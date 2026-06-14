/*
 * amd64 (x86-64) native kernel u.h — gcc (LP64) flavor.
 * Same integer model as the aarch64 port: ulong/uintptr are 64-bit,
 * Limbo int stays 32-bit, so the very same .dis files run on both.
 * va_list is the compiler's own.  FP control bits are the x86 387/SSE
 * values (see libmath/FPcontrol-Inferno.c and getfcr/setfcr in l.S).
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
 * x86 FP control/status (387 control word + SSE MXCSR share these bit
 * names in the Plan 9/Inferno FP model; FPcontrol-Inferno.c maps them).
 */
#define	FPINEX	(1<<5)
#define	FPUNFL	((1<<4)|(1<<1))
#define	FPOVFL	(1<<3)
#define	FPZDIV	(1<<2)
#define	FPINVAL	(1<<0)
#define	FPRNR	(0<<10)
#define	FPRZ	(3<<10)
#define	FPRPINF	(2<<10)
#define	FPRNINF	(1<<10)
#define	FPRMASK	(3<<10)
#define	FPPEXT	(3<<8)
#define	FPPSGL	(0<<8)
#define	FPPDBL	(2<<8)
#define	FPPMASK	(3<<8)
/* sticky cumulative exception bits == the same positions */
#define	FPAINEX	FPINEX
#define	FPAOVFL	FPOVFL
#define	FPAUNFL	FPUNFL
#define	FPAZDIV	FPZDIV
#define	FPAINVAL	FPINVAL

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
