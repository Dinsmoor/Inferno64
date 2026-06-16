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

include "tkwidgets.m";
	tkw: Tkwidgets;
	Scrolledlist, Scrolledtext, Notebook, Paned, Statusbar: import tkw;

Bible: module
{
	init: fn(ctxt: ref Context, args: list of string);
};

BIBLE:	con "/mnt/bible";
NOTES:	con "/mnt/bible/notes";

# fonts: a serif body for readability, sans for the UI chrome
BODYFONT:	con "/fonts/lucida/unicode.14.font";
HEADFONT:	con "/fonts/lucida/unicode.20.font";
VNUMFONT:	con "/fonts/lucida/unicode.10.font";
UIFONT:		con "/fonts/lucidasans/unicode.8.font";
CTXHEADFONT:	con "/fonts/lucidasans/unicode.10.font";

window:	ref Tk->Toplevel;

# megawidgets (Tkwidgets)
books:	ref Scrolledlist;	# the book list (left)
chaps:	ref Scrolledlist;	# the chapter list (left)
ctxnb:	ref Notebook;		# right pane: Cross-refs / Dictionary tabs
navpn:	ref Paned;		# the two stacked nav lists
sb:	ref Statusbar;		# bottom message bar
XT:	string;			# the Cross-refs page text-widget path
DT:	string;			# the Dictionary page text-widget path

# loaded once from /mnt/bible/books
booknames:	array of string;	# canonical order, index 0..65
bookchaps:	array of int;		# chapters per book

# current location
curbook:	int;			# index into booknames
curchap:	int;			# 1-based
curverse:	int;			# selected verse, 0 = none
curvnums:	array of int;		# verse numbers shown in the read pane
mode:		string;			# "read" or "search"
curhl:		string;			# highlight colour of the selected verse's note
havenotes:	int;			# is /mnt/bible/notes mounted?

# Prev/Next navigation history (browser-style back/forward over focused verses)
hist:		array of (int, int, int);	# (book, chap, verse) visited, in order
histn:		int;			# number of valid entries
histpos:	int;			# index of the current entry (-1 = empty)
traversing:	int;			# set while Prev/Next replays history (don't re-record)

