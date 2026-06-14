implement Notefs;

#
# notefs -- per-user Bible notes & highlights as a writable Styx file tree.
#
# Mounted at /mnt/bible/notes (onto the empty stub biblefs exposes), so notes
# sit beside scripture in one namespace: /mnt/bible/books/John/3/16 is the
# verse, /mnt/bible/notes/John/3/16 is your note on it.  Notes persist as plain
# files under $home/lib/bible/notes, so acme/grep/the plumber compose with them
# and they survive a restart.  notefs holds the verse text format opaque; the
# reader (wm/bible) owns the little frontmatter (highlight:, tags:, body).
#
#	mount {notefs} /mnt/bible/notes
#
# Tree:
#   /
#       <Book>/<chap>/<verse>   a note (read/write; created on first write,
#                               removed when written empty or removed)
#       recent                  read: "<Book> <chap>:<verse>" lines, newest first
#
# Any <Book>/<chap>/<verse> path is walkable whether or not a note exists yet
# (like /mnt/bible itself), so a client just opens the path and writes -- no
# mkdir dance.  readdir lists only the books/chapters/verses that have notes,
# which is what a reader uses to mark annotated verses.
#

include "sys.m";
	sys: Sys;
	Qid, Dir: import Sys;

include "draw.m";

include "arg.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;

include "daytime.m";
	daytime: Daytime;

Notefs: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

Kroot, Krecent, Kbookdir, Kchapdir, Kverse: con iota;

KSHIFT:		con 56;
RECENTMAX:	con 300;

Note: adt {
	book:	string;
	chap:	int;
	verse:	int;
	data:	array of byte;
	mtime:	int;
};

notes:		list of ref Note;	# the whole store (a user's notes are few)
seenbooks:	array of string;	# interned book names, indexed by Qid
nbooks:		int;
notesroot:	string;
srv:		ref Styxserver;
stderr:		ref Sys->FD;
user:		string;
clock:		int;			# fallback monotonic mtime when no daytime

