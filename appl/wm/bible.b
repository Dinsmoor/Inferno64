implement Bible;

#
# wm/bible -- a King James Bible reader.
#
# A thin Tk client over the biblefs namespace (/mnt/bible): it holds no data
# model of its own.  Navigation reads the books tree, a chapter is one read of
# the `lookup` query file, search/cross-references are the `search`/`xref` query
# files, and a right-clicked word is looked up in `define/<word>`.  Mount the
# data first (wmsetup does this on boot):
#
#	mount {biblefs} /mnt/bible
#	wm/bible
#
# Phase 1+2: read-only reader (navigation, chapter view, search, cross-refs,
# dictionary).  Notes/highlights (a separate notefs) come later.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	Context: import Draw;

include "tk.m";
	tk: Tk;

include "tkclient.m";
	tkclient: Tkclient;

include "string.m";
	str: String;

Bible: module
{
	init: fn(ctxt: ref Context, args: list of string);
};

BIBLE:	con "/mnt/bible";

# fonts: a serif body for readability, sans for the UI chrome
BODYFONT:	con "/fonts/lucida/unicode.14.font";
HEADFONT:	con "/fonts/lucida/unicode.20.font";
VNUMFONT:	con "/fonts/lucida/unicode.10.font";
UIFONT:		con "/fonts/lucidasans/unicode.8.font";
CTXHEADFONT:	con "/fonts/lucidasans/unicode.10.font";

window:	ref Tk->Toplevel;

# loaded once from /mnt/bible/books
booknames:	array of string;	# canonical order, index 0..65
bookchaps:	array of int;		# chapters per book

# current location
curbook:	int;			# index into booknames
curchap:	int;			# 1-based
curverse:	int;			# selected verse, 0 = none
curvnums:	array of int;		# verse numbers shown in the read pane
mode:		string;			# "read" or "search"
navmode:	string;			# nav list contents: "books" or "chaps"
navbook:	int;			# book whose chapters the nav list shows

# click targets for the result/context panes
searchres:	array of (int, int, int);	# (bookidx, chap, verse)
ctxrefs:	array of (int, int, int);

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	str = load String String->PATH;
	if(tk == nil || tkclient == nil || str == nil){
		sys->fprint(sys->fildes(2), "wm/bible: load failed: %r\n");
		raise "fail:load";
	}
	sys->pctl(Sys->NEWPGRP, nil);

	if(!loadbooks()){
		sys->fprint(sys->fildes(2),
			"wm/bible: cannot read %s -- is biblefs mounted?\n", BIBLE);
		raise "fail:nodata";
	}

	tkclient->init();
	winctl := chan of string;
	(window, winctl) = tkclient->toplevel(ctxt, nil, "Bible", Tkclient->Resize | Tkclient->Hide);

	nav := chan of string;		tk->namechan(window, nav, "nav");
	gochan := chan of string;	tk->namechan(window, gochan, "go");
	srch := chan of string;		tk->namechan(window, srch, "search");
	navpick := chan of string;	tk->namechan(window, navpick, "navpick");
	rsel := chan of string;		tk->namechan(window, rsel, "rsel");
	rdsel := chan of string;	tk->namechan(window, rdsel, "rdsel");
	xsel := chan of string;		tk->namechan(window, xsel, "xsel");
	keyc := chan of string;		tk->namechan(window, keyc, "key");

	for(i := 0; i < len tkconfig; i++)
		tkcmd(tkconfig[i]);
	mktags();

	navmode = "books";
	navbook = -1;
	shownbooks();

	tkclient->onscreen(window, nil);
	tkclient->startinput(window, "kbd" :: "ptr" :: nil);
	tkcmd("focus .read.t");

	# open on the verse of the day, falling back to Genesis 1:1
	mode = "read";
	(b, c, v) := votd();
	if(b < 0){
		b = 0; c = 1; v = 0;
	}
	navigateto(b, c, v);

	for(;;) alt {
	s := <-window.ctxt.kbd =>
		tk->keyboard(window, s);
	s := <-window.ctxt.ptr =>
		tk->pointer(window, *s);
	s := <-window.ctxt.ctl or
	s = <-window.wreq or
	s = <-winctl =>
		tkclient->wmctl(window, s);
	cm := <-nav =>
		case cm {
		"prev" =>	stepchapter(-1);
		"next" =>	stepchapter(1);
		"search" =>	dosearch();
		}
	<-gochan =>
		dogoto();
	<-srch =>
		dosearch();
	<-navpick =>
		onnavpick();
	xy := <-rsel =>
		onreadclick(xy);
	xy := <-rdsel =>
		ondefine(xy);
	xy := <-xsel =>
		onctxclick(xy);
	k := <-keyc =>
		onkey(k);
	}
}

