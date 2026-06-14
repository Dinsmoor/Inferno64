implement Fedifs;

#
# fedifs -- serve a Pleroma/Mastodon account as a Styx file tree.
#
# Wraps the GUI-free Masto library (appl/lib/masto.b) in a styxservers file
# server so the Fediverse becomes part of the namespace.  Mount it and the
# whole system composes against it -- the shell can `cat` a timeline, acme can
# compose a toot, grep can search your feed, the plumber can route a status,
# and a thin client can `import` it from a beefy host.  fedifs is the sole
# holder of the OAuth bearer token at run time; its clients never see it.
#
# Tree (mount at /mnt/fedi):
#
#   /                           the mount root
#   <host>/                     created on demand when first walked
#       ctl                     write commands; read a one-line status
#       home                    read: home timeline (newest first)
#       public                  read: public timeline
#       notifications           read: your notifications
#       me                      read: the authenticated account
#       instance               read: instance name/description
#       compose                 write: one write == one new status
#       stream                  read: blocks, yields new home posts as they land
#
#   ctl verbs (one per write line):
#       login <user> <pass>     log in and persist the session (token kept here)
#       post <text...>          create a status
#       reply <id> <text...>    reply to a status
#       fav <id> | unfav <id>
#       boost <id> | unboost <id>
#       bookmark <id> | unbookmark <id>
#       react <id> <emoji> | unreact <id> <emoji>
#
# Start it (cs must be up so dialtls can resolve):
#       mount {fedifs} /mnt/fedi
# then select a host by walking it:
#       cat /mnt/fedi/nicecrew.digital/home
#
# Streaming is currently a server-side poll of the home timeline (POLLSEC);
# the file interface is identical to a true SSE stream, so the transport can
# be swapped later without any client change.

include "sys.m";
	sys: Sys;
	Qid, Dir: import Sys;

include "draw.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

include "bufio.m";
	bufio: Bufio;

include "json.m";
	json: JSON;
	JValue: import json;

include "masto.m";
	masto: Masto;
	Client, Status, Notification, Account, Reaction, Session: import masto;

Fedifs: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

# file indices within a host subtree; the qid path packs (hostindex<<8)|fileindex
Fhostdir, Fctl, Fhome, Fpublic, Fnotif, Fme, Finstance, Fcompose, Fstream, Fauthurl: con iota;

POLLSEC:	con 30;		# stream poll interval, seconds
SEENMAX:	con 256;	# per-host ring of recently-seen status ids
LIMIT:		con 30;		# timeline page size

user := "inferno";

# a configured instance/account.  `label` is the directory name and session
# key: a bare host ("poa.st") or a fediverse handle ("alice@poa.st") so several
# accounts on one instance coexist as sibling subtrees.  The client always
# dials the *real* host (the part after the last '@').
Host: adt {
	label:	string;		# directory name / session key
	idx:	int;		# >=1; encodes into qid paths
	client:	ref Client;	# carries the bearer token, dials the real host
	me:	string;		# authenticated handle (shown in ctl), "" if unknown
	lasterr:	string;
	seen:	list of string;	# recently-seen ids (stream dedup)
	nseen:	int;
	nstream:	int;		# active stream readers (poller runs only while >0)
	pollstop:	chan of int;	# stop signal for the lazy poller, nil when idle
	pendcid:	string;		# OAuth app id staged by "authbegin", "" if none
	pendcsec:	string;		# matching app secret
	pendurl:	string;		# the /oauth/authorize URL served by the authurl file
};

hosts: list of ref Host;
nhost := 0;

# a client blocked reading a stream file
Streamc: adt {
	fid:	int;
	hidx:	int;
	q:	list of string;		# queued rendered posts, oldest first
	pending: ref Tmsg.Read;
};
streamcs: list of ref Streamc;

tree: ref Tree;
srv: ref Styxserver;
tc: chan of ref Tmsg;
feedc: chan of (int, string);	# (hostindex, rendered post) from pollers

hostof(p: big): int { return int(p >> 8); }
fileof(p: big): int { return int(p & big 16rff); }
mkpath(h, f: int): big { return (big h << 8) | big f; }

