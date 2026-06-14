implement Biblefs;

#
# biblefs -- serve the King James Bible as a Styx file tree.
#
# A scripture reference is a path; you read it.  No SQL, no query language for
# the common case -- the Bible simply becomes part of the namespace, so the
# shell can `cat` a verse, grep can search it, the plumber can route a
# reference, and a thin client (or a future wm/bible) can `import` it from a
# beefy host.  The data is a set of flat files under /lib/bible (built once on
# the host by tools/mkbibledata.py from the kjv_api SQLite database); biblefs
# loads compact byte-offset indices and serves verse text by slicing an
# in-memory blob.  SQLite is never used inside Inferno.
#
# Tree (mount at /mnt/bible):
#
#   /
#       books/                  the canonical text as a walkable tree
#           Genesis/
#               info            "<name>\t<testament>\t<genre>\t<n> chapters\t<n> verses"
#               1/              chapter directory
#                   1           cat books/Genesis/1/1  ->  a verse record
#                   2 ...
#           John/3/16           reference == path
#       define/                 walk define/<word> for an 1828 Webster definition
#       lookup                  write a reference, read the verses back
#       search                  write keywords, read matching verses
#       xref                    write a reference, read its cross-referenced verses
#       votd                    read: the verse of the day (deterministic by date)
#       random                  read: a random verse per open
#       ctl                     read: server status
#
# The query files (lookup/search/xref) use the /net/dns idiom: open the file
# ORDWR, write the query, read the answer from the same fid (one write == one
# query).  Reads stream the answer and ignore the byte offset, so the offset
# left behind by the write does not matter -- a client need not seek.
#
# Verse records are tab-separated, one verse per line, for trivial parsing by a
# GUI client:
#
#       <book>\t<chapter>\t<verse>\t<text>\n
#
# Start it:
#       biblefs                 # mounts /lib/bible data at /mnt/bible
#       biblefs -d /lib/bible /mnt/bible
# then:
#       cat /mnt/bible/John/3/16
#       echo 1cor13:4-7 >[1=0] /mnt/bible/lookup; cat /mnt/bible/lookup   # (from a program holding the fid)
#

include "sys.m";
	sys: Sys;
	Qid, Dir: import Sys;

include "draw.m";

include "arg.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "daytime.m";
	daytime: Daytime;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;

Biblefs: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

# Qid kinds, packed into the high byte of the 64-bit path; the low bits hold
# the payload (book, packed book*1000+chapter, verse id, or word index).
Qroot, Qbooksdir, Qdefinedir, Qlookup, Qsearch, Qxref, Qvotd, Qrandom,
	Qctl, Qbookdir, Qinfo, Qchapdir, Qverse, Qword, Qnotes: con iota;

MAXREF:		con 6000;	# cap verses returned by a single lookup
MAXSEARCH:	con 1000;	# cap search hits
MAXXREF:	con 400;	# cap cross-reference verses

Verse: adt {
	off:	int;		# byte offset into vblob
	vlen:	int;		# byte length of the verse text
};

Chapter: adt {
	verses:	array of ref Verse;	# index 0 == verse 1
};

Bookrec: adt {
	name:		string;
	testament:	string;
	genre:		string;
	chaps:		array of ref Chapter;	# index 0 == chapter 1
};

Dword: adt {
	word:	string;		# lowercased headword
	off:	int;
	dlen:	int;
};

Xrec: adt {
	vid:	int;
	off:	int;
	xlen:	int;
};

books:	array of ref Bookrec;	# index by book number 1..66
nbooks:	int;
vblob:	array of byte;		# the whole verse text, read once
allvids: array of int;		# every verse id, ascending (for votd/random/ranges)
abkeys:	array of (string, int);	# (lowercased name/abbrev, book) sorted by key
dwords:	array of ref Dword;	# dictionary index, sorted by headword
dfd:	ref Sys->FD;		# dict blob
xrefv:	array of ref Xrec;	# cross-reference index, sorted by vid
xfd:	ref Sys->FD;		# xref blob

