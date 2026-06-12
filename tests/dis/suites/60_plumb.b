implement PlumbTest;

#
# Avenue 6: the plumber stack — Regex, Plumbmsg, Plumbing.
#
# These modules back wm/wm's plumber but were never exercised by the other
# headless suites.  Regex and the plumbing rule parser are heavy
# code-generation / automaton paths that are sensitive to the LP64 port; a
# bug there surfaces at runtime as "illegal dis instruction" or "module not
# loaded" rather than a wrong answer, so a green run is itself the assertion
# that the VM executes the compiled automata and module dispatch correctly on
# 64-bit hosts.
#
include "sys.m";
include "draw.m";
include "regex.m";
include "plumbmsg.m";
include "plumbing.m";
include "testing.m";

sys: Sys;
t: Testing;
regex: Regex;
plumbmsg: Plumbmsg;
plumbing: Plumbing;

Re: import regex;
Msg, Attr: import plumbmsg;
Rule, Pattern: import plumbing;

BUILD: con "/tests/dis/_build";

PlumbTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

matched(re: Re, s: string): string
{
	ranges := regex->execute(re, s);
	if(len ranges == 0)
		return "<nomatch>";
	(start, end) := ranges[0];
	if(start < 0)
		return "<nomatch>";
	return s[start:end];
}

submatch(re: Re, s: string, i: int): string
{
	ranges := regex->execute(re, s);
	if(len ranges <= i)
		return "<none>";
	(start, end) := ranges[i];
	if(start < 0)
		return "<none>";
	return s[start:end];
}

