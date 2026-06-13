/*
 * PCI Express enumeration over a generic ECAM host bridge.
 *
 * On qemu -M virt (and arm64 SoCs with the same "pci-host-ecam-generic"
 * layout) there is no firmware to assign BARs: this code walks config
 * space itself, sizes every BAR, and bump-allocates it from the board's
 * 32-bit MMIO window (board.h PCIE_MMIO_PHYS).  Config space is plain
 * MMIO at PCIE_ECAM_PHYS, identity-mapped like every other device
 * register (KADDR(p)==p), so access is a volatile load/store — no CF8/CFC
 * ports, no vmap.
 *
 * INTx is delivered as a GIC SPI: the four legacy lines are SPI 3..6
 * (board.h PCIINTA), slot-swizzled the way qemu's gpex wires them, so a
 * driver hooks p->intl straight through intrenable(..., BusCPU, ...).
 *
 * Exposes the canonical Plan 9 Pcidev/pcimatch API (pci.h) the in-tree
 * ether and sd drivers already call.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "ureg.h"
#include "pci.h"

#define DBG	if(0) print

static Pcidev*	pciroot;	/* flat list, scan order */
static Pcidev*	pcitail;
static int	pcidone;

static uvlong	membase = PCIE_MMIO_PHYS;	/* 32-bit MMIO bump allocator */
static ulong	iobase  = PCIE_PIO_PHYS;	/* I/O-space bump allocator */
static int	maxbno;				/* highest bus number assigned */

/*
 * ECAM config address: bus[27:20] dev[19:15] fn[14:12] reg[11:0].
 * Identity-mapped device memory, so the physical address is the pointer.
 */
static uintptr
cfgaddr(int tbdf, int rno)
{
	return PCIE_ECAM_PHYS
		+ ((uintptr)BUSBNO(tbdf) << 20)
		+ ((uintptr)BUSDNO(tbdf) << 15)
		+ ((uintptr)BUSFNO(tbdf) << 12)
		+ (rno & 0xFFF);
}

static int  rcfg8(int tbdf, int rno)  { return *(volatile uchar*) cfgaddr(tbdf, rno); }
static int  rcfg16(int tbdf, int rno) { return *(volatile ushort*)cfgaddr(tbdf, rno); }
static u32int rcfg32(int tbdf, int rno){ return *(volatile u32int*)cfgaddr(tbdf, rno); }
static void wcfg8(int tbdf, int rno, int v)  { *(volatile uchar*) cfgaddr(tbdf, rno) = v; }
static void wcfg16(int tbdf, int rno, int v) { *(volatile ushort*)cfgaddr(tbdf, rno) = v; }
static void wcfg32(int tbdf, int rno, u32int v){ *(volatile u32int*)cfgaddr(tbdf, rno) = v; }

int  pcicfgr8 (Pcidev *p, int rno) { return rcfg8 (p->tbdf, rno); }
int  pcicfgr16(Pcidev *p, int rno) { return rcfg16(p->tbdf, rno); }
int  pcicfgr32(Pcidev *p, int rno) { return rcfg32(p->tbdf, rno); }
void pcicfgw8 (Pcidev *p, int rno, int v) { wcfg8 (p->tbdf, rno, v); }
void pcicfgw16(Pcidev *p, int rno, int v) { wcfg16(p->tbdf, rno, v); }
void pcicfgw32(Pcidev *p, int rno, int v) { wcfg32(p->tbdf, rno, v); }

static uvlong
memalloc(uvlong *base, int size)
{
	uvlong a;

	a = (*base + size - 1) & ~(uvlong)(size - 1);	/* natural alignment */
	*base = a + size;
	return a;
}

/*
 * Size and assign one device's six BARs from the MMIO/IO windows.
 * BAR size is read by writing all-ones and reading back the decoded mask;
 * mask to 32 bits before negating so LP64 sign-extension can't leak in.
 */
static void
pcibars(Pcidev *p)
{
	int i, rno;
	u32int v, sz, raw;
	uvlong base;
	int size;

	for(i = 0; i < 6; i++){
		rno = PciBAR0 + i*4;
		v = rcfg32(p->tbdf, rno);
		wcfg32(p->tbdf, rno, 0xFFFFFFFF);
		sz = rcfg32(p->tbdf, rno);
		wcfg32(p->tbdf, rno, v);
		if(sz == 0 || sz == 0xFFFFFFFF)
			continue;

		if(v & 1){				/* I/O BAR */
			raw = sz & ~0x3u;
			if(raw == 0)
				continue;
			size = ~raw + 1;
			base = memalloc(&iobase, size);
			wcfg32(p->tbdf, rno, (u32int)base | 1);
			p->mem[i].bar = base | 1;
			p->mem[i].size = size;
			continue;
		}

		/* memory BAR */
		raw = sz & ~0xFu;
		if(raw == 0)
			continue;
		size = ~raw + 1;
		base = memalloc(&membase, size);
		wcfg32(p->tbdf, rno, (u32int)base);
		p->mem[i].bar = base | (v & 0xF);
		p->mem[i].size = size;
		if(((v >> 1) & 3) == 2){		/* 64-bit BAR: high half = 0 */
			wcfg32(p->tbdf, rno + 4, 0);
			i++;				/* consumes the next slot */
		}
	}

	/* turn on memory + I/O decode now that BARs are placed */
	p->pcr = rcfg16(p->tbdf, PciPCR) | MEMen | IOen;
	wcfg16(p->tbdf, PciPCR, p->pcr);
}

