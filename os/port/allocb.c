#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

enum
{
	Hdrspc		= 64,		/* leave room for high-level headers */
	Tlrspc		= 16,		/* extra room at the end for pad/crc/mac */
	Bdead		= 0x51494F42,	/* "QIOB" */
};

struct
{
	Lock;
	ulong	bytes;
} ialloc;

/*
 *  allocate blocks (round data base address to 64 bit boundary).
 *  if mallocz gives us more than we asked for, leave room at the front
 *  for header.
 */
Block*
_allocb(int size)
{
	Block *b;
	ulong addr;
	int n;

	b = mallocz(sizeof(Block)+size+Hdrspc+(BY2V-1), 0);
	if(b == nil)
		return nil;

	b->next = nil;
	b->list = nil;
	b->free = nil;
	b->pool = nil;
	b->flag = 0;

	addr = (ulong)b;
	addr = ROUND(addr + sizeof(Block), BY2V);
	b->base = (uchar*)addr;
	b->lim = ((uchar*)b) + msize(b);
	b->rp = b->base;
	n = b->lim - b->base - size;
	b->rp += n & ~(BY2V-1);
	b->wp = b->rp;

	return b;
}

Block*
allocb(int size)
{
	Block *b;

	if(0 && up == nil)
		panic("allocb outside process: %8.8lux", getcallerpc(&size));
	b = _allocb(size);
	if(b == 0)
		exhausted("Blocks");
	setmalloctag(b, getcallerpc(&size));
	return b;
}

/*
 *  interrupt time allocation
 */
Block*
iallocb(int size)
{
	Block *b;

	if(ialloc.bytes > conf.ialloc){
		//print("iallocb: limited %lud/%lud\n", ialloc.bytes, conf.ialloc);
		return nil;
	}

	b = _allocb(size);
	if(b == nil){
		//print("iallocb: no memory %lud/%lud\n", ialloc.bytes, conf.ialloc);
		return nil;
	}
	setmalloctag(b, getcallerpc(&size));
	b->flag = BINTR;

	ilock(&ialloc);
	ialloc.bytes += b->lim - b->base;
	iunlock(&ialloc);

	return b;
}

void
freeb(Block *b)
{
	void *dead = (void*)Bdead;

	if(b == nil)
		return;

	/*
	 * blocks handed out from a Bpool recycle straight back to it, never
	 * to the general allocator (and bypass the ialloc.bytes accounting).
	 */
	if(b->pool != nil) {
		Bpool *p = b->pool;

		b->next = nil;
		b->rp = b->wp = b->lim - ROUND(p->size+Tlrspc, p->align);
		b->flag = BINTR;
		ilock(p);
		b->list = p->head;
		p->head = b;
		iunlock(p);
		return;
	}

	/*
	 * drivers which perform non cache coherent DMA manage their own buffer
	 * pool of uncached buffers and provide their own free routine.
	 */
	if(b->free) {
		b->free(b);
		return;
	}
	if(b->flag & BINTR) {
		ilock(&ialloc);
		ialloc.bytes -= b->lim - b->base;
		iunlock(&ialloc);
	}

	/* poison the block in case someone is still holding onto it */
	b->next = dead;
	b->rp = dead;
	b->wp = dead;
	b->lim = dead;
	b->base = dead;

	free(b);
}

static ulong
_alignment(ulong align)
{
	if(align <= BLOCKALIGN)
		return BLOCKALIGN;

	/* round up to a power of two */
	align--;
	align |= align>>1;
	align |= align>>2;
	align |= align>>4;
	align |= align>>8;
	align |= align>>16;
	align++;

	return align;
}

/*
 * Aligned single-block allocator, used only as the iallocbp() miss path.
 * Lays out one mallocz'd chunk as [Block | headroom | aligned data], leaving
 * Hdrspc at the front of the data for prepended headers, like _allocb above.
 */
static Block*
_allocbalign(ulong size, ulong align)
{
	Block *b;

	size = ROUND(size+Tlrspc, align);
	if((b = mallocz(sizeof(Block)+Hdrspc+size+align-1, 0)) == nil)
		return nil;

	b->next = nil;
	b->list = nil;
	b->free = nil;
	b->pool = nil;
	b->flag = 0;

	/* align start of the data portion up, end down */
	b->base = (uchar*)ROUND((uintptr)&b[1], (uintptr)align);
	b->lim = (uchar*)(((uintptr)b + msize(b)) & ~((uintptr)align-1));
	b->wp = b->rp = b->lim - size;

	return b;
}

/*
 * Hand out a block from a pool at interrupt time.  Pops the freelist if it
 * can; otherwise allocates a fresh aligned block tagged with ->pool so it
 * lands back in the pool when freed.
 */
Block*
iallocbp(Bpool *p)
{
	Block *b;

	ilock(p);
	if((b = p->head) != nil){
		p->head = b->list;
		b->list = nil;
		iunlock(p);
		return b;
	}
	iunlock(p);

	p->align = _alignment(p->align);
	if((b = _allocbalign(p->size, p->align)) == nil)
		return nil;
	setmalloctag(b, getcallerpc(&p));
	b->pool = p;
	b->flag = BINTR;

	return b;
}

/*
 * Pre-grow a pool by n blocks from one contiguous aligned span (permanent,
 * driver-lifetime memory — pools are never torn down).  The Block headers
 * come from malloc; freeb() threads each onto the freelist.
 */
void
growbp(Bpool *p, int n)
{
	ulong size;
	Block *b, *bb;
	uchar *a;

	if(n < 1)
		return;
	if((bb = malloc(sizeof(Block)*n)) == nil)
		return;
	p->align = _alignment(p->align);
	size = ROUND(p->size+Hdrspc+Tlrspc, p->align);
	if((a = xspanalloc(size*n, p->align, 0)) == nil){
		free(bb);
		return;
	}
	for(b = bb; n > 0; n--, b++){
		memset(b, 0, sizeof(Block));
		b->base = a;
		a += size;
		b->lim = a;
		b->pool = p;
		freeb(b);
	}
}

void
checkb(Block *b, char *msg)
{
	void *dead = (void*)Bdead;

	if(b == dead)
		panic("checkb b %s %lux", msg, b);
	if(b->base == dead || b->lim == dead || b->next == dead
	  || b->rp == dead || b->wp == dead){
		print("checkb: base 0x%8.8luX lim 0x%8.8luX next 0x%8.8luX\n",
			b->base, b->lim, b->next);
		print("checkb: rp 0x%8.8luX wp 0x%8.8luX\n", b->rp, b->wp);
		panic("checkb dead: %s\n", msg);
	}

	if(b->base > b->lim)
		panic("checkb 0 %s %lux %lux", msg, b->base, b->lim);
	if(b->rp < b->base)
		panic("checkb 1 %s %lux %lux", msg, b->base, b->rp);
	if(b->wp < b->base)
		panic("checkb 2 %s %lux %lux", msg, b->base, b->wp);
	if(b->rp > b->lim)
		panic("checkb 3 %s %lux %lux", msg, b->rp, b->lim);
	if(b->wp > b->lim)
		panic("checkb 4 %s %lux %lux", msg, b->wp, b->lim);

}

void
iallocsummary(void)
{
	print("ialloc %lud/%lud\n", ialloc.bytes, conf.ialloc);
}