compileok(pat: string): Re
{
	(re, err) := regex->compile(pat, 1);
	t->ok(re != nil, sys->sprint("regex compile %#q (err=%q)", pat, err));
	return re;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	regex = load Regex Regex->PATH;
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	plumbing = load Plumbing Plumbing->PATH;
	t->init();

	t->ok(regex != nil, "load Regex");
	t->ok(plumbmsg != nil, "load Plumbmsg");
	t->ok(plumbing != nil, "load Plumbing");

	# plumbmsg's module-level helpers (string2attrs/lookup) call sys->...,
	# and plumbmsg loads Sys only inside init(); server mode (0,nil,0)
	# loads Sys and returns without touching /chan.
	t->eqi(big plumbmsg->init(0, nil, 0), big 1, "plumbmsg init (server mode)");

	# ---- Regex: compile + execute over a spread of constructs ----
	re := compileok("a.*b");
	t->eqs(matched(re, "axxxb"), "axxxb", "regex .* greedy match");
	t->eqs(matched(re, "ab"), "ab", "regex .* empty middle");
	t->eqs(matched(re, "xyz"), "<nomatch>", "regex .* no match");

	re = compileok("^[0-9]+$");
	t->eqs(matched(re, "12345"), "12345", "regex anchored digits match");
	t->eqs(matched(re, "12a45"), "<nomatch>", "regex anchored digits reject");

	re = compileok("[a-z]+");
	t->eqs(matched(re, "  hello  "), "hello", "regex class run inside text");

	re = compileok("(cat|dog|bird)");
	t->eqs(matched(re, "I have a dog."), "dog", "regex alternation");
	t->eqs(matched(re, "fish"), "<nomatch>", "regex alternation no match");

	re = compileok("(a+)(b+)");
	t->eqs(matched(re, "aaabb"), "aaabb", "regex submatch whole");
	t->eqs(submatch(re, "aaabb", 1), "aaa", "regex submatch group 1");
	t->eqs(submatch(re, "aaabb", 2), "bb", "regex submatch group 2");

	# multi-range / mixed character classes (exercises class-set codegen)
	re = compileok("[a-zA-Z]+");
	t->eqs(matched(re, "  MixedCase42  "), "MixedCase", "regex multi-range class");
	re = compileok("[A-Za-z0-9_]+");
	t->eqs(matched(re, " foo_Bar9 "), "foo_Bar9", "regex word-char class");

	# file:line, the canonical plumbing capture
	re = compileok("([a-z]+):([0-9]+)");
	t->eqs(matched(re, "see main:42 now"), "main:42", "regex file:line whole");
	t->eqs(submatch(re, "see main:42 now", 1), "main", "regex file:line name");
	t->eqs(submatch(re, "see main:42 now", 2), "42", "regex file:line number");

	# executese: windowed search
	re = compileok("b+");
	rs := regex->executese(re, "abbbc", (1, 4), 0, 0);
	gotlen := 0;
	if(len rs > 0){
		(s0, e0) := rs[0];
		gotlen = e0 - s0;
	}
	t->eqi(big gotlen, big 3, "regex executese windowed match length");

	# ---- Plumbmsg: pack / unpack round-trip ----
	m := ref Msg;
	m.src = "test";
	m.dst = "edit";
	m.dir = "/usr/inferno";
	m.kind = "text";
	m.attr = "addr=42 action=showfile";
	m.data = array of byte "hello plumbing";

	packed := m.pack();
	t->ok(len packed > 0, "plumbmsg pack non-empty");
	m2 := Msg.unpack(packed);
	t->ok(m2 != nil, "plumbmsg unpack");
	if(m2 != nil){
		t->eqs(m2.src, m.src, "plumbmsg round-trip src");
		t->eqs(m2.dst, m.dst, "plumbmsg round-trip dst");
		t->eqs(m2.dir, m.dir, "plumbmsg round-trip dir");
		t->eqs(m2.kind, m.kind, "plumbmsg round-trip kind");
		t->eqs(m2.attr, m.attr, "plumbmsg round-trip attr");
		t->eqs(string m2.data, string m.data, "plumbmsg round-trip data");
		t->eqi(big len m2.data, big len m.data, "plumbmsg round-trip data length");
	}

	# ---- Plumbmsg: attribute parsing (tab-separated, the wire format) ----
	attrs := plumbmsg->string2attrs("addr=42\taction=showfile\tname=foo");
	t->eqi(big len attrs, big 3, "string2attrs count");
	(found, val) := plumbmsg->lookup(attrs, "action");
	t->ok(found != 0, "attr lookup found");
	t->eqs(val, "showfile", "attr lookup value");
	(found2, nil) := plumbmsg->lookup(attrs, "nope");
	t->ok(found2 == 0, "attr lookup absent");
	# round-trip through attrs2string
	round := plumbmsg->string2attrs(plumbmsg->attrs2string(attrs));
	t->eqi(big len round, big 3, "attrs2string -> string2attrs round-trip count");

	# ---- Plumbing: the rule parser + regex-backed matcher ----
	rulesrc :=
		"type	is	text\n" +
		"data	matches	'([a-z]+):([0-9]+)'\n" +
		"plumb	to	edit\n" +
		"plumb	start	edit $0\n" +
		"\n" +
		"type	is	text\n" +
		"data	matches	'(https?://[a-zA-Z0-9./]+)'\n" +
		"plumb	to	web\n" +
		"plumb	start	webbrowse $0\n";
	rfpath := BUILD + "/test_plumbing";
	fd := sys->create(rfpath, Sys->OWRITE, 8r644);
	if(fd == nil){
		t->ok(0, sys->sprint("create rules file %s: %r", rfpath));
	}else{
		b := array of byte rulesrc;
		sys->write(fd, b, len b);
		fd = nil;
		(rules, err) := plumbing->init(regex, rfpath :: nil);
		t->ok(err == nil, sys->sprint("plumbing->init parses rules (err=%q)", err));
		nrules := 0;
		gotre := 0;
		for(rl := rules; rl != nil; rl = tl rl){
			r0 := hd rl;
			nrules++;
			for(i := 0; i < len r0.pattern; i++)
				if(r0.pattern[i].pred == "matches" && r0.pattern[i].regex != nil){
					gotre = 1;
					if(nrules == 1)	# first rule: file:line capture
						t->eqs(matched(r0.pattern[i].regex, "open main:42 please"),
							"main:42", "plumbing rule regex matches");
				}
		}
		t->eqi(big nrules, big 2, "plumbing parsed 2 rules");
		t->ok(gotre, "plumbing rule carries a compiled regex");
	}

	t->summary();
}
