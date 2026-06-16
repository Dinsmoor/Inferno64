implement Pleromussy;

#
# wm/pleromussy — an Inferno Fediverse (Pleroma/Mastodon-API) client.
# Milestone 1: render a public/home timeline in a Tk text widget.
# API client lives in lib/masto (module/masto.m); this file owns only the GUI.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Rect, Point, Image, Display: import draw;

include "bufio.m";			# for masto.m's Bufio->Iobuf reference

include "json.m";			# for masto.m's JSON->JValue reference

include "imageio.m";
	imageio: Imageio;

include "tk.m";
	tk: Tk;

include "tkclient.m";
	tkclient: Tkclient;

include "popup.m";
	popup: Popup;

include "string.m";
	str: String;

include "plumbmsg.m";
	plumbmsg: Plumbmsg;
	Msg: import plumbmsg;

include "masto.m";
	masto: Masto;
	Status, Account, Attachment, Notification, Client, Session: import masto;

Pleromussy: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# generic command entry point, for launching ndb/cs when no one else has
Command: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# result of one async timeline fetch, delivered to the event loop
Result: adt {
	sts:	list of ref Status;
	next:	string;
	err:	string;
	app:	int;		# 1 = append (a "more" page), 0 = replace
};

# result of an async notifications fetch
NResult: adt {
	ns:	list of ref Notification;
	next:	string;
	err:	string;
	app:	int;
};

# result of an async thread (status context) fetch
TResult: adt {
	arr:	array of ref Status;	# ancestors + focused + descendants
	focus:	int;			# index of the focused status in arr
	err:	string;
	gen:	int;			# navigation generation it was issued under
};

# result of an async profile fetch (account + its statuses)
PResult: adt {
	acc:	ref Account;
	arr:	array of ref Status;
	next:	string;
	err:	string;
	app:	int;
	gen:	int;			# navigation generation it was issued under
};

# a restorable snapshot of one view, for the Back history.  We snapshot the
# whole backing state so Back can restore without re-fetching from the server.
Snap: adt {
	curview:	string;
	view:		string;
	statuses:	list of ref Status;
	notifs:		list of ref Notification;
	threadarr:	array of ref Status;
	threadfocus:	int;
	profacc:	ref Account;
	profarr:	list of ref Status;
	nextid:		string;
	selected:	int;
};

ctxt:	ref Draw->Context;	# the draw context, for spawning child windows
window: ref Tk->Toplevel;
client: ref Client;
host:	string;			# current instance hostname (the host we dial)
acctlabel: string;		# active account label = host or user@host (session key)
view:	string;			# "public", "home" or "notifs"
me:	string;			# acct of the logged-in user, "" if anonymous
statuses: list of ref Status;	# accumulated timeline, newest first
statusarr: array of ref Status;	# flattened view, parallel to per-block s<i> tags
selected: int;			# index into statusarr, -1 = nothing selected
rowdepth: array of int;		# thread reply-depth per row (nil = flat view)

# which renderer owns the view right now, so post-action re-renders and Back
# target the right content instead of always snapping to the timeline
curview: string;		# "timeline" | "notifs" | "thread" | "profile"
notifs:	list of ref Notification;	# backing the notifs view, newest first
threadarr: array of ref Status;	# backing the thread view
threadfocus: int;		# index in threadarr of the focused status
profacc: ref Account;		# backing the profile view
profarr: list of ref Status;	# the profile's statuses, newest first
nextid:	string;			# max_id for the next page of the current view

# theme-derived colours, refreshed by loadthemecols() from the live system
# theme at start-up and on every theme push.  Used by mktags() (the .view.t
# text tags) and the inline reaction-chip / emoji-panel backgrounds, neither of
# which "theme reapply" can recolour.  The plain-text colours follow the
# palette; the chip/selection backgrounds stay fixed light tints (with dark
# text) so they read as raised affordances on any palette, including dark.
thINK: string;		# primary text (display names, post bodies)
thMUTED: string;	# meta / separators
thACCENT: string;	# links, media, the "load more" affordance
thCHIPFG: con "#182860";	# inline-button / reaction text
thCHIPBG: con "#eef0f2";	# reaction-chip background (others')
thCHIPMEBG: con "#cfe0ff";	# reaction-chip background (our own reactions)
thSELBG: con "#d7e6ff";		# selected-post highlight

# Back history: snapshots of prior views, most-recent-first.  Navigating to a
# new view pushes the current one; Back pops and restores it (no re-fetch).
history: list of ref Snap;

# navigation generation: bumped on every view change.  The thread/profile
# fetches (which *transition* into a new view, so can't be guarded by curview)
# carry the navgen they were issued under; a result whose gen != navgen is
# stale (the user navigated away while it was in flight) and is dropped.
navgen: int;

# async result channels, promoted to globals so inline-button and context-menu
# dispatch (which run outside init's alt) can kick off fetches/actions directly
results: chan of ref Result;
notifresults: chan of ref NResult;
threadresults: chan of ref TResult;
profresults: chan of ref PResult;
postresult: chan of ref Status;
actionresult: chan of (ref Status, string, ref Status);
reactresult: chan of (ref Status, ref Status, string);
pickresult: chan of (ref Status, string);
# account switcher: the chooser delivers the chosen label here ("" = cancel,
# "+add" = open the login dialog).  whoami carries verify_credentials results.
acctresult: chan of string;
whoami: chan of ref Account;
# the plumber delivers a clicked fediverse link here as (kind, id), kind 0 =
# status (open its thread), 1 = account (open its profile); the id is resolved
# off the event loop by plumbreader so the resolve fetch never blocks the UI.
plumbnav: chan of (int, string);

# Emoji-as-image.  No Inferno font covers the emoji blocks (lucidasans/unicode
# stops at U+FB1E), so each emoji in a reaction chip is drawn as a small inline
# image from the vendored twemoji PNGs.  `emojicache` memoises decoded images by
# twemoji file-name (a nil value is a cached "no asset" negative).  `emojiseq`
# only supplies unique panel names — the embedded panels are owned descendants of
# `.view.t`, so `.view.t delete` destroys them for us (don't destroy them again).
emojicache: list of (string, ref Image);
emojiseq: int;

# set once we've started our own ndb/cs, so the ~10 ensurecs callers don't race
# to spawn duplicates (see ensurecs)
csspawned: int;

# guards so a button can't open a second copy of a single-instance dialog
acctopen: int;		# the account chooser is open
loginopen: int;		# the login dialog is open

BODYFONT:	con "/fonts/lucidasans/unicode.8.font";
NAMEFONT:	con "/fonts/lucidasans/unicode.10.font";
METAFONT:	con "/fonts/lucidasans/unicode.7.font";

tkconfig := array[] of {
	"frame .top",
	# feeds + back on the left, actions on the right
	"button .top.home -text Home -command {send nav home}",
	"button .top.public -text Public -command {send nav public}",
	"button .top.notifs -text Notifs -command {send nav notifs}",
	"button .top.back -text {◂ Back} -command {send nav back}",
	"button .top.new -text {New post} -command {send nav compose}",
	"button .top.refresh -text Refresh -command {send nav refresh}",
	"button .top.accts -text Accounts -command {send nav accounts}",
	"pack .top.accts .top.refresh .top.new -side right",
	"pack .top.home .top.public .top.notifs .top.back -side left",
	"pack .top -fill x",
	"frame .view",
	"text .view.t -state disabled -width 0 -height 0 -wrap word"+
		" -yscrollcommand {.view.yscroll set} -padx 2 -pady 2",
	"bind .view.t <Button-1> {focus .view.t; send sel %x %y}",
	"bind .view.t <Double-Button-1> {send dsel %x %y}",
	"bind .view.t <Button-3> {send ctx %x %y}",
	# keyboard navigation of the timeline (no clicking required).  Inferno Tk's
	# bind grammar has no Up/Down keysyms; the arrows arrive as the private-use
	# runes Up=0xE012 / Down=0xE013 (see include/keyboard.h), as in wm/sh.
	"bind .view.t <Key-\uE012> {send key up}",	# Up arrow
	"bind .view.t <Key-\uE013> {send key down}",	# Down arrow
	"bind .view.t <Key-j> {send key down}",
	"bind .view.t <Key-k> {send key up}",
	"bind .view.t <Key-\n> {send key open}",
	"bind .view.t <Key-t> {send key open}",
	"bind .view.t <Key-f> {send key fav}",
	"bind .view.t <Key-b> {send key boost}",
	"bind .view.t <Key-r> {send key reply}",
	"bind .view.t <Key-u> {send key profile}",
	"bind .view.t <Key-g> {send key top}",
	"bind .view.t <Key-m> {send key more}",
	"scrollbar .view.yscroll -orient vertical -command {.view.t yview}",
	"pack .view.yscroll -fill y -side left",
	"pack .view.t -expand 1 -fill both",
	# bottom status bar: a short message on the left, the focused post URL
	# in a selectable (snarfable) entry filling the rest
	"frame .bot",
	"label .bot.msg -anchor w",
	"entry .bot.url",
	"bind .bot.url <Button-1> {.bot.url select 0 end; focus .bot.url}",
	"pack .bot.msg -side left -padx 4",
	"pack .bot.url -side left -fill x -expand 1 -padx 4 -pady 1",
	"pack .bot -side bottom -fill x",
	"pack .view -expand 1 -fill both",
	"pack propagate . 0",
	". configure -width 640 -height 660",
};

logincfg := array[] of {
	"label .hl -text {Instance:} -anchor w",
	"entry .host",
	"label .ul -text {Username:} -anchor w",
	"entry .user",
	"label .pl -text {Password:} -anchor w",
	"entry .pass -show *",
	"label .status -text { } -anchor w",
	"frame .b",
	"button .b.ok -text Login -command {send b login}",
	"button .b.cancel -text Cancel -command {send b cancel}",
	"button .b.oob -text {Browser login} -command {send b oob}",
	"pack .b.cancel .b.ok -side right",
	"pack .b.oob -side left",
	"bind .user <Key-\n> {focus .pass}",
	"bind .pass <Key-\n> {send b login}",
	"pack .hl .host .ul .user .pl .pass .status .b -fill x -side top -padx 4 -pady 2",
	"pack propagate . 0",
	". configure -width 320 -height 210",
};

composecfg := array[] of {
	"label .l -text {Compose} -anchor w",
	"frame .tf",
	"text .body -width 44 -height 7 -wrap word"+
		" -yscrollcommand {.tf.sb set}",
	"scrollbar .tf.sb -orient vertical -command {.body yview}",
	"pack .tf.sb -in .tf -side right -fill y",
	"pack .body -in .tf -side left -fill both -expand 1",
	"label .vl -text {Visibility (public/unlisted/private/direct):} -anchor w",
	"entry .vis",
	"label .status -text { } -anchor w",
	"frame .b",
	"button .b.post -text Post -command {send b post}",
	"button .b.cancel -text Cancel -command {send b cancel}",
	"pack .b.cancel .b.post -side right",
	"pack .l .tf .vl .vis .status .b -fill x -side top -padx 4 -pady 2",
	"pack propagate . 0",
	". configure -width 400 -height 280",
};

viewcfg := array[] of {
	"frame .top",
	"label .top.l -text {media} -anchor w -width 10",
	"button .top.save -text {Save} -command {send v save}",
	"pack .top.save -side right",
	"pack .top.l -side left -fill x -expand 1 -padx 4",
	"pack .top -fill x",
	"panel .p",
	"pack .p -side bottom -fill both -expand 1",
};

# cap the on-screen size of a media image; larger images are downscaled to fit
MAXIMGW:	con 900;
MAXIMGH:	con 700;

