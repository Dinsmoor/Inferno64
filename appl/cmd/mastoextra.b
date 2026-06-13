implement Mastoextra;

#
# Headless check for the #12 verbs:  mastoextra
# Loads the saved session for nicecrew.digital, then exercises
# notifications / getstatus / statuscontext / getaccount / accountstatuses
# and prints a compact summary.  Requires a token at
# $home/lib/pleromussy/nicecrew.digital.json (never echoed).
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
	Client, Account, Status, Notification, Session: import masto;

HOST: con "nicecrew.digital";

Mastoextra: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Command: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	masto = load Masto Masto->PATH;
	if(masto == nil){
		sys->fprint(sys->fildes(2), "load masto: %r\n");
		raise "fail:load";
	}
	if((e := masto->init()) != nil){
		sys->fprint(sys->fildes(2), "masto init: %s\n", e);
		raise "fail:init";
	}
	ensurecs();

	sess := masto->loadsession(HOST);
	if(sess == nil){
		sys->fprint(sys->fildes(2), "no saved session for %s\n", HOST);
		raise "fail:nosession";
	}
	c := masto->client(HOST, sess.token);

	# who am I
	(me, verr) := masto->verifycredentials(c);
	if(me == nil){
		sys->fprint(sys->fildes(2), "verify: %s\n", verr);
		raise "fail:verify";
	}
	sys->print("me: @%s (id %s)\n", me.acct, me.id);

	# notifications
	(ns, nnext, nerr) := masto->notifications(c, "", 10);
	if(nerr != nil)
		sys->print("notifications ERR: %s\n", nerr);
	else {
		sys->print("notifications: %d (next=%q)\n", len ns, nnext);
		i := 0;
		for(l := ns; l != nil && i < 5; l = tl l){
			n := hd l;
			who := "?";
			if(n.account != nil)
				who = n.account.acct;
			sid := "-";
			if(n.status != nil)
				sid = n.status.id;
			sys->print("  [%s] @%-24s status=%s\n", n.ntype, who, sid);
			i++;
		}
	}

	# a status to inspect a thread for: prefer a notification's status,
	# else the first home-timeline status.
	sid := "";
	for(l := ns; l != nil && sid == ""; l = tl l)
		if((hd l).status != nil)
			sid = (hd l).status.id;
	if(sid == ""){
		(hs, nil, herr) := masto->hometimeline(c, "", 5);
		if(herr == nil && hs != nil)
			sid = (hd hs).id;
	}
	if(sid != ""){
		(st, serr) := masto->getstatus(c, sid);
		if(st == nil)
			sys->print("getstatus(%s) ERR: %s\n", sid, serr);
		else {
			au := "?";
			if(st.account != nil)
				au = st.account.acct;
			sys->print("status %s by @%s, replies=%d\n", st.id, au, st.replies_count);
		}
		(anc, desc, cerr) := masto->statuscontext(c, sid);
		if(cerr != nil)
			sys->print("context ERR: %s\n", cerr);
		else
			sys->print("context: %d ancestors, %d descendants\n", len anc, len desc);
	} else
		sys->print("no status id available to test context\n");

	# profile: my own account + my statuses
	(acc, aerr) := masto->getaccount(c, me.id);
	if(acc == nil)
		sys->print("getaccount ERR: %s\n", aerr);
	else
		sys->print("account @%s: bot=%d locked=%d\n", acc.acct, acc.bot, acc.locked);
	(sts, snext, sterr) := masto->accountstatuses(c, me.id, "", 5);
	if(sterr != nil)
		sys->print("accountstatuses ERR: %s\n", sterr);
	else
		sys->print("accountstatuses: %d (next=%q)\n", len sts, snext);

	# Pleroma emoji reactions: read the reactions on my latest status, then
	# round-trip react/unreact with a test emoji to exercise the write path
	# (cleaned up so it leaves no trace on the account).
	if(sts != nil){
		mine := hd sts;
		(rx, rxerr) := masto->statusreactions(c, mine.id);
		if(rxerr != nil)
			sys->print("reactions ERR: %s\n", rxerr);
		else {
			sys->print("reactions on %s: %d kinds\n", mine.id, len rx);
			for(rl := rx; rl != nil; rl = tl rl){
				re := hd rl;
				sys->print("  %s x%d (me=%d)\n", re.name, re.count, re.me);
			}
		}
		(s1, e1) := masto->react(c, mine.id, "🔥");
		if(e1 != nil)
			sys->print("react ERR: %s\n", e1);
		else {
			sys->print("react ok: %d reaction kinds now\n", len s1.reactions);
			(s2, e2) := masto->unreact(c, mine.id, "🔥");
			if(e2 != nil)
				sys->print("unreact ERR: %s\n", e2);
			else
				sys->print("unreact ok: %d reaction kinds now\n", len s2.reactions);
		}
	}

	sys->print("OK\n");
}

ensurecs()
{
	if(csup())
		return;
	cs := load Command "/dis/ndb/cs.dis";
	if(cs == nil)
		return;
	spawn cs->init(nil, "cs" :: nil);
	for(i := 0; i < 50 && !csup(); i++)
		sys->sleep(100);
}

csup(): int
{
	fd := sys->open("/net/cs", Sys->ORDWR);
	return fd != nil;
}
