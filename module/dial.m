Dial: module
{
	PATH: con "/dis/lib/dial.dis";

	Connection: adt
	{
		dfd:	ref Sys->FD;
		cfd:	ref Sys->FD;
		dir:	string;
	};

	Conninfo: adt
	{
		dir:	string;
		root:	string;
		spec:	string;
		lsys:	string;
		lserv:	string;
		rsys:	string;
		rserv:	string;
		laddr:	string;
		raddr:	string;
	};

	announce:	fn(addr: string): ref Connection;
	dial:	fn(addr, local: string): ref Connection;
	listen:	fn(c: ref Connection): ref Connection;
	accept:	fn(c: ref Connection): ref Sys->FD;
	reject:	fn(c: ref Connection, why: string): int;
#	parse:	fn(addr: string): (string, string, string);

	netmkaddr:	fn(addr, net, svc: string): string;
	netinfo:	fn(c: ref Connection): ref Conninfo;

	# Modern TLS (1.2/1.3) via the #T devtls device.
	# pushtls layers TLS onto an already-connected fd: returns the cleartext
	# data fd, the ctl fd (KEEP IT OPEN for the connection's life — closing it
	# tears down the TLS conversation and underlying socket), and an error
	# string (nil on success).  servername is used for SNI + cert hostname
	# verification (pass the real host; "" disables SNI and likely cert verify).
	pushtls:	fn(fd: ref Sys->FD, servername: string): (ref Sys->FD, ref Sys->FD, string);
	# dialtls = dial + pushtls; c.dfd is cleartext, the returned fd is the ctl.
	dialtls:	fn(addr, local, servername: string): (ref Connection, ref Sys->FD, string);
};