# click targets for the result/context panes
searchres:	array of (int, int, int);	# (bookidx, chap, verse)
ctxrefs:	array of (int, int, int);

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	str = load String String->PATH;
	tkw = load Tkwidgets Tkwidgets->PATH;
	if(tk == nil || tkclient == nil || str == nil || tkw == nil){
		sys->fprint(sys->fildes(2), "wm/bible: load failed: %r\n");
		raise "fail:load";
	}
	tkw->init();
	sys->pctl(Sys->NEWPGRP, nil);

	if(!loadbooks()){
		sys->fprint(sys->fildes(2),
			"wm/bible: cannot read %s -- is biblefs mounted?\n", BIBLE);
		raise "fail:nodata";
	}
	havenotes = isdir(NOTES);

	tkclient->init();
	winctl := chan of string;
	(window, winctl) = tkclient->toplevel(ctxt, nil, "Bible", Tkclient->Resize | Tkclient->Hide);

	nav := chan of string;		tk->namechan(window, nav, "nav");
	gochan := chan of string;	tk->namechan(window, gochan, "go");
	srch := chan of string;		tk->namechan(window, srch, "search");
	rdsel := chan of string;	tk->namechan(window, rdsel, "rdsel");
	keyc := chan of string;		tk->namechan(window, keyc, "key");
	nsave := chan of string;	tk->namechan(window, nsave, "nsave");
	nclear := chan of string;	tk->namechan(window, nclear, "nclear");
	nhl := chan of string;		tk->namechan(window, nhl, "nhl");

	for(i := 0; i < len tkconfig; i++)
		tkcmd(tkconfig[i]);

	# left nav: two stacked, resizable lists (books over chapters) -- a Paned
	# with two Scrolledlists, the layout pack could not give us before
	navpn = Paned.new(window, ".main.nav", Tkwidgets->Vert, array[] of {380, 200});
	tkcmd("pack .main.nav -side left -fill y");
	books = Scrolledlist.new(window, navpn.pane(0) + ".l", 168, 0,
		"-selectmode browse -font " + UIFONT);
	tkcmd("pack " + books.fr + " -fill both -expand 1");
	chaps = Scrolledlist.new(window, navpn.pane(1) + ".l", 168, 0,
		"-selectmode browse -font " + UIFONT);
	tkcmd("pack " + chaps.fr + " -fill both -expand 1");

	# right context: a Notebook with Cross-refs and Dictionary tabs (each a
	# Scrolledtext), so a definition no longer overwrites the cross-references
	tkcmd("frame .main.ctx -width 240");
	tkcmd("pack propagate .main.ctx 0");
	tkcmd("pack .main.ctx -side right -fill y");
	ctxnb = Notebook.new(window, ".main.ctx.nb");
	tkcmd("pack .main.ctx.nb -fill both -expand 1");
	CTXOPTS := "-state disabled -wrap word -padx 4 -pady 2";
	xst := Scrolledtext.new(window, ctxnb.add("xref", "Cross-refs") + ".st", 0, 0, CTXOPTS);
	tkcmd("pack " + xst.fr + " -fill both -expand 1");
	XT = xst.t;
	dst := Scrolledtext.new(window, ctxnb.add("dict", "Dictionary") + ".st", 0, 0, CTXOPTS);
	tkcmd("pack " + dst.fr + " -fill both -expand 1");
	DT = dst.t;

	# centre reading pane (a read-only Scrolledtext)
	rt := Scrolledtext.new(window, ".read", 0, 0,
		"-state disabled -wrap word -padx 8 -pady 4");
	tkcmd("pack .read -in .main -side left -fill both -expand 1");
	tkcmd("bind .read.t <Button-3> {send rdsel %x %y}");	# right-click: define
	tkcmd("bind .read.t <Key-\uE012> {send key up}");
	tkcmd("bind .read.t <Key-\uE013> {send key down}");
	tkcmd("bind .read.t <Key-j> {send key down}");
	tkcmd("bind .read.t <Key-k> {send key up}");
	tkcmd("bind .read.t <Key-n> {send key next}");
	tkcmd("bind .read.t <Key-p> {send key prev}");
	tkcmd("bind .read.t <Key-/> {send key search}");
	tkcmd("pack .main -side top -fill both -expand 1");

	# bottom: note editor (editable Scrolledtext) strip, then the status bar
	noteed := Scrolledtext.new(window, ".note.tf", 0, 0,
		"-wrap word -padx 4 -pady 2 -font " + UIFONT);
	tkcmd("grid .note.tf -row 1 -column 0 -sticky nsew");
	sb = Statusbar.new(window, ".sb");
	tkcmd("pack .sb -side bottom -fill x");
	tkcmd("pack .note -side bottom -fill x");

	mktags();
	books.setitems(booknames);

	tkclient->onscreen(window, nil);
	tkclient->startinput(window, "kbd" :: "ptr" :: nil);
	tkcmd("focus .read.t");

	# open on the verse of the day, falling back to Genesis 1:1
	mode = "read";
	histpos = -1;
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
		# the wm pushed a system theme: widget backgrounds re-theme via
		# "theme reapply" inside wmctl, but text tags do not -- redo them.
		if(s != nil && len s >= 6 && s[0:6] == "theme ")
			mktags();
	cm := <-nav =>
		case cm {
		"prev" =>	histback();
		"next" =>	histfwd();
		"search" =>	dosearch();
		}
	<-gochan =>
		dogoto();
	<-srch =>
		dosearch();
	<-books.ev =>
		onbookpick();
	<-chaps.ev =>
		onchappick();
	tab := <-ctxnb.ev =>
		ctxnb.select(tab);
	psh := <-navpn.ev =>
		navpn.drag(psh);
	xy := <-rt.ev =>
		onreadclick(xy);
	xy := <-rdsel =>
		ondefine(xy);
	xy := <-xst.ev =>
		onctxclick(xy);
	<-dst.ev =>		# Dictionary page clicks: nothing to follow
		;
	<-noteed.ev =>		# note editor focus click: nothing to do
		;
	k := <-keyc =>
		onkey(k);
	<-nsave =>
		onsave();
	<-nclear =>
		onclear();
	col := <-nhl =>
		onhl(col);
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
	"entry .top.gof.e",
	"bind .top.gof.e <Button-1> {focus .top.gof.e}",
	"bind .top.gof.e <Key-\n> {send go}",
	"pack .top.gof.e -fill both -expand 1",
	"label .top.sl -text {Search:}",
	"frame .top.sf -width 150 -height 22",
	"pack propagate .top.sf 0",
	"entry .top.sf.e",
	"bind .top.sf.e <Button-1> {focus .top.sf.e}",
	"bind .top.sf.e <Key-\n> {send search}",
	"pack .top.sf.e -fill both -expand 1",
	"button .top.sb -text Search -command {send search}",
	"pack .top.prev .top.next .top.gol .top.gof -side left -padx 2",
	"pack .top.sb .top.sf .top.sl -side right -padx 2",
	"pack .top -fill x -pady 2",

	# the three-pane main area; nav (Paned) and ctx (Notebook) are built in
	# code from Tkwidgets, then packed into .main alongside the reading pane
	"frame .main",

	# the reading pane (.read), context pages, and note editor are Scrolledtext
	# megawidgets built in code; their bindings/tags are set up there too

	# note editor: a fixed-height strip below the reading area, the bar gridded
	# above the editor (a Scrolledtext, added in code at row 1)
	"frame .note -height 116",
	"grid propagate .note 0",
	"frame .note.bar",
	"label .note.bar.l -text {Note} -anchor w -font " + CTXHEADFONT,
	"button .note.bar.none -text {clear hl} -command {send nhl none}",
	"button .note.bar.gold -text gold -command {send nhl gold}",
	"button .note.bar.green -text green -command {send nhl green}",
	"button .note.bar.blue -text blue -command {send nhl blue}",
	"button .note.bar.pink -text pink -command {send nhl pink}",
	"button .note.bar.save -text Save -command {send nsave}",
	"button .note.bar.del -text Delete -command {send nclear}",
	"pack .note.bar.l -side left -padx 4",
	"pack .note.bar.none .note.bar.gold .note.bar.green .note.bar.blue .note.bar.pink -side left -padx 1",
	"pack .note.bar.del .note.bar.save -side right -padx 2",
	# bar gridded at row 0; the editor (Scrolledtext .note.tf) is gridded at
	# row 1 in code.  grid (not pack) stacks them reliably (see DEV_TK_EXTENSIONS)
	"grid .note.bar -row 0 -column 0 -sticky ew",
	"grid rowconfigure .note 1 -weight 1",
	"grid columnconfigure .note 0 -weight 1",

	# .main / .note / .sb are packed in code once the megawidgets exist
	"pack propagate . 0",
	". configure -width 760 -height 680",
};