fail(s: string)
{
	sys->fprint(stderr, "notefs: %s\n", s);
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
	daytime = load Daytime Daytime->PATH;	# optional

	arg := load Arg Arg->PATH;
	if(arg == nil) nomod(Arg->PATH);
	arg->init(args);
	arg->setusage("mount {notefs [-D] [-d notesdir]} /mnt/bible/notes");
	user = rf("/dev/user");
	if(user == nil)
		user = "inferno";
	notesroot = "/usr/" + user + "/lib/bible/notes";
	while((o := arg->opt()) != 0)
		case o {
		'D' =>	styxservers->traceset(1);
		'd' =>	notesroot = arg->earg();
		* =>	arg->usage();
		}
	arg = nil;

	seenbooks = array[8] of string;
	nbooks = 0;
	mkdirp(notesroot);
	loadall();

	navops := chan of ref Navop;
	spawn navigator(navops);
	(tchan, nsrv) := Styxserver.new(sys->fildes(0), Navigator.new(navops), big mkp(Kroot, big 0));
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

now(): int
{
	if(daytime != nil)
		return daytime->now();
	return ++clock;
}

#
# Qid packing: kind in the high byte; payload packs bookidx<<24 | chap<<12 | verse
#

mkp(kind: int, pay: big): big
{
	return (big kind << KSHIFT) | pay;
}

kindof(p: big): int
{
	return int (p >> KSHIFT) & 16rFF;
}

payof(p: big): big
{
	return p & ((big 1 << KSHIFT) - big 1);
}

packbcv(bi, c, v: int): big
{
	return (big bi << 24) | (big c << 12) | big v;
}

bookof(p: big): int
{
	return int (payof(p) >> 24);
}

chapof(p: big): int
{
	return int (payof(p) >> 12) & 16rFFF;
}

verseof(p: big): int
{
	return int payof(p) & 16rFFF;
}

bookintern(name: string): int
{
	for(i := 0; i < nbooks; i++)
		if(seenbooks[i] == name)
			return i;
	if(nbooks >= len seenbooks){
		a := array[len seenbooks * 2] of string;
		a[0:] = seenbooks;
		seenbooks = a;
	}
	seenbooks[nbooks] = name;
	return nbooks++;
}

#
# the note store
#

findnote(book: string, chap, verse: int): ref Note
{
	for(l := notes; l != nil; l = tl l){
		n := hd l;
		if(n.chap == chap && n.verse == verse && n.book == book)
			return n;
	}
	return nil;
}

putnote(book: string, chap, verse: int, data: array of byte)
{
	n := findnote(book, chap, verse);
	if(n != nil){
		n.data = data;
		n.mtime = now();
	}else
		notes = ref Note(book, chap, verse, data, now()) :: notes;
}

delnote(book: string, chap, verse: int)
{
	nl: list of ref Note;
	for(l := notes; l != nil; l = tl l){
		n := hd l;
		if(!(n.chap == chap && n.verse == verse && n.book == book))
			nl = n :: nl;
	}
	notes = nl;
}

#
# persistence: $home/lib/bible/notes/<Book>/<chap>/<verse>
#

notepath(book: string, chap, verse: int): string
{
	return notesroot + "/" + book + "/" + string chap + "/" + string verse;
}

mkdirp(path: string)
{
	# create each component in turn, ignoring "already exists"
	cur := "";
	(nil, els) := sys->tokenize(path, "/");
	for(; els != nil; els = tl els){
		cur += "/" + hd els;
		(ok, d) := sys->stat(cur);
		if(ok < 0 || !(d.mode & Sys->DMDIR)){
			fd := sys->create(cur, Sys->OREAD, Sys->DMDIR | 8r777);
			fd = nil;
		}
	}
}

savenote(book: string, chap, verse: int, data: array of byte)
{
	mkdirp(notesroot + "/" + book + "/" + string chap);
	fp := notepath(book, chap, verse);
	fd := sys->create(fp, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(stderr, "notefs: create %s: %r\n", fp);
		return;
	}
	if(len data > 0)
		sys->write(fd, data, len data);
}

removenotefile(book: string, chap, verse: int)
{
	sys->remove(notepath(book, chap, verse));
}

loadall()
{
	bd := sys->open(notesroot, Sys->OREAD);
	if(bd == nil)
		return;
	for(;;){
		(rc, books) := sys->dirread(bd);
		if(rc <= 0)
			break;
		for(i := 0; i < rc; i++){
			if(!(books[i].mode & Sys->DMDIR))
				continue;
			loadbook(books[i].name);
		}
	}
}

loadbook(book: string)
{
	cd := sys->open(notesroot + "/" + book, Sys->OREAD);
	if(cd == nil)
		return;
	for(;;){
		(rc, chaps) := sys->dirread(cd);
		if(rc <= 0)
			break;
		for(i := 0; i < rc; i++){
			if(!(chaps[i].mode & Sys->DMDIR))
				continue;
			loadchap(book, chaps[i].name);
		}
	}
}

loadchap(book, chapname: string)
{
	chap := int chapname;
	vd := sys->open(notesroot + "/" + book + "/" + chapname, Sys->OREAD);
	if(vd == nil)
		return;
	for(;;){
		(rc, verses) := sys->dirread(vd);
		if(rc <= 0)
			break;
		for(i := 0; i < rc; i++){
			if(verses[i].mode & Sys->DMDIR)
				continue;
			verse := int verses[i].name;
			data := readfile(notepath(book, chap, verse));
			if(data == nil)
				data = array[0] of byte;
			notes = ref Note(book, chap, verse, data, verses[i].mtime) :: notes;
		}
	}
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	n := int d.length;
	buf := array[n] of byte;
	r := 0;
	while(r < n){
		m := sys->read(fd, buf[r:], n - r);
		if(m <= 0)
			break;
		r += m;
	}
	return buf[0:r];
}

#
# synthesized content
#

recenttext(): array of byte
{
	# newest first; selection sort over a small list
	a := l2a();
	for(i := 0; i < len a; i++){
		mx := i;
		for(j := i + 1; j < len a; j++)
			if(a[j].mtime > a[mx].mtime)
				mx = j;
		t := a[i]; a[i] = a[mx]; a[mx] = t;
	}
	s := "";
	for(i = 0; i < len a && i < RECENTMAX; i++)
		s += a[i].book + " " + string a[i].chap + ":" + string a[i].verse + "\n";
	return array of byte s;
}

l2a(): array of ref Note
{
	n := 0;
	for(l := notes; l != nil; l = tl l)
		n++;
	a := array[n] of ref Note;
	i := 0;
	for(l = notes; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
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
			sys->fprint(stderr, "notefs: fatal read error: %s\n", m.error);
			break Serve;
		Open =>
			c := srv.getfid(m.fid);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, styxservers->Ebadfid));
				break;
			}
			if(kindof(c.path) != Kverse){
				srv.open(m);		# dirs and recent: default handling
				break;
			}
			mode := styxservers->openmode(m.mode);
			if(mode < 0){
				srv.reply(ref Rmsg.Error(m.tag, Ebadarg));
				break;
			}
			if(m.mode & Sys->OTRUNC)
				c.data = array[0] of byte;
			else
				c.data = notedata(c.path);
			qid := Qid(c.path, 0, Sys->QTFILE);
			c.open(mode, qid);
			srv.reply(ref Rmsg.Open(m.tag, qid, srv.iounit()));
		Read =>
			(c, err) := srv.canread(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR){
				srv.read(m);		# readdir via navigator
				break;
			}
			if(kindof(c.path) == Krecent){
				if(c.data == nil)
					c.data = recenttext();
				srv.reply(styxservers->readbytes(m, c.data));
				break;
			}
			if(c.data == nil)
				c.data = array[0] of byte;
			srv.reply(styxservers->readbytes(m, c.data));
		Write =>
			(c, err) := srv.canwrite(m);
			if(c == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(kindof(c.path) != Kverse){
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
				break;
			}
			c.data = writeat(c.data, int m.offset, m.data);
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		Clunk =>
			c := srv.getfid(m.fid);
			if(c != nil && kindof(c.path) == Kverse &&
			   (c.mode == Sys->OWRITE || c.mode == Sys->ORDWR))
				commit(c.path, c.data);
			srv.clunk(m);
		Remove =>
			c := srv.getfid(m.fid);
			if(c != nil && kindof(c.path) == Kverse){
				bi := bookof(c.path);
				book := seenbooks[bi];
				chap := chapof(c.path);
				verse := verseof(c.path);
				delnote(book, chap, verse);
				removenotefile(book, chap, verse);
				srv.delfid(c);
				srv.reply(ref Rmsg.Remove(m.tag));
			}else
				srv.remove(m);
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

# the note content backing a verse-file fid (empty if none yet)
notedata(p: big): array of byte
{
	bi := bookof(p);
	if(bi < 0 || bi >= nbooks)
		return array[0] of byte;
	n := findnote(seenbooks[bi], chapof(p), verseof(p));
	if(n == nil)
		return array[0] of byte;
	return n.data;
}

# persist (or, when written empty, delete) the note for a verse-file path
commit(p: big, data: array of byte)
{
	bi := bookof(p);
	if(bi < 0 || bi >= nbooks)
		return;
	book := seenbooks[bi];
	chap := chapof(p);
	verse := verseof(p);
	if(data == nil)
		data = array[0] of byte;
	if(len data == 0){
		delnote(book, chap, verse);
		removenotefile(book, chap, verse);
	}else{
		putnote(book, chap, verse, data);
		savenote(book, chap, verse, data);
	}
}

writeat(buf: array of byte, off: int, data: array of byte): array of byte
{
	if(buf == nil)
		buf = array[0] of byte;
	need := off + len data;
	if(need > len buf){
		nb := array[need] of byte;
		nb[0:] = buf;
		buf = nb;
	}
	buf[off:] = data;
	return buf;
}

#
# navigator: walk-any tree, readdir from the note store
#

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
	case kindof(p) {
	Kroot =>
		return (dir(Qid(p, 0, Sys->QTDIR), "/", 8r755), nil);
	Krecent =>
		return (dir(Qid(p, 0, Sys->QTFILE), "recent", 8r444), nil);
	Kbookdir =>
		bi := bookof(p);
		if(bi < 0 || bi >= nbooks)
			return (nil, Enotfound);
		return (dir(Qid(p, 0, Sys->QTDIR), seenbooks[bi], 8r755), nil);
	Kchapdir =>
		return (dir(Qid(p, 0, Sys->QTDIR), string chapof(p), 8r755), nil);
	Kverse =>
		return (dir(Qid(p, 0, Sys->QTFILE), string verseof(p), 8r666), nil);
	}
	return (nil, Enotfound);
}

