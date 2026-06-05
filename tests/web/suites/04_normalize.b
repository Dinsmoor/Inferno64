implement CssNormalizeTest;

#
# Tests for the Charon CSS value-normalisation helpers in csseng.b:
#   Props.fontweight  (CSS font-weight -> 0/100..900)
#   Props.lengthpx    (CSS <length> -> integer pixels, generic resolver used by
#                      the box-model code).
# Pure logic, headless under emu-g.  These live in the generic engine (not
# build.b) precisely because they are Charon-independent; build.b only does the
# final mapping into Charon's font buckets.
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

CssNormalizeTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

eng: ref Csseng->Engine;

BASE: con 16;	# reference px for em/rem/ex/% resolution

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
	author :=
		".wbold   { font-weight: bold; }\n" +
		".w700    { font-weight: 700; }\n" +
		".w400    { font-weight: 400; }\n" +
		".wnormal { font-weight: normal; }\n" +
		".wlight  { font-weight: lighter; }\n" +
		".w300    { font-weight: 300; }\n" +
		".ppx     { padding-left: 16px; }\n" +
		".ppt     { padding-left: 12pt; }\n" +		# 12pt = 16px
		".wem     { width: 2em; }\n" +			# 2 * 16 = 32
		".mpc     { margin-left: 50%; }\n" +		# 50% of 16 = 8
		".wex     { width: 1ex; }\n";			# ~0.5em of 16 = 8
	(ass, aerr) := css->parse(author);
	t->ok(aerr == nil || aerr == "", "author sheet parsed");
	eng.addsheet(ass, Csseng->AUTHOR);

	# --- font-weight normalisation ---------------------------------------
	t->eqi(big fw("wbold",   "font-weight"), big 700, "font-weight: bold -> 700");
	t->eqi(big fw("w700",    "font-weight"), big 700, "font-weight: 700 -> 700");
	t->eqi(big fw("w400",    "font-weight"), big 400, "font-weight: 400 -> 400");
	t->eqi(big fw("wnormal", "font-weight"), big 400, "font-weight: normal -> 400");
	t->eqi(big fw("wlight",  "font-weight"), big 300, "font-weight: lighter -> 300");
	t->eqi(big fw("w300",    "font-weight"), big 300, "font-weight: 300 -> 300");
	t->eqi(big fwabs(),                      big 0,   "font-weight: unspecified -> 0");

	# --- length -> px resolution -----------------------------------------
	lpx("ppx", "padding-left", 16, "16px -> 16px");
	lpx("ppt", "padding-left", 16, "12pt -> 16px");
	lpx("wem", "width",        32, "2em  -> 32px (base 16)");
	lpx("mpc", "margin-left",   8, "50%  -> 8px (of base 16)");
	lpx("wex", "width",         8, "1ex  -> 8px (~0.5em of 16)");
	# absent length: not found
	pp := eng.compute(Elem.mk("div", "", "wem", nil), nil);
	(nil, found) := pp.lengthpx("padding-top", BASE);
	t->ok(found == 0, "absent length -> not found");

	t->summary();
}

fw(cls, prop: string): int
{
	p := eng.compute(Elem.mk("div", "", cls, nil), nil);
	return p.fontweight(prop);
}

fwabs(): int
{
	p := eng.compute(Elem.new("div", nil), nil);
	return p.fontweight("font-weight");
}

lpx(cls, prop: string, want: int, label: string)
{
	p := eng.compute(Elem.mk("div", "", cls, nil), nil);
	(px, found) := p.lengthpx(prop, BASE);
	t->ok(found && px == want, label + " (got " + string px + " found " + string found + ")");
}