srv:	ref Styxserver;
stderr:	ref Sys->FD;
user:	string;
seed:	int;

fail(s: string)
{
	sys->fprint(stderr, "biblefs: %s\n", s);
	raise "fail:"+s;
}

nomod(p: string)
{
	fail(sys->sprint("cannot load %s: %r", p));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	styx = load Styx Styx->PATH;
	if(styx == nil) nomod(Styx->PATH);
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) nomod(Styxservers->PATH);
	styxservers->init(styx);
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil) nomod(Bufio->PATH);
	daytime = load Daytime Daytime->PATH;	# optional

	arg := load Arg Arg->PATH;
	if(arg == nil) nomod(Arg->PATH);
	arg->init(args);
	arg->setusage("mount {biblefs [-D] [-d datadir]} /mnt/bible");
	datadir := "/lib/bible";
	while((o := arg->opt()) != 0)
		case o {
		'D' =>	styxservers->traceset(1);
		'd' =>	datadir = arg->earg();
		* =>	arg->usage();
		}
	arg = nil;

	loaddata(datadir);

	user = rf("/dev/user");
	if(user == nil)
		user = "inferno";
	seed = sys->millisec() ^ (sys->pctl(0, nil) << 8);
	if(daytime != nil)
		seed ^= daytime->now();

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, nsrv) := Styxserver.new(sys->fildes(0), Navigator.new(navops), big mkpath(Qroot, 0));
	srv = nsrv;

	serve(tchan, navops);
}

rf(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return nil;
	return string b[0:n];
}

mkpath(kind, payload: int): big
{
	return (big kind << 56) | big payload;
}

pkind(p: big): int
{
	return int (p >> 56) & 16rFF;
}

ppayload(p: big): int
{
	return int (p & big 16rFFFFFFFFFFFFFF);
}

vid(b, c, v: int): int
{
	return b*1000000 + c*1000 + v;
}

#
# data loading
#