badmod(p: string)
{
	sys->fprint(sys->fildes(2), "fedifs: cannot load %s: %r\n", p);
	raise "fail:load";
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	if(styx == nil) badmod(Styx->PATH);
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) badmod(Styxservers->PATH);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil) badmod(Nametree->PATH);
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil) badmod(Bufio->PATH);
	json = load JSON JSON->PATH;
	if(json == nil) badmod(JSON->PATH);
	masto = load Masto Masto->PATH;
	if(masto == nil) badmod(Masto->PATH);

	styx->init();
	styxservers->init(styx);
	nametree->init();
	e := masto->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "fedifs: masto init: %s\n", e);
		raise "fail:masto";
	}

	(t, treeop) := nametree->start();
	tree = t;
	tree.create(big 0, dir(".", Sys->DMDIR|8r555, big 0));

	feedc = chan of (int, string);
	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big 0);
	enumsessions();		# expose already-logged-in hosts as walkable trees
	serve();
}

dir(name: string, perm: int, path: big): Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

findhost(idx: int): ref Host
{
	for(l := hosts; l != nil; l = tl l)
		if((hd l).idx == idx)
			return hd l;
	return nil;
}

findhostbylabel(label: string): ref Host
{
	for(l := hosts; l != nil; l = tl l)
		if((hd l).label == label)
			return hd l;
	return nil;
}

# the real hostname to dial: the part after the last '@' (so "alice@poa.st"
# dials poa.st), tolerating a leading '@' on a "@user@host" handle.
hostfromlabel(label: string): string
{
	for(i := len label - 1; i >= 0; i--)
		if(label[i] == '@')
			return label[i+1:];
	return label;
}

# the username encoded in a "user@host" label ("" for a bare host)
userfromlabel(label: string): string
{
	s := label;
	if(len s > 0 && s[0] == '@')
		s = s[1:];
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == '@')
			return s[0:i];
	return "";
}

# create the account subtree on first walk; idempotent.  the poller is NOT
# started here -- it runs lazily, only while a stream file is open.
ensurehost(label: string): ref Host
{
	h := findhostbylabel(label);
	if(h != nil)
		return h;
	idx := ++nhost;
	sess := masto->loadsession(label);
	token := "";
	if(sess != nil)
		token = sess.token;
	h = ref Host(label, idx, masto->client(hostfromlabel(label), token),
		"", "", nil, 0, 0, nil, "", "", "");
	hosts = h :: hosts;

	base := mkpath(idx, Fhostdir);
	tree.create(big 0, dir(label, Sys->DMDIR|8r555, base));
	tree.create(base, dir("ctl", 8r666, mkpath(idx, Fctl)));
	tree.create(base, dir("home", 8r444, mkpath(idx, Fhome)));
	tree.create(base, dir("public", 8r444, mkpath(idx, Fpublic)));
	tree.create(base, dir("notifications", 8r444, mkpath(idx, Fnotif)));
	tree.create(base, dir("me", 8r444, mkpath(idx, Fme)));
	tree.create(base, dir("instance", 8r444, mkpath(idx, Finstance)));
	tree.create(base, dir("compose", 8r222, mkpath(idx, Fcompose)));
	tree.create(base, dir("stream", 8r444, mkpath(idx, Fstream)));
	tree.create(base, dir("authurl", 8r444, mkpath(idx, Fauthurl)));
	return h;
}

# pick up a session that appeared on disk after this host was created
# anonymously (e.g. a GUI login wrote the JSON).  Only loads while we still
# have no token, so an authenticated host is never disturbed.  force re-reads
# regardless (the `reload` ctl verb).
refreshauth(h: ref Host, force: int)
{
	if(h == nil || (h.client.token != "" && !force))
		return;
	sess := masto->loadsession(h.label);
	if(sess != nil && sess.token != "")
		h.client.token = sess.token;
}

# pre-populate a subtree for every saved session so `ls /mnt/fedi` lists the
# accounts you're already logged into, each a ready authenticated tree.  Hosts
# without a saved session are still reachable by walking them on demand.
enumsessions()
{
	fd := sys->open(masto->sessiondir(), Sys->OREAD);
	if(fd == nil)
		return;
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			name := dirs[i].name;
			if(len name > 5 && name[len name - 5:] == ".json")
				ensurehost(name[0:len name - 5]);
		}
	}
}

serve()
{
	for(;;) alt {
	tmsg := <-tc =>
		if(tmsg == nil)
			break;
		dispatch(tmsg);
	(hidx, msg) := <-feedc =>
		deliverfeed(hidx, msg);
	}
	tree.quit();
}

