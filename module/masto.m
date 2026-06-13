# Masto: a Mastodon/Pleroma client-API library for Inferno.
#
# Pure-Limbo HTTP/JSON client for the Mastodon client API and its Pleroma
# extensions (see docs/ref/pleroma.api.md).  It owns transport (TLS via
# Dial->dialtls over the #T devtls device) and entity parsing; it has no GUI
# dependency, so it can be exercised headless from a cmd harness.
#
# Includers must first include "bufio.m" and "json.m" — this interface names
# Bufio->Iobuf and JSON->JValue.

Masto: module
{
	PATH:	con "/dis/lib/masto.dis";

	# A session against one instance.  token is the OAuth bearer token, or ""
	# for anonymous (public) access.
	Client: adt {
		host:	string;		# bare hostname, e.g. "nicecrew.digital"
		token:	string;		# bearer access token; "" = anonymous
	};

	# A persisted login: the bearer token plus the OAuth app credentials it was
	# minted against (kept so the token can be re-issued without re-registering).
	# Stored as JSON at $home/lib/pleromussy/<host>.json.
	Session: adt {
		host:		string;
		token:		string;
		client_id:	string;
		client_secret:	string;
	};

	Account: adt {
		id:		string;		# opaque FlakeID — never parse to int
		acct:		string;		# user@host (or bare user if local)
		username:	string;
		display_name:	string;
		avatar:		string;		# URL
		note:		string;		# HTML bio
		url:		string;
		bot:		int;
		locked:		int;
	};

	Attachment: adt {
		id:		string;
		atype:		string;		# "image"/"video"/"gifv"/"audio"/...
		url:		string;
		preview_url:	string;
		description:	string;
	};

	# A Pleroma emoji reaction aggregated over a status: the emoji, how many
	# accounts reacted with it, and whether the authenticated user is one of
	# them.  name is a unicode emoji (e.g. "🔥") or a :shortcode: for a custom
	# emoji.  (Pleroma extension; absent on vanilla Mastodon servers.)
	Reaction: adt {
		name:	string;
		count:	int;
		me:	int;
	};

	# A notification: someone mentioned/boosted/favourited you, followed you,
	# etc.  status is the related status (nil for plain follows).
	Notification: adt {
		id:		string;
		ntype:		string;		# "mention"/"reblog"/"favourite"/"follow"/"follow_request"/"poll"/"update"
		created_at:	string;
		account:	ref Account;	# who triggered it
		status:		ref Status;	# related status; nil for follows
	};

	Status: adt {
		id:		string;
		created_at:	string;
		content:	string;		# HTML
		spoiler_text:	string;
		visibility:	string;
		uri:		string;
		url:		string;
		account:	ref Account;
		reblog:		cyclic ref Status;	# boost target, nil if not a boost
		favourited:	int;
		reblogged:	int;
		bookmarked:	int;
		favourites_count:	int;
		reblogs_count:	int;
		replies_count:	int;
		media:		list of ref Attachment;
		reactions:	list of ref Reaction;	# Pleroma emoji reactions (nil if none/unsupported)
	};

	# Result of one raw HTTP request.  body is the full response body wrapped
	# in an in-memory Iobuf (the socket is already drained and closed), so the
	# caller may read it at leisure.  next is the max_id parsed from a
	# rel="next" Link: header ("" if none).  On transport failure code is -1
	# and err is set.
	Resp: adt {
		code:	int;
		body:	ref Bufio->Iobuf;
		next:	string;
		err:	string;
	};

	# Load dependencies; returns nil on success or an error string.
	init:	fn(): string;

	client:	fn(host, token: string): ref Client;

	# Low-level: perform one request.  method is "GET"/"POST"/...; path is the
	# absolute path (no host).  query is a list of (key,value) pairs, url-encoded
	# here.  jbody, if non-nil, is serialized as JSON (ctype defaults to
	# application/json); pass formbody/ctype for urlencoded OAuth bodies.
	api:	fn(c: ref Client, method, path: string,
		   query: list of (string, string),
		   jbody: ref JSON->JValue): ref Resp;

	# OAuth.  registerapp POSTs /api/v1/apps, returning (client_id,
	# client_secret, err).  passwordlogin runs the resource-owner password
	# grant against /oauth/token, returning (access_token, err).  scope ""
	# defaults to "read write follow".
	registerapp:	fn(c: ref Client, name: string): (string, string, string);
	passwordlogin:	fn(c: ref Client, client_id, client_secret, user, pass, scope: string): (string, string);

	# login is registerapp + passwordlogin in one step, returning a populated
	# Session ready to hand to savesession.  scope "" defaults as above.
	login:		fn(c: ref Client, user, pass, scope: string): (ref Session, string);

	# Token persistence under $home/lib/pleromussy/<host>.json.  loadsession
	# returns nil if absent/empty; savesession returns "" on success else an
	# error string (it creates the directory, mode 0600 on the file).
	sessionpath:	fn(host: string): string;
	loadsession:	fn(host: string): ref Session;
	savesession:	fn(s: ref Session): string;

	# Verbs (Milestone 1).
	# instance returns the parsed /api/v1/instance object.
	instance:	fn(c: ref Client): (ref JSON->JValue, string);
	# verifycredentials returns the authenticated account (GET
	# /api/v1/accounts/verify_credentials); err is set if not logged in.
	verifycredentials:	fn(c: ref Client): (ref Account, string);
	# publictimeline / hometimeline return (statuses, next_max_id, err).
	publictimeline:	fn(c: ref Client, max_id: string, limit: int): (list of ref Status, string, string);
	hometimeline:	fn(c: ref Client, max_id: string, limit: int): (list of ref Status, string, string);

	# Posting and interactions (all require a token).
	# poststatus creates a status; visibility "" lets the server default,
	# in_reply_to_id/spoiler "" omit them.  Returns the created Status.
	poststatus:	fn(c: ref Client, text, visibility, in_reply_to_id, spoiler: string): (ref Status, string);
	# statusaction POSTs /api/v1/statuses/<id>/<action> where action is one of
	# favourite, unfavourite, reblog, unreblog, bookmark, unbookmark; it returns
	# the updated Status (authoritative favourited/reblogged/counts).
	statusaction:	fn(c: ref Client, id, action: string): (ref Status, string);

	# notifications returns (notifications, next_max_id, err) — the
	# authenticated account's notification feed (GET /api/v1/notifications).
	notifications:	fn(c: ref Client, max_id: string, limit: int): (list of ref Notification, string, string);

	# getstatus fetches a single status by id (GET /api/v1/statuses/<id>).
	getstatus:	fn(c: ref Client, id: string): (ref Status, string);

	# statuscontext returns (ancestors, descendants, err) for a status' thread
	# (GET /api/v1/statuses/<id>/context).  ancestors are root-first; descendants
	# are the reply subtree, server-ordered.
	statuscontext:	fn(c: ref Client, id: string): (list of ref Status, list of ref Status, string);

	# getaccount fetches an account by id (GET /api/v1/accounts/<id>);
	# accountstatuses returns that account's posts as a timeline page.
	getaccount:	fn(c: ref Client, id: string): (ref Account, string);
	accountstatuses:	fn(c: ref Client, id, max_id: string, limit: int): (list of ref Status, string, string);

	# Pleroma emoji reactions (extension; require a token).
	# statusreactions lists the aggregated reactions on a status (GET
	# /api/v1/pleroma/statuses/<id>/reactions).  react adds the authenticated
	# user's reaction with emoji (PUT .../reactions/<emoji>); unreact removes it
	# (DELETE .../reactions/<emoji>).  emoji is a unicode emoji or a bare custom
	# shortcode (no surrounding colons).  Both return the updated Status.
	statusreactions:	fn(c: ref Client, id: string): (list of ref Reaction, string);
	react:		fn(c: ref Client, id, emoji: string): (ref Status, string);
	unreact:	fn(c: ref Client, id, emoji: string): (ref Status, string);

	# fetchurl GETs an arbitrary http/https URL (media, avatars) with no auth,
	# following up to a few redirects, and returns the raw body bytes.  For
	# images, hand the bytes to $Imageio/Imageload.  err is set on failure.
	fetchurl:	fn(url: string): (array of byte, string);

	# Parsers (exposed for reuse/testing).
	mkaccount:	fn(jv: ref JSON->JValue): ref Account;
	mkstatus:	fn(jv: ref JSON->JValue): ref Status;
	mknotification:	fn(jv: ref JSON->JValue): ref Notification;
	mkreaction:	fn(jv: ref JSON->JValue): ref Reaction;
};
