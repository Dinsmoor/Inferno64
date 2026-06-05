#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include <kernel.h>

#define	A(r)	*((Array**)(r))

Module*	modules;
int	dontcompile;

/* operand(), disw() and canontod() now live in disops.c (declared in
 * interp.h) so they can be unit-tested without the rest of the loader. */

Module*
load(char *path)
{
	return readmod(path, nil, 0);
}

int
brpatch(Inst *ip, Module *m)
{
	switch(ip->op) {
	case ICALL:
	case IJMP:
	case IBEQW:
	case IBNEW:
	case IBLTW:
	case IBLEW:
	case IBGTW:
	case IBGEW:
	case IBEQB:
	case IBNEB:
	case IBLTB:
	case IBLEB:
	case IBGTB:
	case IBGEB:
	case IBEQF:
	case IBNEF:
	case IBLTF:
	case IBLEF:
	case IBGTF:
	case IBGEF:
	case IBEQC:
	case IBNEC:
	case IBLTC:
	case IBLEC:
	case IBGTC:
	case IBGEC:
	case IBEQL:
	case IBNEL:
	case IBLTL:
	case IBLEL:
	case IBGTL:
	case IBGEL:
	case ISPAWN:
		if(ip->d.imm < 0 || ip->d.imm >= m->nprog)
			return 0;
		/* patch branch/spawn target to an absolute Inst*; store the
		 * full native pointer via the union's ins member (JMP reads
		 * *(Inst**)&d.imm), not the truncating WORD imm. */
		ip->d.ins = &m->prog[ip->d.imm];
		break;
	}
	return 1;
}

