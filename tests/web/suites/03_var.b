implement CssVarTest;

#
# Phase CSS3-a: custom properties + var() resolution (textual preprocess).
#
# Validates Engine.addvars()/flatten(): harvesting `--name: value` definitions
# and substituting var(--name[, fallback]) — including cross-sheet definitions,
# fallbacks, nested var()s, and the end-to-end result through the cascade
# (var-resolved colour applies to an element).  Pure logic, headless.
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

Engine, Props, Elem: import ce;

CssVarTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

contains(hay, needle: string): int
{
	n := len needle;
	for(i := 0; i + n <= len hay; i++)
		if(hay[i:i+n] == needle)
			return 1;
	return 0;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	css = load CSS CSS->PATH;
	ce = load Csseng Csseng->PATH;
	t->init();
	if(css == nil || ce == nil){
		t->ok(0, "load modules");
		t->summary();
		return;
	}
	t->ok(1, "load CSS + Csseng");
	css->init(0);
	ce->init();

	# --- basic harvest + substitution -------------------------------------
	e := ce->new();
	e.addvars(":root { --c: #ff0000; --big: 2em; }");
	f1 := e.flatten("h1 { color: var(--c); font-size: var(--big); }");
	t->ok(contains(f1, "#ff0000"), "var(--c) -> #ff0000 [" + f1 + "]");
	t->ok(contains(f1, "2em"), "var(--big) -> 2em");
	t->ok(!contains(f1, "var("), "no var( left after flatten");

	# --- fallback when undefined ------------------------------------------
	f2 := e.flatten("p { color: var(--missing, blue); }");
	t->ok(contains(f2, "blue") && !contains(f2, "var("), "var(--missing, blue) -> blue");

	# --- nested var() (a value that is itself a var) ----------------------
	e2 := ce->new();
	e2.addvars(":root { --a: var(--b); --b: green; }");
	f3 := e2.flatten("p { color: var(--a); }");
	t->ok(contains(f3, "green") && !contains(f3, "var("), "nested var(--a)->var(--b)->green [" + f3 + "]");

	# --- comments stripped (a --x in a comment is not a definition) -------
	e3 := ce->new();
	e3.addvars("/* --c: #000000; */ :root { --c: #112233; }");
	f4 := e3.flatten("a { color: var(--c); }");
	t->ok(contains(f4, "#112233"), "comment def ignored, real def used [" + f4 + "]");

	# --- end-to-end: flattened sheet -> parse -> cascade -> colour --------
	e4 := ce->new();
	sheet := ":root { --fg: #336699; }\n" + ".x { color: var(--fg); }\n";
	e4.addvars(sheet);
	(ss, err) := css->parse(e4.flatten(sheet));
	t->ok(err == nil || err == "", "flattened sheet parses");
	e4.addsheet(ss, Csseng->AUTHOR);
	el := Elem.mk("div", "", "x", nil);
	(r, g, b, found) := e4.compute(el, nil).color("color");
	t->ok(found && r == 16r33 && g == 16r66 && b == 16r99,
		".x color resolves to #336699 (got " + string r + "," + string g + "," + string b + ")");

	# --- guaranteed-invalid var() invalidates the WINNING declaration --------
	# Real-browser semantics (CSS Variables): a var() that resolves to nothing
	# (undefined, no usable fallback) does NOT make the declaration disappear so
	# a lower-specificity rule can win.  The high-specificity declaration still
	# wins the cascade, then computes to `unset` -> the property falls to its
	# initial/inherited value.  This is the bible.nicecrew.digital case:
	#   button { background: blue }            (low specificity, defined)
	#   .book-button { background: var(--undefined) }   (high specificity)
	# A real browser shows the button transparent (NOT blue); flatten() must
	# substitute `unset` for the empty var() so the .book-button rule still
	# suppresses the bare `button` rule.
	e5 := ce->new();
	uadef := "button { background-color: #6b9bd1; }\n";
	e5.addvars(uadef);
	(uss, uerr) := css->parse(e5.flatten(uadef));
	t->ok(uerr == nil || uerr == "", "ua button sheet parses");
	e5.addsheet(uss, Csseng->AUTHOR);
	bbdef := ".book-button { background-color: var(--undefined-bg); }\n";
	e5.addvars(bbdef);
	fbb := e5.flatten(bbdef);
	t->ok(contains(fbb, "unset") && !contains(fbb, "var("),
		"empty var() -> unset keyword [" + fbb + "]");
	(bss, berr) := css->parse(fbb);
	t->ok(berr == nil || berr == "", ".book-button sheet parses");
	e5.addsheet(bss, Csseng->AUTHOR);
	bel := Elem.mk("button", "", "book-button", nil);
	(nil, nil, nil, bfound) := e5.compute(bel, nil).color("background-color");
	t->ok(!bfound,
		"invalid var() wins cascade then computes unset -> background not painted (blue suppressed)");

	t->summary();
}
