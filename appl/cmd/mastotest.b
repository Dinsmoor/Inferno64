implement Mastotest;

#
# Throwaway harness: fetch and print a public timeline, proving the
# masto library's TLS->JSON->ADT path with no GUI.
#   mastotest [host]      (default nicecrew.digital)
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
	Status, Account, Client: import masto;

Mastotest: module
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
	e := masto->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "masto init: %s\n", e);
		raise "fail:init";
	}

	host := "nicecrew.digital";
	if(tl argv != nil)
		host = hd tl argv;

	c := masto->client(host, "");
	sys->print("fetching public timeline of %s ...\n", host);
	(sts, next, err) := masto->publictimeline(c, "", 10);
	if(err != nil){
		sys->fprint(sys->fildes(2), "publictimeline: %s\n", err);
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
		sys->print("    id=%s vis=%s  fav=%d boost=%d reply=%d\n",
			s.id, s.visibility, s.favourites_count, s.reblogs_count, s.replies_count);
		sys->print("    %s\n", striphtml(s.content));
	}
	sys->print("\n-- %d statuses, next max_id=%q\n", n, next);
}

# crude HTML -> text: drop tags, decode a few entities, collapse to one line
striphtml(s: string): string
{
	out := "";
	intag := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '<'){
			intag = 1;
			continue;
		}
		if(c == '>'){
			intag = 0;
			out[len out] = ' ';
			continue;
		}
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