dispatch(tmsg: ref Tmsg)
{
	pick tm := tmsg {
	Readerror =>
		# fatal: connection gone
		raise "fail:readerror";
	Flush =>
		cancelpending(tm.oldtag);
		srv.reply(ref Rmsg.Flush(tm.tag));
	Walk =>
		# dynamically materialise a host subtree the first time it is walked
		f := srv.getfid(tm.fid);
		if(f != nil && hostof(f.path) == 0 && len tm.names > 0)
			ensurehost(tm.names[0]);
		srv.walk(tm);
	Open =>
		c := srv.open(tm);
		if(c == nil)
			break;
		idx := hostof(c.path);
		refreshauth(findhost(idx), 0);	# catch a login that landed since creation
		case fileof(c.path) {
		Fhome or Fpublic or Fnotif or Fme or Finstance =>
			c.data = rendercontent(idx, fileof(c.path));	# cache for the read
		Fstream =>
			streamcs = ref Streamc(tm.fid, idx, nil, nil) :: streamcs;
			startpoll(idx);		# run the poller only while a stream is open
		}
	Read =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			break;
		}
		case fileof(c.path) {
		Fhostdir =>
			srv.read(tm);			# directory listing via navigator
		Fctl =>
			refreshauth(findhost(hostof(c.path)), 0);
			srv.reply(styxservers->readstr(tm, ctlstatus(hostof(c.path))));
		Fstream =>
			streamread(tm);
		Fcompose =>
			srv.reply(styxservers->readstr(tm, ""));
		Fauthurl =>
			h := findhost(hostof(c.path));
			u := "";
			if(h != nil && h.pendurl != "")
				u = h.pendurl + "\n";
			srv.reply(styxservers->readstr(tm, u));
		* =>
			srv.reply(styxservers->readbytes(tm, c.data));
		}
	Write =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			break;
		}
		idx := hostof(c.path);
		case fileof(c.path) {
		Fctl =>
			e := doctl(idx, string tm.data);
			if(e != nil)
				srv.reply(ref Rmsg.Error(tm.tag, e));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		Fcompose =>
			h := findhost(idx);
			e := "no such host";
			if(h != nil){
				refreshauth(h, 0);
				(nil, err) := masto->poststatus(h.client, string tm.data, "", "", "");
				e = err;
			}
			if(e != nil)
				srv.reply(ref Rmsg.Error(tm.tag, e));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		}
	Clunk =>
		c := srv.clunk(tm);
		if(c != nil && fileof(c.path) == Fstream){
			delstreamc(tm.fid);
			stoppoll(hostof(c.path));	# stop the poller when the last reader leaves
		}
	* =>
		srv.default(tmsg);
	}
}

# ---- rendering -------------------------------------------------------------

rendercontent(idx, which: int): array of byte
{
	h := findhost(idx);
	if(h == nil)
		return array of byte "no such host\n";
	case which {
	Fhome =>
		(ss, nil, err) := masto->hometimeline(h.client, "", LIMIT);
		if(err != nil) return array of byte ("error: " + err + "\n");
		return array of byte renderstatuses(ss);
	Fpublic =>
		(ss, nil, err) := masto->publictimeline(h.client, "", LIMIT);
		if(err != nil) return array of byte ("error: " + err + "\n");
		return array of byte renderstatuses(ss);
	Fnotif =>
		(ns, nil, err) := masto->notifications(h.client, "", LIMIT);
		if(err != nil) return array of byte ("error: " + err + "\n");
		s := "";
		for(l := ns; l != nil; l = tl l)
			s += rendernotif(hd l);
		return array of byte s;
	Fme =>
		(a, err) := masto->verifycredentials(h.client);
		if(err != nil) return array of byte ("error: " + err + "\n");
		return array of byte renderaccount(a);
	Finstance =>
		(jv, err) := masto->instance(h.client);
		if(err != nil) return array of byte ("error: " + err + "\n");
		return array of byte renderinstance(jv);
	}
	return nil;
}

renderstatuses(ss: list of ref Status): string
{
	s := "";
	for(; ss != nil; ss = tl ss)
		s += renderstatus(hd ss);
	return s;
}