loaddata(dir: string)
{
	loadbooks(dir+"/books");
	vblob = readfile(dir+"/verses");
	loadverseidx(dir+"/verses.idx");
	loadabbrev(dir+"/abbrev");
	loaddict(dir+"/dict.idx");
	dfd = sys->open(dir+"/dict", Sys->OREAD);
	if(dfd == nil) fail(sys->sprint("open %s/dict: %r", dir));
	loadxref(dir+"/xref.idx");
	xfd = sys->open(dir+"/xref", Sys->OREAD);
	if(xfd == nil) fail(sys->sprint("open %s/xref: %r", dir));
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) fail(sys->sprint("open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0) fail(sys->sprint("stat %s: %r", path));
	n := int d.length;
	buf := array[n] of byte;
	r := 0;
	while(r < n){
		m := sys->read(fd, buf[r:], n-r);
		if(m <= 0)
			break;
		r += m;
	}
	return buf[0:r];
}

bopen(path: string): ref Iobuf
{
	bf := bufio->open(path, Sys->OREAD);
	if(bf == nil) fail(sys->sprint("open %s: %r", path));
	return bf;
}

loadbooks(path: string)
{
	bf := bopen(path);
	books = array[67] of ref Bookrec;
	nbooks = 0;
	while((s := bf.gets('\n')) != nil){
		(n, f) := sys->tokenize(s, "\t\n");
		if(n < 4)
			continue;
		b := atoi(hd f);
		nm := hd tl f;
		tt := hd tl tl f;
		gg := hd tl tl tl f;
		if(b >= 1 && b <= 66){
			books[b] = ref Bookrec(nm, tt, gg, nil);
			if(b > nbooks)
				nbooks = b;
		}
	}
}

loadverseidx(path: string)
{
	# first pass: count, find max chapter per book and verses per chapter
	bf := bopen(path);
	ids: list of int;
	offs: list of int;
	lens: list of int;
	n := 0;
	maxchap := array[67] of int;
	while((s := bf.gets('\n')) != nil){
		(nf, f) := sys->tokenize(s, " \n");
		if(nf < 3)
			continue;
		id := atoi(hd f);
		voffset := atoi(hd tl f);
		ln := atoi(hd tl tl f);
		ids = id :: ids;
		offs = voffset :: offs;
		lens = ln :: lens;
		b := id/1000000;
		c := (id/1000)%1000;
		if(b >= 1 && b <= 66 && c > maxchap[b])
			maxchap[b] = c;
		n++;
	}
	# build ascending arrays (lists were prepended, so reverse)
	allvids = array[n] of int;
	voff := array[n] of int;
	vlen := array[n] of int;
	i := n;
	for(; ids != nil; ids = tl ids){
		i--;
		allvids[i] = hd ids;
		voff[i] = hd offs;
		vlen[i] = hd lens;
		offs = tl offs;
		lens = tl lens;
	}
	# allocate chapter arrays
	for(b := 1; b <= 66; b++)
		if(books[b] != nil && maxchap[b] > 0)
			books[b].chaps = array[maxchap[b]] of ref Chapter;
	# group contiguous runs of (book,chapter); verses are 1..nv contiguous
	i = 0;
	while(i < n){
		b = allvids[i]/1000000;
		c := (allvids[i]/1000)%1000;
		j := i;
		while(j < n && allvids[j]/1000000 == b && (allvids[j]/1000)%1000 == c)
			j++;
		nv := allvids[j-1]%1000;
		ch := ref Chapter(array[nv] of ref Verse);
		for(k := i; k < j; k++){
			v := allvids[k]%1000;
			if(v >= 1 && v <= nv)
				ch.verses[v-1] = ref Verse(voff[k], vlen[k]);
		}
		if(books[b] != nil && books[b].chaps != nil && c >= 1 && c <= len books[b].chaps)
			books[b].chaps[c-1] = ch;
		i = j;
	}
}

loadabbrev(path: string)
{
	bf := bopen(path);
	l: list of (string, int);
	n := 0;
	while((s := bf.gets('\n')) != nil){
		(nf, f) := sys->tokenize(s, "\t\n");
		if(nf < 2)
			continue;
		l = (hd f, atoi(hd tl f)) :: l;
		n++;
	}
	abkeys = array[n] of (string, int);
	i := n;
	for(; l != nil; l = tl l){
		i--;
		abkeys[i] = hd l;
	}
}

loaddict(path: string)
{
	bf := bopen(path);
	l: list of ref Dword;
	n := 0;
	while((s := bf.gets('\n')) != nil){
		if(s[len s - 1] == '\n')
			s = s[0:len s - 1];
		# format: word\toff len
		tab := index(s, '\t');
		if(tab < 0)
			continue;
		w := s[0:tab];
		(nf, f) := sys->tokenize(s[tab+1:], " ");
		if(nf < 2)
			continue;
		l = ref Dword(w, atoi(hd f), atoi(hd tl f)) :: l;
		n++;
	}
	dwords = array[n] of ref Dword;
	i := n;
	for(; l != nil; l = tl l){
		i--;
		dwords[i] = hd l;
	}
}

loadxref(path: string)
{
	bf := bopen(path);
	l: list of ref Xrec;
	n := 0;
	while((s := bf.gets('\n')) != nil){
		(nf, f) := sys->tokenize(s, " \n");
		if(nf < 3)
			continue;
		l = ref Xrec(atoi(hd f), atoi(hd tl f), atoi(hd tl tl f)) :: l;
		n++;
	}
	xrefv = array[n] of ref Xrec;
	i := n;
	for(; l != nil; l = tl l){
		i--;
		xrefv[i] = hd l;
	}
}

#
# content generation
#

versetext(id: int): string
{
	b := id/1000000;
	c := (id/1000)%1000;
	v := id%1000;
	if(b < 1 || b > 66 || books[b] == nil || books[b].chaps == nil)
		return nil;
	if(c < 1 || c > len books[b].chaps)
		return nil;
	ch := books[b].chaps[c-1];
	if(ch == nil || v < 1 || v > len ch.verses)
		return nil;
	ve := ch.verses[v-1];
	if(ve == nil)
		return nil;
	return string vblob[ve.off:ve.off+ve.vlen];
}

versetsv(id: int): array of byte
{
	t := versetext(id);
	if(t == nil)
		return nil;
	b := id/1000000;
	c := (id/1000)%1000;
	v := id%1000;
	return array of byte sys->sprint("%s\t%d\t%d\t%s\n", books[b].name, c, v, t);
}

# concatenate a reverse-ordered list of byte arrays into one, restoring order
mkresult(rev: list of array of byte): array of byte
{
	total := 0;
	for(l := rev; l != nil; l = tl l)
		total += len hd l;
	out := array[total] of byte;
	pos := total;
	for(l = rev; l != nil; l = tl l){
		b := hd l;
		pos -= len b;
		out[pos:] = b;
	}
	return out;
}

lookup(q: string): array of byte
{
	res: list of array of byte;
	total := 0;
	(nil, parts) := sys->tokenize(q, ",;\n");
	for(; parts != nil; parts = tl parts){
		(lo, hi) := parseref(hd parts);
		if(lo <= 0)
			continue;
		i := lbound(lo);
		while(i < len allvids && allvids[i] <= hi && total < MAXREF){
			b := versetsv(allvids[i]);
			if(b != nil){
				res = b :: res;
				total++;
			}
			i++;
		}
	}
	return mkresult(res);
}

search(q: string): array of byte
{
	(nt, terms) := sys->tokenize(tolower(q), " \t\n");
	if(nt == 0)
		return nil;
	tarr := array[nt] of array of byte;
	for(i := 0; i < nt; i++){
		tarr[i] = array of byte hd terms;
		terms = tl terms;
	}
	res: list of array of byte;
	total := 0;
	for(j := 0; j < len allvids && total < MAXSEARCH; j++){
		id := allvids[j];
		b := id/1000000;
		c := (id/1000)%1000;
		v := id%1000;
		ve := books[b].chaps[c-1].verses[v-1];
		if(ve == nil)
			continue;
		if(allterms(ve.off, ve.vlen, tarr)){
			res = versetsv(id) :: res;
			total++;
		}
	}
	return mkresult(res);
}

# do all terms occur (case-folded) within vblob[off:off+n]?
allterms(off, n: int, terms: array of array of byte): int
{
	for(i := 0; i < len terms; i++)
		if(!foldfind(off, n, terms[i]))
			return 0;
	return 1;
}

foldfind(off, n: int, term: array of byte): int
{
	m := len term;
	if(m == 0)
		return 1;
	if(m > n)
		return 0;
	end := off + n - m;
	for(s := off; s <= end; s++){
		k := 0;
		while(k < m && fold(vblob[s+k]) == term[k])
			k++;
		if(k == m)
			return 1;
	}
	return 0;
}

fold(b: byte): byte
{
	if(b >= byte 'A' && b <= byte 'Z')
		return b + byte 16r20;
	return b;
}

xreflookup(q: string): array of byte
{
	(lo, nil) := parseref(q);
	if(lo <= 0)
		return nil;
	xi := xreffind(lo);
	if(xi < 0)
		return nil;
	xr := xrefv[xi];
	buf := array[xr.xlen] of byte;
	if(sys->pread(xfd, buf, xr.xlen, big xr.off) != xr.xlen)
		return nil;
	res: list of array of byte;
	total := 0;
	(nil, lines) := sys->tokenize(string buf, "\n");
	for(; lines != nil && total < MAXXREF; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " ");
		if(nf < 2)
			continue;
		sv := atoi(hd f);
		ev := atoi(hd tl f);
		if(ev <= sv){
			b := versetsv(sv);
			if(b != nil){
				res = b :: res;
				total++;
			}
		}else{
			i := lbound(sv);
			while(i < len allvids && allvids[i] <= ev && total < MAXXREF){
				b := versetsv(allvids[i]);
				if(b != nil){
					res = b :: res;
					total++;
				}
				i++;
			}
		}
	}
	return mkresult(res);
}