tkconfig := array[] of {
	"frame .top",
	"button .top.prev -text {‹ Prev} -command {send nav prev}",
	"button .top.next -text {Next ›} -command {send nav next}",
	"label .top.gol -text {Go:}",
	# entries render at their natural (tiny) size -- a fixed-size frame with
	# propagate 0 gives them a visible, clickable width (see DEV_TK_EXTENSIONS).
	"frame .top.gof -width 120 -height 22",
	"pack propagate .top.gof 0",
	"entry .top.gof.e -bg white",
	"bind .top.gof.e <Button-1> {focus .top.gof.e}",
	"bind .top.gof.e <Key-\n> {send go}",
	"pack .top.gof.e -fill both -expand 1",
	"label .top.sl -text {Search:}",
	"frame .top.sf -width 150 -height 22",
	"pack propagate .top.sf 0",
	"entry .top.sf.e -bg white",
	"bind .top.sf.e <Button-1> {focus .top.sf.e}",
	"bind .top.sf.e <Key-\n> {send search}",
	"pack .top.sf.e -fill both -expand 1",
	"button .top.sb -text Search -command {send search}",
	"pack .top.prev .top.next .top.gol .top.gof -side left -padx 2",
	"pack .top.sb .top.sf .top.sl -side right -padx 2",
	"pack .top -fill x -pady 2",

	# left: a single drill-down list (books -> chapters -> back).  Inferno Tk's
	# packer won't give two stacked listboxes independent fixed heights, so one
	# list that switches contents is the robust shape (see DEV_TK_EXTENSIONS.md).
	"frame .nav -width 160",
	"pack propagate .nav 0",
	"label .nav.title -text Books -anchor w -font " + CTXHEADFONT,
	"pack .nav.title -side top -fill x",
	"frame .nav.lf -width 160 -height 560",
	"pack propagate .nav.lf 0",
	"scrollbar .nav.lf.sb -orient vertical -command {.nav.list yview}",
	"listbox .nav.list -selectmode browse -width 18 -bg white -font " + UIFONT +
		" -yscrollcommand {.nav.lf.sb set}",
	"bind .nav.list <ButtonRelease-1> {send navpick}",
	"pack .nav.lf.sb -side right -fill y",
	"pack .nav.list -side left -fill both -expand 1",
	"pack .nav.lf -side top -fill both -expand 1",

	# right: context (cross-references / dictionary)
	"frame .ctx -width 230",
	"pack propagate .ctx 0",
	"label .ctx.l -text {Context} -anchor w -font " + CTXHEADFONT,
	"frame .ctx.tf",
	"scrollbar .ctx.tf.sb -orient vertical -command {.ctx.t yview}",
	"text .ctx.t -state disabled -width 26 -height 10 -bg white -wrap word -padx 4 -pady 2" +
		" -yscrollcommand {.ctx.tf.sb set}",
	"bind .ctx.t <Button-1> {send xsel %x %y}",
	"pack .ctx.tf.sb -side right -fill y",
	"pack .ctx.t -side left -fill both -expand 1",
	"pack .ctx.l -fill x",
	"pack .ctx.tf -fill both -expand 1",

	# center: the reading pane
	"frame .read",
	"scrollbar .read.sb -orient vertical -command {.read.t yview}",
	"text .read.t -state disabled -bg white -wrap word -padx 8 -pady 4" +
		" -yscrollcommand {.read.sb set}",
	"bind .read.t <Button-1> {focus .read.t; send rsel %x %y}",
	# right-click a word for its dictionary definition (Button-3 doesn't also
	# fire Button-1, so it never races with verse selection / cross-refs)
	"bind .read.t <Button-3> {send rdsel %x %y}",
	"bind .read.t <Key-\uE012> {send key up}",
	"bind .read.t <Key-\uE013> {send key down}",
	"bind .read.t <Key-j> {send key down}",
	"bind .read.t <Key-k> {send key up}",
	"bind .read.t <Key-n> {send key next}",
	"bind .read.t <Key-p> {send key prev}",
	"bind .read.t <Key-/> {send key search}",
	"pack .read.sb -side left -fill y",
	"pack .read.t -side left -fill both -expand 1",

	# assemble: nav left, ctx right, read fills the middle
	"frame .main",
	"pack .nav -in .main -side left -fill y",
	"pack .ctx -in .main -side right -fill y",
	"pack .read -in .main -side left -fill both -expand 1",
	"pack .main -fill both -expand 1",

	"frame .bot",
	"label .bot.msg -anchor w -font " + UIFONT,
	"pack .bot.msg -side left -padx 4",
	"pack .bot -fill x",

	"pack propagate . 0",
	". configure -width 720 -height 640",
};

