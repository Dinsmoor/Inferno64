implement StyxNetTest;

#
# Avenue 1: networking + 9P/Styx.
# A real TCP loopback round-trip through emu's /net (devip) using the Dial
# module (announce/listen/accept/dial over a spawned server), plus Styx
# (9P2000) message marshalling: Tmsg/Rmsg pack->unpack round-trips for the
# pointer-heavy message variants (arrays of names/qids, big offsets, Dir
# stat) and packdir/unpackdir.  This exercises the kernel's Block/Fcall paths
# and the Styx library's serialisation, both sensitive to pointer width.
#
include "sys.m";
include "draw.m";
include "dial.m";
include "styx.m";
include "testing.m";

sys: Sys;
dial: Dial;
styx: Styx;
t: Testing;

Tmsg, Rmsg: import styx;

StyxNetTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# server: accept one connection, echo a single line back uppercased-length-prefixed
echoserver(c: ref Dial->Connection, ready: chan of int)
{
	ready <-= 1;
	nc := dial->listen(c);
	if(nc == nil)
		return;
	fd := dial->accept(nc);
	if(fd == nil)
		return;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n > 0)
		sys->write(fd, buf, n);		# echo verbatim
}

localport(dir: string): string
{
	fd := sys->open(dir + "/local", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	# "127.0.0.1!41715\n" -> "41715"
	(nil, toks) := sys->tokenize(string b[0:n], "!\n");
	if(len toks < 2)
		return nil;
	return hd tl toks;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	t = load Testing Testing->PATH;
	t->init();

	# ===== TCP loopback round-trip via devip =====
	c := dial->announce("tcp!127.0.0.1!0");
	t->ok(c != nil, "announce tcp loopback");
	if(c != nil){
		port := localport(c.dir);
		t->ok(port != nil, "read assigned local port");

		ready := chan of int;
		spawn echoserver(c, ready);
		<-ready;

		addr := "tcp!127.0.0.1!" + port;
		cc := dial->dial(addr, nil);
		t->ok(cc != nil, "dial back to server");
		if(cc != nil){
			msg := array of byte "ping-9p-loopback";
			sys->write(cc.dfd, msg, len msg);
			rb := array[256] of byte;
			n := sys->read(cc.dfd, rb, len rb);
			t->eqs(string rb[0:n], "ping-9p-loopback", "TCP echo round-trip");
		}
	}

	# ===== Styx (9P2000) message pack/unpack round-trips =====
	# Tmsg.Version
	rt(t, ref Tmsg.Version(Styx->NOTAG, 8192, "9P2000"), "Tmsg.Version");
	# Tmsg.Walk carries an array of names (pointers)
	rt(t, ref Tmsg.Walk(1, 4, 5, array[] of {"usr", "glenda", "tmp"}), "Tmsg.Walk(3 names)");
	# Tmsg.Open
	rt(t, ref Tmsg.Open(2, 7, Sys->OREAD), "Tmsg.Open");
	# Tmsg.Read with a big (64-bit) offset
	rt(t, ref Tmsg.Read(3, 9, big 16r100000000 + big 12345, 4096), "Tmsg.Read big offset");
	# Tmsg.Write carries a data array
	rt(t, ref Tmsg.Write(4, 11, big 4096, array of byte "payload-bytes"), "Tmsg.Write data");
	# Tmsg.Attach
	rt(t, ref Tmsg.Attach(5, 0, Styx->NOFID, "glenda", "main"), "Tmsg.Attach");

	# Rmsg side
	rrt(t, ref Rmsg.Version(Styx->NOTAG, 8192, "9P2000"), "Rmsg.Version");
	rrt(t, ref Rmsg.Read(6, array of byte "the quick brown fox"), "Rmsg.Read data");
	rrt(t, ref Rmsg.Error(7, "no such file"), "Rmsg.Error");
	q := Sys->Qid(big 16r200000001, 42, Sys->QTDIR);
	rrt(t, ref Rmsg.Walk(8, array[] of {q, q, q}), "Rmsg.Walk(3 qids)");

	# ===== Dir stat marshalling (packdir/unpackdir) =====
	d: Sys->Dir;
	d.name = "testfile";
	d.uid = "glenda";
	d.gid = "glenda";
	d.muid = "glenda";
	d.qid = Sys->Qid(big 16r300000007, 99, Sys->QTFILE);
	d.mode = 8r644;
	d.atime = 1717200000;
	d.mtime = 1717200001;
	d.length = big 16r100000064;		# > 4 GiB to exercise the 64-bit length
	d.dtype = 'M';
	d.dev = 0;
	packed := styx->packdir(d);
	t->eqi(big len packed, big styx->packdirsize(d), "packdir size matches");
	(nn, d2) := styx->unpackdir(packed);
	t->eqi(big nn, big len packed, "unpackdir consumed all bytes");
	t->eqs(d2.name, d.name, "unpackdir name");
	t->eqi(d2.length, d.length, "unpackdir 64-bit length");
	t->eqi(d2.qid.path, d.qid.path, "unpackdir qid path (big)");

	t->summary();
}

# Tmsg round-trip: pack, unpack, compare text() representations
rt(t: Testing, m: ref Tmsg, name: string)
{
	a := m.pack();
	if(a == nil){
		t->ok(0, name + " (pack returned nil)");
		return;
	}
	(n, m2) := Tmsg.unpack(a);
	if(n != len a || m2 == nil){
		t->ok(0, name + " (unpack failed)");
		return;
	}
	t->eqs(m2.text(), m.text(), name);
}

rrt(t: Testing, m: ref Rmsg, name: string)
{
	a := m.pack();
	if(a == nil){
		t->ok(0, name + " (pack returned nil)");
		return;
	}
	(n, m2) := Rmsg.unpack(a);
	if(n != len a || m2 == nil){
		t->ok(0, name + " (unpack failed)");
		return;
	}
	t->eqs(m2.text(), m.text(), name);
}