# vendored twemoji PNGs, and the on-screen pixel size of an inline emoji
EMOJIDIR:	con "/icons/emoji";
EMOJIPX:	con 16;

# deepest thread reply-indent level (deeper replies share the last margin)
MAXDEPTH:	con 6;

init(actxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	str = load String String->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	masto = load Masto Masto->PATH;
	imageio = load Imageio Imageio->PATH;	# optional: media viewing
	popup = load Popup Popup->PATH;		# optional: right-click context menus
	if(popup != nil)
		popup->init();
	if(tk == nil || tkclient == nil || masto == nil){
		sys->fprint(sys->fildes(2), "pleromussy: load failed: %r\n");
		raise "fail:load";
	}
	if((e := masto->init()) != nil){
		sys->fprint(sys->fildes(2), "pleromussy: masto init: %s\n", e);
		raise "fail:init";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	ctxt = actxt;
	selected = -1;

	host = "nicecrew.digital";
	acctlabel = "";
	view = "public";
	explicit := 0;			# a host/account was named on the command line
	pendingplumb := "";		# a link we were launched to open (from the plumber)
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-home" =>	view = "home";
		"-public" =>	view = "public";
		* =>
			arg := hd a;
			if(islink(arg)){
				pendingplumb = arg;
				if((h := hostfromlink(arg)) != ""){
					host = h;
					acctlabel = h;
					explicit = 1;
				}
			} else {
				host = arg;
				acctlabel = arg;
				explicit = 1;
			}
		}
	}

	# with no host named, open the first saved account (via the fedifs
	# namespace, so a fedilogin/ctl login shows up); else the default host.
	if(!explicit){
		accts := accounts();
		if(accts != nil)
			acctlabel = hd accts;
		else
			acctlabel = host;
	}
	host = hostfromlabel(acctlabel);

	sess := masto->loadsession(acctlabel);
	token := "";
	if(sess != nil)
		token = sess.token;
	client = masto->client(host, token);

	tkclient->init();
	winctl: chan of string;
	(window, winctl) = tkclient->toplevel(ctxt, nil, "Pleromussy", Tkclient->Resize | Tkclient->Hide);
	nav := chan of string;
	tk->namechan(window, nav, "nav");
	sel := chan of string;
	tk->namechan(window, sel, "sel");
	dsel := chan of string;
	tk->namechan(window, dsel, "dsel");
	ctx := chan of string;
	tk->namechan(window, ctx, "ctx");
	keyc := chan of string;
	tk->namechan(window, keyc, "key");
	# clicks on an embedded emoji-image panel can't reach .view.t's tag
	# hit-test, so each panel sends "<i> <j>" here to toggle that reaction
	rtog := chan of string;
	tk->namechan(window, rtog, "rtog");
	for(i := 0; i < len tkconfig; i++)
		tkcmd(window, tkconfig[i]);
	mktags();
	tkclient->onscreen(window, nil);
	tkclient->startinput(window, "kbd" :: "ptr" :: nil);
	tkcmd(window, "focus .view.t");		# so timeline key bindings fire

	results = chan of ref Result;
	notifresults = chan of ref NResult;
	threadresults = chan of ref TResult;
	profresults = chan of ref PResult;
	postresult = chan of ref Status;
	actionresult = chan of (ref Status, string, ref Status);
	reactresult = chan of (ref Status, ref Status, string);
	pickresult = chan of (ref Status, string);
	plumbnav = chan of (int, string);
	acctresult = chan[1] of string;
	whoami = chan of ref Account;
	loginresult := chan of ref Session;
	nextid = "";
	curview = "timeline";

	# Become a plumb target: a fediverse URL or @user@host handle clicked
	# anywhere (acme, charon, the shell, the wm Log) is routed by the plumber
	# to our "fedi" port and opened here.  See lib/plumbing.
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	if(plumbmsg != nil && plumbmsg->init(1, "fedi", 0) >= 0)
		spawn plumbreader();
	if(pendingplumb != "")		# launched to open a specific link
		spawn doresolve(pendingplumb);

	settitle(titlefor("(loading…)"));
	spawn fetch(client, view, "", 0, results);
	if(token != "")			# verify the saved session, show who we are
		spawn verify(client, whoami);
	else {				# no saved session: offer to log in
		loginopen = 1;
		spawn logindialog(host, loginresult);
	}

	for(;;) alt {
	s := <-window.ctxt.kbd =>
		tk->keyboard(window, s);
	s := <-window.ctxt.ptr =>
		tk->pointer(window, *s);
	s := <-window.ctxt.ctl or
	s = <-window.wreq or
	s = <-winctl =>
		# Delegate every wm request — including "exit" — to tkclient.
		# wmctl("exit") writes "killgrp" to /prog/<pid>/ctl then exits,
		# which reaps the whole proc group: the cs daemon, in-flight
		# fetch procs, and any open child windows.  A bare `return` here
		# left those alive, so the window's input channels stopped being
		# drained and the wm's demux proc wedged -> hang on close.
		tkclient->wmctl(window, s);
		# a theme push re-themes the plain widgets via "theme reapply"
		# inside wmctl; the .view.t text tags are not, so redo them.
		if(s != nil && len s >= 6 && s[0:6] == "theme ")
			mktags();
	xy := <-sel =>
		selectat(xy);
	xy := <-dsel =>
		doubleclick(xy);
	xy := <-ctx =>
		contextclick(xy);
	kc := <-keyc =>
		keynav(kc);
	rt := <-rtog =>
		(nr, rp) := sys->tokenize(rt, " ");
		if(nr >= 2){
			selected = int hd rp;
			highlight(selected);
			togglereaction(int hd rp, int hd tl rp);
		}
	cmd := <-nav =>
		case cmd {
		"public" or "home" =>
			if(!(cmd == view && curview == "timeline")){
				pushhistory();
				navgen++;
				view = cmd;
				curview = "timeline";
				nextid = "";
				selected = -1;
				settitle(titlefor("(loading…)"));
				spawn fetch(client, view, "", 0, results);
			}
		"notifs" =>
			if(curview != "notifs")
				pushhistory();
			navgen++;
			view = "notifs";
			curview = "notifs";
			nextid = "";
			selected = -1;
			settitle(titlefor("(loading…)"));
			spawn fetchnotifs(client, "", 0, notifresults);
		"refresh" =>
			navgen++;
			nextid = "";
			selected = -1;
			settitle(titlefor("(loading…)"));
			case curview {
			"notifs" =>	spawn fetchnotifs(client, "", 0, notifresults);
			"profile" =>	if(profacc != nil) spawn fetchprofile(client, profacc.id, "", 0, navgen, profresults);
			"thread" =>	if(threadarr != nil && threadfocus < len threadarr)
						spawn fetchthread(client, threadarr[threadfocus].id, navgen, threadresults);
			* =>		spawn fetch(client, view, "", 0, results);
			}
		"more" =>
			loadolder();
		"back" =>
			goback();
		"accounts" =>
			if(!acctopen){
				acctopen = 1;
				spawn acctchooser(accounts(), acctresult);
			}
		"compose" =>
			spawn composedialog("", "", postresult);
		}
	posted := <-postresult =>
		if(posted != nil){
			navgen++;
			nextid = "";
			selected = -1;
			curview = "timeline";
			if(view == "notifs")
				view = "home";
			settitle(titlefor("(posted; refreshing…)"));
			spawn fetch(client, view, "", 0, results);
		}
	(target, action, srv) := <-actionresult =>
		if(srv != nil)
			copyinteraction(target, srv);
		else
			revertaction(target, action);
		rerender();
	(rtarget, rsrv, rerr) := <-reactresult =>
		if(rsrv != nil){
			# adopt the server's authoritative reaction list + counts
			rtarget.reactions = rsrv.reactions;
			copyinteraction(rtarget, rsrv);
			rerender();
			settitle(titlefor(""));
		} else
			settitle(titlefor("[react: " + rerr + "]"));
	(ptarget, pemoji) := <-pickresult =>
		if(pemoji != "")
			reactdo(ptarget, pemoji, 1);
	lbl := <-acctresult =>
		acctopen = 0;		# the chooser has closed
		if(lbl == "+add"){
			if(!loginopen){
				loginopen = 1;
				spawn logindialog(host, loginresult);
			}
		} else if(len lbl > 0 && lbl[0] == '-')
			logoutacct(lbl[1:]);
		else if(lbl != "" && lbl != acctlabel)
			switchaccount(lbl);
	(kind, id) := <-plumbnav =>
		# a plumbed link resolved to a status or account; navigate to it
		navgen++;
		if(kind == 0)
			spawn fetchthread(client, id, navgen, threadresults);
		else
			spawn fetchprofile(client, id, "", 0, navgen, profresults);
	newsess := <-loginresult =>
		loginopen = 0;		# the login dialog has closed
		if(newsess != nil){
			# dologin set newsess.host to the account label (user@host)
			acctlabel = newsess.host;
			host = hostfromlabel(acctlabel);
			me = "";
			client = masto->client(host, newsess.token);
			if((serr := masto->savesession(newsess)) != nil)
				settitle(titlefor("[save: " + serr + "]"));
			else {
				selected = -1;
				navgen++;
				curview = "timeline";
				if(view == "notifs")
					view = "home";
				settitle(titlefor("(loading…)"));
				spawn fetch(client, view, "", 0, results);
				spawn verify(client, whoami);
			}
		}
	acc := <-whoami =>
		if(acc != nil){
			me = acc.acct;
			backfillacct(acctlabel, acc.acct);
			settitle(titlefor(""));
		}
	r := <-results =>
		if(r.err != nil){
			settitle(titlefor("[" + r.err + "]"));
		} else {
			nextid = r.next;
			top := "";
			if(r.app)
				top = viewtop();
			if(r.app)
				statuses = appendstatuses(statuses, r.sts);
			else
				statuses = r.sts;
			# a late timeline page must not clobber an overlay view
			if(curview == "timeline"){
				redraw();
				restoretop(top);
			}
			settitle(titlefor(""));
		}
	nr := <-notifresults =>
		if(nr.err != nil){
			settitle(titlefor("[" + nr.err + "]"));
		} else {
			nextid = nr.next;
			top := "";
			if(nr.app)
				top = viewtop();
			if(nr.app)
				notifs = appendnotifs(notifs, nr.ns);
			else
				notifs = nr.ns;
			if(curview == "notifs"){
				rendernotifs();
				restoretop(top);
			}
			settitle(titlefor(""));
		}
	tr := <-threadresults =>
		# drop a stale result: the user navigated away while it loaded
		if(tr.gen == navgen){
			if(tr.err != nil){
				settitle(titlefor("[" + tr.err + "]"));
			} else {
				threadarr = tr.arr;
				threadfocus = tr.focus;
				curview = "thread";
				selected = tr.focus;
				renderthread();
				settitle(titlefor("(thread)"));
			}
		}
	pr := <-profresults =>
		# drop a stale result: the user navigated away while it loaded
		if(pr.gen == navgen){
			if(pr.err != nil){
				settitle(titlefor("[" + pr.err + "]"));
			} else {
				nextid = pr.next;
				top := "";
				if(pr.app){
					top = viewtop();
					profarr = appendstatuses(profarr, a2l(pr.arr));
				} else {
					profacc = pr.acc;
					profarr = a2l(pr.arr);
				}
				curview = "profile";
				selected = -1;
				renderprofile();
				restoretop(top);
				settitle(titlefor("(profile)"));
			}
		}
	}
}