worddef(i: int): array of byte
{
	if(i < 0 || i >= len dwords)
		return nil;
	dw := dwords[i];
	buf := array[dw.dlen] of byte;
	if(sys->pread(dfd, buf, dw.dlen, big dw.off) != dw.dlen)
		return nil;
	return buf;
}

bookinfo(b: int): array of byte
{
	if(b < 1 || b > 66 || books[b] == nil)
		return nil;
	bk := books[b];
	nc := 0;
	nv := 0;
	if(bk.chaps != nil){
		nc = len bk.chaps;
		for(c := 0; c < nc; c++)
			if(bk.chaps[c] != nil)
				nv += len bk.chaps[c].verses;
	}
	return array of byte sys->sprint("%s\t%s\t%s\t%d chapters\t%d verses\n",
		bk.name, bk.testament, bk.genre, nc, nv);
}

votd(): array of byte
{
	if(len allvids == 0)
		return nil;
	day := 0;
	if(daytime != nil)
		day = daytime->now() / 86400;
	idx := day % len allvids;
	if(idx < 0)
		idx += len allvids;
	return versetsv(allvids[idx]);
}

randomverse(): array of byte
{
	if(len allvids == 0)
		return nil;
	seed = seed*1103515245 + 12345;
	idx := (seed >> 8) & 16r7fffffff;
	return versetsv(allvids[idx % len allvids]);
}