# one theme value with a fallback; lets the reading tags follow the live palette
themecol(key, def: string): string
{
	v := tkclient->themecolour(window, key);
	if(v == nil || v == "")
		return def;
	return v;
}

# (Re)configure the text tags from the current system theme.  The reading and
# context panes are -state disabled, so untagged/body text would otherwise pick
# up the env's *disabled* foreground (a light grey, illegible on a dark theme):
# every body tag therefore sets an explicit foreground.  Called at start-up and
# again whenever the wm pushes a theme change (tag colours are not covered by
# "theme reapply", unlike the now-unstyled widget backgrounds).
mktags()
{
	ink := themecol("fg", "#202020");		# primary text
	accent := themecol("select", "#3060a0");	# verse numbers / refs
	muted := themecol("disablefg", "#606060");	# context headings

	tkcmd(".read.t tag configure HEAD -font " + HEADFONT + " -foreground " + ink + " -spacing3 8");
	tkcmd(".read.t tag configure BODY -font " + BODYFONT + " -foreground " + ink +
		" -lmargin1 4 -lmargin2 4 -rmargin 4 -spacing1 2 -spacing3 2");
	tkcmd(".read.t tag configure VNUM -font " + VNUMFONT + " -foreground " + accent + " -offset 4");
	tkcmd(".read.t tag configure RES -font " + BODYFONT + " -foreground " + ink +
		" -lmargin1 4 -lmargin2 16 -spacing1 2 -spacing3 2");
	tkcmd(".read.t tag configure REF -font " + VNUMFONT + " -foreground " + accent);
	# the current-verse cursor (SEL) and the note tints are fixed light pastels;
	# force dark text on them so a highlighted verse stays legible under any
	# palette (a light-on-pastel verse would vanish under the dark theme).
	tkcmd(".read.t tag configure SEL -background #fff0b0 -foreground #202020");
	tkcmd(".read.t tag configure HL_gold -background #ffe9a8 -foreground #202020");
	tkcmd(".read.t tag configure HL_green -background #cdeec0 -foreground #202020");
	tkcmd(".read.t tag configure HL_blue -background #c8dcf8 -foreground #202020");
	tkcmd(".read.t tag configure HL_pink -background #f8cce0 -foreground #202020");
	tkcmd(".read.t tag configure HL_note -background #eaeaea -foreground #202020");
	# highlight tints must out-rank BODY so their forced-dark text wins; the
	# current-verse cursor shows over any highlight.
	tkcmd(".read.t tag raise HL_gold");
	tkcmd(".read.t tag raise HL_green");
	tkcmd(".read.t tag raise HL_blue");
	tkcmd(".read.t tag raise HL_pink");
	tkcmd(".read.t tag raise HL_note");
	tkcmd(".read.t tag raise SEL");
	# context-page tags (same on both notebook pages)
	for(p := list of {XT, DT}; p != nil; p = tl p){
		w := hd p;
		tkcmd(w + " tag configure XHEAD -font " + CTXHEADFONT + " -foreground " + muted + " -spacing3 4");
		tkcmd(w + " tag configure XREF -font " + VNUMFONT + " -foreground " + accent + " -spacing1 2");
		tkcmd(w + " tag configure XBODY -font " + UIFONT + " -foreground " + ink + " -lmargin1 4 -lmargin2 4 -spacing3 4");
		tkcmd(w + " tag configure DEF -font " + UIFONT + " -foreground " + ink + " -lmargin1 4 -lmargin2 4 -spacing3 4");
	}
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

	# keep the two nav lists in sync with where we are
	books.select(bi);
	if(chaps.count() != bookchaps[bi])
		fillchaps(bi);
	chaps.select(chap - 1);

	renderchapter();
	if(verse > 0){
		selectverse(verse);		# records via selectverse
	}else{
		curverse = 0;
		setref();
		record();
	}
}