# build the title bar text for the current host/view, including the logged-in
# account when known, plus an optional status suffix
# the in-window status line: the page plus a transient status (identity lives
# in the wm title bar now, see wmtitle)
titlefor(extra: string): string
{
	t := pagename();
	if(extra != "")
		t += "  " + extra;
	return t;
}

# fetch the logged-in account in the background (so init doesn't block on it)
verify(c: ref Client, out: chan of ref Account)
{
	ensurecs();
	(a, nil) := masto->verifycredentials(c);
	out <-= a;
}

fetch(c: ref Client, v, max_id: string, app: int, out: chan of ref Result)
{
	ensurecs();
	sts: list of ref Status;
	next, err: string;
	if(v == "home")
		(sts, next, err) = masto->hometimeline(c, max_id, 20);
	else
		(sts, next, err) = masto->publictimeline(c, max_id, 20);
	out <-= ref Result(sts, next, err, app);
}

fetchnotifs(c: ref Client, max_id: string, app: int, out: chan of ref NResult)
{
	ensurecs();
	(ns, next, err) := masto->notifications(c, max_id, 20);
	out <-= ref NResult(ns, next, err, app);
}

# fetch a status' thread: ancestors + the focused status + descendants,
# flattened root-first with the focused index marked
fetchthread(c: ref Client, id: string, gen: int, out: chan of ref TResult)
{
	ensurecs();
	(focus, ferr) := masto->getstatus(c, id);
	if(focus == nil){
		out <-= ref TResult(nil, 0, ferr, gen);
		return;
	}
	(anc, desc, cerr) := masto->statuscontext(c, id);
	if(cerr != nil){
		out <-= ref TResult(nil, 0, cerr, gen);
		return;
	}
	arr := array[len anc + 1 + len desc] of ref Status;
	i := 0;
	for(l := anc; l != nil; l = tl l)
		arr[i++] = hd l;
	focusidx := i;
	arr[i++] = focus;
	for(l = desc; l != nil; l = tl l)
		arr[i++] = hd l;
	out <-= ref TResult(arr, focusidx, nil, gen);
}

fetchprofile(c: ref Client, id, max_id: string, app, gen: int, out: chan of ref PResult)
{
	ensurecs();
	acc: ref Account;
	aerr: string;
	if(!app){
		(acc, aerr) = masto->getaccount(c, id);
		if(acc == nil){
			out <-= ref PResult(nil, nil, "", aerr, app, gen);
			return;
		}
	}
	(sts, next, serr) := masto->accountstatuses(c, id, max_id, 20);
	if(serr != nil){
		out <-= ref PResult(nil, nil, "", serr, app, gen);
		return;
	}
	out <-= ref PResult(acc, l2a(sts), next, nil, app, gen);
}

# Modal-ish login window in its own toplevel + event loop.  Delivers the
# resulting Session (or nil if cancelled/closed) on out, then closes.
logindialog(h: string, out: chan of ref Session)
{
	(lw, lwc) := tkclient->toplevel(ctxt, nil, "Pleromussy: Login", Tkclient->Plain);
	b := chan of string;
	tk->namechan(lw, b, "b");
	for(i := 0; i < len logincfg; i++)
		tkcmd(lw, logincfg[i]);
	tkcmd(lw, ".host insert 0 " + tk->quote(h));
	tkcmd(lw, "focus .user");
	tkclient->onscreen(lw, nil);
	tkclient->startinput(lw, "kbd" :: "ptr" :: nil);

	netresult := chan[1] of ref Session;	# buffered: see mediaviewer
	oobresult := chan[1] of (string, string, string, string);	# cid,csec,url,err
	busy := 0;
	oobmode := 0;				# 1 once we are in code-paste mode
	oobcid := "";				# the staged OAuth app credentials
	oobcsec := "";
	for(;;) alt {
	k := <-lw.ctxt.kbd =>
		tk->keyboard(lw, k);
	p := <-lw.ctxt.ptr =>
		tk->pointer(lw, *p);
	c := <-lw.ctxt.ctl or
	c = <-lw.wreq or
	c = <-lwc =>
		if(c == "exit"){
			out <-= nil;
			return;
		}
		tkclient->wmctl(lw, c);
	cmd := <-b =>
		case cmd {
		"login" =>
			if(!busy){
				eh := tkcmd(lw, ".host get");
				eu := tkcmd(lw, ".user get");
				ep := tkcmd(lw, ".pass get");
				if(eu == "" || ep == ""){
					tkcmd(lw, ".status configure -text {enter a username and password}");
				} else {
					tkcmd(lw, ".status configure -text {logging in…}");
					busy = 1;
					spawn dologin(eh, eu, ep, netresult);
				}
			}
		"oob" =>
			# OAuth authorization-code fallback for instances that reject
			# the password grant: register an app, open the instance's own
			# authorize page in Charon, and switch to code-paste mode.
			if(!busy && !oobmode){
				eh := tkcmd(lw, ".host get");
				if(eh == "")
					tkcmd(lw, ".status configure -text {enter the instance hostname first}");
				else {
					tkcmd(lw, ".status configure -text {registering with " + eh + "…}");
					busy = 1;
					spawn dobeginoob(eh, oobresult);
				}
			}
		"finish" =>
			if(!busy && oobmode){
				eh := tkcmd(lw, ".host get");
				code := tkcmd(lw, ".code get");
				if(code == "")
					tkcmd(lw, ".status configure -text {paste the code shown by the browser}");
				else {
					tkcmd(lw, ".status configure -text {finishing login…}");
					busy = 1;
					spawn dofinishoob(eh, oobcid, oobcsec, code, netresult);
				}
			}
		"cancel" =>
			out <-= nil;
			return;
		}
	(ocid, ocsec, ourl, oerr) := <-oobresult =>
		busy = 0;
		if(oerr != "" || ourl == "")
			tkcmd(lw, ".status configure -text {browser login unavailable: " + oerr + "}");
		else {
			oobcid = ocid; oobcsec = ocsec; oobmode = 1;
			launchcharon(ourl);
			# repurpose the dialog for code paste: drop user/pass, show the
			# (snarfable) URL and a code field, retask the OK button.
			tkcmd(lw, "pack forget .ul .user .pl .pass");
			tkcmd(lw, "entry .url");
			tkcmd(lw, ".url insert 0 " + tk->quote(ourl));
			tkcmd(lw, "bind .url <Button-1> {.url select 0 end; focus .url}");
			tkcmd(lw, "label .cl -text {Paste code from browser:} -anchor w");
			tkcmd(lw, "entry .code");
			tkcmd(lw, "bind .code <Key-\n> {send b finish}");
			tkcmd(lw, "pack .url .cl .code -before .status -fill x -side top -padx 4 -pady 2");
			tkcmd(lw, ".b.ok configure -text Finish -command {send b finish}");
			tkcmd(lw, ".b.oob configure -state disabled");
			tkcmd(lw, "focus .code");
			tkcmd(lw, ".status configure -text {approve in the browser, then paste the code}");
		}
	sess := <-netresult =>
		busy = 0;
		if(sess == nil)
			tkcmd(lw, ".status configure -text {login failed (check credentials/instance)}");
		else {
			out <-= sess;
			return;
		}
	}
}

# run the OAuth password grant off the dialog's UI thread; nil on any error.
# On success the session's host is set to the account label (user@host) so it
# persists as its own account, letting several accounts share one instance.
dologin(h, user, pass: string, out: chan of ref Session)
{
	ensurecs();
	c := masto->client(h, "");
	(sess, err) := masto->login(c, user, pass, "");
	if(err != nil)
		sys->fprint(sys->fildes(2), "pleromussy: login: %s\n", err);
	if(sess != nil){
		sess.host = localpart(user) + "@" + h;
		sess.acct = localpart(user);	# best-effort handle; refined on verify
	}
	out <-= sess;
}

# stage the OAuth authorization-code flow off the UI thread: register an app and
# build the authorize URL.  Delivers (client_id, client_secret, url, err).
dobeginoob(h: string, out: chan of (string, string, string, string))
{
	ensurecs();
	c := masto->client(h, "");
	out <-= masto->beginoob(c, "");
}

# complete the authorization-code flow with the pasted code, then learn the
# handle so the account persists under its user@host label (like dologin).
dofinishoob(h, cid, csec, code: string, out: chan of ref Session)
{
	ensurecs();
	c := masto->client(h, "");
	(sess, err) := masto->finishoob(c, cid, csec, code, "");
	if(err != nil)
		sys->fprint(sys->fildes(2), "pleromussy: oob login: %s\n", err);
	if(sess != nil){
		c.token = sess.token;
		(acc, nil) := masto->verifycredentials(c);
		if(acc != nil){
			sess.acct = localpart(acc.acct);
			sess.host = localpart(acc.acct) + "@" + h;
		} else
			sess.host = h;		# fall back to the bare host as the label
	}
	out <-= sess;
}

# open a URL in Charon (its own proc/fd set, sharing our Draw context), used to
# show the instance's OAuth authorize page during browser login.
launchcharon(url: string)
{
	spawn runcharon(url);
}

runcharon(url: string)
{
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	ch := load Command "/dis/charon.dis";
	if(ch == nil){
		sys->fprint(sys->fildes(2), "pleromussy: cannot load charon\n");
		return;
	}
	ch->init(ctxt, "charon" :: url :: nil);
}

# the real hostname to dial from an account label: the part after the last '@'
hostfromlabel(label: string): string
{
	for(i := len label - 1; i >= 0; i--)
		if(label[i] == '@')
			return label[i+1:];
	return label;
}

# the local username part of a typed handle (before the first '@')
localpart(s: string): string
{
	if(len s > 0 && s[0] == '@')
		s = s[1:];
	for(i := 0; i < len s; i++)
		if(s[i] == '@')
			return s[0:i];
	return s;
}

# the available accounts: the live fedifs namespace (so a fedilogin/ctl login
# shows up) unioned with the on-disk session store (so a just-saved GUI account
# appears even if a running fedifs has not re-enumerated it yet)
accounts(): list of string
{
	out := listdir("/mnt/fedi", 0);
	for(l := listdir(masto->sessiondir(), 1); l != nil; l = tl l)
		out = addonce(out, hd l);
	return out;
}

addonce(l: list of string, s: string): list of string
{
	for(p := l; p != nil; p = tl p)
		if(hd p == s)
			return l;
	return s :: l;
}

listdir(path: string, stripjson: int): list of string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	out: list of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			nm := d[i].name;
			if(nm == "." || nm == "..")
				continue;
			if(stripjson){
				if(len nm > 5 && nm[len nm-5:] == ".json")
					out = nm[0:len nm-5] :: out;
			} else
				out = nm :: out;
		}
	}
	return out;
}

# switch the active account: rebuild the client from the selected label's saved
# session and reload the current view for it
switchaccount(label: string)
{
	acctlabel = label;
	host = hostfromlabel(label);
	sess := masto->loadsession(label);
	token := "";
	if(sess != nil)
		token = sess.token;
	client = masto->client(host, token);
	me = "";
	history = nil;			# back history belongs to the old account
	navgen++;
	nextid = "";
	selected = -1;
	if(curview != "notifs")
		curview = "timeline";
	settitle(titlefor("(loading…)"));
	if(curview == "notifs")
		spawn fetchnotifs(client, "", 0, notifresults);
	else
		spawn fetch(client, view, "", 0, results);
	if(token != "")
		spawn verify(client, whoami);
}