mktags()
{
	tkcmd(".read.t tag configure HEAD -font " + HEADFONT + " -foreground #202020 -spacing3 8");
	tkcmd(".read.t tag configure BODY -font " + BODYFONT + " -lmargin1 4 -lmargin2 4" +
		" -rmargin 4 -spacing1 2 -spacing3 2");
	tkcmd(".read.t tag configure VNUM -font " + VNUMFONT + " -foreground #3060a0 -offset 4");
	tkcmd(".read.t tag configure SEL -background #fff0b0");
	tkcmd(".read.t tag configure RES -font " + BODYFONT + " -lmargin1 4 -lmargin2 16" +
		" -spacing1 2 -spacing3 2");
	tkcmd(".read.t tag configure REF -font " + VNUMFONT + " -foreground #3060a0");
	tkcmd(".read.t tag raise SEL");
	tkcmd(".ctx.t tag configure XHEAD -font " + CTXHEADFONT + " -foreground #404040 -spacing3 4");
	tkcmd(".ctx.t tag configure XREF -font " + VNUMFONT + " -foreground #3060a0 -spacing1 2");
	tkcmd(".ctx.t tag configure XBODY -font " + UIFONT + " -lmargin1 4 -lmargin2 4 -spacing3 4");
	tkcmd(".ctx.t tag configure DEF -font " + UIFONT + " -lmargin1 4 -lmargin2 4 -spacing3 4");
}

#
# data access -- everything is a file read against /mnt/bible
#

loadbooks(): int
{
	names := dirnames(BIBLE + "/books");
	if(names == nil)
		return 0;
	booknames = names;
	bookchaps = array[len names] of int;
	for(i := 0; i < len names; i++){
		info := readfile(BIBLE + "/books/" + names[i] + "/info");
		# info: name\ttestament\tgenre\t<n> chapters\t<n> verses
		(nf, f) := sys->tokenize(info, "\t");
		bookchaps[i] = 1;
		if(nf >= 4){
			(nn, ff) := sys->tokenize(hd tl tl tl f, " ");
			if(nn >= 1)
				bookchaps[i] = int hd ff;
		}
	}
	return 1;
}

votd(): (int, int, int)
{
	line := readfile(BIBLE + "/votd");
	return parsetsvfirst(line);
}

# parse the first TSV verse line "book\tchap\tverse\ttext" -> (bookidx,chap,verse)
parsetsvfirst(s: string): (int, int, int)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n'){
			s = s[0:i];
			break;
		}
	(nf, f) := sys->tokenize(s, "\t");
	if(nf < 4)
		return (-1, 0, 0);
	bi := bookindex(hd f);
	if(bi < 0)
		return (-1, 0, 0);
	return (bi, int hd tl f, int hd tl tl f);
}

bookindex(name: string): int
{
	for(i := 0; i < len booknames; i++)
		if(booknames[i] == name)
			return i;
	return -1;
}

#
# navigation + chapter rendering
#