ctltext(): array of byte
{
	return array of byte sys->sprint(
		"biblefs\nbooks\t%d\nverses\t%d\ndictionary\t%d\nxref-verses\t%d\n",
		nbooks, len allvids, len dwords, len xrefv);
}

#
# reference parsing: "john3:16", "1cor13", "1cor13:4-7", "ps23", "gen1:1-3"
# returns an inclusive (lo,hi) verse-id range, or (0,0) on failure.
#

parseref(s0: string): (int, int)
{
	s := "";
	for(i := 0; i < len s0; i++){
		c := s0[i];
		if(c != ' ' && c != '\t')
			s[len s] = tolowerc(c);
	}
	if(len s == 0)
		return (0, 0);
	i = 0;
	tok := "";
	# a leading digit that is part of a book name (1cor, 2john, 3john)
	if(isdigit(s[0]) && len s > 1 && isalpha(s[1])){
		tok[len tok] = s[0];
		i = 1;
	}
	while(i < len s && isalpha(s[i])){
		tok[len tok] = s[i];
		i++;
	}
	b := resolvebook(tok);
	if(b <= 0 || books[b] == nil || books[b].chaps == nil)
		return (0, 0);
	rest := s[i:];
	return chapverse(b, rest);
}

chapverse(b: int, rest: string): (int, int)
{
	bk := books[b];
	lastc := len bk.chaps;
	if(rest == ""){
		# whole book
		lv := nverses(b, lastc);
		return (vid(b, 1, 1), vid(b, lastc, lv));
	}
	colon := index(rest, ':');
	cstr := rest;
	vstr := "";
	if(colon >= 0){
		cstr = rest[0:colon];
		vstr = rest[colon+1:];
	}
	c := atoi(cstr);
	if(c < 1 || c > lastc || bk.chaps[c-1] == nil)
		return (0, 0);
	nv := nverses(b, c);
	if(vstr == ""){
		# whole chapter
		return (vid(b, c, 1), vid(b, c, nv));
	}
	dash := index(vstr, '-');
	if(dash < 0){
		v := atoi(vstr);
		if(v < 1) v = 1;
		if(v > nv) v = nv;
		return (vid(b, c, v), vid(b, c, v));
	}
	v1 := atoi(vstr[0:dash]);
	v2s := vstr[dash+1:];
	v2 := nv;
	if(v2s != "")
		v2 = atoi(v2s);
	if(v1 < 1) v1 = 1;
	if(v2 > nv) v2 = nv;
	if(v2 < v1) v2 = v1;
	return (vid(b, c, v1), vid(b, c, v2));
}

