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
host:	string;			# current instance hostname
view:	string;			# "public", "home" or "notifs"
me:	string;			# acct of the logged-in user, "" if anonymous
statuses: list of ref Status;	# accumulated timeline, newest first
statusarr: array of ref Status;	# flattened view, parallel to per-block s<i> tags
selected: int;			# index into statusarr, -1 = nothing selected

# which renderer owns the view right now, so post-action re-renders and Back
# target the right content instead of always snapping to the timeline
curview: string;		# "timeline" | "notifs" | "thread" | "profile"
notifs:	list of ref Notification;	# backing the notifs view, newest first
threadarr: array of ref Status;	# backing the thread view
threadfocus: int;		# index in threadarr of the focused status
profacc: ref Account;		# backing the profile view
profarr: list of ref Status;	# the profile's statuses, newest first
nextid:	string;			# max_id for the next page of the current view

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

BODYFONT:	con "/fonts/lucidasans/unicode.8.font";
NAMEFONT:	con "/fonts/lucidasans/unicode.10.font";
METAFONT:	con "/fonts/lucidasans/unicode.7.font";

tkconfig := array[] of {
	"frame .top",
	"button .top.public -text Public -command {send nav public}",
	"button .top.home -text Home -command {send nav home}",
	"button .top.notifs -text Notifs -command {send nav notifs}",
	"button .top.new -text {New post} -command {send nav compose}",
	"button .top.back -text {◂ Back} -command {send nav back}",
	"label .top.title -text {pleromussy} -anchor w",
	"button .top.refresh -text Refresh -command {send nav refresh}",
	"button .top.more -text {More posts} -command {send nav more}",
	"button .top.login -text Login -command {send nav login}",
	"pack .top.login .top.more .top.refresh -side right",
	"pack .top.public .top.home .top.notifs .top.new .top.back -side left",
	"pack .top.title -side left -fill x -expand 1 -padx 4",
	"pack .top -fill x",
	"frame .view",
	"text .view.t -state disabled -width 0 -height 0 -bg white -wrap word"+
		" -yscrollcommand {.view.yscroll set} -padx 2 -pady 2",
	"bind .view.t <Button-1> {send sel %x %y}",
	"bind .view.t <Double-Button-1> {send dsel %x %y}",
	"bind .view.t <Button-3> {send ctx %x %y}",
	"scrollbar .view.yscroll -orient vertical -command {.view.t yview}",
	"pack .view.yscroll -fill y -side left",
	"pack .view.t -expand 1 -fill both",
	"pack .view -expand 1 -fill both",
	"pack propagate . 0",
	". configure -width 620 -height 660",
};

logincfg := array[] of {
	"label .hl -text {Instance:} -anchor w",
	"entry .host -bg white",
	"label .ul -text {Username:} -anchor w",
	"entry .user -bg white",
	"label .pl -text {Password:} -anchor w",
	"entry .pass -bg white -show *",
	"label .status -text { } -anchor w -foreground #a00000",
	"frame .b",
	"button .b.ok -text Login -command {send b login}",
	"button .b.cancel -text Cancel -command {send b cancel}",
	"pack .b.cancel .b.ok -side right",
	"bind .user <Key-\n> {focus .pass}",
	"bind .pass <Key-\n> {send b login}",
	"pack .hl .host .ul .user .pl .pass .status .b -fill x -side top -padx 4 -pady 2",
	"pack propagate . 0",
	". configure -width 320 -height 210",
};