#
# Prev/Next navigation history (back/forward over the verses we have focused)
#

# remember the current location, unless we are replaying history
record()
{
	if(traversing)
		return;
	if(histpos >= 0){
		(pb, pc, pv) := hist[histpos];
		if(pb == curbook && pc == curchap && pv == curverse)
			return;		# no move; don't duplicate
	}
	histn = histpos + 1;		# drop any forward entries (browser semantics)
	if(hist == nil || histn >= len hist){
		a := array[(histn + 1) * 2] of (int, int, int);
		for(i := 0; i < histn; i++)
			a[i] = hist[i];
		hist = a;
	}
	hist[histn] = (curbook, curchap, curverse);
	histn++;
	histpos = histn - 1;
}

histback()
{
	if(histpos <= 0)
		return;
	traversing = 1;
	histpos--;
	(b, c, v) := hist[histpos];
	navigateto(b, c, v);
	traversing = 0;
}

histfwd()
{
	if(histpos < 0 || histpos >= histn - 1)
		return;
	traversing = 1;
	histpos++;
	(b, c, v) := hist[histpos];
	navigateto(b, c, v);
	traversing = 0;
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
	applynotes();
	tkcmd(".read.t yview 1.0");
	tkcmd("update");
}

# tint every verse in the current chapter that has a note (by its highlight
# colour, or HL_note for a note with no colour chosen)
applynotes()
{
	if(!havenotes)
		return;
	vs := dirnames(NOTES + "/" + booknames[curbook] + "/" + string curchap);
	for(i := 0; i < len vs; i++){
		v := int vs[i];
		if(v <= 0)
			continue;
		(hl, nil, nil) := parsenote(readnote(curbook, curchap, v));
		sethighlight(v, hltag(hl));
	}
}