nverses(b, c: int): int
{
	if(b < 1 || b > 66 || books[b] == nil || books[b].chaps == nil)
		return 0;
	if(c < 1 || c > len books[b].chaps || books[b].chaps[c-1] == nil)
		return 0;
	return len books[b].chaps[c-1].verses;
}

resolvebook(tok: string): int
{
	if(tok == "")
		return 0;
	# exact match (binary search on sorted abkeys)
	lo := 0;
	hi := len abkeys;
	while(lo < hi){
		mid := (lo+hi)/2;
		(k, nil) := abkeys[mid];
		if(k < tok)
			lo = mid+1;
		else
			hi = mid;
	}
	if(lo < len abkeys){
		(k, bb) := abkeys[lo];
		if(k == tok)
			return bb;
	}
	# unique-ish prefix match: first key that starts with tok
	for(i := 0; i < len abkeys; i++){
		(k, bb) := abkeys[i];
		if(len k >= len tok && k[0:len tok] == tok)
			return bb;
	}
	return 0;
}

# index of first allvids entry >= x
lbound(x: int): int
{
	lo := 0;
	hi := len allvids;
	while(lo < hi){
		mid := (lo+hi)/2;
		if(allvids[mid] < x)
			lo = mid+1;
		else
			hi = mid;
	}
	return lo;
}

xreffind(id: int): int
{
	lo := 0;
	hi := len xrefv;
	while(lo < hi){
		mid := (lo+hi)/2;
		if(xrefv[mid].vid < id)
			lo = mid+1;
		else
			hi = mid;
	}
	if(lo < len xrefv && xrefv[lo].vid == id)
		return lo;
	return -1;
}

dwordfind(w: string): int
{
	lo := 0;
	hi := len dwords;
	while(lo < hi){
		mid := (lo+hi)/2;
		if(dwords[mid].word < w)
			lo = mid+1;
		else
			hi = mid;
	}
	if(lo < len dwords && dwords[lo].word == w)
		return lo;
	return -1;
}

#
# small helpers
#

atoi(s: string): int
{
	n := 0;
	i := 0;
	while(i < len s && s[i] == ' ')
		i++;
	while(i < len s && isdigit(s[i])){
		n = n*10 + (s[i] - '0');
		i++;
	}
	return n;
}