# log out an account: drop its saved session (and tell a mounted fedifs to drop
# its in-memory token too).  If it was the active account, move to another or
# fall back to anonymous on the same host.
logoutacct(label: string)
{
	masto->deletesession(label);
	fd := sys->open("/mnt/fedi/" + label + "/ctl", Sys->OWRITE);	# best-effort
	if(fd != nil){
		b := array of byte "logout";
		sys->write(fd, b, len b);
	}
	if(label != acctlabel)
		return;
	next := "";
	for(l := accounts(); l != nil; l = tl l)
		if(hd l != label){
			next = hd l;
			break;
		}
	if(next != "")
		switchaccount(next);
	else {
		me = "";
		client = masto->client(host, "");
		navgen++;
		selected = -1;
		settitle(titlefor("(logged out)"));
		spawn fetch(client, view, "", 0, results);
	}
}

# record the verified handle into a saved session that lacks one, so the
# account chooser can show a username for accounts saved as a bare host
backfillacct(label, acct: string)
{
	if(label == "" || acct == "")
		return;
	sess := masto->loadsession(label);
	if(sess != nil && sess.acct == ""){
		sess.acct = acct;
		masto->savesession(sess);
	}
}

# Account chooser in its own toplevel: a button per account (the active one
# marked), plus Add account… and Cancel.  Delivers the chosen label on out,
# "+add" to open the login dialog, or "" on cancel/close.
acctchooser(accts: list of string, out: chan of string)
{
	acc := array[len accts] of string;
	j := 0;
	for(l := accts; l != nil; l = tl l)
		acc[j++] = hd l;

	(cw, cwc) := tkclient->toplevel(ctxt, nil, "Pleromussy: Accounts", Tkclient->Plain);
	b := chan of string;
	tk->namechan(cw, b, "b");
	tkcmd(cw, "label .l -text {Choose account:} -anchor w");
	tkcmd(cw, "pack .l -fill x -side top -padx 4 -pady 2");
	for(i := 0; i < len acc; i++){
		rf := ".r" + string i;
		mark := "  ";
		if(acc[i] == acctlabel)
			mark = "• ";	# bullet marks the active account
		tkcmd(cw, "frame " + rf);
		tkcmd(cw, "button " + rf + ".sel -text " + tk->quote(mark + acctdisplay(acc[i])) +
			" -anchor w -command {send b a" + string i + "}");
		tkcmd(cw, "button " + rf + ".out -text {Log out} -command {send b L" + string i + "}");
		tkcmd(cw, "pack " + rf + ".out -side right");
		tkcmd(cw, "pack " + rf + ".sel -side left -fill x -expand 1");
		tkcmd(cw, "pack " + rf + " -fill x -side top -padx 4 -pady 1");
	}
	tkcmd(cw, "frame .bf");
	tkcmd(cw, "button .bf.add -text {Add account…} -command {send b add}");
	tkcmd(cw, "button .bf.cancel -text Cancel -command {send b cancel}");
	tkcmd(cw, "pack .bf.cancel .bf.add -side right");
	tkcmd(cw, "pack .bf -fill x -side top -padx 4 -pady 2");
	tkcmd(cw, "pack propagate . 0");
	tkcmd(cw, ". configure -width 360 -height " + string (104 + 30*len acc));
	tkclient->onscreen(cw, nil);
	tkclient->startinput(cw, "kbd" :: "ptr" :: nil);

	for(;;) alt {
	k := <-cw.ctxt.kbd =>
		tk->keyboard(cw, k);
	p := <-cw.ctxt.ptr =>
		tk->pointer(cw, *p);
	c := <-cw.ctxt.ctl or
	c = <-cw.wreq or
	c = <-cwc =>
		if(c == "exit"){
			out <-= "";
			return;
		}
		tkclient->wmctl(cw, c);
	cmd := <-b =>
		case cmd {
		"cancel" =>
			out <-= "";
			return;
		"add" =>
			out <-= "+add";
			return;
		* =>
			# a<i> = select that account, L<i> = log it out
			if(len cmd > 1 && (cmd[0] == 'a' || cmd[0] == 'L')){
				idx := int cmd[1:];
				if(idx >= 0 && idx < len acc){
					if(cmd[0] == 'L')
						out <-= "-" + acc[idx];
					else
						out <-= acc[idx];
					return;
				}
			}
		}
	}
}

# a friendly display name for an account label: prefer the stored handle, then
# the user@host's user, else the bare label
acctdisplay(label: string): string
{
	h := hostfromlabel(label);
	sess := masto->loadsession(label);
	if(sess != nil && sess.acct != "")
		return "@" + sess.acct + " (" + h + ")";
	u := userfromlabel(label);
	if(u != "")
		return "@" + u + " (" + h + ")";
	return label;
}

# the username part of a "user@host" label ("" for a bare host)
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

# Compose window in its own toplevel + event loop.  inreply is the id being
# replied to ("" for a fresh post); prefill seeds the body (e.g. "@user ").
# Delivers the posted Status on out (nil if cancelled), then closes.
composedialog(inreply, prefill: string, out: chan of ref Status)
{
	title := "Pleromussy: Compose";
	if(inreply != "")
		title = "Pleromussy: Reply";
	(cw, cwc) := tkclient->toplevel(ctxt, nil, title, Tkclient->Plain);
	b := chan of string;
	tk->namechan(cw, b, "b");
	for(i := 0; i < len composecfg; i++)
		tkcmd(cw, composecfg[i]);
	tkcmd(cw, ".vis insert 0 public");
	if(prefill != "")
		tkcmd(cw, ".body insert end " + tk->quote(prefill));
	tkcmd(cw, "focus .body");
	tkclient->onscreen(cw, nil);
	tkclient->startinput(cw, "kbd" :: "ptr" :: nil);

	netresult := chan[1] of ref Status;	# buffered: see mediaviewer
	busy := 0;
	for(;;) alt {
	k := <-cw.ctxt.kbd =>
		tk->keyboard(cw, k);
	p := <-cw.ctxt.ptr =>
		tk->pointer(cw, *p);
	c := <-cw.ctxt.ctl or
	c = <-cw.wreq or
	c = <-cwc =>
		if(c == "exit"){
			out <-= nil;
			return;
		}
		tkclient->wmctl(cw, c);
	cmd := <-b =>
		case cmd {
		"post" =>
			if(!busy){
				text := trimws(tkcmd(cw, ".body get 1.0 end"));
				vis := tkcmd(cw, ".vis get");
				if(text == "")
					tkcmd(cw, ".status configure -text {nothing to post}");
				else {
					tkcmd(cw, ".status configure -text {posting…}");
					busy = 1;
					spawn dopost(client, text, vis, inreply, netresult);
				}
			}
		"cancel" =>
			out <-= nil;
			return;
		}
	st := <-netresult =>
		busy = 0;
		if(st == nil)
			tkcmd(cw, ".status configure -text {post failed}");
		else {
			out <-= st;
			return;
		}
	}
}

dopost(c: ref Client, text, vis, inreply: string, out: chan of ref Status)
{
	ensurecs();
	(s, err) := masto->poststatus(c, text, vis, inreply, "");
	if(err != nil)
		sys->fprint(sys->fildes(2), "pleromussy: post: %s\n", err);
	out <-= s;
}

trimws(s: string): string
{
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t' || s[0] == '\n' || s[0] == '\r'))
		s = s[1:];
	while(len s > 0 && (s[len s-1] == ' ' || s[len s-1] == '\t' || s[len s-1] == '\n' || s[len s-1] == '\r'))
		s = s[0:len s-1];
	return s;
}

# Media viewer in its own toplevel + event loop.  Opens immediately showing a
# "loading" label, then fills in the decoded image (or an error) when the
# background download/decode completes.  Save writes the raw bytes to disk.
mediaviewer(m: ref Attachment)
{
	(vw, vwc) := tkclient->toplevel(ctxt, nil, "Pleromussy: media", Tkclient->Appl);
	v := chan of string;
	tk->namechan(vw, v, "v");
	for(i := 0; i < len viewcfg; i++)
		tkcmd(vw, viewcfg[i]);
	desc := m.atype;
	if(m.description != "")
		desc = m.atype + " — " + m.description;
	tkcmd(vw, ".top.l configure -text " + tk->quote("loading: " + desc));
	tkcmd(vw, ". configure -width 460 -height 90");
	tkclient->onscreen(vw, nil);
	tkclient->startinput(vw, "kbd" :: "ptr" :: nil);

	# buffered so loadmedia can deliver and exit even if this viewer was
	# closed mid-download (otherwise the helper proc would block forever)
	loaded := chan[1] of (ref Image, array of byte, string);
	spawn loadmedia(m.url, loaded);

	rawdata: array of byte;
	for(;;) alt {
	k := <-vw.ctxt.kbd =>
		tk->keyboard(vw, k);
	p := <-vw.ctxt.ptr =>
		tk->pointer(vw, *p);
	c := <-vw.ctxt.ctl or
	c = <-vw.wreq or
	c = <-vwc =>
		if(c == "exit")
			return;
		tkclient->wmctl(vw, c);
	(img, data, lerr) := <-loaded =>
		if(img == nil){
			tkcmd(vw, ".top.l configure -text " + tk->quote("failed: " + lerr) + "; update");
		} else {
			rawdata = data;
			imconfig(vw, img);
			tk->putimage(vw, ".p", img, nil);
			tkcmd(vw, ".top.l configure -text " + tk->quote(desc));
			w := img.r.dx();
			h := img.r.dy() + 34;
			tkcmd(vw, ". configure -width " + string w + " -height " + string h);
			tkcmd(vw, "update");
		}
	cmd := <-v =>
		case cmd {
		"save" =>
			if(rawdata != nil){
				(ok, path) := savemedia(m.url, rawdata);
				if(ok)
					tkcmd(vw, ".top.l configure -text " + tk->quote("saved: " + path) + "; update");
				else
					tkcmd(vw, ".top.l configure -text {save failed}; update");
			}
		}
	}
}

# download + decode an image off the viewer's UI thread
loadmedia(url: string, out: chan of (ref Image, array of byte, string))
{
	ensurecs();
	(data, err) := masto->fetchurl(url);
	if(err != nil){
		out <-= (nil, nil, err);
		return;
	}
	(img, ierr) := decodeimage(data);
	out <-= (img, data, ierr);
}

# decode encoded image bytes into a Draw image.  decodefit downscales a large
# source to MAXIMGW x MAXIMGH *in C*, so the full-resolution RGBA never has to
# fit in the Dis heap (a big fedi photo is tens of MB and would overflow the
# main arena -> "arena main too large" + a failed decode).
decodeimage(data: array of byte): (ref Image, string)
{
	(dw, dh, drgba, err) := imageio->decodefit(data, MAXIMGW, MAXIMGH);
	if(drgba == nil)
		return (nil, "decode: " + err);
	img := ctxt.display.newimage(Rect(Point(0,0), Point(dw,dh)), draw->ABGR32, 0, draw->White);
	if(img == nil)
		return (nil, "newimage failed");
	img.writepixels(img.r, drgba);
	return (img, nil);
}

# map an emoji string to its twemoji file-name: the lowercase hex of each rune,
# joined by '-', with the U+FE0F variation selector dropped (twemoji's scheme).
emojiname(s: string): string
{
	name := "";
	for(i := 0; i < len s; i++){
		if(s[i] == 16rFE0F)
			continue;
		if(name != "")
			name += "-";
		name += sys->sprint("%x", s[i]);
	}
	return name;
}

# decoded Draw image for an emoji string, or nil when no asset is bundled (so
# the caller falls back to rendering the raw emoji as text).  Memoised — the
# negative (nil) result is cached too, so a missing emoji is looked up once.
emojiimage(s: string): ref Image
{
	name := emojiname(s);
	if(name == "")
		return nil;
	for(l := emojicache; l != nil; l = tl l){
		(k, im) := hd l;
		if(k == name)
			return im;
	}
	img: ref Image;
	(data, derr) := readfile(EMOJIDIR + "/" + name + ".png");
	if(derr == nil)
		(img, derr) = decodeemoji(data);
	emojicache = (name, img) :: emojicache;
	return img;
}