Module*
parsemod(char *path, uchar *code, ulong length, Dir *dir)
{
	Heap *h;
	Inst *ip;
	Type *pt;
	String *s;
	Module *m;
	Array *ary;
	ulong ul[2];
	WORD lo, hi;
	int lsize, id, v, entry, entryt, tnp, tsz, siglen;
	int mag, mymagic, mysmagic;
	int de, pc, i, n, isize, dsize, hsize, dasp;
	uchar *mod, sm, *istream, **isp, *si, *addr, *dastack[DADEPTH];
	Link *l;

	istream = code;
	isp = &istream;

	m = malloc(sizeof(Module));
	if(m == nil)
		return nil;

	m->dev = dir->dev;
	m->dtype = dir->type;
	m->qid = dir->qid;
	m->mtime = dir->mtime;
	m->origmp = H;
	m->pctab = nil;

	/*
	 * Accept only the magic for this build's Dis pointer width (IBY2PTR).
	 * A module compiled for the other width parses fine but its register/
	 * pointer-slot layout would be wrong at run time, so reject it with a
	 * distinct, catchable error (exDiswidth) that the shell uses to trigger
	 * a recompile from source.  Genuine garbage still reports "bad magic".
	 */
	mymagic = (IBY2PTR == 8) ? XMAGIC8 : XMAGIC;
	mysmagic = (IBY2PTR == 8) ? SMAGIC8 : SMAGIC;
	mag = operand(isp);
	if(mag == mysmagic){
		siglen = operand(isp);
		n = length-(*isp-code);
		if(n < 0 || siglen > n){
			kwerrstr("corrupt signature");
			goto bad;
		}
		if(verifysigner(*isp, siglen, *isp+siglen, n-siglen) == 0) {
			kwerrstr("security violation");
			goto bad;
		}
		*isp += siglen;
	}
	else if(mag == mymagic){
		if(mustbesigned(path, code, length, dir)){
			kwerrstr("security violation: not signed");
			goto bad;
		}
	}
	else if(mag == XMAGIC || mag == SMAGIC || mag == XMAGIC8 || mag == SMAGIC8){
		kwerrstr(exDiswidth);
		goto bad;
	}
	else {
		kwerrstr("bad magic");
		goto bad;
	}

	m->rt = operand(isp);
	m->ss = operand(isp);
	isize = operand(isp);
	dsize = operand(isp);
	hsize = operand(isp);
	lsize = operand(isp);
	entry = operand(isp);
	entryt = operand(isp);

	if(isize < 0 || dsize < 0 || hsize < 0 || lsize < 0) {
		kwerrstr("implausible Dis file");
		goto bad;
	}

	m->nprog = isize;
	m->prog = mallocz(isize*sizeof(Inst), 0);
	if(m->prog == nil) {
		kwerrstr(exNomem);
		goto bad;
	}

	m->ref = 1;

	ip = m->prog;
	for(i = 0; i < isize; i++) {
		ip->op = *istream++;
		ip->add = *istream++;
		ip->reg = 0;
		ip->s.imm = 0;
		ip->d.imm = 0;
		switch(ip->add & ARM) {
		case AXIMM:
		case AXINF:
		case AXINM:
			ip->reg = operand(isp);
		 	break;
		}
		switch(UXSRC(ip->add)) {
		case SRC(AFP):
		case SRC(AMP):	
		case SRC(AIMM):
			ip->s.ind = operand(isp);
			break;
		case SRC(AIND|AFP):
		case SRC(AIND|AMP):
			ip->s.i.f = operand(isp);
			ip->s.i.s = operand(isp);
			break;
		}
		switch(UXDST(ip->add)) {
		case DST(AFP):
		case DST(AMP):	
			ip->d.ind = operand(isp);
			break;
		case DST(AIMM):
			ip->d.ind = operand(isp);
			if(brpatch(ip, m) == 0) {
				kwerrstr("bad branch addr");
				goto bad;
			}
			break;
		case DST(AIND|AFP):
		case DST(AIND|AMP):
			ip->d.i.f = operand(isp);
			ip->d.i.s = operand(isp);
			break;
		}
		ip++;		
	}

	m->ntype = hsize;
	m->type = malloc(hsize*sizeof(Type*));
	if(m->type == nil) {
		kwerrstr(exNomem);
		goto bad;
	}
	for(i = 0; i < hsize; i++) {
		id = operand(isp);
		if(id > hsize) {
			kwerrstr("heap id range");
			goto bad;
		}
		tsz = operand(isp);
		tnp = operand(isp);
		if(tsz < 0 || tnp < 0 || tnp > 128*1024){
			kwerrstr("implausible Dis file");
			goto bad;
		}
		pt = dtype(freeheap, tsz, istream, tnp);
		if(pt == nil) {
			kwerrstr(exNomem);
			goto bad;
		}
		if(!verifytype(pt, &v)) {
			kwerrstr("%s: type %d pointer map marks a slot at +%d beyond size %d (stale or wrong-ABI .dis)", path, id, v, tsz);
			freetype(pt);
			goto bad;
		}
		istream += tnp;
		m->type[id] = pt;
	}

	if(dsize != 0) {
		pt = m->type[0];
		if(pt == 0 || pt->size != dsize) {
			kwerrstr("bad desc for mp");
			goto bad;
		}
		h = heapz(pt);
		m->origmp = H2D(uchar*, h);
	}
	addr = m->origmp;
	dasp = 0;
	for(;;) {
		sm = *istream++;
		if(sm == 0)
			break;
		n = DLEN(sm);
		if(n == 0)
			n = operand(isp);
		v = operand(isp);
		si = addr + v;
		switch(DTYPE(sm)) {
		default:
			kwerrstr("bad data item");
			goto bad;
		case DEFS:
			s = c2string((char*)istream, n);
			istream += n;
			*(String**)si = s;
			break;
		case DEFB:
			for(i = 0; i < n; i++)
				*si++ = *istream++;
			break;
		case DEFW:
			for(i = 0; i < n; i++) {
				*(WORD*)si = disw(isp);
				si += sizeof(WORD);
			}
			break;
		case DEFL:
			for(i = 0; i < n; i++) {
				hi = disw(isp);
				lo = disw(isp);
				/*
				 * The low word must be ZERO-extended.  lo is a signed
				 * WORD; on LP64 (ulong)lo sign-extends a low word whose
				 * bit 31 is set into bits 32..63, corrupting the value
				 * (e.g. 123456789012 loaded as -1097262572).  (u32int)
				 * keeps it a 32-bit unsigned quantity.  The high word
				 * keeps its sign (it carries the big's sign).  On 32-bit
				 * ulong was 4 bytes so this never sign-extended.
				 */
				/* assemble in uvlong: shifting the (possibly negative)
				 * (LONG)hi left is UB; the bit pattern is identical. */
				*(LONG*)si = (LONG)(((uvlong)(u32int)hi << 32) | (u32int)lo);
				si += sizeof(LONG);
			}
			break;
		case DEFF:
			for(i = 0; i < n; i++) {
				ul[0] = disw(isp);
				ul[1] = disw(isp);
				*(REAL*)si = canontod(ul);
				si += sizeof(REAL);
			}
			break;
		case DEFA:			/* Array */
			v = disw(isp);
			if(v < 0 || v > m->ntype) {
				kwerrstr("bad array type");
				goto bad;
			}
			pt = m->type[v];
			v = disw(isp);
			h = nheap(sizeof(Array)+(pt->size*v));
			h->t = &Tarray;
			h->t->ref++;
			ary = H2D(Array*, h);
			ary->t = pt;
			ary->len = v;
			ary->root = H;
			ary->data = (uchar*)ary+sizeof(Array);
			memset((void*)ary->data, 0, pt->size*v);
			initarray(pt, ary);
			A(si) = ary;
			break;			
		case DIND:			/* Set index */
			ary = A(si);
			if(ary == H || D2H(ary)->t != &Tarray) {
				kwerrstr("ind not array");
				goto bad;
			}
			v = disw(isp);
			if(v > ary->len || v < 0 || dasp >= DADEPTH) {
				kwerrstr("array init range");
				goto bad;
			}
			dastack[dasp++] = addr;
			addr = ary->data+v*ary->t->size;
			break;
		case DAPOP:
			if(dasp == 0) {
				kwerrstr("pop range");
				goto bad;
			}
			addr = dastack[--dasp];
			break;
		}
	}
	mod = istream;
	if(memchr(mod, 0, 128) == 0) {
		kwerrstr("bad module name");
		goto bad;
	}
	m->name = strdup((char*)mod);
	if(m->name == nil) {
		kwerrstr(exNomem);
		goto bad;
	}
	while(*istream++)
		;

	l = m->ext = (Link*)malloc((lsize+1)*sizeof(Link));
	if(l == nil){
		kwerrstr(exNomem);
		goto bad;
	}
	for(i = 0; i < lsize; i++, l++) {
		pc = operand(isp);
		de = operand(isp);
		v  = disw(isp);
		pt = nil;
		if(de != -1)
			pt = m->type[de];
		mlink(m, l, istream, v, pc, pt);
		while(*istream++)
			;
	}
	l->name = nil;

	if(m->rt & HASLDT0){
		kwerrstr("obsolete dis");
		goto bad;
	}

	if(m->rt & HASLDT){
		int j, nl;
		Import *i1, **i2;

		nl = operand(isp);
		i2 = m->ldt = (Import**)malloc((nl+1)*sizeof(Import*));
		if(i2 == nil){
			kwerrstr(exNomem);
			goto bad;
		}
		for(i = 0; i < nl; i++, i2++){
			n = operand(isp);
			i1 = *i2 = (Import*)malloc((n+1)*sizeof(Import));
			if(i1 == nil){
				kwerrstr(exNomem);
				goto bad;
			}
			for(j = 0; j < n; j++, i1++){
				i1->sig = disw(isp);
				i1->name = strdup((char*)istream);
				if(i1->name == nil){
					kwerrstr(exNomem);
					goto bad;
				}
				while(*istream++)
					;
			}
		}
		istream++;
	}

	if(m->rt & HASEXCEPT){
		int j, nh;
		Handler *h;
		Except *e;

		nh = operand(isp);
		m->htab = malloc((nh+1)*sizeof(Handler));
		if(m->htab == nil){
			kwerrstr(exNomem);
			goto bad;
		}
		h = m->htab;
		for(i = 0; i < nh; i++, h++){
			h->eoff = operand(isp);
			h->pc1 = operand(isp);
			h->pc2 = operand(isp);
			n = operand(isp);
			if(n != -1)
				h->t = m->type[n];
			n = operand(isp);
			h->ne = n>>16;
			n &= 0xffff;
			h->etab = malloc((n+1)*sizeof(Except));
			if(h->etab == nil){
				kwerrstr(exNomem);
				goto bad;
			}
			e = h->etab;
			for(j = 0; j < n; j++, e++){
				e->s = strdup((char*)istream);
				if(e->s == nil){
					kwerrstr(exNomem);
					goto bad;
				}
				while(*istream++)
					;
				e->pc = operand(isp);
			}
			e->s = nil;
			e->pc = operand(isp);
		}
		istream++;
	}

	m->entryt = nil;
	m->entry = m->prog;
	if((ulong)entry < isize && (ulong)entryt < hsize) {
		m->entry = &m->prog[entry];
		m->entryt = m->type[entryt];
	}

	if(cflag) {
		if((m->rt&DONTCOMPILE) == 0 && !dontcompile)
			compile(m, isize, nil);
	}
	else
	if(m->rt & MUSTCOMPILE && !dontcompile) {
		if(compile(m, isize, nil) == 0) {
			kwerrstr("compiler required");
			goto bad;
		}
	}

	m->path = strdup(path);
	if(m->path == nil) {
		kwerrstr(exNomem);
		goto bad;
	}
	m->link = modules;
	modules = m;

	return m;
bad:
	destroy(m->origmp);
	freemod(m);
	return nil;
}