navigateto(bi, chap, verse: int)
{
	if(bi < 0 || bi >= len booknames)
		return;
	curbook = bi;
	if(chap < 1)
		chap = 1;
	if(chap > bookchaps[bi])
		chap = bookchaps[bi];
	curchap = chap;
	mode = "read";

	# keep the nav list following the current book's chapters
	if(navmode != "chaps" || navbook != bi)
		shownchaps(bi);
	tkcmd(".nav.list selection clear 0 end");
	tkcmd(".nav.list selection set " + string chap);	# item 0 is "‹ Books"
	tkcmd(".nav.list see " + string chap);

	renderchapter();
	if(verse > 0)
		selectverse(verse);
	else
		curverse = 0;
	setref();
}

renderchapter()
{
	tsv := query(BIBLE + "/lookup", booknames[curbook] + " " + string curchap);
	(nl, lines) := sys->tokenize(tsv, "\n");
	curvnums = array[nl] of int;
	n := 0;

	tkcmd(".read.t delete 1.0 end");
	ins(".read.t", booknames[curbook] + " " + string curchap + "\n", "HEAD");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, "\t");
		if(nf < 4)
			continue;
		v := int hd tl tl f;
		text := hd tl tl tl f;
		startidx := tkcmd(".read.t index {end -1c}");
		ins(".read.t", string v + " ", "VNUM");
		ins(".read.t", text + "\n", "BODY");
		endidx := tkcmd(".read.t index {end -1c}");
		tkcmd(".read.t tag add v" + string v + " " + startidx + " " + endidx);
		curvnums[n++] = v;
	}
	curvnums = curvnums[0:n];
	tkcmd(".read.t yview 1.0");
	tkcmd("update");
}

stepchapter(d: int)
{
	c := curchap + d;
	b := curbook;
	if(c < 1){
		if(b > 0){
			b--;
			c = bookchaps[b];
		} else
			c = 1;
	} else if(c > bookchaps[b]){
		if(b < len booknames - 1){
			b++;
			c = 1;
		} else
			c = bookchaps[b];
	}
	navigateto(b, c, 0);
}

selectverse(v: int)
{
	curverse = v;
	tkcmd(".read.t tag remove SEL 1.0 end");
	r := tkcmd(".read.t tag ranges v" + string v);
	(n, t) := sys->tokenize(r, " ");
	if(n >= 2){
		tkcmd(".read.t tag add SEL " + hd t + " " + hd tl t);
		tkcmd(".read.t see " + hd t);
	}
	tkcmd("update");
	setref();
	loadxrefs();
}

setref()
{
	rs := booknames[curbook] + " " + string curchap;
	if(curverse > 0)
		rs += ":" + string curverse;
	tkclient->settitle(window, "Bible — " + rs);
	status(rs);
}

#
# cross-references (right pane)
#

loadxrefs()
{
	if(curverse == 0)
		return;
	refstr := booknames[curbook] + " " + string curchap + ":" + string curverse;
	tsv := query(BIBLE + "/xref", refstr);
	ctxclear();
	ins(".ctx.t", "Cross references\n", "XHEAD");
	(nl, lines) := sys->tokenize(tsv, "\n");
	ctxrefs = array[nl] of (int, int, int);
	n := 0;
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, "\t");
		if(nf < 4)
			continue;
		bi := bookindex(hd f);
		if(bi < 0)
			continue;
		c := int hd tl f;
		v := int hd tl tl f;
		text := hd tl tl tl f;
		startidx := tkcmd(".ctx.t index {end -1c}");
		ins(".ctx.t", hd f + " " + string c + ":" + string v + "\n", "XREF");
		ins(".ctx.t", elide(text, 90) + "\n", "XBODY");
		endidx := tkcmd(".ctx.t index {end -1c}");
		tkcmd(".ctx.t tag add x" + string n + " " + startidx + " " + endidx);
		ctxrefs[n++] = (bi, c, v);
	}
	ctxrefs = ctxrefs[0:n];
	if(n == 0)
		ins(".ctx.t", "(none)\n", "XBODY");
	tkcmd(".ctx.t yview 1.0");
	tkcmd("update");
}

#
# dictionary (right pane), on double-click of a word
#