# decode emoji PNG bytes into a small Draw image (downscaled to EMOJIPX).  Kept
# separate from decodeimage so emoji get their own tiny size cap.
decodeemoji(data: array of byte): (ref Image, string)
{
	(w, h, rgba, err) := imageio->decode(data);
	if(rgba == nil)
		return (nil, "decode: " + err);
	dw := EMOJIPX;
	dh := EMOJIPX;
	drgba := rgba;
	if(w != dw || h != dh)
		drgba = emojiscale(w, h, rgba, dw, dh);
	img := ctxt.display.newimage(Rect(Point(0,0), Point(dw,dh)), draw->ABGR32, 0, draw->Transparent);
	if(img == nil)
		return (nil, "newimage failed");
	img.writepixels(img.r, drgba);
	return (img, nil);
}

# alpha-weighted area-average downscale of RGBA8 (bytes R,G,B,A == ABGR32 in
# memory).  Box-filtering beats fit()'s nearest-neighbour for emoji, which carry
# fine detail and antialiased edges; weighting colour by alpha avoids dark
# halos where transparent pixels would otherwise drag the average toward black.
emojiscale(w, h: int, rgba: array of byte, dw, dh: int): array of byte
{
	out := array[dw * dh * 4] of byte;
	for(dy := 0; dy < dh; dy++){
		sy0 := dy * h / dh;
		sy1 := (dy + 1) * h / dh;
		if(sy1 <= sy0) sy1 = sy0 + 1;
		for(dx := 0; dx < dw; dx++){
			sx0 := dx * w / dw;
			sx1 := (dx + 1) * w / dw;
			if(sx1 <= sx0) sx1 = sx0 + 1;
			ar := ag := ab := aw := n := 0;
			for(sy := sy0; sy < sy1; sy++){
				for(sx := sx0; sx < sx1; sx++){
					si := (sy * w + sx) * 4;
					a := int rgba[si + 3];
					ar += int rgba[si] * a;
					ag += int rgba[si + 1] * a;
					ab += int rgba[si + 2] * a;
					aw += a;
					n++;
				}
			}
			di := (dy * dw + dx) * 4;
			if(aw > 0){
				out[di]   = byte (ar / aw);
				out[di+1] = byte (ag / aw);
				out[di+2] = byte (ab / aw);
			}
			out[di+3] = byte (aw / n);
		}
	}
	return out;
}

# embed an emoji image inline at the current end of the text widget, over a
# panel tinted `bg` (the chip colour) so the emoji's transparent edges blend in.
# The image doubles as its own matte, so its alpha composites over the panel.
# The panel is an owned descendant of `.view.t`, so the next `.view.t delete`
# destroys it automatically — we must NOT destroy it ourselves (a manual destroy
# before the delete dangles the text item's sub-widget pointer; after it, it's a
# double-destroy that prints "bad window path").
emojipanel(img: ref Image, bg: string, i, j: int)
{
	p := ".view.t.e" + string emojiseq++;
	w := img.r.dx();
	h := img.r.dy();
	tkcmd(window, "panel " + p + " -bd 0 -width " + string w +
		" -height " + string h + " -background " + bg);
	tkcmd(window, ".view.t window create {end -1c} -window " + p + " -align center");
	tkcmd(window, "bind " + p + " <Button-1> {send rtog " +
		string i + " " + string j + "}");
	tk->putimage(window, p, img, img);
}

# read a whole (small) local file; used for the bundled emoji PNGs
readfile(path: string): (array of byte, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	buf: array of byte;
	tmp := array[8192] of byte;
	for(;;){
		n := sys->read(fd, tmp, len tmp);
		if(n < 0)
			return (nil, sys->sprint("%r"));
		if(n == 0)
			break;
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = tmp[0:n];
		buf = nb;
	}
	return (buf, nil);
}

imconfig(t: ref Tk->Toplevel, im: ref Image)
{
	tkcmd(t, ".p configure -width " + string im.r.dx() +
		" -height " + string im.r.dy() + "; update");
}

# save raw media bytes to /tmp/pleromussy/<basename>
savemedia(url: string, data: array of byte): (int, string)
{
	dir := "/tmp/pleromussy";
	sys->create(dir, Sys->OREAD, Sys->DMDIR | 8r700);
	base := urlbasename(url);
	if(base == "")
		base = "media";
	path := dir + "/" + base;
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return (0, "");
	if(sys->write(fd, data, len data) != len data)
		return (0, "");
	return (1, path);
}

urlbasename(url: string): string
{
	for(i := 0; i < len url; i++)
		if(url[i] == '?'){
			url = url[0:i];
			break;
		}
	last := "";
	(nil, parts) := sys->tokenize(url, "/");
	for(l := parts; l != nil; l = tl l)
		last = hd l;
	return last;
}

# snapshot the current view onto the Back history before navigating away
pushhistory()
{
	history = ref Snap(curview, view, statuses, notifs, threadarr,
		threadfocus, profacc, profarr, nextid, selected) :: history;
}

# Back: pop the previous view off the history and restore it verbatim (no
# server re-fetch), then re-render with the renderer that owns that view
goback()
{
	if(history == nil){
		settitle(titlefor("(nothing to go back to)"));
		return;
	}
	navgen++;	# any in-flight thread/profile fetch is now stale
	s := hd history;
	history = tl history;
	curview = s.curview;
	view = s.view;
	statuses = s.statuses;
	notifs = s.notifs;
	threadarr = s.threadarr;
	threadfocus = s.threadfocus;
	profacc = s.profacc;
	profarr = s.profarr;
	nextid = s.nextid;
	selected = s.selected;
	rerender();
	settitle(titlefor(""));
}

# load the next (older) page of the current view and append it.  This is the
# only pagination affordance now (the inline "load older posts" row and the `m`
# key both call it); Refresh, by contrast, reloads the view from newest.
loadolder()
{
	if(curview == "thread"){
		settitle(titlefor("(whole thread shown — Refresh pulls new replies)"));
		return;
	}
	if(nextid == ""){
		settitle(titlefor("(no older posts)"));
		return;
	}
	settitle(titlefor("(loading older…)"));
	case curview {
	"notifs" =>	spawn fetchnotifs(client, nextid, 1, notifresults);
	"profile" =>	if(profacc != nil) spawn fetchprofile(client, profacc.id, nextid, 1, navgen, profresults);
	* =>		spawn fetch(client, view, nextid, 1, results);
	}
}

# the text index at the top of the viewport, captured before a rebuild so the
# scroll position can be restored afterward (so "More posts" pagination, which
# appends at the end and rebuilds the widget, doesn't jump back to the top)
viewtop(): string
{
	return tkcmd(window, ".view.t index @0,0");
}

restoretop(ix: string)
{
	if(ix != "")
		tkcmd(window, ".view.t yview " + ix);
}

# re-render whatever view currently owns the screen (used after an action
# toggle so the change shows without snapping back to the timeline)
rerender()
{
	case curview {
	"notifs" =>	rendernotifs();
	"thread" =>	renderthread();
	"profile" =>	renderprofile();
	* =>		redraw();
	}
}

# render one status block at index i, tag it s<i> (so a click maps back) and
# POST (margins/spacing for the card look), then a faint separator rule after
renderblock(i: int, s: ref Status)
{
	startidx := tkcmd(window, ".view.t index {end -1c}");
	renderone(i, s);
	endidx := tkcmd(window, ".view.t index {end -1c}");
	tkcmd(window, ".view.t tag add s" + string i + " " + startidx + " " + endidx);
	# in the thread view a depth tag indents the post into a reply tree; other
	# views use the flat POST margins
	ptag := "POST";
	if(rowdepth != nil && i < len rowdepth){
		d := rowdepth[i];
		if(d > MAXDEPTH)
			d = MAXDEPTH;
		ptag = "D" + string d;
	}
	tkcmd(window, ".view.t tag add " + ptag + " " + startidx + " " + endidx);
	# the separator newline sits OUTSIDE the s<i> range so clicking it is inert
	ins(SEPRULE, "SEP");
}

SEPRULE: con "────────────────────────────────────────────────────────\n";

# rebuild the whole text widget from the accumulated `statuses`, tagging each
# status's block with a unique s<i> tag so clicks can be mapped back to it
redraw()
{
	rowdepth = nil;
	statusarr = l2a(statuses);
	tkcmd(window, ".view.t delete 1.0 end");
	for(i := 0; i < len statusarr; i++)
		renderblock(i, statusarr[i]);
	appendmorerow();
	if(selected >= 0 && selected < len statusarr)
		highlight(selected);
	tkcmd(window, "update");
}

# append a clickable "load older posts" row when more pages exist (hit-tagged
# "more", handled in selectat); the only pagination control besides the m key
appendmorerow()
{
	if(nextid == "")
		return;
	startidx := tkcmd(window, ".view.t index {end -1c}");
	ins("↓ load older posts ↓\n", "MORE");
	endidx := tkcmd(window, ".view.t index {end -1c}");
	tkcmd(window, ".view.t tag add more " + startidx + " " + endidx);
}

# the notifications view: a header line per notification, plus the related
# status as a normal (selectable) block when there is one
rendernotifs()
{
	rowdepth = nil;
	tkcmd(window, ".view.t delete 1.0 end");
	tmp := array[len notifs] of ref Status;
	n := 0;
	for(l := notifs; l != nil; l = tl l){
		nt := hd l;
		ins(notifline(nt) + "\n", "META");
		if(nt.status != nil){
			renderblock(n, nt.status);
			tmp[n] = nt.status;
			n++;
		} else
			ins("\n", "META");
	}
	statusarr = tmp[0:n];
	appendmorerow();
	if(selected >= 0 && selected < len statusarr)
		highlight(selected);
	tkcmd(window, "update");
}

# one-line summary of who did what, for the notifications view
notifline(n: ref Notification): string
{
	who := "?";
	if(n.account != nil){
		who = n.account.display_name;
		if(who == "")
			who = n.account.username;
		who += " @" + n.account.acct;
	}
	glyph := "•";
	verb := n.ntype;
	case n.ntype {
	"favourite" =>			glyph = "★"; verb = "favourited";
	"reblog" =>			glyph = "↺"; verb = "boosted";
	"mention" =>			glyph = "✎"; verb = "mentioned you";
	"follow" =>			glyph = "＋"; verb = "followed you";
	"follow_request" =>		glyph = "＋"; verb = "requested to follow";
	"poll" =>			glyph = "▦"; verb = "poll ended";
	"update" =>			glyph = "✱"; verb = "edited a post";
	"pleroma:emoji_reaction" =>	glyph = "☺"; verb = "reacted";
	}
	return glyph + " " + who + " " + verb + "   " + reltime(n.created_at);
}

# the thread view: ancestors, the focused status, then descendants, all
# selectable; the focused one is highlighted
renderthread()
{
	tkcmd(window, ".view.t delete 1.0 end");
	statusarr = threadarr;
	rowdepth = threaddepths(threadarr);	# indent replies into a tree
	for(i := 0; i < len threadarr; i++)
		renderblock(i, threadarr[i]);
	if(selected >= 0 && selected < len statusarr)
		highlight(selected);
	tkcmd(window, "update");
}

# reply-depth of each status in a thread: follow in_reply_to_id within the
# thread set; a post whose parent isn't in the set sits at depth 0
threaddepths(arr: array of ref Status): array of int
{
	d := array[len arr] of {* => 0};
	for(i := 0; i < len arr; i++)
		d[i] = depthof(arr, i, 0);
	return d;
}

