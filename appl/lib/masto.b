implement Masto;

#
# Mastodon/Pleroma client-API library.  Transport over Dial->dialtls (the
# in-tree mbedTLS #T devtls path); responses parsed with lib/json.  GUI-free.
# See module/masto.m and docs/ref/pleroma.api.md.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "string.m";
	str: String;

include "dial.m";
	dial: Dial;

include "json.m";
	json: JSON;
	JValue: import json;

include "masto.m";

init(): string
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	dial = load Dial Dial->PATH;
	json = load JSON JSON->PATH;
	if(sys == nil || bufio == nil || str == nil || dial == nil || json == nil)
		return "masto: failed to load a dependency";
	json->init(bufio);
	return nil;
}

client(host, token: string): ref Client
{
	return ref Client(host, token);
}

#
# Transport
#

api(c: ref Client, method, path: string,
    query: list of (string, string), jbody: ref JValue): ref Resp
{
	q := "";
	for(l := query; l != nil; l = tl l){
		(k, v) := hd l;
		if(q == "")
			q = "?";
		else
			q += "&";
		q += urlencode(k) + "=" + urlencode(v);
	}

	bodybytes: array of byte = nil;
	if(jbody != nil)
		bodybytes = array of byte jbody.text();

	addr := "tcp!" + c.host + "!443";
	(conn, ctlfd, derr) := dial->dialtls(addr, nil, c.host);
	if(conn == nil)
		return ref Resp(-1, nil, "", "dialtls " + addr + ": " + derr);
	# ctlfd must stay open for the connection's life; we drain the body fully
	# below before returning, so keeping it in scope here is sufficient.
	fd := conn.dfd;

	req := method + " " + path + q + " HTTP/1.1\r\n" +
		"Host: " + c.host + "\r\n" +
		"User-Agent: pleromussy/0.1 (Inferno)\r\n" +
		"Accept: application/json\r\n";
	if(c.token != "")
		req += "Authorization: Bearer " + c.token + "\r\n";
	if(bodybytes != nil)
		req += "Content-Type: application/json\r\n" +
			"Content-Length: " + string len bodybytes + "\r\n";
	req += "Connection: close\r\n\r\n";

	rb := array of byte req;
	if(sys->write(fd, rb, len rb) != len rb)
		return ref Resp(-1, nil, "", sys->sprint("write request: %r"));
	if(bodybytes != nil)
		sys->write(fd, bodybytes, len bodybytes);

	b := bufio->fopen(fd, Bufio->OREAD);
	if(b == nil)
		return ref Resp(-1, nil, "", "fopen response");

	code := parsestatus(b.gets('\n'));
	if(code < 0)
		return ref Resp(-1, nil, "", "bad/empty status line");

	clen := -1;
	chunked := 0;
	next := "";
	for(;;){
		h := trimcrlf(b.gets('\n'));
		if(h == "")
			break;			# blank line (or EOF): end of headers
		(key, val) := splitheader(h);
		case str->tolower(key) {
		"content-length" =>
			clen = int val;
		"transfer-encoding" =>
			if(strindex(str->tolower(val), "chunked") >= 0)
				chunked = 1;
		"link" =>
			next = parselink(val);
		}
	}

	body: array of byte;
	if(chunked)
		body = readchunked(b);
	else if(clen >= 0)
		body = readn(b, clen);
	else
		body = readall(b);

	# touch ctlfd so it provably outlives the read (silences "unused")
	if(ctlfd == nil)
		{}
	return ref Resp(code, bufio->aopen(body), next, "");
}

#
# Verbs
#

instance(c: ref Client): (ref JValue, string)
{
	r := api(c, "GET", "/api/v1/instance", nil, nil);
	if(r.err != "")
		return (nil, r.err);
	if(r.code != 200)
		return (nil, sys->sprint("http %d", r.code));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "json: " + jerr);
	return (jv, nil);
}