ondefine(xy: string)
{
	(nx, t) := sys->tokenize(xy, " ");
	if(nx < 2)
		return;
	raw := tkcmd(".read.t get {@" + hd t + "," + hd tl t + " wordstart}" +
		" {@" + hd t + "," + hd tl t + " wordend}");
	w := cleanword(raw);
	if(w == "")
		return;
	status("define: " + w);
	def := readfile(BIBLE + "/define/" + w);
	ctxclear();
	ins(".ctx.t", "Define: " + w + "\n", "XHEAD");
	if(def == nil)
		ins(".ctx.t", "(no definition)\n", "DEF");
	else
		ins(".ctx.t", def + "\n", "DEF");
	tkcmd(".ctx.t yview 1.0");
	tkcmd("update");
}

cleanword(w: string): string
{
	out := "";
	for(i := 0; i < len w; i++){
		c := w[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		if(c >= 'a' && c <= 'z')
			out[len out] = c;
	}
	return out;
}

#
# search (center pane, mode "search")
#

dosearch()
{
	q := tkcmd(".top.sf.e get");
	if(q == "")
		return;
	tsv := query(BIBLE + "/search", q);
	mode = "search";
	tkcmd(".read.t delete 1.0 end");
	ins(".read.t", "Search: " + q + "\n", "HEAD");
	(nl, lines) := sys->tokenize(tsv, "\n");
	searchres = array[nl] of (int, int, int);
	n := 0;
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, "\t");
		if(nf < 4)
			continue;
		bi := bookindex(hd f);
		if(bi < 0)
			continue;
		c := int hd tl f;
		v := int hd tl tl f;
		text := hd tl tl tl f;
		startidx := tkcmd(".read.t index {end -1c}");
		ins(".read.t", hd f + " " + string c + ":" + string v + "  ", "REF");
		ins(".read.t", text + "\n", "RES");
		endidx := tkcmd(".read.t index {end -1c}");
		tkcmd(".read.t tag add r" + string n + " " + startidx + " " + endidx);
		searchres[n++] = (bi, c, v);
	}
	searchres = searchres[0:n];
	if(n == 0)
		ins(".read.t", "No matches.\n", "BODY");
	status("search: " + string n + " result(s)");
	tkcmd(".read.t yview 1.0");
	tkcmd("update");
}

dogoto()
{
	g := tkcmd(".top.gof.e get");
	if(g == "")
		return;
	tsv := query(BIBLE + "/lookup", g);
	(bi, c, v) := parsetsvfirst(tsv);
	if(bi < 0){
		status("not found: " + g);
		return;
	}
	navigateto(bi, c, v);
}

#
# click handlers
#

onreadclick(xy: string)
{
	tags := tagsat(".read.t", xy);
	if(mode == "search"){
		for(l := tags; l != nil; l = tl l){
			tag := hd l;
			if(len tag >= 2 && tag[0] == 'r' && isdigit(tag[1])){
				i := int tag[1:];
				if(i >= 0 && i < len searchres){
					(bi, c, v) := searchres[i];
					navigateto(bi, c, v);
				}
				return;
			}
		}
		return;
	}
	for(l := tags; l != nil; l = tl l){
		tag := hd l;
		if(len tag >= 2 && tag[0] == 'v' && isdigit(tag[1])){
			selectverse(int tag[1:]);
			return;
		}
	}
}

onctxclick(xy: string)
{
	tags := tagsat(".ctx.t", xy);
	for(l := tags; l != nil; l = tl l){
		tag := hd l;
		if(len tag >= 2 && tag[0] == 'x' && isdigit(tag[1])){
			i := int tag[1:];
			if(i >= 0 && i < len ctxrefs){
				(bi, c, v) := ctxrefs[i];
				navigateto(bi, c, v);
			}
			return;
		}
	}
}

shownbooks()
{
	tkcmd(".nav.list delete 0 end");
	for(i := 0; i < len booknames; i++)
		tkcmd(".nav.list insert end " + tk->quote(booknames[i]));
	tkcmd(".nav.title configure -text {Books}");
	navmode = "books";
	navbook = -1;
}

