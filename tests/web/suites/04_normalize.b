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
		".wex     { width: 1ex; }\n" +			# ~0.5em of 16 = 8
		".pad2    { padding: 8px 16px; }\n" +		# top/bottom 8, left/right 16
		".bsh     { border: 2px solid red; }\n" +	# shorthand: width 2, color red
		".bnamed  { border-color: navy; }\n" +
		".gauto   { grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); }\n" +
		".grep    { grid-template-columns: repeat(3, 1fr); }\n" +
		".gexp    { grid-template-columns: 100px 200px 1fr; }\n" +
		".bgc     { background-color: #112233; }\n" +
		".bgsh    { background: #0e1116; }\n" +			# shorthand colour
		".bgnamed { background: navy; }\n" +			# shorthand named colour
		".bggrad  { background: linear-gradient(90deg, red, blue); }\n" +  # no solid colour
		".bgboth  { background: #ffffff; background-color: #010203; }\n" +  # longhand wins
		".hred    { color: hsl(0, 100%, 50%); }\n" +		# -> red
		".hgrn    { color: hsl(120, 100%, 50%); }\n" +		# -> green
		".hblu    { color: hsl(240, 100%, 50%); }\n" +		# -> blue
		".hbga    { background: hsla(40, 100%, 60%, 0.8); }\n";  # shorthand hsla, alpha dropped
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

	# --- shorthand-aware helpers (box model) -----------------------------
	pad := eng.compute(Elem.mk("div", "", "pad2", nil), nil);
	(p0, f0) := pad.nthlengthpx("padding", 0, BASE);
	(p1, f1) := pad.nthlengthpx("padding", 1, BASE);
	(nil, f2) := pad.nthlengthpx("padding", 2, BASE);
	t->ok(f0 && p0 == 8,  "padding shorthand value 0 -> 8px");
	t->ok(f1 && p1 == 16, "padding shorthand value 1 -> 16px");
	t->ok(f2 == 0, "padding shorthand value 2 -> absent");

	bsh := eng.compute(Elem.mk("div", "", "bsh", nil), nil);
	(bw, bwf) := bsh.nthlengthpx("border", 0, BASE);
	t->ok(bwf && bw == 2, "border shorthand width -> 2px");
	(rr, rg, rb, rf) := bsh.anycolor("border");
	t->ok(rf && rr == 255 && rg == 0 && rb == 0, "border shorthand color -> red");

	bn := eng.compute(Elem.mk("div", "", "bnamed", nil), nil);
	(nr, ng, nb, nf) := bn.anycolor("border-color");
	t->ok(nf && nr == 0 && ng == 0 && nb == 128, "border-color named navy -> #000080");

	# --- grid-template-columns ------------------------------------------
	ga := eng.compute(Elem.mk("div", "", "gauto", nil), nil);
	(amin, acnt, afnd) := ga.gridtrack(BASE);
	t->ok(afnd && amin == 160 && acnt == 0, "repeat(auto-fill, minmax(160px,1fr)) -> (160,0)");

	gr := eng.compute(Elem.mk("div", "", "grep", nil), nil);
	(rmin, rcnt, rfnd) := gr.gridtrack(BASE);
	t->ok(rfnd && rcnt == 3, "repeat(3, 1fr) -> count 3");

	ge := eng.compute(Elem.mk("div", "", "gexp", nil), nil);
	(emin, ecnt, efnd) := ge.gridtrack(BASE);
	t->ok(efnd && emin == 100 && ecnt == 3, "explicit 100px 200px 1fr -> (100,3)");

	gn := eng.compute(Elem.mk("div", "", "wem", nil), nil);
	(nil, nil, gnf) := gn.gridtrack(BASE);
	t->ok(gnf == 0, "no grid-template-columns -> not found");

	# --- background colour: longhand AND the `background` shorthand -------
	# Modern sheets paint the page/card/button fill through the shorthand, so
	# bgcolor() must read both (a gradient/image-only background has no solid
	# colour to paint).  This is the fix that lights up the dark theme.
	bgc := eng.compute(Elem.mk("div", "", "bgc", nil), nil);
	(c0r, c0g, c0b, c0f) := bgc.bgcolor();
	t->ok(c0f && c0r == 16r11 && c0g == 16r22 && c0b == 16r33, "background-color longhand -> #112233");

	bgs := eng.compute(Elem.mk("div", "", "bgsh", nil), nil);
	(s0r, s0g, s0b, s0f) := bgs.bgcolor();
	t->ok(s0f && s0r == 16r0e && s0g == 16r11 && s0b == 16r16, "background shorthand -> #0e1116");

	bgn := eng.compute(Elem.mk("div", "", "bgnamed", nil), nil);
	(n0r, n0g, n0b, n0f) := bgn.bgcolor();
	t->ok(n0f && n0r == 0 && n0g == 0 && n0b == 128, "background: navy -> #000080");

	bgg := eng.compute(Elem.mk("div", "", "bggrad", nil), nil);
	(nil, nil, nil, g0f) := bgg.bgcolor();
	t->ok(g0f == 0, "background: linear-gradient(...) -> no solid colour");

	bgb := eng.compute(Elem.mk("div", "", "bgboth", nil), nil);
	(b0r, b0g, b0b, b0f) := bgb.bgcolor();
	t->ok(b0f && b0r == 1 && b0g == 2 && b0b == 3, "background-color longhand beats background shorthand");

	# --- hsl()/hsla() colour resolution ---------------------------------
	hr := eng.compute(Elem.mk("div", "", "hred", nil), nil);
	(hrr, hrg, hrb, hrf) := hr.color("color");
	t->ok(hrf && hrr == 255 && hrg == 0 && hrb == 0, "hsl(0,100%,50%) -> red");

	hg := eng.compute(Elem.mk("div", "", "hgrn", nil), nil);
	(hgr, hgg, hgb, hgf) := hg.color("color");
	t->ok(hgf && hgr == 0 && hgg == 255 && hgb == 0, "hsl(120,100%,50%) -> green");

	hb := eng.compute(Elem.mk("div", "", "hblu", nil), nil);
	(hbr, hbg, hbb, hbf) := hb.color("color");
	t->ok(hbf && hbr == 0 && hbg == 0 && hbb == 255, "hsl(240,100%,50%) -> blue");

	ha := eng.compute(Elem.mk("div", "", "hbga", nil), nil);
	(har, hag, hab, haf) := ha.bgcolor();
	t->ok(haf && har == 255 && hag == 187 && hab == 51, "hsla via background shorthand -> #ffbb33 (alpha dropped)");

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
