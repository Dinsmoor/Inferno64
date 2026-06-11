#include "../port/portfns.h"

void	archconfinit(void);
void	archreboot(void);
void	archreset(void);
void	clockcheck(void);
void	clockinit(void);
void	clockpoll(void);
#define	coherence()	__asm__ __volatile__("dmb ish" ::: "memory")
void	delay(int);
void	dumpregs(Ureg*);
void	dumpstack(void);
int	fpiarm(Ureg*);
void	fpinit(void);
ulong	getfcr(void);
ulong	getfsr(void);
void	setfcr(ulong);
void	setfsr(ulong);
#define	getcallerpc(x)	((uintptr)__builtin_return_address(0))
#define	idlehands()	__asm__ __volatile__("wfe" ::: "memory")
void	intrenable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrdisable(int, void (*)(Ureg*, void*), void*, int, char*);
void	links(void);
void	microdelay(int);
#define procsave(p)
#define procrestore(p)
int	segflush(void*, ulong);
extern void	(*screenputs)(char*, int);
void	setpanic(void);
void	trapinit(void);
void	uartinit(void);
void	vectors(void);
ulong	va2pa(void*);

/*
 * gcc must treat setlabel like setjmp or it will cache values
 * in registers across the second return.
 */
int	setlabel(Label*) __attribute__((returns_twice));

#define	waserror()	(up->nerrlab++, setlabel(&up->errlab[up->nerrlab-1]))

#define KADDR(p)	((void*)(p))
#define PADDR(v)	((uintptr)(v))

#define	splfhi	splhi
#define	splflo	spllo
