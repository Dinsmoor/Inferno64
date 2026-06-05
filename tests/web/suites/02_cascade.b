implement CssCascadeTest;

#
# Phase 3 test for the Charon CSS cascade engine (appl/charon/csseng.b).
#
# Builds an Engine from the W3C CSS2.1 UA default sheet plus a crafted author
# sheet, constructs element contexts, and asserts the computed properties.
# Exercises: UA application, type-vs-class specificity, descendant combinator,
# attribute selectors, inline-style precedence, !important, colour resolution
# (hex + named), and display:none.  Pure logic, headless under emu-g.
#
include "sys.m";
include "draw.m";
include "css.m";
include "csseng.m";
include "testing.m";

sys: Sys;
css: CSS;
ce: Csseng;
t: Testing;

# bind cross-module ADT methods to the loaded Csseng instance
Engine, Props, Elem: import ce;

CssCascadeTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

eng: ref Csseng->Engine;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();

	css = load CSS CSS->PATH;
	ce = load Csseng Csseng->PATH;
	if(css == nil || ce == nil){
		t->ok(0, "load CSS + Csseng modules");
		t->summary();
		return;
	}
	t->ok(1, "load CSS + Csseng modules");
	css->init(0);
	ce->init();

	eng = ce->new();

	# UA default sheet
	ua := readfile("/tests/web/fixtures/css21_default.css");
	(uss, uerr) := css->parse(ua);
	t->ok(uerr == nil || uerr == "" , "UA sheet parsed");
	eng.addsheet(uss, Csseng->UA);

	# crafted author sheet
	author :=
		"h1 { color: #ff0000; }\n" +
		"p { color: green; }\n" +
		".hi { color: blue; }\n" +
		"div p { color: navy; }\n" +
		"p.imp { color: green !important; }\n" +
		"input[type=text] { color: teal; }\n";
	(ass, aerr) := css->parse(author);
	t->ok(aerr == nil || aerr == "", "author sheet parsed");
	eng.addsheet(ass, Csseng->AUTHOR);

	# --- UA application ---------------------------------------------------
	h1 := Elem.new("h1", nil);
	ph1 := eng.compute(h1, nil);
	t->eqs(ph1.ident("display"), "block", "h1: UA display=block");
	t->eqs(ph1.ident("font-weight"), "bolder", "h1: UA font-weight=bolder");
	t->eqs(ph1.str("font-size"), "2em", "h1: UA font-size=2em");

	head := Elem.new("head", nil);
	t->eqs(eng.compute(head, nil).ident("display"), "none", "head: UA display=none");

	li := Elem.new("li", nil);
	t->eqs(eng.compute(li, nil).ident("display"), "list-item", "li: UA display=list-item");

	# --- colour resolution + author over UA -------------------------------
	col(ph1, "color", 255, 0, 0, "h1: author color #ff0000");

	p := Elem.new("p", nil);
	col(eng.compute(p, nil), "color", 0, 128, 0, "p: author color green (named)");

	# --- specificity: class beats type -----------------------------------
	phi := Elem.mk("p", "", "hi", nil);
	col(eng.compute(phi, nil), "color", 0, 0, 255, "p.hi: .hi(class) beats p(type) -> blue");

	# --- descendant combinator --------------------------------------------
	divp := Elem.new("p", Elem.new("div", nil));
	col(eng.compute(divp, nil), "color", 0, 0, 128, "div p: descendant -> navy beats p");

	# --- attribute selector -----------------------------------------------
	inp := Elem.new("input", nil);
	inp.attrs = ("type", "text") :: nil;
	col(eng.compute(inp, nil), "color", 0, 128, 128, "input[type=text] -> teal");

	# --- inline precedence ------------------------------------------------
	(idecls, nil) := css->parsedecl("color: orange");
	col(eng.compute(p, idecls), "color", 255, 165, 0, "inline color beats author rule");

	# --- !important author beats inline normal ----------------------------
	pimp := Elem.mk("p", "", "imp", nil);
	col(eng.compute(pimp, idecls), "color", 0, 128, 0, "author !important beats inline normal");

	t->summary();
}

col(p: ref Csseng->Props, name: string, wr, wg, wb: int, label: string)
{
	(r, g, b, found) := p.color(name);
	t->ok(found && r == wr && g == wg && b == wb,
		label + " (got " + string r + "," + string g + "," + string b +
		" found " + string found + ")");
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}