shownchaps(bi: int)
{
	tkcmd(".nav.list delete 0 end");
	tkcmd(".nav.list insert end {<< Books}");
	for(c := 1; c <= bookchaps[bi]; c++)
		tkcmd(".nav.list insert end " + string c);
	tkcmd(".nav.title configure -text " + tk->quote(booknames[bi]));
	navmode = "chaps";
	navbook = bi;
}

onnavpick()
{
	sel := tkcmd(".nav.list curselection");
	if(sel == "")
		return;
	i := int sel;
	if(navmode == "books"){
		navigateto(i, 1, 0);		# shows that book's chapters too
	} else {
		if(i == 0)
			shownbooks();		# the "‹ Books" item
		else
			navigateto(navbook, i, 0);
	}
}

onkey(k: string)
{
	case k {
	"down" =>	moveverse(1);
	"up" =>		moveverse(-1);
	"next" =>	stepchapter(1);
	"prev" =>	stepchapter(-1);
	"search" =>	tkcmd("focus .top.sf.e");
	}
}

moveverse(d: int)
{
	if(mode != "read" || curvnums == nil || len curvnums == 0)
		return;
	# find current position among the displayed verses
	pos := 0;
	for(i := 0; i < len curvnums; i++)
		if(curvnums[i] == curverse){
			pos = i;
			break;
		}
	if(curverse == 0)
		pos = -1;
	pos += d;
	if(pos < 0)
		pos = 0;
	if(pos >= len curvnums)
		pos = len curvnums - 1;
	selectverse(curvnums[pos]);
}

#
# tk + io helpers
#

ins(w, s, tag: string)
{
	tkcmd(w + " insert end " + tk->quote(s) + " " + tag);
}

ctxclear()
{
	tkcmd(".ctx.t delete 1.0 end");
}

tagsat(w, xy: string): list of string
{
	(n, t) := sys->tokenize(xy, " ");
	if(n < 2)
		return nil;
	names := tkcmd(w + " tag names @" + hd t + "," + hd tl t);
	(nil, tags) := sys->tokenize(names, " ");
	return tags;
}

status(s: string)
{
	tkcmd(".bot.msg configure -text " + tk->quote(s));
}

tkcmd(s: string): string
{
	e := tk->cmd(window, s);
	if(e != nil && len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "wm/bible: tk error %s on '%s'\n", e, s);
	return e;
}

elide(s: string, n: int): string
{
	if(len s <= n)
		return s;
	return s[0:n] + "…";
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

dirnames(path: string): array of string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	names: list of string;
	n := 0;
	for(;;){
		(rc, d) := sys->dirread(fd);
		if(rc <= 0)
			break;
		for(i := 0; i < rc; i++){
			names = d[i].name :: names;
			n++;
		}
	}
	a := array[n] of string;
	for(; names != nil; names = tl names)
		a[--n] = hd names;
	return a;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	return readall(fd);
}

query(path, q: string): string
{
	fd := sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return nil;
	d := array of byte q;
	if(sys->write(fd, d, len d) != len d)
		return nil;
	return readall(fd);
}

readall(fd: ref Sys->FD): string
{
	s := "";
	buf := array[8192] of byte;
	rem: array of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		# carry a partial UTF-8 sequence across reads
		b := buf[0:n];
		if(rem != nil){
			nb := array[len rem + n] of byte;
			nb[0:] = rem;
			nb[len rem:] = b;
			b = nb;
			rem = nil;
		}
		(s2, r) := utfclean(b);
		s += s2;
		rem = r;
	}
	if(rem != nil)
		s += string rem;
	return s;
}

# split a byte array into a clean string plus any trailing partial UTF-8 bytes
utfclean(b: array of byte): (string, array of byte)
{
	# walk back from the end over continuation bytes to find a clean boundary
	n := len b;
	i := n;
	k := 0;
	while(i > 0 && (int b[i-1] & 16r80) && k < 4){
		i--;
		k++;
		if(int b[i] & 16r40)	# start byte of a multibyte sequence
			break;
	}
	# if the tail looks like a complete sequence, keep it all
	if(i < n){
		(c, m, nil) := sys->byte2char(b, i);
		if(c >= 0 && i + m == n)
			return (string b, nil);
		return (string b[0:i], b[i:]);
	}
	return (string b, nil);
}
