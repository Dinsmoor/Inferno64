implement CssMediaTest;

#
# Media-query support for prefers-color-scheme (css.b medialist parsing +
# csseng.b mediascreen/querymatch evaluation).  A @media block's rules are
# admitted into the engine only when at least one of its queries matches the
# current screen + colour scheme, so we assert by whether a property declared
# *inside* the block wins on a <p> after addsheet().
#
# Pure logic, headless under emu-g.  ce->setdarkmode() must be called BEFORE
# addsheet() because media filtering happens at sheet-add time.
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

CssMediaTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

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

	# prefers-color-scheme: dark  -> applies only in dark mode
	d := "@media (prefers-color-scheme: dark) { p { color: #ff0000 } }";
	checkcol(d, 1, 1, 255, 0, 0, "prefers dark: applies in dark");
	checkabsent(d, 0, "prefers dark: dropped in light");

	# prefers-color-scheme: light -> applies only in light mode
	l := "@media (prefers-color-scheme: light) { p { color: #00ff00 } }";
	checkcol(l, 0, 1, 0, 255, 0, "prefers light: applies in light");
	checkabsent(l, 1, "prefers light: dropped in dark");

	# media type + feature: screen and (prefers dark)
	sd := "@media screen and (prefers-color-scheme: dark) { p { color: #0000ff } }";
	checkcol(sd, 1, 1, 0, 0, 255, "screen and prefers dark: applies in dark");
	checkabsent(sd, 0, "screen and prefers dark: dropped in light");

	# no-space colon (the ':' lexes as PSEUDO) must parse identically
	ns := "@media (prefers-color-scheme:dark){p{color:#ff0000}}";
	checkcol(ns, 1, 1, 255, 0, 0, "no-space colon: applies in dark");

	# bare media types still work
	checkcol("@media screen { p { color: #112233 } }", 0, 1,
		16r11, 16r22, 16r33, "screen: always applies");
	checkabsent("@media print { p { color: #ffff00 } }", 1,
		"print: never applies to screen");

	# negation: `not all and (prefers dark)` is false in dark, true in light
	ndark := "@media not all and (prefers-color-scheme: dark) { p { color: #ff0000 } }";
	checkabsent(ndark, 1, "not...dark: dropped in dark");
	checkcol(ndark, 0, 1, 255, 0, 0, "not...dark: applies in light");

	# comma list: first query matches -> whole block applies
	comma := "@media print, (prefers-color-scheme: dark) { p { color: #abcdef } }";
	checkcol(comma, 1, 1, 16rab, 16rcd, 16ref, "comma list: dark arm matches");

	t->summary();
}

# compute p.color for `sheet` parsed and added under colour scheme `dark`
pcolor(sheet: string, dark: int): (int, int, int, int)
{
	ce->setdarkmode(dark);
	e := ce->new();
	(ss, err) := css->parse(sheet);
	if(err != nil && err != "")
		t->ok(0, "parse error: " + err);
	e.addsheet(ss, Csseng->AUTHOR);
	p := Elem.new("p", nil);
	return e.compute(p, nil).color("color");
}

checkcol(sheet: string, dark, wf, wr, wg, wb: int, label: string)
{
	(r, g, b, found) := pcolor(sheet, dark);
	t->ok(found == wf && r == wr && g == wg && b == wb,
		label + " (got " + string r + "," + string g + "," + string b +
		" found " + string found + ")");
}

checkabsent(sheet: string, dark: int, label: string)
{
	(nil, nil, nil, found) := pcolor(sheet, dark);
	t->ok(!found, label + " (found=" + string found + ")");
}