renderstatus(st: ref Status): string
{
	if(st == nil)
		return "";
	disp := st;
	pre := "";
	if(st.reblog != nil){
		who := "?";
		if(st.account != nil)
			who = st.account.acct;
		pre = "(boost by " + who + ")\n";
		disp = st.reblog;
	}
	acct := "?";
	name := "";
	if(disp.account != nil){
		acct = disp.account.acct;
		name = disp.account.display_name;
	}
	s := pre + "@" + acct;
	if(name != nil)
		s += " (" + name + ")";
	s += "\n";
	if(disp.spoiler_text != nil)
		s += "CW: " + disp.spoiler_text + "\n";
	s += htmltext(disp.content) + "\n";
	s += sys->sprint("[fav %d boost %d reply %d] %s\n",
		disp.favourites_count, disp.reblogs_count, disp.replies_count, disp.id);
	if(disp.reactions != nil){
		s += "reactions:";
		for(r := disp.reactions; r != nil; r = tl r)
			s += " " + (hd r).name + "(" + string (hd r).count + ")";
		s += "\n";
	}
	s += "----\n";
	return s;
}

rendernotif(n: ref Notification): string
{
	if(n == nil)
		return "";
	who := "?";
	if(n.account != nil)
		who = n.account.acct;
	s := n.ntype + " from @" + who + "\n";
	if(n.status != nil)
		s += htmltext(n.status.content) + " " + n.status.id + "\n";
	s += "----\n";
	return s;
}

renderaccount(a: ref Account): string
{
	if(a == nil)
		return "";
	s := "@" + a.acct + " (" + a.display_name + ")\n";
	s += "url: " + a.url + "\n";
	if(a.note != nil)
		s += htmltext(a.note) + "\n";
	return s;
}

renderinstance(jv: ref JValue): string
{
	if(jv == nil)
		return "";
	return jstr(jv, "title") + "\n" + jstr(jv, "version") + "\n" +
		htmltext(jstr(jv, "description")) + "\n";
}

# pull a top-level string field out of a JSON object, tolerant of shape
jstr(jv: ref JValue, key: string): string
{
	if(jv == nil)
		return "";
	v := jv.get(key);
	if(v == nil)
		return "";
	pick vv := v {
	String =>
		return vv.s;
	}
	return "";
}

# crude HTML -> plain text: drop tags, turn <br>/<p> into newlines, decode
# the handful of entities that actually show up in toots.
htmltext(s: string): string
{
	out := "";
	intag := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(intag){
			if(c == '>')
				intag = 0;
			continue;
		}
		case c {
		'<' =>
			# treat block breaks as newlines
			if(i+3 < len s && (s[i+1]=='b'||s[i+1]=='B') && (s[i+2]=='r'||s[i+2]=='R'))
				out += "\n";
			else if(i+2 < len s && (s[i+1]=='/') && (s[i+2]=='p'||s[i+2]=='P'))
				out += "\n";
			intag = 1;
		'&' =>
			(ent, ni) := readentity(s, i);
			out += ent;
			i = ni;
		* =>
			out[len out] = c;
		}
	}
	return out;
}

readentity(s: string, i: int): (string, int)
{
	# i points at '&'; return (decoded, index of last char consumed)
	j := i+1;
	while(j < len s && s[j] != ';' && j-i < 10)
		j++;
	if(j >= len s || s[j] != ';')
		return ("&", i);
	name := s[i+1:j];
	r := "?";
	case name {
	"amp" => r = "&";
	"lt" => r = "<";
	"gt" => r = ">";
	"quot" => r = "\"";
	"apos" or "#39" => r = "'";
	"nbsp" => r = " ";
	* =>
		if(len name > 1 && name[0] == '#'){
			n := int name[1:];
			if(n > 0){
				r = "";
				r[0] = n;
			}
		}
	}
	return (r, j);
}

# ---- ctl -------------------------------------------------------------------

ctlstatus(idx: int): string
{
	h := findhost(idx);
	if(h == nil)
		return "no such host\n";
	st := "anonymous";
	if(h.client.token != ""){
		st = "logged in";
		if(h.me != "")
			st += " as @" + h.me;
	}
	s := h.label + " (" + hostfromlabel(h.label) + "): " + st + "\n";
	if(h.pendurl != "")
		s += "auth pending: read the authurl file, then write 'authcode <code>'\n";
	if(h.lasterr != nil)
		s += "last error: " + h.lasterr + "\n";
	return s;
}