depthof(arr: array of ref Status, i, guard: int): int
{
	if(arr[i] == nil || guard > 64)
		return 0;
	pid := arr[i].in_reply_to_id;
	if(pid == "")
		return 0;
	pi := idindex(arr, pid);
	if(pi < 0 || pi == i)
		return 0;
	return 1 + depthof(arr, pi, guard+1);
}

idindex(arr: array of ref Status, id: string): int
{
	for(i := 0; i < len arr; i++)
		if(arr[i] != nil && arr[i].id == id)
			return i;
	return -1;
}

# the profile view: an account header (name/handle/bio) then that account's
# statuses as selectable blocks
renderprofile()
{
	rowdepth = nil;
	tkcmd(window, ".view.t delete 1.0 end");
	if(profacc != nil){
		nm := profacc.display_name;
		if(nm == "")
			nm = profacc.username;
		ins(nm, "NAME");
		ins("   @" + profacc.acct + "\n", "META");
		bio := htmltext(profacc.note);
		if(bio != "")
			ins(bio + "\n", "BODY");
		ins("\n", "META");
	}
	statusarr = l2a(profarr);
	for(i := 0; i < len statusarr; i++)
		renderblock(i, statusarr[i]);
	appendmorerow();
	if(selected >= 0 && selected < len statusarr)
		highlight(selected);
	tkcmd(window, "update");
}

renderone(idx: int, s: ref Status)
{
	disp := s;
	if(s.reblog != nil){
		ins("  ↻ boosted by " + authorname(s) + "\n", "META");
		disp = s.reblog;
	}
	a := disp.account;
	name := "?";
	acct := "";
	if(a != nil){
		name = a.display_name;
		if(name == "")
			name = a.username;
		acct = "  @" + a.acct;
	}
	ins(name, "NAME");
	ins(acct + "   " + reltime(disp.created_at) + "\n", "META");
	body := htmltext(disp.content);
	if(body != "")
		ins(body + "\n", "BODY");
	rendermedia(idx, disp);
	renderactions(idx, disp);
	renderreactions(idx, disp);
}

# the Pleroma emoji-reaction row: one clickable chip per reaction, "<emoji> N",
# hit-tagged r<idx>_<j> so a click toggles the user's own reaction with that
# emoji.  Chips the user has reacted with are shaded distinctly (RXME).  Renders
# nothing when the status has no reactions (or the server isn't Pleroma).
renderreactions(idx: int, s: ref Status)
{
	if(s.reactions == nil)
		return;
	ins("  ", "META");
	j := 0;
	for(l := s.reactions; l != nil; l = tl l){
		rx := hd l;
		tag := "RXN";
		bg := thCHIPBG;
		if(rx.me){
			tag = "RXME";
			bg = thCHIPMEBG;
		}
		startidx := tkcmd(window, ".view.t index {end -1c}");
		# the emoji itself: an inline image when we have the asset, else the
		# raw emoji text (a missing-glyph box) as a fallback
		img := emojiimage(rx.name);
		if(img != nil){
			ins(" ", tag);
			emojipanel(img, bg, idx, j);
			ins(" " + string rx.count + " ", tag);
		} else
			ins(" " + rx.name + " " + string rx.count + " ", tag);
		endidx := tkcmd(window, ".view.t index {end -1c}");
		tkcmd(window, ".view.t tag add r" + string idx + "_" + string j +
			" " + startidx + " " + endidx);
		ins(" ", "META");
		j++;
	}
	ins("\n", "META");
}

# the per-status action row: inline, clickable button-styled spans.  Each span
# carries a hit-test tag b<idx>_<code> so a Button-1 click dispatches directly
# on this post — no separate "select then act" step.
renderactions(idx: int, s: ref Status)
{
	ins("  ", "META");
	fav := sys->sprint(" ♡ %d ", s.favourites_count);
	if(s.favourited)
		fav = sys->sprint(" ★ %d ", s.favourites_count);
	btn(idx, "fav", fav);
	ins(" ", "META");
	bst := sys->sprint(" ↻ %d ", s.reblogs_count);
	if(s.reblogged)
		bst = sys->sprint(" ↺ %d ", s.reblogs_count);
	btn(idx, "boost", bst);
	ins(" ", "META");
	btn(idx, "reply", sys->sprint(" ✎ %d ", s.replies_count));
	ins(" ", "META");
	btn(idx, "more", " ⋯ ");
	if(s.bookmarked)
		ins("   ▣ saved", "META");
	ins("\n", "META");
}

# render one inline button span, styled BTN, hit-tagged b<idx>_<code>
btn(idx: int, code, text: string)
{
	startidx := tkcmd(window, ".view.t index {end -1c}");
	ins(text, "BTN");
	endidx := tkcmd(window, ".view.t index {end -1c}");
	tkcmd(window, ".view.t tag add b" + string idx + "_" + code +
		" " + startidx + " " + endidx);
}

# render one clickable line per attachment, tagged med<statusidx>_<attachidx>
# so a Button-1 click maps back to the exact attachment to open
rendermedia(idx: int, s: ref Status)
{
	j := 0;
	for(l := s.media; l != nil; l = tl l){
		m := hd l;
		glyph := "▶";
		if(m.atype == "image")
			glyph = "▤";
		line := "  " + glyph + " " + m.atype;
		if(m.description != "")
			line += " — " + m.description;
		line += "   [open]";
		startidx := tkcmd(window, ".view.t index {end -1c}");
		ins(line + "\n", "MEDIA");
		endidx := tkcmd(window, ".view.t index {end -1c}");
		tkcmd(window, ".view.t tag add med" + string idx + "_" + string j +
			" " + startidx + " " + endidx);
		j++;
	}
}

# the status a click landed on, following a boost to its target, or nil
targetidx(i: int): ref Status
{
	if(i < 0 || i >= len statusarr)
		return nil;
	s := statusarr[i];
	if(s.reblog != nil)
		return s.reblog;
	return s;
}

# the tag names applied at a "<x> <y>" pointer position, as a list of strings
tagsat(xy: string): list of string
{
	(n, t) := sys->tokenize(xy, " ");
	if(n < 2)
		return nil;
	names := tkcmd(window, ".view.t tag names @" + hd t + "," + hd tl t);
	(nil, tags) := sys->tokenize(names, " ");
	return tags;
}

# convert a widget-relative "<x> <y>" to toplevel coordinates (for menu posting)
toplevelxy(xy: string): (int, int)
{
	(n, t) := sys->tokenize(xy, " ");
	if(n < 2)
		return (0, 0);
	ax := int tkcmd(window, ".view.t cget -actx");
	ay := int tkcmd(window, ".view.t cget -acty");
	return (ax + int hd t, ay + int hd tl t);
}

# Single Button-1: an inline button or media line acts directly; otherwise the
# post under the cursor is selected (highlighted).  Priority: media > button >
# select.
selectat(xy: string)
{
	tags := tagsat(xy);
	(px, py) := toplevelxy(xy);
	# the inline "load older posts" row
	for(l := tags; l != nil; l = tl l)
		if(hd l == "more"){
			loadolder();
			return;
		}
	# a media line takes priority: open the attachment rather than select
	for(l = tags; l != nil; l = tl l){
		tag := hd l;
		if(len tag > 3 && tag[0:3] == "med"){
			openmedia(tag[3:]);
			return;
		}
	}
	# an emoji-reaction chip: r<idx>_<j> — toggle the user's reaction
	for(l = tags; l != nil; l = tl l){
		tag := hd l;
		if(len tag >= 2 && tag[0] == 'r' && tag[1] >= '0' && tag[1] <= '9'){
			(nr, rp) := sys->tokenize(tag[1:], "_");
			if(nr >= 2){
				selected = int hd rp;
				highlight(selected);
				togglereaction(int hd rp, int hd tl rp);
			}
			return;
		}
	}
	# an inline action button: b<idx>_<code>
	for(l = tags; l != nil; l = tl l){
		tag := hd l;
		if(len tag >= 2 && tag[0] == 'b' && tag[1] >= '0' && tag[1] <= '9'){
			(nb, bp) := sys->tokenize(tag[1:], "_");
			if(nb >= 2){
				selected = int hd bp;
				highlight(selected);
				dispatch(int hd bp, hd tl bp, px, py);
			}
			return;
		}
	}
	# otherwise select the post block
	for(l = tags; l != nil; l = tl l){
		tag := hd l;
		if(len tag >= 2 && tag[0] == 's' && tag[1] >= '0' && tag[1] <= '9'){
			selected = int tag[1:];
			highlight(selected);
			settitle(titlefor(""));
			return;
		}
	}
}

# the post-block index under "<x> <y>", or -1
postidxat(xy: string): int
{
	for(l := tagsat(xy); l != nil; l = tl l){
		tag := hd l;
		if(len tag >= 2 && tag[0] == 's' && tag[1] >= '0' && tag[1] <= '9')
			return int tag[1:];
	}
	return -1;
}

# Double Button-1 on a post's body (not on a button/media span) opens its thread
doubleclick(xy: string)
{
	for(l := tagsat(xy); l != nil; l = tl l){
		tag := hd l;
		# a button, reaction, or media span owns the double-click; ignore here
		if(len tag >= 2 && (tag[0] == 'b' || tag[0] == 'r') && tag[1] >= '0' && tag[1] <= '9')
			return;
		if(len tag > 3 && tag[0:3] == "med")
			return;
	}
	i := postidxat(xy);
	if(i >= 0){
		selected = i;
		highlight(i);
		dispatch(i, "thread", 0, 0);
	}
}

# Button-3 on a post: pop up a context menu of actions for it
contextclick(xy: string)
{
	i := postidxat(xy);
	if(i < 0)
		return;
	selected = i;
	highlight(i);
	(px, py) := toplevelxy(xy);
	code := runmenu(i, px, py);
	if(code != "")
		dispatch(i, code, px, py);
}

# Build + post the per-post context menu and pump events until the user picks an
# item (returns its code) or dismisses it (returns "").  This runs synchronously
# on the main proc with a nested event pump — the popup menu's grab needs the
# window's kbd/ptr events fed to it, so we can't just block on the result chan in
# a side proc (cf. wm/ftree's post()).
runmenu(i: int, px, py: int): string
{
	if(popup == nil){
		settitle(titlefor("(no context-menu support)"));
		return "";
	}
	t := targetidx(i);
	if(t == nil)
		return "";
	labels := array[8] of string;
	codes := array[8] of string;
	labels[0] = "Reply";				codes[0] = "reply";
	if(t.favourited){ labels[1] = "Unfavourite"; }	else { labels[1] = "Favourite"; }
	codes[1] = "fav";
	if(t.reblogged){ labels[2] = "Unboost"; }	else { labels[2] = "Boost"; }
	codes[2] = "boost";
	labels[3] = "React…";				codes[3] = "react";
	if(t.bookmarked){ labels[4] = "Remove bookmark"; } else { labels[4] = "Bookmark"; }
	codes[4] = "bookmark";
	labels[5] = "View thread";			codes[5] = "thread";
	labels[6] = "View profile";			codes[6] = "profile";
	labels[7] = "Copy link";			codes[7] = "copy";

	r := pumpmenu(popup->post(window, (px, py), labels, 0));
	if(r >= 0 && r < len codes)
		return codes[r];
	return "";
}