composecfg := array[] of {
	"label .l -text {Compose} -anchor w",
	"frame .tf",
	"text .body -width 44 -height 7 -wrap word -bg white"+
		" -yscrollcommand {.tf.sb set}",
	"scrollbar .tf.sb -orient vertical -command {.body yview}",
	"pack .tf.sb -in .tf -side right -fill y",
	"pack .body -in .tf -side left -fill both -expand 1",
	"label .vl -text {Visibility (public/unlisted/private/direct):} -anchor w",
	"entry .vis -bg white",
	"label .status -text { } -anchor w -foreground #a00000",
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
	view = "public";
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-home" =>	view = "home";
		"-public" =>	view = "public";
		* =>		host = hd a;
		}
	}

	sess := masto->loadsession(host);
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
	for(i := 0; i < len tkconfig; i++)
		tkcmd(window, tkconfig[i]);
	mktags();
	tkclient->onscreen(window, nil);
	tkclient->startinput(window, "kbd" :: "ptr" :: nil);

	results = chan of ref Result;
	notifresults = chan of ref NResult;
	threadresults = chan of ref TResult;
	profresults = chan of ref PResult;
	postresult = chan of ref Status;
	actionresult = chan of (ref Status, string, ref Status);
	loginresult := chan of ref Session;
	whoami := chan of ref Account;
	nextid = "";
	curview = "timeline";

	settitle(titlefor("(loading…)"));
	spawn fetch(client, view, "", 0, results);
	if(token != "")			# verify the saved session, show who we are
		spawn verify(client, whoami);
	else				# no saved session: offer to log in
		spawn logindialog(host, loginresult);

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
	xy := <-sel =>
		selectat(xy);
	xy := <-dsel =>
		doubleclick(xy);
	xy := <-ctx =>
		contextclick(xy);
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
			case curview {
			"thread" =>
				settitle(titlefor("(thread has no more pages)"));
			* =>
				if(nextid == "")
					settitle(titlefor("(no more posts)"));
				else {
					settitle(titlefor("(loading more…)"));
					case curview {
					"notifs" =>	spawn fetchnotifs(client, nextid, 1, notifresults);
					"profile" =>	if(profacc != nil) spawn fetchprofile(client, profacc.id, nextid, 1, navgen, profresults);
					* =>		spawn fetch(client, view, nextid, 1, results);
					}
				}
			}
		"back" =>
			goback();
		"login" =>
			spawn logindialog(host, loginresult);
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
	newsess := <-loginresult =>
		if(newsess != nil){
			host = newsess.host;
			me = "";
			client = masto->client(host, newsess.token);
			if((serr := masto->savesession(newsess)) != nil)
				settitle(titlefor("[save: " + serr + "]"));
			else {
				selected = -1;
				settitle(titlefor("(loading…)"));
				spawn fetch(client, view, "", 0, results);
				spawn verify(client, whoami);
			}
		}
	acc := <-whoami =>
		if(acc != nil){
			me = acc.acct;
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
titlefor(extra: string): string
{
	t := host + " — " + view;
	if(me != "")
		t += "  (@" + me + ")";
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
	busy := 0;
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
		"cancel" =>
			out <-= nil;
			return;
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

# run the OAuth password grant off the dialog's UI thread; nil on any error
dologin(h, user, pass: string, out: chan of ref Session)
{
	ensurecs();
	c := masto->client(h, "");
	(sess, err) := masto->login(c, user, pass, "");
	if(err != nil)
		sys->fprint(sys->fildes(2), "pleromussy: login: %s\n", err);
	out <-= sess;
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

# decode encoded image bytes into a Draw image, downscaling to fit the cap
decodeimage(data: array of byte): (ref Image, string)
{
	(w, h, rgba, err) := imageio->decode(data);
	if(rgba == nil)
		return (nil, "decode: " + err);
	(dw, dh, drgba) := fit(w, h, rgba, MAXIMGW, MAXIMGH);
	img := ctxt.display.newimage(Rect(Point(0,0), Point(dw,dh)), draw->ABGR32, 0, draw->White);
	if(img == nil)
		return (nil, "newimage failed");
	img.writepixels(img.r, drgba);
	return (img, nil);
}

# nearest-neighbour downscale of RGBA8 pixels to fit within maxw x maxh; a
# small-enough image is returned untouched
fit(w, h: int, rgba: array of byte, maxw, maxh: int): (int, int, array of byte)
{
	if(w <= maxw && h <= maxh)
		return (w, h, rgba);
	s := real maxw / real w;
	sh := real maxh / real h;
	if(sh < s)
		s = sh;
	dw := int(real w * s);
	dh := int(real h * s);
	if(dw < 1) dw = 1;
	if(dh < 1) dh = 1;
	out := array[dw * dh * 4] of byte;
	for(y := 0; y < dh; y++){
		sy := int(real y / s);
		if(sy >= h) sy = h - 1;
		drow := y * dw * 4;
		srow := sy * w * 4;
		for(x := 0; x < dw; x++){
			sx := int(real x / s);
			if(sx >= w) sx = w - 1;
			si := srow + sx * 4;
			di := drow + x * 4;
			out[di] = rgba[si];
			out[di+1] = rgba[si+1];
			out[di+2] = rgba[si+2];
			out[di+3] = rgba[si+3];
		}
	}
	return (dw, dh, out);
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
	tkcmd(window, ".view.t tag add POST " + startidx + " " + endidx);
	# the separator newline sits OUTSIDE the s<i> range so clicking it is inert
	ins(SEPRULE, "SEP");
}

SEPRULE: con "────────────────────────────────────────────────────────\n";

# rebuild the whole text widget from the accumulated `statuses`, tagging each
# status's block with a unique s<i> tag so clicks can be mapped back to it
redraw()
{
	statusarr = l2a(statuses);
	tkcmd(window, ".view.t delete 1.0 end");
	for(i := 0; i < len statusarr; i++)
		renderblock(i, statusarr[i]);
	if(selected >= 0 && selected < len statusarr)
		highlight(selected);
	tkcmd(window, "update");
}

# the notifications view: a header line per notification, plus the related
# status as a normal (selectable) block when there is one
rendernotifs()
{
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
	for(i := 0; i < len threadarr; i++)
		renderblock(i, threadarr[i]);
	if(selected >= 0 && selected < len statusarr)
		highlight(selected);
	tkcmd(window, "update");
}

# the profile view: an account header (name/handle/bio) then that account's
# statuses as selectable blocks
renderprofile()
{
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
	# a media line takes priority: open the attachment rather than select
	for(l := tags; l != nil; l = tl l){
		tag := hd l;
		if(len tag > 3 && tag[0:3] == "med"){
			openmedia(tag[3:]);
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
		# a button or media span owns the double-click; ignore it here
		if(len tag >= 2 && tag[0] == 'b' && tag[1] >= '0' && tag[1] <= '9')
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
		dispatch(i, code, 0, 0);
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
	labels := array[7] of string;
	codes := array[7] of string;
	labels[0] = "Reply";				codes[0] = "reply";
	if(t.favourited){ labels[1] = "Unfavourite"; }	else { labels[1] = "Favourite"; }
	codes[1] = "fav";
	if(t.reblogged){ labels[2] = "Unboost"; }	else { labels[2] = "Boost"; }
	codes[2] = "boost";
	if(t.bookmarked){ labels[3] = "Remove bookmark"; } else { labels[3] = "Bookmark"; }
	codes[3] = "bookmark";
	labels[4] = "View thread";			codes[4] = "thread";
	labels[5] = "View profile";			codes[5] = "profile";
	labels[6] = "Copy link";			codes[6] = "copy";

	rc := popup->post(window, (px, py), labels, 0);
	for(;;) alt {
	r := <-rc =>
		if(r >= 0 && r < len codes)
			return codes[r];
		return "";
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
			dispatch(i, mc, 0, 0);
	}
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

# start ndb/cs if /net/cs isn't already being served, and wait for it
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
	tkcmd(window, ".top.title configure -text " + tk->quote(s));
}

mktags()
{
	tkcmd(window, ".view.t tag configure NAME -font " + NAMEFONT + " -foreground #102a54");
	tkcmd(window, ".view.t tag configure META -font " + METAFONT + " -foreground #808080");
	tkcmd(window, ".view.t tag configure BODY -font " + BODYFONT);
	tkcmd(window, ".view.t tag configure MEDIA -font " + METAFONT + " -foreground #1a4ba0");
	# inline action buttons: a raised, bordered, shaded span
	tkcmd(window, ".view.t tag configure BTN -font " + METAFONT +
		" -foreground #182860 -background #e8e8ec -relief raised -borderwidth 1");
	# per-post padding: left/right margins + a little vertical breathing room
	tkcmd(window, ".view.t tag configure POST -lmargin1 8 -lmargin2 8 -rmargin 8"+
		" -spacing1 3 -spacing3 3");
	# faint rule between posts
	tkcmd(window, ".view.t tag configure SEP -font " + METAFONT + " -foreground #dcdce2");
	tkcmd(window, ".view.t tag configure SEL -background #d7e6ff");
	tkcmd(window, ".view.t tag raise SEL");
	tkcmd(window, ".view.t tag raise BTN");
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