walk(parent: big, name: string): (ref Dir, string)
{
	if(name == ".."){
		case kindof(parent) {
		Kchapdir =>	return dirgen(mkp(Kbookdir, packbcv(bookof(parent), 0, 0)));
		Kbookdir =>	return dirgen(mkp(Kroot, big 0));
		* =>		return dirgen(mkp(Kroot, big 0));
		}
	}
	case kindof(parent) {
	Kroot =>
		if(name == "recent")
			return dirgen(mkp(Krecent, big 0));
		bi := bookintern(name);
		return dirgen(mkp(Kbookdir, packbcv(bi, 0, 0)));
	Kbookdir =>
		if(isnum(name))
			return dirgen(mkp(Kchapdir, packbcv(bookof(parent), int name, 0)));
	Kchapdir =>
		if(isnum(name))
			return dirgen(mkp(Kverse, packbcv(bookof(parent), chapof(parent), int name)));
	}
	return (nil, Enotfound);
}

children(p: big): array of big
{
	case kindof(p) {
	Kroot =>
		bks := distinctbooks();
		a := array[len bks + 1] of big;
		a[0] = mkp(Krecent, big 0);
		for(i := 0; i < len bks; i++)
			a[i+1] = mkp(Kbookdir, packbcv(bks[i], 0, 0));
		return a;
	Kbookdir =>
		bi := bookof(p);
		cs := distinctchaps(seenbooks[bi]);
		a := array[len cs] of big;
		for(i := 0; i < len cs; i++)
			a[i] = mkp(Kchapdir, packbcv(bi, cs[i], 0));
		return a;
	Kchapdir =>
		bi := bookof(p);
		c := chapof(p);
		vs := chapverses(seenbooks[bi], c);
		a := array[len vs] of big;
		for(i := 0; i < len vs; i++)
			a[i] = mkp(Kverse, packbcv(bi, c, vs[i]));
		return a;
	}
	return nil;
}