static void
pciintx(Pcidev *p)
{
	int pin;

	pin = rcfg8(p->tbdf, PciINTP);		/* 1..4 == INTA..INTD, 0 == none */
	if(pin == 0){
		p->intl = 0;
		return;
	}
	/* qemu gpex swizzle: SPI = PCIINTA + (slot + pin-1) mod 4 */
	p->intl = PCIINTA + ((BUSDNO(p->tbdf) + pin - 1) & 3);
	wcfg8(p->tbdf, PciINTL, p->intl);
}

static void pciscanbus(int bno);

static void
pcilink(Pcidev *p)
{
	if(pciroot == nil)
		pciroot = p;
	else
		pcitail->list = p;
	pcitail = p;
}

static void
pciscanbus(int bno)
{
	int dno, fno, tbdf, hdt, sbn;
	u32int l;
	Pcidev *p;

	if(bno > maxbno)
		maxbno = bno;
	for(dno = 0; dno <= 31; dno++){
		for(fno = 0; fno <= 7; fno++){
			tbdf = MKBUS(BusPCI, bno, dno, fno);
			l = rcfg32(tbdf, PciVID);
			if((l & 0xFFFF) == 0xFFFF || (l & 0xFFFF) == 0){
				if(fno == 0)
					break;		/* no fn0 => no device */
				continue;
			}

			p = mallocz(sizeof(Pcidev), 1);
			if(p == nil)
				panic("pci: out of memory");
			p->tbdf = tbdf;
			p->vid = l & 0xFFFF;
			p->did = (l >> 16) & 0xFFFF;
			p->rid = rcfg8(tbdf, PciRID);
			p->ccrp = rcfg8(tbdf, PciCCRp);
			p->ccru = rcfg8(tbdf, PciCCRu);
			p->ccrb = rcfg8(tbdf, PciCCRb);
			hdt = rcfg8(tbdf, PciHDT);
			pcilink(p);

			DBG("pci %d.%d.%d: %04ux/%04ux class %02ux.%02ux.%02ux hdt %ux\n",
				bno, dno, fno, p->vid, p->did,
				p->ccrb, p->ccru, p->ccrp, hdt);

			if((hdt & 0x7F) == 1){		/* PCI-PCI bridge */
				sbn = maxbno + 1;
				/* primary, secondary, subordinate (0xff for now) */
				wcfg32(tbdf, 0x18, (0xFFU << 16) | (sbn << 8) | bno);
				pciscanbus(sbn);
				/* tighten subordinate to the highest seen */
				wcfg8(tbdf, PciUBN, maxbno);
			}else{
				pcibars(p);
				pciintx(p);
			}

			if(fno == 0 && (hdt & 0x80) == 0)
				break;			/* not multifunction */
		}
	}
}

void
pciscan(void)
{
	Pcidev *p;

	if(pcidone)
		return;
	pcidone = 1;
	pciscanbus(0);

	for(p = pciroot; p != nil; p = p->list)
		print("pci %d.%d.%d: %.4ux/%.4ux class %.2ux.%.2ux irq %d bar0 %llux\n",
			BUSBNO(p->tbdf), BUSDNO(p->tbdf), BUSFNO(p->tbdf),
			p->vid, p->did, p->ccrb, p->ccru, p->intl, p->mem[0].bar);
}

Pcidev*
pcimatch(Pcidev *prev, int vid, int did)
{
	if(!pcidone)
		pciscan();
	prev = (prev == nil) ? pciroot : prev->list;
	for(; prev != nil; prev = prev->list){
		if((vid == 0 || prev->vid == vid)
		&& (did == 0 || prev->did == did))
			return prev;
	}
	return nil;
}

Pcidev*
pcimatchtbdf(int tbdf)
{
	Pcidev *p;

	if(!pcidone)
		pciscan();
	for(p = pciroot; p != nil; p = p->list)
		if(p->tbdf == tbdf)
			return p;
	return nil;
}

void
pcisetbme(Pcidev *p)
{
	p->pcr |= MASen;
	wcfg16(p->tbdf, PciPCR, p->pcr);
}

void
pciclrbme(Pcidev *p)
{
	p->pcr &= ~MASen;
	wcfg16(p->tbdf, PciPCR, p->pcr);
}
