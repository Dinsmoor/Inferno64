implement CssParseTest;

#
# Phase 1 smoke test for the Charon CSS engine work.
#
# Validates the in-tree W3C CSS2.1 parser (module/css.m -> appl/lib/w3c/css.b,
# /dis/lib/w3c/css.dis) on two inputs:
#
#  1. css21_default.css  - the authoritative CSS2.1 default style sheet for
#     HTML4 (W3C CSS2.1 spec, Appendix D).  Pure 2.1; we assert it parses with
#     no error and yields the exact ruleset count, i.e. the parser is faithful
#     to the 2.1 grammar.  (This file also becomes the UA default sheet the
#     cascade will use.)
#
#  2. page.css + inline.css - the real CSS shipped by the rendering testbed
#     (bible.nicecrew.digital).  We assert its 2.1 constructs parse (rulesets,
#     declarations, attribute & pseudo selectors).  Its CSS3 constructs
#     (@media feature queries, custom properties --x, var()) are reported as
#     TAP SKIPs, not failures: a 2.1 parser correctly drops them.  Climbing to
#     CSS3 is later, deliberate work.
#
include "sys.m";
include "draw.m";
include "css.m";
include "testing.m";

sys: Sys;
css: CSS;
t: Testing;

CssParseTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# per-parse counters (reset by analyze())
nrule, ndecl, nmedia, nattrib, npseudo, nvar, ncustom: int;
perr: string;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();

	css = load CSS CSS->PATH;
	if(css == nil){
		t->ok(0, "load CSS module (" + CSS->PATH + ")");
		t->summary();
		return;
	}
	t->ok(1, "load CSS module");
	css->init(0);			# diag off

	# --- 1. authoritative CSS2.1 default sheet: strict conformance ---------
	analyze("/tests/web/fixtures/css21_default.css");
	t->ok(perr == nil || perr == "", "css21_default: parse without error [" + perr + "]");
	# 52 '{' in the file = 51 ruleset braces + 1 @media-print wrapper brace
	t->eqi(big nrule, big 51, "css21_default: exact ruleset count (W3C Appendix D)");
	t->ok(ndecl > 0, "css21_default: declarations parsed (" + string ndecl + ")");
	# @media with a plain medium ("print") parses fine; only CSS3 feature
	# queries like @media (max-width:..) are unsupported.
	t->eqi(big nmedia, big 1, "css21_default: @media print block parsed");

	# --- 2. real testbed CSS: 2.1 features must parse ----------------------
	# parse both site files, accumulate
	analyze("/tests/web/fixtures/bible/page.css");
	r := nrule; d := ndecl; a := nattrib; ps := npseudo;
	pe1 := perr;
	analyze("/tests/web/fixtures/bible/inline.css");
	r += nrule; d += ndecl; a += nattrib; ps += npseudo;
	# CSS3 tallies come from the inline sheet (where :root/var/@media live)
	m3 := nmedia; c3 := ncustom; v3 := nvar;

	t->ok((pe1 == nil || pe1 == "") && (perr == nil || perr == ""),
		"site css: parse without error");
	t->ok(r > 0, "site css: rulesets parsed (" + string r + ")");
	t->ok(d > 0, "site css: declarations parsed (" + string d + ")");
	t->ok(a > 0, "site css: attribute selectors (" + string a + ")");
	t->ok(ps > 0, "site css: pseudo selectors (" + string ps + ")");

	# --- 3. CSS3 constructs: expected to be dropped by a 2.1 parser --------
	t->skip("site css: @media feature queries (saw " + string m3 + ")",
		"CSS3 Media Queries - out of scope until the CSS3 step");
	t->skip("site css: custom properties --x (saw " + string c3 + ")",
		"CSS3 Custom Properties - out of scope until the CSS3 step");
	t->skip("site css: var() references (saw " + string v3 + ")",
		"CSS3 Variables - out of scope until the CSS3 step");

	t->summary();
}

# parse one stylesheet file, populating the module-level counters
analyze(path: string)
{
	nrule = ndecl = nmedia = nattrib = npseudo = nvar = ncustom = 0;
	perr = nil;
	src := readfile(path);
	if(len src == 0){
		perr = "could not read " + path;
		return;
	}
	(ss, err) := css->parse(src);
	perr = err;
	if(ss == nil)
		return;
	for(sl := ss.statements; sl != nil; sl = tl sl)
		walkstmt(hd sl);
}

walkstmt(st: ref CSS->Statement)
{
	pick s := st {
	Ruleset =>
		ruleset(s.selectors, s.decls);
	Media =>
		nmedia++;
		for(rl := s.rules; rl != nil; rl = tl rl){
			r := hd rl;		# ref Statement.Ruleset
			ruleset(r.selectors, r.decls);
		}
	Page =>
		walkdecls(s.decls);
	}
}

ruleset(sels: list of CSS->Selector, decls: list of ref CSS->Decl)
{
	nrule++;
	walksels(sels);
	walkdecls(decls);
}

walksels(sels: list of CSS->Selector)
{
	for(; sels != nil; sels = tl sels){
		sel := hd sels;			# list of (int, Simplesel)
		for(cl := sel; cl != nil; cl = tl cl){
			(nil, simple) := hd cl;	# (combinator, Simplesel)
			for(sp := simple; sp != nil; sp = tl sp){
				pick x := hd sp {
				Attrib =>	nattrib++;
				Pseudo =>	npseudo++;
				}
			}
		}
	}
}

walkdecls(decls: list of ref CSS->Decl)
{
	for(; decls != nil; decls = tl decls){
		d := hd decls;
		ndecl++;
		if(len d.property >= 2 && d.property[0:2] == "--")
			ncustom++;
		for(vl := d.values; vl != nil; vl = tl vl)
			nvar += countvar(hd vl);
	}
}

countvar(v: ref CSS->Value): int
{
	n := 0;
	pick x := v {
	Function =>
		if(x.name == "var")
			n = 1;
		for(al := x.args; al != nil; al = tl al)
			n += countvar(hd al);
	}
	return n;
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