Module*
newmod(char *s)
{
	Module *m;

	m = malloc(sizeof(Module));
	if(m == nil)
		error(exNomem);
	m->ref = 1;
	m->path = s;
	m->origmp = H;
	m->name = strdup(s);
	if(m->name == nil) {
		free(m);
		error(exNomem);
	}
	m->link = modules;
	modules = m;
	m->pctab = nil;
	return m;
}

Module*
lookmod(char *s)
{
	Module *m;

	for(m = modules; m != nil; m = m->link)
		if(strcmp(s, m->path) == 0) {
			m->ref++;
			return m;
		}
	return nil;
}

void
freemod(Module *m)
{
	int i;
	Handler *h;
	Except *e;
	Import *i1, **i2;

	if(m->type != nil) {
		for(i = 0; i < m->ntype; i++)
			freetype(m->type[i]);
		free(m->type);
	}
	free(m->name);
	if(!m->compiled)		/* JIT modules' prog points into the code arena */
		free(m->prog);
	free(m->path);
	free(m->pctab);
	if(m->ldt != nil){
		for(i2 = m->ldt; *i2 != nil; i2++){
			for(i1 = *i2; i1->name != nil; i1++)
				free(i1->name);
			free(*i2);
		}
		free(m->ldt);
	}
	if(m->htab != nil){
		for(h = m->htab; h->etab != nil; h++){
			for(e = h->etab; e->s != nil; e++)
				free(e->s);
			free(h->etab);
		}
		free(m->htab);
	}
	free(m);
}

void
unload(Module *m)
{
	Module **last, *mm;

	m->ref--;
	if(m->ref > 0)
		return;
	if(m->ref == -1)
		abort();

	last = &modules;
	for(mm = modules; mm != nil; mm = mm->link) {
		if(mm == m) {
			*last = m->link;
			break;
		}
		last = &mm->link;
	}

	if(m->rt == DYNMOD)
		freedyncode(m);
	else
		destroy(m->origmp);

	destroylinks(m);

	freemod(m);
}
