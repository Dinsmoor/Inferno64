implement Sql;

#
# sql - minimal client for the sqlitefs host Styx server.
#
# Worked example for docs/ON_C_AT_RUNTIME.md: dial the out-of-process
# native C server, mount it, and drive SQLite purely by reading/writing
# files.  A crash in the C server shows up here only as an I/O error.
#
#	sql [-a tcp!host!port] dbfile 'SQL statement'
#

include "sys.m";
	sys: Sys;
include "draw.m";

Sql: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;

usage()
{
	sys->fprint(stderr, "usage: sql [-a tcp!host!port] dbfile 'SQL statement'\n");
	raise "fail:usage";
}

fail(s: string)
{
	sys->fprint(stderr, "sql: %s\n", s);
	raise "fail:error";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	addr := "tcp!127.0.0.1!6701";
	mnt := "/n/sqlite";

	argv = tl argv;
	if(argv != nil && hd argv == "-a"){
		argv = tl argv;
		if(argv == nil)
			usage();
		addr = hd argv;
		argv = tl argv;
	}
	if(len argv != 2)
		usage();
	dbfile := hd argv;
	stmt := hd tl argv;

	# 1. dial the out-of-process C server and mount it as a file tree
	# private namespace so each run is isolated and leaves no stale mounts
	sys->pctl(Sys->FORKNS, nil);
	sys->unmount(nil, mnt);			# clear any leftover mount

	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0)
		fail(sys->sprint("cannot dial %s: %r", addr));
	if(sys->stat(mnt).t0 < 0){		# ensure the mount point exists
		dfd := sys->create(mnt, Sys->OREAD, Sys->DMDIR | 8r777);
		if(dfd == nil)
			fail(sys->sprint("cannot create mountpoint %s: %r", mnt));
	}
	if(sys->mount(conn.dfd, nil, mnt, Sys->MREPL, "") < 0)
		fail(sys->sprint("cannot mount %s: %r", mnt));

	# 2. clone a fresh connection; the open fd is its ctl file
	ctl := sys->open(mnt+"/db/new", Sys->ORDWR);
	if(ctl == nil)
		fail(sys->sprint("open %s/db/new: %r", mnt));
	buf := array[32] of byte;
	n := sys->read(ctl, buf, len buf);
	if(n <= 0)
		fail(sys->sprint("read connection number: %r"));
	id := string buf[0:n];
	dir := mnt+"/db/"+id;

	# 3. point this connection at the database file
	if(sys->fprint(ctl, "open %s", dbfile) < 0)
		fail(sys->sprint("open db %q: %r", dbfile));

	# 4. run the statement by writing it to cmd
	cmd := sys->open(dir+"/cmd", Sys->OWRITE);
	if(cmd == nil)
		fail(sys->sprint("open %s/cmd: %r", dir));
	if(sys->write(cmd, a := array of byte stmt, len a) < 0)
		fail(sys->sprint("sql error: %r"));

	# 5. read the result rows back out of data
	data := sys->open(dir+"/data", Sys->OREAD);
	if(data == nil)
		fail(sys->sprint("open %s/data: %r", dir));
	out := sys->fildes(1);
	rbuf := array[8192] of byte;
	for(;;){
		n = sys->read(data, rbuf, len rbuf);
		if(n < 0)
			fail(sys->sprint("read result: %r"));
		if(n == 0)
			break;
		sys->write(out, rbuf, n);
	}
}
