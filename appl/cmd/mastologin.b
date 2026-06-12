implement Mastologin;

#
# OAuth password-grant harness:
#   mastologin host user passfile
# Reads the password from passfile (so it never appears on a command line),
# registers an app, runs the password grant, persists the session via
# masto->savesession ($home/lib/pleromussy/<host>.json), then fetches the
# authed public timeline as a smoke test.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;

include "masto.m";
	masto: Masto;

Mastologin: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	masto = load Masto Masto->PATH;
	if(masto == nil){
		sys->fprint(sys->fildes(2), "load Masto: %r\n");
		raise "fail:load";
	}
	if((e := masto->init()) != nil){
		sys->fprint(sys->fildes(2), "masto init: %s\n", e);
		raise "fail:init";
	}

	argv = tl argv;
	if(len argv < 3){
		sys->fprint(sys->fildes(2), "usage: mastologin host user passfile\n");
		raise "fail:usage";
	}
	host := hd argv;
	user := hd tl argv;
	passfile := hd tl tl argv;

	pass := readtrim(passfile);
	if(pass == ""){
		sys->fprint(sys->fildes(2), "empty password file %s\n", passfile);
		raise "fail:pass";
	}

	c := masto->client(host, "");
	sys->print("logging in as %s on %s ...\n", user, host);
	(sess, le) := masto->login(c, user, pass, "");
	if(le != nil){
		sys->fprint(sys->fildes(2), "login: %s\n", le);
		raise "fail:login";
	}
	tok := sess.token;
	sys->print("got access_token (len %d)\n", len tok);

	# persist the session ($home/lib/pleromussy/<host>.json)
	if((serr := masto->savesession(sess)) != nil){
		sys->fprint(sys->fildes(2), "savesession: %s\n", serr);
		raise "fail:save";
	}
	sys->print("session saved to %s\n", masto->sessionpath(host));

	# smoke test: authed public timeline
	c2 := masto->client(host, tok);
	sys->print("\nfetching authed public timeline ...\n");
	(sts, next, ferr) := masto->publictimeline(c2, "", 10);
	if(ferr != nil){
		sys->fprint(sys->fildes(2), "publictimeline: %s\n", ferr);
		raise "fail:fetch";
	}
	n := 0;
	for(l := sts; l != nil; l = tl l){
		s := hd l;
		n++;
		who := "?";
		if(s.account != nil){
			who = s.account.acct;
			if(s.account.display_name != "")
				who = s.account.display_name + " (@" + s.account.acct + ")";
		}
		sys->print("\n[%d] %s  %s\n", n, who, s.created_at);
		sys->print("    %s\n", striphtml(s.content));
	}
	sys->print("\n-- %d statuses, next max_id=%q\n", n, next);
}

readtrim(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	s := string buf[0:n];
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

striphtml(s: string): string
{
	out := "";
	intag := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '<'){ intag = 1; continue; }
		if(c == '>'){ intag = 0; out[len out] = ' '; continue; }
		if(!intag){
			if(c == '\n' || c == '\r' || c == '\t')
				c = ' ';
			out[len out] = c;
		}
	}
	if(len out > 200)
		out = out[0:200] + "...";
	return out;
}