# an image-based emoji picker in its own toplevel: a grid of clickable emoji
# images.  A popup menu can only show text, which renders as missing-glyph boxes
# (no Inferno font covers the emoji blocks), so the picker reuses the same
# inline-image machinery as the reaction chips.  Spawned like the other child
# dialogs (so the feed stays live); delivers (target, chosen-emoji) on `out`,
# with "" for the emoji when dismissed (Escape or window close).
reactpicker(t: ref Status, out: chan of (ref Status, string))
{
	emoji := array[] of {
		"👍", "🔥", "😂", "❤", "😢", "🎉", "👀", "🤔",
		"😭", "😍", "🙏", "💯", "😎", "🤣", "👏", "🥺",
	};
	cols := 8;
	(pw, pwc) := tkclient->toplevel(ctxt, nil, "React", Tkclient->Plain);
	pchan := chan of string;
	tk->namechan(pw, pchan, "pick");
	tkcmd(pw, "frame .g");
	for(k := 0; k < len emoji; k++){
		cell := ".g.e" + string k;
		pos := " -row " + string (k / cols) + " -column " + string (k % cols) +
			" -padx 1 -pady 1";
		img := emojiimage(emoji[k]);
		if(img != nil){
			tkcmd(pw, "panel " + cell + " -bd 1 -relief raised -width " +
				string EMOJIPX + " -height " + string EMOJIPX + " -background " + thCHIPBG);
			tkcmd(pw, "grid " + cell + pos);
			tk->putimage(pw, cell, img, img);
		} else {
			tkcmd(pw, "button " + cell + " -text " + tk->quote(emoji[k]));
			tkcmd(pw, "grid " + cell + pos);
		}
		tkcmd(pw, "bind " + cell + " <Button-1> {send pick " + string k + "}");
	}
	tkcmd(pw, "pack .g -padx 2 -pady 2");
	tkclient->onscreen(pw, nil);
	tkclient->startinput(pw, "kbd" :: "ptr" :: nil);
	for(;;) alt {
	key := <-pw.ctxt.kbd =>
		if(key == 16r1b){		# Escape dismisses
			out <-= (t, "");
			return;		# closes by dropping pw; NOT wmctl("exit")
		}
		tk->keyboard(pw, key);
	p := <-pw.ctxt.ptr =>
		tk->pointer(pw, *p);
	c := <-pw.ctxt.ctl or
	c = <-pw.wreq or
	c = <-pwc =>
		if(c == "exit"){
			out <-= (t, "");
			return;
		}
		tkclient->wmctl(pw, c);
	s := <-pchan =>
		# close by dropping pw (NOT wmctl("exit"), which killgrps the app)
		out <-= (t, emoji[int s]);
		return;
	}
}

# pump the main window's events while a popup menu's grab is active, returning
# the chosen index (or <0 if dismissed).  The popup grab needs the window's
# kbd/ptr events fed to it, so this runs synchronously on the main proc rather
# than blocking on the result chan in a side proc (cf. wm/ftree's post()).
pumpmenu(rc: chan of int): int
{
	for(;;) alt {
	r := <-rc =>
		return r;
	k := <-window.ctxt.kbd =>
		tk->keyboard(window, k);
	p := <-window.ctxt.ptr =>
		tk->pointer(window, *p);
	s := <-window.ctxt.ctl or
	s = <-window.wreq =>
		tkclient->wmctl(window, s);
	}
}

# run an action code on status index i.  px,py are only used by "more" (open the
# context menu at the click position); they are 0 when the source is a menu.
dispatch(i: int, code: string, px, py: int)
{
	t := targetidx(i);
	if(t == nil)
		return;
	case code {
	"fav" or "boost" or "bookmark" =>
		actionon(t, code);
	"react" =>
		spawn reactpicker(t, pickresult);
	"reply" =>
		pre := "";
		if(t.account != nil)
			pre = "@" + t.account.acct + " ";
		spawn composedialog(t.id, pre, postresult);
	"thread" =>
		pushhistory();
		navgen++;
		settitle(titlefor("(loading thread…)"));
		spawn fetchthread(client, t.id, navgen, threadresults);
	"profile" =>
		if(t.account != nil){
			pushhistory();
			navgen++;
			settitle(titlefor("(loading profile…)"));
			spawn fetchprofile(client, t.account.id, "", 0, navgen, profresults);
		}
	"copy" =>
		link := t.url;
		if(link == "")
			link = t.uri;
		if(link != ""){
			tkclient->snarfput(link);
			settitle(titlefor("(link copied)"));
		}
	"more" =>
		mc := runmenu(i, px, py);
		if(mc != "")
			dispatch(i, mc, px, py);
	}
}

# react to / un-react from a status with emoji.  Non-optimistic: we ask the
# server, then adopt its authoritative reaction list (simpler and race-free
# versus the optimistic fav/boost path, and reactions are lower-frequency).
reactdo(t: ref Status, emoji: string, add: int)
{
	if(t == nil)
		return;
	if(me == ""){
		settitle(titlefor("(log in to react)"));
		return;
	}
	verb := "reacting";
	if(!add)
		verb = "removing reaction";
	settitle(titlefor("(" + verb + "…)"));
	spawn doreact(client, t, emoji, add, reactresult);
}

# clicking an existing reaction chip toggles the user's own reaction with that
# emoji (add it if not already reacted, remove it otherwise)
togglereaction(i, j: int)
{
	t := targetidx(i);
	if(t == nil)
		return;
	rl := t.reactions;
	while(j > 0 && rl != nil){
		rl = tl rl;
		j--;
	}
	if(rl == nil)
		return;
	rx := hd rl;
	reactdo(t, rx.name, !rx.me);
}

doreact(c: ref Client, target: ref Status, emoji: string, add: int,
	out: chan of (ref Status, ref Status, string))
{
	ensurecs();
	srv: ref Status;
	err: string;
	if(add)
		(srv, err) = masto->react(c, target.id, emoji);
	else
		(srv, err) = masto->unreact(c, target.id, emoji);
	if(err != nil)
		sys->fprint(sys->fildes(2), "pleromussy: react: %s\n", err);
	out <-= (target, srv, err);
}

# spec is "<statusidx>_<attachidx>"; resolve to the Attachment and view it
openmedia(spec: string)
{
	(n, parts) := sys->tokenize(spec, "_");
	if(n < 2)
		return;
	i := int hd parts;
	j := int hd tl parts;
	if(i < 0 || i >= len statusarr)
		return;
	s := statusarr[i];
	if(s.reblog != nil)
		s = s.reblog;
	l := s.media;
	while(j > 0 && l != nil){
		l = tl l;
		j--;
	}
	if(l == nil)
		return;
	m := hd l;
	if(m.url == ""){
		settitle(titlefor("(attachment has no url)"));
		return;
	}
	if(imageio == nil){
		settitle(titlefor("(no image decoder available)"));
		return;
	}
	# only still images decode; video/audio would download huge blobs
	if(m.atype != "image" && m.atype != "unknown" && m.atype != ""){
		settitle(titlefor("(" + m.atype + " not viewable: " + m.url + ")"));
		return;
	}
	settitle(titlefor("(loading media…)"));
	spawn mediaviewer(m);
}

highlight(i: int)
{
	tkcmd(window, ".view.t tag remove SEL 1.0 end");
	r := tkcmd(window, ".view.t tag ranges s" + string i);
	(n, t) := sys->tokenize(r, " ");
	if(n >= 2){
		tkcmd(window, ".view.t tag add SEL " + hd t + " " + hd tl t);
		tkcmd(window, ".view.t see " + hd t);
	}
	updatefocusbar(i);
}

# keyboard navigation of the timeline: move the selection, open/act on it
keynav(cmd: string)
{
	have := selected >= 0 && selected < len statusarr;
	case cmd {
	"down" =>	movesel(1);
	"up" =>		movesel(-1);
	"top" =>
		if(len statusarr > 0){
			selected = 0;
			highlight(0);
		}
	"open" =>	if(have) dispatch(selected, "thread", 0, 0);
	"fav" =>	if(have) dispatch(selected, "fav", 0, 0);
	"boost" =>	if(have) dispatch(selected, "boost", 0, 0);
	"reply" =>	if(have) dispatch(selected, "reply", 0, 0);
	"profile" =>	if(have) dispatch(selected, "profile", 0, 0);
	"more" =>	loadolder();
	}
}

# move the selection by d posts (clamped), highlighting and scrolling to it
movesel(d: int)
{
	if(len statusarr == 0)
		return;
	ni := selected + d;
	if(selected < 0)
		ni = 0;
	if(ni < 0)
		ni = 0;
	if(ni >= len statusarr)
		ni = len statusarr - 1;
	selected = ni;
	highlight(selected);
}

# begin a fav/boost/bookmark on a given status: toggle optimistically,
# re-render the current view, then confirm with the server in the background
actionon(t: ref Status, kind: string)
{
	if(t == nil)
		return;
	if(me == ""){
		settitle(titlefor("(log in to interact)"));
		return;
	}
	action := "";
	case kind {
	"fav" =>
		if(t.favourited){
			action = "unfavourite"; t.favourited = 0;
			if(t.favourites_count > 0) t.favourites_count--;
		} else {
			action = "favourite"; t.favourited = 1; t.favourites_count++;
		}
	"boost" =>
		if(t.reblogged){
			action = "unreblog"; t.reblogged = 0;
			if(t.reblogs_count > 0) t.reblogs_count--;
		} else {
			action = "reblog"; t.reblogged = 1; t.reblogs_count++;
		}
	"bookmark" =>
		if(t.bookmarked){ action = "unbookmark"; t.bookmarked = 0; }
		else { action = "bookmark"; t.bookmarked = 1; }
	}
	rerender();
	spawn doaction(client, t, action, actionresult);
}

doaction(c: ref Client, target: ref Status, action: string,
	 out: chan of (ref Status, string, ref Status))
{
	ensurecs();
	(srv, err) := masto->statusaction(c, target.id, action);
	if(err != nil)
		sys->fprint(sys->fildes(2), "pleromussy: %s: %s\n", action, err);
	out <-= (target, action, srv);
}

# reconcile a status's interaction fields from the server's authoritative copy
copyinteraction(dst, src: ref Status)
{
	dst.favourited = src.favourited;
	dst.favourites_count = src.favourites_count;
	dst.reblogged = src.reblogged;
	dst.reblogs_count = src.reblogs_count;
	dst.bookmarked = src.bookmarked;
	dst.replies_count = src.replies_count;
}

# undo an optimistic toggle when the server call failed
revertaction(t: ref Status, action: string)
{
	case action {
	"favourite" =>		t.favourited = 0; if(t.favourites_count > 0) t.favourites_count--;
	"unfavourite" =>	t.favourited = 1; t.favourites_count++;
	"reblog" =>		t.reblogged = 0; if(t.reblogs_count > 0) t.reblogs_count--;
	"unreblog" =>		t.reblogged = 1; t.reblogs_count++;
	"bookmark" =>		t.bookmarked = 0;
	"unbookmark" =>		t.bookmarked = 1;
	}
	settitle(titlefor("[action failed]"));
}

# append an older page to the accumulated timeline
appendstatuses(cur, more: list of ref Status): list of ref Status
{
	if(cur == nil)
		return more;
	# walk to the tail and splice; lists are short (pages of 20)
	rev: list of ref Status;
	for(l := cur; l != nil; l = tl l)
		rev = hd l :: rev;
	for(l = more; l != nil; l = tl l)
		rev = hd l :: rev;
	out: list of ref Status;
	for(l = rev; l != nil; l = tl l)
		out = hd l :: out;
	return out;
}

appendnotifs(cur, more: list of ref Notification): list of ref Notification
{
	if(cur == nil)
		return more;
	rev: list of ref Notification;
	for(l := cur; l != nil; l = tl l)
		rev = hd l :: rev;
	for(l = more; l != nil; l = tl l)
		rev = hd l :: rev;
	out: list of ref Notification;
	for(l = rev; l != nil; l = tl l)
		out = hd l :: out;
	return out;
}