index(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

isalpha(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

tolowerc(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		return c + ('a' - 'A');
	return c;
}

tolower(s: string): string
{
	for(i := 0; i < len s; i++)
		s[i] = tolowerc(s[i]);
	return s;
}

#
# the file server
#

serve(tchan: chan of ref Tmsg, navops: chan of ref Navop)
{
Serve:
	while((gm := <-tchan) != nil){
		pick m := gm {
		Readerror =>
			sys->fprint(stderr, "biblefs: fatal read error: %s\n", m.error);
			break Serve;
		Read =>
			(c, err) := srv.canread(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR){
				srv.read(m);	# directory listing via navigator
				break;
			}
			k := pkind(c.path);
			if(k == Qlookup || k == Qsearch || k == Qxref){
				# request/response stream (the /net/dns idiom): the
				# answer to the last write is consumed by reads, so
				# the byte offset left by the write is irrelevant.
				if(c.data == nil)
					c.data = array[0] of byte;
				n := m.count;
				if(n > len c.data)
					n = len c.data;
				srv.reply(ref Rmsg.Read(m.tag, c.data[0:n]));
				c.data = c.data[n:];
				break;
			}
			if(c.data == nil)
				c.data = filedata(c);
			srv.reply(styxservers->readbytes(m, c.data));
		Write =>
			(c, err) := srv.canwrite(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			q := string m.data;
			case pkind(c.path) {
			Qlookup =>
				c.data = lookup(q);
			Qsearch =>
				c.data = search(q);
			Qxref =>
				c.data = xreflookup(q);
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
				break;
			}
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		Open =>
			c := srv.getfid(m.fid);
			if(c != nil)
				c.data = nil;	# fresh content for this open
			srv.open(m);
		Clunk =>
			srv.clunk(m);
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

# generate the bytes for a read-only file fid the first time it is read
filedata(c: ref Fid): array of byte
{
	case pkind(c.path) {
	Qverse =>
		return versetsv(ppayload(c.path));
	Qword =>
		return worddef(ppayload(c.path));
	Qinfo =>
		return bookinfo(ppayload(c.path));
	Qvotd =>
		return votd();
	Qrandom =>
		return randomverse();
	Qctl =>
		return ctltext();
	}
	return nil;
}

dir(qid: Qid, name: string, perm: int): ref Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(qid.qtype & Sys->QTDIR)
		perm |= Sys->DMDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = big 0;
	return d;
}

dirgen(p: big): (ref Dir, string)
{
	kind := pkind(p);
	pay := ppayload(p);
	case kind {
	Qroot =>
		return (dir(Qid(p, 0, Sys->QTDIR), "/", 8r555), nil);
	Qbooksdir =>
		return (dir(Qid(p, 0, Sys->QTDIR), "books", 8r555), nil);
	Qdefinedir =>
		return (dir(Qid(p, 0, Sys->QTDIR), "define", 8r555), nil);
	Qlookup =>
		return (dir(Qid(p, 0, Sys->QTFILE), "lookup", 8r666), nil);
	Qsearch =>
		return (dir(Qid(p, 0, Sys->QTFILE), "search", 8r666), nil);
	Qxref =>
		return (dir(Qid(p, 0, Sys->QTFILE), "xref", 8r666), nil);
	Qvotd =>
		return (dir(Qid(p, 0, Sys->QTFILE), "votd", 8r444), nil);
	Qrandom =>
		return (dir(Qid(p, 0, Sys->QTFILE), "random", 8r444), nil);
	Qctl =>
		return (dir(Qid(p, 0, Sys->QTFILE), "ctl", 8r444), nil);
	Qnotes =>
		# empty stub directory: a mount point for a per-user notefs, so the
		# notes tree appears at /mnt/bible/notes within this same namespace.
		return (dir(Qid(p, 0, Sys->QTDIR), "notes", 8r555), nil);
	Qbookdir =>
		if(pay < 1 || pay > 66 || books[pay] == nil)
			return (nil, Enotfound);
		return (dir(Qid(p, 0, Sys->QTDIR), books[pay].name, 8r555), nil);
	Qinfo =>
		return (dir(Qid(p, 0, Sys->QTFILE), "info", 8r444), nil);
	Qchapdir =>
		c := pay % 1000;
		return (dir(Qid(p, 0, Sys->QTDIR), string c, 8r555), nil);
	Qverse =>
		return (dir(Qid(p, 0, Sys->QTFILE), string (pay%1000), 8r444), nil);
	Qword =>
		if(pay < 0 || pay >= len dwords)
			return (nil, Enotfound);
		return (dir(Qid(p, 0, Sys->QTFILE), dwords[pay].word, 8r444), nil);
	}
	return (nil, Enotfound);
}

# child paths of a directory, in listing order
children(p: big): array of big
{
	kind := pkind(p);
	pay := ppayload(p);
	case kind {
	Qroot =>
		return array[] of {
			mkpath(Qbooksdir, 0),
			mkpath(Qdefinedir, 0),
			mkpath(Qlookup, 0),
			mkpath(Qsearch, 0),
			mkpath(Qxref, 0),
			mkpath(Qvotd, 0),
			mkpath(Qrandom, 0),
			mkpath(Qctl, 0),
			mkpath(Qnotes, 0),
		};
	Qbooksdir =>
		a := array[nbooks] of big;
		for(b := 1; b <= nbooks; b++)
			a[b-1] = mkpath(Qbookdir, b);
		return a;
	Qbookdir =>
		if(pay < 1 || pay > 66 || books[pay] == nil)
			return nil;
		nc := 0;
		if(books[pay].chaps != nil)
			nc = len books[pay].chaps;
		a := array[nc+1] of big;
		a[0] = mkpath(Qinfo, pay);
		for(c := 1; c <= nc; c++)
			a[c] = mkpath(Qchapdir, pay*1000 + c);
		return a;
	Qchapdir =>
		b := pay / 1000;
		c := pay % 1000;
		nv := nverses(b, c);
		a := array[nv] of big;
		for(v := 1; v <= nv; v++)
			a[v-1] = mkpath(Qverse, vid(b, c, v));
		return a;
	Qdefinedir =>
		return nil;	# walk-only: define/<word>
	}
	return nil;
}

walk(parent: big, name: string): (ref Dir, string)
{
	kind := pkind(parent);
	pay := ppayload(parent);
	if(name == ".."){
		case kind {
		Qbookdir =>	return dirgen(mkpath(Qbooksdir, 0));
		Qchapdir =>	return dirgen(mkpath(Qbookdir, pay/1000));
		* =>		return dirgen(mkpath(Qroot, 0));
		}
	}
	case kind {
	Qroot =>
		case name {
		"books" =>	return dirgen(mkpath(Qbooksdir, 0));
		"define" =>	return dirgen(mkpath(Qdefinedir, 0));
		"lookup" =>	return dirgen(mkpath(Qlookup, 0));
		"search" =>	return dirgen(mkpath(Qsearch, 0));
		"xref" =>	return dirgen(mkpath(Qxref, 0));
		"votd" =>	return dirgen(mkpath(Qvotd, 0));
		"random" =>	return dirgen(mkpath(Qrandom, 0));
		"ctl" =>	return dirgen(mkpath(Qctl, 0));
		"notes" =>	return dirgen(mkpath(Qnotes, 0));
		}
	Qbooksdir =>
		b := bookbyname(name);
		if(b > 0)
			return dirgen(mkpath(Qbookdir, b));
	Qbookdir =>
		if(name == "info")
			return dirgen(mkpath(Qinfo, pay));
		if(len name > 0 && isdigit(name[0])){
			c := atoi(name);
			if(c >= 1 && c <= len books[pay].chaps && books[pay].chaps[c-1] != nil)
				return dirgen(mkpath(Qchapdir, pay*1000 + c));
		}
	Qchapdir =>
		b := pay/1000;
		c := pay%1000;
		if(len name > 0 && isdigit(name[0])){
			v := atoi(name);
			if(v >= 1 && v <= nverses(b, c))
				return dirgen(mkpath(Qverse, vid(b, c, v)));
		}
	Qdefinedir =>
		i := dwordfind(tolower(name));
		if(i >= 0)
			return dirgen(mkpath(Qword, i));
	}
	return (nil, Enotfound);
}

bookbyname(name: string): int
{
	ln := tolower(name);
	for(b := 1; b <= nbooks; b++)
		if(books[b] != nil && tolower(books[b].name) == ln)
			return b;
	return 0;
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil){
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);
		Walk =>
			n.reply <-= walk(n.path, n.name);
		Readdir =>
			kids := children(n.path);
			i := n.offset;
			cnt := n.count;
			while(cnt-- > 0 && i < len kids){
				n.reply <-= dirgen(kids[i]);
				i++;
			}
			n.reply <-= (nil, nil);
		}
	}
}
