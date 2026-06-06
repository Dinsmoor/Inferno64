implement DomBuildTest;

#
# Tests the token-stream -> DOM glue in build.b (domfeed/domattrs/domvoid via the
# exported Build->htmltodom).  Feeds synthetic Lex tokens (no ByteSource, no
# tokenizer, no CharonUtils) and asserts the resulting Dom tree, so it runs
# headless like the other web suites while exercising the *real* build.b code
# that getitems drives during a live parse.
#
# Lex's tagname/attrnames tables are populated at module-load time, so a bare
# `load Lex` (no init) is enough to resolve tag/attribute names.
#

include "common.m";	# pulls sys/draw/lex/dom/build (+deps) in the right order
include "testing.m";

sys: Sys;
lex: Lex;
	Token, Attr: import lex;
dom: Dom;
	Node: import dom;
build: Build;
t: Testing;

DomBuildTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();

	lex = load Lex Lex->PATH;
	build = load Build Build->PATH;
	dom = load Dom Dom->PATH;
	if(lex == nil || build == nil || dom == nil){
		t->ok(0, "load Lex + Build + Dom");
		t->summary();
		return;
	}
	dom->init();				# so Node methods that use sys (hasclass) work
	t->ok(1, "load Lex + Build + Dom");

	# Synthesise the token stream for:
	#   <html><body>
	#     <div id=main class="box">
	#       <p id=greet>Hello <b>world</b></p>
	#       <img src=x.png>
	#       <ul><li>one</li><li>two</li></ul>
	#     </div>
	#     <!-- note -->
	#   </body></html>
	toks := list of {
		mko(Lex->Thtml),
		mko(Lex->Tbody),
		mko2(Lex->Tdiv, Lex->Aid, "main", Lex->Aclass, "box"),
		mko1(Lex->Tp, Lex->Aid, "greet"),
		mkd("Hello "),
		mko(Lex->Tb),
		mkd("world"),
		mke(Lex->Tb),
		mke(Lex->Tp),
		mko1(Lex->Timg, Lex->Asrc, "x.png"),	# void: no end tag
		mko(Lex->Tul),
		mko(Lex->Tli),
		mkd("one"),
		mke(Lex->Tli),
		mko(Lex->Tli),
		mkd("two"),
		mke(Lex->Tli),
		mke(Lex->Tul),
		mke(Lex->Tdiv),
		mkc(" note "),
		mke(Lex->Tbody),
		mke(Lex->Thtml)
	};

	root := build->htmltodom(lex, toks);
	if(root == nil){
		t->ok(0, "htmltodom returned a tree");
		t->summary();
		return;
	}
	t->ok(1, "htmltodom returned a tree");
	t->eqi(big root.ty, big Dom->Ndocument, "root is a Document node");

	# structure: document > html > body > {div, comment}
	html := root.firstkid;
	t->ok(html != nil && html.ty == Dom->Nelement, "document has an element child");
	body := root.byid("");		# no id; use bytag instead
	bodies := root.bytag("body");
	t->eqi(big len bodies, big 1, "exactly one <body>");
	body = hd bodies;

	# byid + textContent across nested inline element
	greet := root.byid("greet");
	t->ok(greet != nil, "byid finds <p id=greet>");
	t->eqs(greet.text(), "Hello world", "textContent flattens nested <b>");

	# class attribute round-trips through domattrs
	maindiv := root.byid("main");
	t->ok(maindiv != nil, "byid finds <div id=main>");
	t->ok(maindiv.hasclass("box"), "class attribute parsed (hasclass)");

	# the div has exactly three element children: p, img, ul
	t->eqi(big nelems(maindiv), big 3, "div has 3 element children (p, img, ul)");

	# void element: <img> is a leaf and did NOT swallow following siblings
	imgs := root.bytag("img");
	t->eqi(big len imgs, big 1, "one <img>");
	img := hd imgs;
	t->ok(img.firstkid == nil, "void <img> has no children");
	t->eqs(img.attr("src"), "x.png", "img src attribute");

	# list structure intact after the void element
	t->eqi(big len root.bytag("li"), big 2, "two <li> after the void <img>");
	t->eqi(big len root.bytag("p"), big 1, "one <p>");

	# comment node carries no text and is not an element
	comments := 0;
	for(c := body.firstkid; c != nil; c = c.nextsib)
		if(c.ty == Dom->Ncomment)
			comments++;
	t->eqi(big comments, big 1, "comment node added under body");
	# body textContent is the concatenation of element text only (no comment text)
	t->eqs(body.text(), "Hello worldonetwo", "body textContent excludes comment");

	t->summary();
}

# --- synthetic token constructors ---------------------------------------
mko(tag: int): ref Token			# start tag, no attributes
{
	return ref Token(tag, "", nil);
}
mko1(tag, a0: int, v0: string): ref Token	# start tag, one attribute
{
	return ref Token(tag, "", Attr(a0, v0) :: nil);
}
mko2(tag, a0: int, v0: string, a1: int, v1: string): ref Token
{
	return ref Token(tag, "", Attr(a0, v0) :: Attr(a1, v1) :: nil);
}
mke(tag: int): ref Token			# end tag
{
	return ref Token(tag + Lex->RBRA, "", nil);
}
mkd(s: string): ref Token			# character data
{
	return ref Token(Lex->Data, s, nil);
}
mkc(s: string): ref Token			# comment
{
	return ref Token(Lex->Comment, s, nil);
}

nelems(n: ref Node): int
{
	k := 0;
	for(c := n.firstkid; c != nil; c = c.nextsib)
		if(c.ty == Dom->Nelement)
			k++;
	return k;
}