# the highlight tag for a colour name ("" => the generic note tint)
hltag(hl: string): string
{
	case hl {
	"gold" =>	return "HL_gold";
	"green" =>	return "HL_green";
	"blue" =>	return "HL_blue";
	"pink" =>	return "HL_pink";
	"none" or "" =>	return "HL_note";
	}
	return "HL_note";
}

sethighlight(v: int, tag: string)
{
	r := tkcmd(".read.t tag ranges v" + string v);
	(n, t) := sys->tokenize(r, " ");
	if(n < 2)
		return;
	for(hls := list of {"HL_gold", "HL_green", "HL_blue", "HL_pink", "HL_note"}; hls != nil; hls = tl hls)
		tkcmd(".read.t tag remove " + hd hls + " " + hd t + " " + hd tl t);
	if(tag != "")
		tkcmd(".read.t tag add " + tag + " " + hd t + " " + hd tl t);
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
	loadnote();
	record();
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
	ctxclear(XT);
	ins(XT, "Cross references for " + refstr + "\n", "XHEAD");
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
		startidx := tkcmd(XT + " index {end -1c}");
		ins(XT, hd f + " " + string c + ":" + string v + "\n", "XREF");
		ins(XT, elide(text, 90) + "\n", "XBODY");
		endidx := tkcmd(XT + " index {end -1c}");
		tkcmd(XT + " tag add x" + string n + " " + startidx + " " + endidx);
		ctxrefs[n++] = (bi, c, v);
	}
	ctxrefs = ctxrefs[0:n];
	if(n == 0)
		ins(XT, "(none)\n", "XBODY");
	tkcmd(XT + " yview 1.0");
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
	ctxclear(DT);
	ins(DT, "Define: " + w + "\n", "XHEAD");
	if(def == nil)
		ins(DT, "(no definition)\n", "DEF");
	else
		ins(DT, def + "\n", "DEF");
	tkcmd(DT + " yview 1.0");
	ctxnb.select("dict");		# bring the Dictionary tab forward
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
			selectverse(int tag[1:]);	# records via selectverse
			return;
		}
	}
}