verifycredentials(c: ref Client): (ref Account, string)
{
	r := api(c, "GET", "/api/v1/accounts/verify_credentials", nil, nil);
	if(r.err != "")
		return (nil, r.err);
	if(r.code != 200)
		return (nil, apierr("verify_credentials", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "json: " + jerr);
	a := mkaccount(jv);
	if(a == nil)
		return (nil, "verify_credentials: not an account object");
	return (a, nil);
}

registerapp(c: ref Client, name: string): (string, string, string)
{
	body := json->jvobject(
		("client_name", json->jvstring(name)) ::
		("redirect_uris", json->jvstring("urn:ietf:wg:oauth:2.0:oob")) ::
		("scopes", json->jvstring("read write follow")) :: nil);
	r := api(c, "POST", "/api/v1/apps", nil, body);
	if(r.err != "")
		return ("", "", r.err);
	if(r.code != 200)
		return ("", "", apierr("register app", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return ("", "", "json: " + jerr);
	return (jstr(jv, "client_id"), jstr(jv, "client_secret"), nil);
}

passwordlogin(c: ref Client, client_id, client_secret, user, pass, scope: string): (string, string)
{
	if(scope == "")
		scope = "read write follow";
	body := json->jvobject(
		("grant_type", json->jvstring("password")) ::
		("client_id", json->jvstring(client_id)) ::
		("client_secret", json->jvstring(client_secret)) ::
		("username", json->jvstring(user)) ::
		("password", json->jvstring(pass)) ::
		("scope", json->jvstring(scope)) :: nil);
	r := api(c, "POST", "/oauth/token", nil, body);
	if(r.err != "")
		return ("", r.err);
	if(r.code != 200)
		return ("", apierr("login", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return ("", "json: " + jerr);
	return (jstr(jv, "access_token"), nil);
}

login(c: ref Client, user, pass, scope: string): (ref Session, string)
{
	(cid, csec, e1) := registerapp(c, "pleromussy");
	if(e1 != nil)
		return (nil, e1);
	(tok, e2) := passwordlogin(c, cid, csec, user, pass, scope);
	if(e2 != nil)
		return (nil, e2);
	return (ref Session(c.host, tok, cid, csec), nil);
}

#
# Token persistence: $home/lib/pleromussy/<host>.json
#

sessiondir(): string
{
	return "/usr/" + getuser() + "/lib/pleromussy";
}

sessionpath(host: string): string
{
	return sessiondir() + "/" + host + ".json";
}

loadsession(host: string): ref Session
{
	fd := sys->open(sessionpath(host), Sys->OREAD);
	if(fd == nil)
		return nil;
	b := bufio->fopen(fd, Bufio->OREAD);
	if(b == nil)
		return nil;
	(jv, nil) := json->readjson(b);
	if(jv == nil || !jv.isobject())
		return nil;
	tok := jstr(jv, "access_token");
	if(tok == "")
		return nil;
	return ref Session(host, tok, jstr(jv, "client_id"), jstr(jv, "client_secret"));
}

savesession(s: ref Session): string
{
	if(s == nil)
		return "nil session";
	mkdirp(sessiondir());
	path := sessionpath(s.host);
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("create %s: %r", path);
	jv := json->jvobject(
		("access_token", json->jvstring(s.token)) ::
		("client_id", json->jvstring(s.client_id)) ::
		("client_secret", json->jvstring(s.client_secret)) :: nil);
	txt := array of byte jv.text();
	if(sys->write(fd, txt, len txt) != len txt)
		return sys->sprint("write %s: %r", path);
	return "";
}

getuser(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return "none";
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "none";
	return string buf[0:n];
}

# create each component of an absolute path as a directory if it's missing
mkdirp(path: string)
{
	(nil, elems) := sys->tokenize(path, "/");
	cur := "";
	for(; elems != nil; elems = tl elems){
		cur += "/" + hd elems;
		(ok, nil) := sys->stat(cur);
		if(ok < 0){
			fd := sys->create(cur, Sys->OREAD, Sys->DMDIR | 8r700);
			if(fd == nil)
				return;
		}
	}
}

publictimeline(c: ref Client, max_id: string, limit: int): (list of ref Status, string, string)
{
	return timeline(c, "/api/v1/timelines/public", max_id, limit);
}

hometimeline(c: ref Client, max_id: string, limit: int): (list of ref Status, string, string)
{
	return timeline(c, "/api/v1/timelines/home", max_id, limit);
}

poststatus(c: ref Client, text, visibility, in_reply_to_id, spoiler: string): (ref Status, string)
{
	fields := ("status", json->jvstring(text)) :: nil;
	if(visibility != "")
		fields = ("visibility", json->jvstring(visibility)) :: fields;
	if(in_reply_to_id != "")
		fields = ("in_reply_to_id", json->jvstring(in_reply_to_id)) :: fields;
	if(spoiler != "")
		fields = ("spoiler_text", json->jvstring(spoiler)) :: fields;
	r := api(c, "POST", "/api/v1/statuses", nil, json->jvobject(fields));
	if(r.err != "")
		return (nil, r.err);
	if(r.code != 200)
		return (nil, apierr("post", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "json: " + jerr);
	return (mkstatus(jv), nil);
}

statusaction(c: ref Client, id, action: string): (ref Status, string)
{
	r := api(c, "POST", "/api/v1/statuses/" + id + "/" + action, nil, nil);
	if(r.err != "")
		return (nil, r.err);
	if(r.code != 200)
		return (nil, apierr(action, r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "json: " + jerr);
	return (mkstatus(jv), nil);
}

notifications(c: ref Client, max_id: string, limit: int): (list of ref Notification, string, string)
{
	q: list of (string, string);
	if(limit > 0)
		q = ("limit", string limit) :: q;
	if(max_id != "")
		q = ("max_id", max_id) :: q;
	r := api(c, "GET", "/api/v1/notifications", q, nil);
	if(r.err != "")
		return (nil, "", r.err);
	if(r.code != 200)
		return (nil, "", apierr("notifications", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "", "json: " + jerr);
	ns: list of ref Notification;
	pick x := jv {
	Array =>
		for(i := len x.a - 1; i >= 0; i--){
			n := mknotification(x.a[i]);
			if(n != nil)
				ns = n :: ns;
		}
	* =>
		return (nil, "", "expected a JSON array");
	}
	return (ns, r.next, nil);
}

getstatus(c: ref Client, id: string): (ref Status, string)
{
	r := api(c, "GET", "/api/v1/statuses/" + id, nil, nil);
	if(r.err != "")
		return (nil, r.err);
	if(r.code != 200)
		return (nil, apierr("status", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "json: " + jerr);
	return (mkstatus(jv), nil);
}

statuscontext(c: ref Client, id: string): (list of ref Status, list of ref Status, string)
{
	r := api(c, "GET", "/api/v1/statuses/" + id + "/context", nil, nil);
	if(r.err != "")
		return (nil, nil, r.err);
	if(r.code != 200)
		return (nil, nil, apierr("context", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, nil, "json: " + jerr);
	if(!jv.isobject())
		return (nil, nil, "expected a JSON object");
	return (statusarray(jget(jv, "ancestors")), statusarray(jget(jv, "descendants")), nil);
}

getaccount(c: ref Client, id: string): (ref Account, string)
{
	r := api(c, "GET", "/api/v1/accounts/" + id, nil, nil);
	if(r.err != "")
		return (nil, r.err);
	if(r.code != 200)
		return (nil, apierr("account", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "json: " + jerr);
	return (mkaccount(jv), nil);
}

accountstatuses(c: ref Client, id, max_id: string, limit: int): (list of ref Status, string, string)
{
	return timeline(c, "/api/v1/accounts/" + id + "/statuses", max_id, limit);
}

#
# Pleroma emoji reactions (extension verbs)
#

statusreactions(c: ref Client, id: string): (list of ref Reaction, string)
{
	r := api(c, "GET", "/api/v1/pleroma/statuses/" + id + "/reactions", nil, nil);
	if(r.err != "")
		return (nil, r.err);
	if(r.code != 200)
		return (nil, apierr("reactions", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "json: " + jerr);
	return (reactionarray(jv), nil);
}

react(c: ref Client, id, emoji: string): (ref Status, string)
{
	return reactverb(c, "PUT", id, emoji);
}

unreact(c: ref Client, id, emoji: string): (ref Status, string)
{
	return reactverb(c, "DELETE", id, emoji);
}

# PUT/DELETE /api/v1/pleroma/statuses/<id>/reactions/<emoji>; both return the
# updated Status.  The emoji travels in the path, so url-encode it.
reactverb(c: ref Client, method, id, emoji: string): (ref Status, string)
{
	path := "/api/v1/pleroma/statuses/" + id + "/reactions/" + urlencode(emoji);
	r := api(c, method, path, nil, nil);
	if(r.err != "")
		return (nil, r.err);
	if(r.code != 200)
		return (nil, apierr("react", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "json: " + jerr);
	return (mkstatus(jv), nil);
}

#
# Generic URL fetch (media/avatars) — no auth, follows redirects.
#

MAXREDIR: con 4;
MAXBYTES: con 25*1024*1024;	# refuse media larger than this (OOM guard)

# Fetch a URL with a soft retry: networks drop, TLS handshakes flake, and a body
# can stop mid-stream (now a "short read" error, see httpfetch).  Re-fetch the
# whole thing a few times with a short backoff before giving up.  Permanent
# failures (a real 4xx, an oversize body, a bad URL) are not retried.
FETCHTRIES: con 3;

fetchurl(url: string): (array of byte, string)
{
	err := "";
	for(try := 0; ; try++){
		(body, e) := fetchonce(url);
		if(e == nil)
			return (body, nil);
		err = e;
		if(try >= FETCHTRIES - 1 || !retryable(e))
			break;
		sys->sleep(250 * (try + 1));	# 250ms, then 500ms
	}
	return (nil, err);
}

# is this fetch error worth retrying?  Transient = network/TLS/short read;
# a definite HTTP 4xx, an oversize body, a redirect loop, or a malformed URL
# won't get better on a retry.
retryable(err: string): int
{
	permanent := array[] of {"http 4", "too large", "too many redirects", "bad url"};
	for(i := 0; i < len permanent; i++)
		if(strindex(err, permanent[i]) >= 0)
			return 0;
	return 1;
}

fetchonce(url: string): (array of byte, string)
{
	for(redir := 0; redir < MAXREDIR; redir++){
		(scheme, host, port, path, perr) := parseurl(url);
		if(perr != nil)
			return (nil, perr);
		addr := "tcp!" + host + "!" + port;
		fd: ref Sys->FD;
		ctlfd: ref Sys->FD;
		if(scheme == "https"){
			(conn, cf, derr) := dial->dialtls(addr, nil, host);
			if(conn == nil)
				return (nil, "dialtls " + addr + ": " + derr);
			fd = conn.dfd;
			ctlfd = cf;
		} else {
			conn := dial->dial(addr, nil);
			if(conn == nil)
				return (nil, sys->sprint("dial %s: %r", addr));
			fd = conn.dfd;
		}
		(code, loc, body, herr) := httpfetch(fd, host, path);
		if(ctlfd == nil)
			{}			# keep ctlfd alive across the read
		if(herr != nil)
			return (nil, herr);
		if(code >= 200 && code < 300)
			return (body, nil);
		if((code==301||code==302||code==303||code==307||code==308) && loc != ""){
			url = resolveloc(scheme, host, port, loc);
			continue;
		}
		return (nil, sys->sprint("http %d", code));
	}
	return (nil, "too many redirects");
}

# one GET; returns (status code, Location header, body, error).  Enforces the
# MAXBYTES cap so a huge response (e.g. a video) can't exhaust memory.
httpfetch(fd: ref Sys->FD, host, path: string): (int, string, array of byte, string)
{
	req := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + host + "\r\n" +
		"User-Agent: pleromussy/0.1 (Inferno)\r\n" +
		"Accept: */*\r\n" +
		"Connection: close\r\n\r\n";
	rb := array of byte req;
	if(sys->write(fd, rb, len rb) != len rb)
		return (-1, "", nil, "write request failed");
	b := bufio->fopen(fd, Bufio->OREAD);
	if(b == nil)
		return (-1, "", nil, "fopen response");
	code := parsestatus(b.gets('\n'));
	if(code < 0)
		return (-1, "", nil, "bad/empty status line");
	clen := -1;
	chunked := 0;
	loc := "";
	for(;;){
		h := trimcrlf(b.gets('\n'));
		if(h == "")
			break;
		(key, val) := splitheader(h);
		case str->tolower(key) {
		"content-length" =>	clen = int val;
		"transfer-encoding" =>	if(strindex(str->tolower(val), "chunked") >= 0) chunked = 1;
		"location" =>		loc = val;
		}
	}
	if(clen > MAXBYTES)
		return (code, loc, nil, sys->sprint("too large (%d bytes)", clen));
	body: array of byte;
	if(chunked)
		body = readchunked(b);
	else if(clen >= 0){
		body = readn(b, clen);
		# a connection dropped mid-body leaves a short read; report it as an
		# error (don't hand back a truncated image as success) so the caller
		# can retry.  readn returns buf[0:got] on a short read, no error.
		if(len body < clen)
			return (code, loc, nil,
				sys->sprint("short read: %d of %d bytes", len body, clen));
	} else
		body = readcapped(b, MAXBYTES);
	if(len body > MAXBYTES)
		return (code, loc, nil, "too large");
	return (code, loc, body, nil);
}

# split "scheme://host[:port]/path" into parts; defaults https/443 (http/80)
parseurl(url: string): (string, string, string, string, string)
{
	scheme := "https";
	rest := url;
	i := strindex(url, "://");
	if(i >= 0){
		scheme = str->tolower(url[0:i]);
		rest = url[i+3:];
	}
	path := "/";
	hostport := rest;
	j := strindex(rest, "/");
	if(j >= 0){
		hostport = rest[0:j];
		path = rest[j:];
	}
	host := hostport;
	port := "443";
	if(scheme == "http")
		port = "80";
	k := strindex(hostport, ":");
	if(k >= 0){
		host = hostport[0:k];
		port = hostport[k+1:];
	}
	if(host == "")
		return ("", "", "", "", "bad url: " + url);
	return (scheme, host, port, path, nil);
}

# resolve a redirect target against the current origin
resolveloc(scheme, host, port, loc: string): string
{
	if(strindex(loc, "://") >= 0)
		return loc;
	origin := scheme + "://" + host;
	if((scheme == "https" && port != "443") || (scheme == "http" && port != "80"))
		origin += ":" + port;
	if(len loc > 0 && loc[0] == '/')
		return origin + loc;
	return origin + "/" + loc;
}

timeline(c: ref Client, path, max_id: string, limit: int): (list of ref Status, string, string)
{
	q: list of (string, string);
	if(limit > 0)
		q = ("limit", string limit) :: q;
	if(max_id != "")
		q = ("max_id", max_id) :: q;
	r := api(c, "GET", path, q, nil);
	if(r.err != "")
		return (nil, "", r.err);
	if(r.code != 200)
		return (nil, "", apierr("timeline", r));
	(jv, jerr) := json->readjson(r.body);
	if(jv == nil)
		return (nil, "", "json: " + jerr);

	statuses: list of ref Status;
	pick x := jv {
	Array =>
		for(i := len x.a - 1; i >= 0; i--){
			s := mkstatus(x.a[i]);
			if(s != nil)
				statuses = s :: statuses;
		}
	* =>
		return (nil, "", "expected a JSON array");
	}
	return (statuses, r.next, nil);
}

# format an HTTP error, folding in the body's {"error": ...} when present
apierr(what: string, r: ref Resp): string
{
	msg := "";
	if(r.body != nil){
		(jv, nil) := json->readjson(r.body);
		if(jv != nil)
			msg = jstr(jv, "error");
	}
	if(msg != "")
		return sys->sprint("%s: http %d: %s", what, r.code, msg);
	return sys->sprint("%s: http %d", what, r.code);
}

#
# JSON -> ADT parsers
#

# parse a JSON array of status objects, preserving server order
statusarray(jv: ref JValue): list of ref Status
{
	out: list of ref Status;
	pick x := jv {
	Array =>
		for(i := len x.a - 1; i >= 0; i--){
			s := mkstatus(x.a[i]);
			if(s != nil)
				out = s :: out;
		}
	}
	return out;
}

mknotification(jv: ref JValue): ref Notification
{
	if(jv == nil || !jv.isobject())
		return nil;
	st: ref Status;
	s := jget(jv, "status");
	if(s != nil && s.isobject())
		st = mkstatus(s);
	return ref Notification(
		jstr(jv, "id"), jstr(jv, "type"), jstr(jv, "created_at"),
		mkaccount(jget(jv, "account")), st);
}

mkaccount(jv: ref JValue): ref Account
{
	if(jv == nil || !jv.isobject())
		return nil;
	return ref Account(
		jstr(jv, "id"), jstr(jv, "acct"), jstr(jv, "username"),
		jstr(jv, "display_name"), jstr(jv, "avatar"), jstr(jv, "note"),
		jstr(jv, "url"), jbool(jv, "bot"), jbool(jv, "locked"));
}

mkstatus(jv: ref JValue): ref Status
{
	if(jv == nil || !jv.isobject())
		return nil;
	acct := mkaccount(jget(jv, "account"));
	reblog: ref Status;
	rb := jget(jv, "reblog");
	if(rb != nil && rb.isobject())
		reblog = mkstatus(rb);
	return ref Status(
		jstr(jv, "id"), jstr(jv, "created_at"), jstr(jv, "content"),
		jstr(jv, "spoiler_text"), jstr(jv, "visibility"), jstr(jv, "uri"),
		jstr(jv, "url"), acct, reblog,
		jbool(jv, "favourited"), jbool(jv, "reblogged"), jbool(jv, "bookmarked"),
		jint(jv, "favourites_count"), jint(jv, "reblogs_count"),
		jint(jv, "replies_count"), parsemedia(jget(jv, "media_attachments")),
		reactionarray(jget(jget(jv, "pleroma"), "emoji_reactions")));
}

# parse a JSON array of Pleroma reaction objects ({name,count,me,...}),
# preserving server order; tolerates nil/missing (vanilla Mastodon)
reactionarray(jv: ref JValue): list of ref Reaction
{
	out: list of ref Reaction;
	pick x := jv {
	Array =>
		for(i := len x.a - 1; i >= 0; i--){
			rx := mkreaction(x.a[i]);
			if(rx != nil)
				out = rx :: out;
		}
	}
	return out;
}

mkreaction(jv: ref JValue): ref Reaction
{
	if(jv == nil || !jv.isobject())
		return nil;
	return ref Reaction(jstr(jv, "name"), jint(jv, "count"), jbool(jv, "me"));
}

parsemedia(jv: ref JValue): list of ref Attachment
{
	if(jv == nil)
		return nil;
	res: list of ref Attachment;
	pick x := jv {
	Array =>
		for(i := len x.a - 1; i >= 0; i--){
			m := x.a[i];
			if(m != nil && m.isobject())
				res = ref Attachment(jstr(m, "id"), jstr(m, "type"),
					jstr(m, "url"), jstr(m, "preview_url"),
					jstr(m, "description")) :: res;
		}
	}
	return res;
}

#
# JValue accessors that tolerate missing/null/wrong-typed fields
#

jget(jv: ref JValue, k: string): ref JValue
{
	if(jv == nil || !jv.isobject())
		return nil;
	return jv.get(k);
}

jstr(jv: ref JValue, k: string): string
{
	v := jget(jv, k);
	if(v == nil)
		return "";
	pick x := v {
	String =>
		return x.s;
	}
	return "";
}

jint(jv: ref JValue, k: string): int
{
	v := jget(jv, k);
	if(v == nil)
		return 0;
	pick x := v {
	Int =>
		return int x.value;
	Real =>
		return int x.value;
	}
	return 0;
}

jbool(jv: ref JValue, k: string): int
{
	v := jget(jv, k);
	if(v == nil)
		return 0;
	pick x := v {
	True =>
		return 1;
	}
	return 0;
}

#
# HTTP helpers
#

parsestatus(line: string): int
{
	(n, toks) := sys->tokenize(line, " \t\r\n");
	if(n < 2)
		return -1;
	return int hd tl toks;
}

splitheader(h: string): (string, string)
{
	(k, rest) := str->splitl(h, ":");
	v := "";
	if(rest != "")
		v = str->drop(rest[1:], " \t");
	return (k, v);
}

# extract the max_id parameter of the rel="next" link in an RFC 5988 Link header
parselink(v: string): string
{
	(nil, parts) := sys->tokenize(v, ",");
	for(l := parts; l != nil; l = tl l){
		p := hd l;
		if(strindex(p, "rel=\"next\"") < 0)
			continue;
		i := strindex(p, "max_id=");
		if(i < 0)
			return "";
		rest := p[i + len "max_id=":];
		j := 0;
		while(j < len rest){
			c := rest[j];
			if(c == '&' || c == '>' || c == '"' || c == ' ' || c == ';')
				break;
			j++;
		}
		return rest[0:j];
	}
	return "";
}

readn(b: ref Iobuf, n: int): array of byte
{
	if(n <= 0)
		return array[0] of byte;
	buf := array[n] of byte;
	got := 0;
	while(got < n){
		m := b.read(buf[got:], n - got);
		if(m <= 0)
			break;
		got += m;
	}
	if(got < n)
		return buf[0:got];
	return buf;
}

readall(b: ref Iobuf): array of byte
{
	return readcapped(b, MAXBYTES);
}

# read to EOF, stopping once cap bytes are accumulated.  Collects fixed-size
# chunks in a list and joins once (no O(n^2) repeated reallocation).
readcapped(b: ref Iobuf, cap: int): array of byte
{
	chunks: list of array of byte;
	total := 0;
	for(;;){
		tmp := array[16*1024] of byte;
		m := b.read(tmp, len tmp);
		if(m <= 0)
			break;
		chunks = tmp[0:m] :: chunks;
		total += m;
		if(total >= cap)
			break;
	}
	out := array[total] of byte;
	o := total;
	for(; chunks != nil; chunks = tl chunks){
		c := hd chunks;
		o -= len c;
		out[o:] = c;
	}
	return out;
}

readchunked(b: ref Iobuf): array of byte
{
	out := array[0] of byte;
	for(;;){
		(sz, nil) := str->splitl(trimcrlf(b.gets('\n')), ";");
		n := hextoint(sz);
		if(n <= 0)
			break;
		out = concat(out, readn(b, n));
		b.gets('\n');			# trailing CRLF after chunk data
		if(len out > MAXBYTES)
			break;
	}
	return out;
}

concat(a, b: array of byte): array of byte
{
	o := array[len a + len b] of byte;
	o[0:] = a;
	o[len a:] = b;
	return o;
}

trimcrlf(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

strindex(s, sub: string): int
{
	n := len s;
	m := len sub;
	if(m == 0)
		return 0;
	for(i := 0; i + m <= n; i++)
		if(s[i:i + m] == sub)
			return i;
	return -1;
}

hextoint(s: string): int
{
	s = str->drop(s, " \t");
	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		d: int;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		else
			break;
		v = v * 16 + d;
	}
	return v;
}

urlencode(s: string): string
{
	b := array of byte s;
	out := "";
	for(i := 0; i < len b; i++){
		c := int b[i];
		if(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' ||
		   c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == '~')
			out[len out] = c;
		else
			out += sys->sprint("%%%.2X", c);
	}
	return out;
}