distinctbooks(): array of int
{
	idx: list of int;
	n := 0;
	for(l := notes; l != nil; l = tl l){
		bi := bookintern((hd l).book);
		if(!member(bi, idx)){
			idx = bi :: idx;
			n++;
		}
	}
	return l2ai(idx, n);
}

distinctchaps(book: string): array of int
{
	cs: list of int;
	n := 0;
	for(l := notes; l != nil; l = tl l){
		nt := hd l;
		if(nt.book == book && !member(nt.chap, cs)){
			cs = nt.chap :: cs;
			n++;
		}
	}
	return l2ai(cs, n);
}

chapverses(book: string, chap: int): array of int
{
	vs: list of int;
	n := 0;
	for(l := notes; l != nil; l = tl l){
		nt := hd l;
		if(nt.book == book && nt.chap == chap){
			vs = nt.verse :: vs;
			n++;
		}
	}
	return l2ai(vs, n);
}

member(x: int, l: list of int): int
{
	for(; l != nil; l = tl l)
		if(hd l == x)
			return 1;
	return 0;
}

l2ai(l: list of int, n: int): array of int
{
	a := array[n] of int;
	i := n;
	for(; l != nil; l = tl l)
		a[--i] = hd l;
	return a;
}

isnum(s: string): int
{
	if(s == "")
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
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