onctxclick(xy: string)
{
	tags := tagsat(XT, xy);
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

# load the chapter list (1..N) for a book into the chapter Scrolledlist
fillchaps(bi: int)
{
	a := array[bookchaps[bi]] of string;
	for(c := 0; c < bookchaps[bi]; c++)
		a[c] = string (c + 1);
	chaps.setitems(a);
}

onbookpick()
{
	i := books.cursel();
	if(i >= 0)
		navigateto(i, 1, 0);		# also refills the chapter list
}

onchappick()
{
	i := chaps.cursel();
	if(i >= 0)
		navigateto(curbook, i + 1, 0);
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
# notes & highlights (bottom editor, persisted via /mnt/bible/notes)
#
# A note file is a small header of "key: value" lines, a blank line, then the
# body:
#	highlight: gold
#	tags: salvation love
#
#	<body...>
# wm/bible owns this format; notefs stores it opaquely.

notepath(bi, chap, verse: int): string
{
	return NOTES + "/" + booknames[bi] + "/" + string chap + "/" + string verse;
}

readnote(bi, chap, verse: int): string
{
	return readfile(notepath(bi, chap, verse));
}

parsenote(s: string): (string, string, string)
{
	hl := "";
	tags := "";
	# header lines until a blank line; the remainder is the body
	i := 0;
	while(i < len s){
		j := i;
		while(j < len s && s[j] != '\n')
			j++;
		line := s[i:j];
		nexti := j;
		if(nexti < len s)
			nexti++;
		if(line == ""){		# blank line ends the header
			i = nexti;
			break;
		}
		c := index(line, ':');
		if(c < 0){		# no header at all: the whole thing is body
			return (hl, tags, s);
		}
		key := line[0:c];
		val := line[c+1:];
		while(len val > 0 && val[0] == ' ')
			val = val[1:];
		case key {
		"highlight" =>	hl = val;
		"tags" =>	tags = val;
		}
		i = nexti;
	}
	return (hl, tags, s[i:]);
}

buildnote(hl, tags, body: string): string
{
	hdr := "";
	if(hl != "" && hl != "none")
		hdr += "highlight: " + hl + "\n";
	if(tags != "")
		hdr += "tags: " + tags + "\n";
	if(hdr != "")
		return hdr + "\n" + body;
	return body;
}

# load the selected verse's note into the bottom editor
loadnote()
{
	tkcmd(".note.tf.t delete 1.0 end");
	curhl = "";
	if(curverse == 0){
		tkcmd(".note.bar.l configure -text {Note}");
		return;
	}
	rs := booknames[curbook] + " " + string curchap + ":" + string curverse;
	tkcmd(".note.bar.l configure -text " + tk->quote("Note " + rs));
	if(!havenotes)
		return;
	(hl, nil, body) := parsenote(readnote(curbook, curchap, curverse));
	curhl = hl;
	if(body != "")
		ins(".note.tf.t", body, "");
}

# write the selected verse's note (empty body + no highlight removes it)
savenote()
{
	if(curverse == 0)
		return;
	body := tkcmd(".note.tf.t get 1.0 {end -1c}");
	path := notepath(curbook, curchap, curverse);
	if(body == "" && (curhl == "" || curhl == "none")){
		sys->remove(path);		# notefs drops an empty note
		return;
	}
	text := buildnote(curhl, "", body);
	fd := sys->open(path, Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil){
		status("cannot save note: " + sys->sprint("%r"));
		return;
	}
	d := array of byte text;
	sys->write(fd, d, len d);
}

onsave()
{
	if(curverse == 0){
		status("select a verse first");
		return;
	}
	savenote();
	sethighlight(curverse, hltag(curhl));
	status("note saved: " + booknames[curbook] + " " + string curchap + ":" + string curverse);
}

onclear()
{
	if(curverse == 0)
		return;
	curhl = "";
	tkcmd(".note.tf.t delete 1.0 end");
	sys->remove(notepath(curbook, curchap, curverse));
	sethighlight(curverse, "");
	status("note deleted");
}

onhl(col: string)
{
	if(curverse == 0){
		status("select a verse first");
		return;
	}
	if(col == "none")
		curhl = "";
	else
		curhl = col;
	savenote();			# persist the colour change immediately
	sethighlight(curverse, hltag(curhl));
}

isdir(path: string): int
{
	(ok, d) := sys->stat(path);
	return ok >= 0 && (d.mode & Sys->DMDIR);
}

#
# tk + io helpers
#

ins(w, s, tag: string)
{
	tkcmd(w + " insert end " + tk->quote(s) + " " + tag);
}

ctxclear(w: string)
{
	tkcmd(w + " delete 1.0 end");
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
	sb.msg(s);
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

index(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
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