a2l(a: array of ref Status): list of ref Status
{
	l: list of ref Status;
	for(i := len a - 1; i >= 0; i--)
		l = a[i] :: l;
	return l;
}

l2a(l: list of ref Status): array of ref Status
{
	a := array[len l] of ref Status;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

# Receive plumbed links and turn them into navigation.  recv() blocks, and so
# does the resolve fetch, so both run here off the event loop; the result is
# handed to the loop on plumbnav.  The message data is a fediverse URL (from
# the URL plumb rule) or an @user@host handle — masto->resolve maps either to a
# status or an account via the server's search.
plumbreader()
{
	for(;;){
		m := Msg.recv();
		if(m == nil)
			return;
		q := string m.data;
		if(q != "")
			spawn doresolve(q);	# resolve off this proc; don't stall recv
	}
}

# resolve one link/handle and hand the result to the event loop
doresolve(q: string)
{
	ensurecs();
	(st, acc, nil) := masto->resolve(client, q);
	if(st != nil)
		plumbnav <-= (0, st.id);
	else if(acc != nil)
		plumbnav <-= (1, acc.id);
}

# does this argument look like something we can resolve (URL or @user@host)?
islink(s: string): int
{
	if(len s > 0 && s[0] == '@')
		return 1;
	for(i := 0; i+2 < len s; i++)
		if(s[i] == ':' && s[i+1] == '/' && s[i+2] == '/')
			return 1;
	return 0;
}

# pull the host out of a scheme://host/... URL or an @user@host handle
hostfromlink(s: string): string
{
	# @user@host
	if(len s > 0 && s[0] == '@'){
		for(i := len s - 1; i > 0; i--)
			if(s[i] == '@')
				return s[i+1:];
		return "";
	}
	# scheme://host/...
	st := 0;
	for(i := 0; i+2 < len s; i++)
		if(s[i] == ':' && s[i+1] == '/' && s[i+2] == '/'){
			st = i+3;
			break;
		}
	if(st == 0)
		return "";
	e := st;
	while(e < len s && s[e] != '/')
		e++;
	return s[st:e];
}

# start ndb/cs if /net/cs isn't already being served, and wait for it
ensurecs()
{
	if(csup())
		return;
	# Only ever start ONE cs of our own.  ensurecs is called from ~10 sites
	# (init + every fetch/media/react proc); without this guard, procs racing
	# before cs comes up each spawn a cs, and the losers print "cs already
	# exists" when they bind /net/cs (and become extra procs killgrp must reap on
	# exit).  csspawned is set before the load so test-and-set is atomic under
	# cooperative scheduling (no yield in between).
	if(csspawned)
		return;
	csspawned = 1;
	spawn startcs();
	for(i := 0; i < 50 && !csup(); i++)
		sys->sleep(100);
}

# Start cs with a clean file-descriptor table.  cs does FORKFD|NEWPGRP (cs.b),
# which would otherwise *copy* — and so pin open — our /chan/wmctl connection to
# the window manager.  Because cs detaches into its own process group it
# survives the killgrp we issue when our window closes; that dangling reference
# then keeps the wm from ever seeing us disconnect, so it never reaps our window
# — the "hang on close".  Dropping all but the standard fds (cs builds its own
# service channels and uses the namespace, not inherited fds) breaks the
# reference so the close is clean.
startcs()
{
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	cs := load Command "/dis/ndb/cs.dis";
	if(cs == nil)
		return;
	cs->init(nil, "cs" :: nil);
}

csup(): int
{
	fd := sys->open("/net/cs", Sys->ORDWR);
	return fd != nil;
}

authorname(s: ref Status): string
{
	if(s.account == nil)
		return "?";
	if(s.account.display_name != "")
		return s.account.display_name;
	return s.account.username;
}

ins(s, tag: string)
{
	tkcmd(window, ".view.t insert end " + tk->quote(s) + " " + tag);
}

settitle(s: string)
{
	tkcmd(window, ".bot.msg configure -text " + tk->quote(s));
	tkclient->settitle(window, wmtitle());	# the wm title bar shows the identity
}

# show the focused post's URL in the snarfable bottom entry
updatefocusbar(i: int)
{
	tkcmd(window, ".bot.url delete 0 end");
	u := focusurl(i);
	if(u != "")
		tkcmd(window, ".bot.url insert 0 " + tk->quote(u));
}

# the canonical URL of the post at index i (the boosted post for a boost)
focusurl(i: int): string
{
	if(i < 0 || i >= len statusarr)
		return "";
	s := statusarr[i];
	if(s == nil)
		return "";
	if(s.reblog != nil)
		s = s.reblog;
	if(s.url != "")
		return s.url;
	return s.uri;
}

# a human page name for the current view
pagename(): string
{
	case curview {
	"notifs" =>	return "Notifications";
	"thread" =>	return "Thread";
	"profile" =>	return "Profile";
	* =>
		if(view == "home")
			return "Home";
		return "Public";
	}
}

# the window-manager title bar: "Pleromussy — as @user on Page"
wmtitle(): string
{
	who := acctlabel;
	if(me != "")
		who = "@" + me;
	if(who == "")
		return "Pleromussy";
	return "Pleromussy — as " + who + " on " + pagename();
}

# refresh the theme-derived colour globals from the live system theme
loadthemecols()
{
	thINK = themecol("fg", "#202020");
	thMUTED = themecol("disablefg", "#808080");
	thACCENT = themecol("select", "#1a4ba0");
}

themecol(key, def: string): string
{
	v := tkclient->themecolour(window, key);
	if(v == nil || v == "")
		return def;
	return v;
}

# (Re)configure the .view.t text tags from the current theme.  .view.t is
# -state disabled, so a tag with no explicit foreground renders in the env's
# *disabled* colour (a light grey, illegible on a dark theme) -- every text tag
# therefore sets a foreground.  Called at start-up and on every theme push
# (tag colours are not covered by "theme reapply").
mktags()
{
	loadthemecols();
	tkcmd(window, ".view.t tag configure NAME -font " + NAMEFONT + " -foreground " + thINK);
	tkcmd(window, ".view.t tag configure META -font " + METAFONT + " -foreground " + thMUTED);
	tkcmd(window, ".view.t tag configure BODY -font " + BODYFONT + " -foreground " + thINK);
	tkcmd(window, ".view.t tag configure MEDIA -font " + METAFONT + " -foreground " + thACCENT);
	# inline action buttons: a raised, bordered, shaded span (fixed light chip)
	tkcmd(window, ".view.t tag configure BTN -font " + METAFONT +
		" -foreground " + thCHIPFG + " -background " + thCHIPBG + " -relief raised -borderwidth 1");
	# per-post padding: left/right margins + a little vertical breathing room
	tkcmd(window, ".view.t tag configure POST -lmargin1 8 -lmargin2 8 -rmargin 8"+
		" -spacing1 3 -spacing3 3");
	# faint rule between posts
	tkcmd(window, ".view.t tag configure SEP -font " + METAFONT + " -foreground " + thMUTED);
	# emoji-reaction chips: a rounded shaded span; RXME (the user's own
	# reactions) is tinted blue to stand out from RXN (others')
	tkcmd(window, ".view.t tag configure RXN -font " + METAFONT +
		" -foreground " + thCHIPFG + " -background " + thCHIPBG + " -relief raised -borderwidth 1");
	tkcmd(window, ".view.t tag configure RXME -font " + METAFONT +
		" -foreground " + thCHIPFG + " -background " + thCHIPMEBG + " -relief raised -borderwidth 1");
	tkcmd(window, ".view.t tag configure SEL -background " + thSELBG + " -foreground #202020");
	# the inline "load older posts" affordance
	tkcmd(window, ".view.t tag configure MORE -font " + METAFONT +
		" -foreground " + thACCENT + " -justify center -spacing1 4 -spacing3 4");
	# thread reply-depth: D<d> indents a reply by its depth in the chain so the
	# thread reads as a tree (used in place of POST in the thread view)
	for(d := 0; d <= MAXDEPTH; d++){
		m := 8 + d*16;
		tkcmd(window, ".view.t tag configure D" + string d +
			" -lmargin1 " + string m + " -lmargin2 " + string m +
			" -rmargin 8 -spacing1 3 -spacing3 3");
	}
	tkcmd(window, ".view.t tag raise SEL");
	tkcmd(window, ".view.t tag raise BTN");
	tkcmd(window, ".view.t tag raise RXN");
	tkcmd(window, ".view.t tag raise RXME");
}

tkcmd(top: ref Tk->Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if(e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "tk error %s on '%s'\n", e, s);
	return e;
}

# show the date/time portion of an ISO 8601 timestamp, "T" -> " "
reltime(iso: string): string
{
	if(len iso < 16)
		return iso;
	s := iso[0:16];
	for(i := 0; i < len s; i++)
		if(s[i] == 'T')
			s[i] = ' ';
	return s;
}

# crude HTML -> text: tags dropped (block tags become newlines), entities
# decoded, runs of spaces collapsed.
htmltext(in: string): string
{
	out := "";
	n := len in;
	i := 0;
	while(i < n){
		c := in[i];
		if(c == '<'){
			j := i + 1;
			while(j < n && in[j] != '>')
				j++;
			tagn := str->tolower(in[i + 1:j]);
			if(str->prefix("br", tagn) || str->prefix("/p", tagn) ||
			   str->prefix("p", tagn) || str->prefix("/div", tagn) ||
			   str->prefix("/h", tagn))
				out[len out] = '\n';
			i = j + 1;
		} else if(c == '&'){
			j := i + 1;
			while(j < n && in[j] != ';' && j - i < 12)
				j++;
			if(j < n && in[j] == ';'){
				out += entity(in[i + 1:j]);
				i = j + 1;
			} else {
				out[len out] = c;
				i++;
			}
		} else {
			if(c == '\t' || c == '\r')
				c = ' ';
			out[len out] = c;
			i++;
		}
	}
	return collapse(out);
}

entity(e: string): string
{
	if(len e == 0)
		return "";
	if(e[0] == '#'){
		v := 0;
		if(len e > 1 && (e[1] == 'x' || e[1] == 'X')){
			for(i := 2; i < len e; i++)
				v = v * 16 + hexdig(e[i]);
		} else
			v = int e[1:];
		if(v > 0)
			return sys->sprint("%c", v);
		return "";
	}
	case e {
	"amp" =>	return "&";
	"lt" =>		return "<";
	"gt" =>		return ">";
	"quot" =>	return "\"";
	"apos" =>	return "'";
	"nbsp" =>	return " ";
	"mdash" =>	return "—";
	"hellip" =>	return "…";
	}
	return "";
}

hexdig(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

# collapse runs of spaces; cap consecutive blank lines at one
collapse(s: string): string
{
	out := "";
	sp := 0;
	nl := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == ' '){
			if(!sp && nl == 0)
				out[len out] = ' ';
			else if(!sp)
				out[len out] = ' ';
			sp = 1;
			continue;
		}
		if(c == '\n'){
			if(nl < 2)
				out[len out] = '\n';
			nl++;
			sp = 0;
			continue;
		}
		out[len out] = c;
		sp = 0;
		nl = 0;
	}
	# trim leading/trailing whitespace
	while(len out > 0 && (out[0] == '\n' || out[0] == ' '))
		out = out[1:];
	while(len out > 0 && (out[len out - 1] == '\n' || out[len out - 1] == ' '))
		out = out[0:len out - 1];
	return out;
}