doctl(idx: int, line: string): string
{
	h := findhost(idx);
	if(h == nil)
		return "no such host";
	(n, toks) := sys->tokenize(line, " \t\n");
	if(n == 0)
		return nil;
	cmd := hd toks;
	args := tl toks;
	err := "";
	case cmd {
	"login" =>
		# On a "user@host" node only the password is needed (the user is in
		# the node name); on a bare host node give "login <user> <pass>".
		# The password is taken as the rest of the line, so it may contain
		# spaces and shell-special characters.
		usr := userfromlabel(h.label);
		pass: string;
		if(usr != ""){
			if(len args < 1)
				return "usage: login <password>";
			pass = restafter(line, 1);
		} else {
			if(len args < 2)
				return "usage: login <user> <password>";
			usr = hd args;
			pass = restafter(line, 2);
		}
		(sess, e) := masto->login(h.client, usr, pass, "");
		if(e != nil)
			err = e;
		else
			err = establish(h, sess);
	"authbegin" =>
		# OAuth authorization-code fallback for instances that reject the
		# password grant: register the app and stage the authorize URL on the
		# authurl file.  The user opens that URL in a browser, approves, and
		# pastes the one-time code back via "authcode".
		(cid, csec, url, e) := masto->beginoob(h.client, "");
		if(e != nil)
			err = e;
		else {
			h.pendcid = cid; h.pendcsec = csec; h.pendurl = url;
		}
	"authcode" =>
		if(len args < 1)
			return "usage: authcode <code>";
		if(h.pendcid == "")
			return "no pending authorization; write authbegin first";
		(sess, e) := masto->finishoob(h.client, h.pendcid, h.pendcsec, restafter(line, 1), "");
		if(e != nil)
			err = e;
		else {
			err = establish(h, sess);
			h.pendcid = ""; h.pendcsec = ""; h.pendurl = "";
		}
	"logout" =>
		sys->remove(masto->sessionpath(h.label));
		h.client.token = "";
		h.me = "";
		h.pendcid = ""; h.pendcsec = ""; h.pendurl = "";
		stopallpoll(h);
	"reload" =>
		refreshauth(h, 1);		# force re-read the session from disk
	"fav" =>
		err = act(h, args, "favourite");
	"unfav" =>
		err = act(h, args, "unfavourite");
	"boost" =>
		err = act(h, args, "reblog");
	"unboost" =>
		err = act(h, args, "unreblog");
	"bookmark" =>
		err = act(h, args, "bookmark");
	"unbookmark" =>
		err = act(h, args, "unbookmark");
	"react" =>
		if(len args < 2) return "usage: react id emoji";
		(nil, e) := masto->react(h.client, hd args, hd tl args);
		err = e;
	"unreact" =>
		if(len args < 2) return "usage: unreact id emoji";
		(nil, e) := masto->unreact(h.client, hd args, hd tl args);
		err = e;
	"post" =>
		(nil, e) := masto->poststatus(h.client, joinrest(args), "", "", "");
		err = e;
	"reply" =>
		if(len args < 2) return "usage: reply id text";
		(nil, e) := masto->poststatus(h.client, joinrest(tl args), "", hd args, "");
		err = e;
	* =>
		return "unknown command: " + cmd;
	}
	if(err != nil)
		h.lasterr = err;
	return err;
}

# persist a freshly-minted session under the account label, adopt its token,
# and learn the authenticated handle.  Shared by the password and oob logins.
establish(h: ref Host, sess: ref Session): string
{
	sess.host = h.label;
	if((se := masto->savesession(sess)) != "")
		return se;
	h.client.token = sess.token;
	(acc, nil) := masto->verifycredentials(h.client);
	if(acc != nil)
		h.me = acc.acct;
	return "";
}

act(h: ref Host, args: list of string, action: string): string
{
	if(args == nil)
		return "missing id";
	(nil, e) := masto->statusaction(h.client, hd args, action);
	return e;
}

joinrest(args: list of string): string
{
	s := "";
	for(; args != nil; args = tl args){
		if(s != "")
			s += " ";
		s += hd args;
	}
	return s;
}

# the remainder of `line` after the first `ntok` whitespace-separated tokens,
# kept verbatim (so a password may contain spaces) minus any trailing newline
restafter(line: string, ntok: int): string
{
	i := 0;
	while(i < len line && (line[i] == ' ' || line[i] == '\t'))
		i++;
	for(t := 0; t < ntok && i < len line; t++){
		while(i < len line && line[i] != ' ' && line[i] != '\t' && line[i] != '\n')
			i++;
		while(i < len line && (line[i] == ' ' || line[i] == '\t'))
			i++;
	}
	e := len line;
	while(e > i && (line[e-1] == '\n' || line[e-1] == '\r'))
		e--;
	return line[i:e];
}

# stop a host's poller unconditionally (used on logout)
stopallpoll(h: ref Host)
{
	if(h.pollstop != nil){
		h.pollstop <-= 0;
		h.pollstop = nil;
	}
}

# ---- streaming -------------------------------------------------------------

# a stream reader just opened: start the poller for this host if it is the
# first reader and we are authenticated (no point polling a feed we can't read)
startpoll(idx: int)
{
	h := findhost(idx);
	if(h == nil)
		return;
	if(h.nstream++ == 0 && h.pollstop == nil && h.client.token != ""){
		h.pollstop = chan[1] of int;
		spawn poller(idx, h.pollstop);
	}
}

# a stream reader left: stop the poller when the last reader is gone
stoppoll(idx: int)
{
	h := findhost(idx);
	if(h == nil)
		return;
	if(h.nstream > 0)
		h.nstream--;
	if(h.nstream == 0 && h.pollstop != nil){
		h.pollstop <-= 0;	# buffered, so this never blocks the serve loop
		h.pollstop = nil;
	}
}

# poll the home timeline while a stream is open, emitting unseen posts on feedc;
# exits promptly when signalled on stop
poller(idx: int, stop: chan of int)
{
	for(;;){
		h := findhost(idx);
		if(h == nil)
			return;
		(ss, nil, err) := masto->hometimeline(h.client, "", LIMIT);
		if(err == nil){
			# emit oldest-first so the stream reads chronologically
			rev: list of ref Status;
			for(l := ss; l != nil; l = tl l)
				rev = hd l :: rev;
			for(; rev != nil; rev = tl rev){
				st := hd rev;
				if(st != nil && !seenid(h, st.id)){
					markseen(h, st.id);
					feedc <-= (idx, renderstatus(st));
				}
			}
		} else
			h.lasterr = err;
		# interruptible sleep: wake early to exit when the last reader leaves
		for(slept := 0; slept < POLLSEC*1000; slept += 250){
			alt {
			<-stop =>
				return;
			* =>
				sys->sleep(250);
			}
		}
	}
}

seenid(h: ref Host, id: string): int
{
	for(l := h.seen; l != nil; l = tl l)
		if(hd l == id)
			return 1;
	return 0;
}

markseen(h: ref Host, id: string)
{
	h.seen = id :: h.seen;
	if(++h.nseen > SEENMAX){
		# trim the tail
		nl: list of string;
		i := 0;
		for(l := h.seen; l != nil && i < SEENMAX; l = tl l){
			nl = hd l :: nl;
			i++;
		}
		rl: list of string;
		for(; nl != nil; nl = tl nl)
			rl = hd nl :: rl;
		h.seen = rl;
		h.nseen = i;
	}
}

# a new post arrived for host idx: queue it to every stream client and
# satisfy any that are blocked in a read
deliverfeed(idx: int, msg: string)
{
	for(l := streamcs; l != nil; l = tl l){
		sc := hd l;
		if(sc.hidx != idx)
			continue;
		if(sc.pending != nil){
			srv.reply(styxservers->readstr(sc.pending, msg));
			sc.pending = nil;
		} else
			sc.q = appendstr(sc.q, msg);
	}
}

streamread(tm: ref Tmsg.Read)
{
	sc := findstreamc(tm.fid);
	if(sc == nil){
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
		return;
	}
	if(sc.q != nil){
		msg := hd sc.q;
		sc.q = tl sc.q;
		srv.reply(styxservers->readstr(tm, msg));
		return;
	}
	if(sc.pending != nil){
		srv.reply(ref Rmsg.Error(tm.tag, "read already pending"));
		return;
	}
	sc.pending = tm;	# block until a post arrives
}

findstreamc(fid: int): ref Streamc
{
	for(l := streamcs; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

delstreamc(fid: int)
{
	nl: list of ref Streamc;
	for(l := streamcs; l != nil; l = tl l)
		if((hd l).fid != fid)
			nl = hd l :: nl;
	streamcs = nl;
}

cancelpending(tag: int)
{
	for(l := streamcs; l != nil; l = tl l){
		sc := hd l;
		if(sc.pending != nil && sc.pending.tag == tag){
			sc.pending = nil;
			return;
		}
	}
}

appendstr(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: appendstr(tl l, s);
}
