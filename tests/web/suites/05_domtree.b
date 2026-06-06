implement DomTest;

#
# Unit test for Charon's retained DOM node tree (appl/charon/dom.{m,b}).
#
# Pure data-structure logic -- no display, no ECMAScript -- so it runs headless
# under emu-g exactly like the cssparse/cascade suites.  It exercises tree
# construction + mutation (append/insert/remove, move semantics), attribute
# get/set/del, the query helpers (byid, bytag, textContent), and the
# stack-driven Builder that build.b will drive from the token stream.
#

include "sys.m";
include "draw.m";
include "dom.m";
include "testing.m";

sys: Sys;
dom: Dom;
t: Testing;
Node, Builder: import dom;	# adt types bound to the loaded Dom instance

DomTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();

	dom = load Dom Dom->PATH;
	if(dom == nil){
		t->ok(0, "load Dom module (" + Dom->PATH + ")");
		t->summary();
		return;
	}
	t->ok(1, "load Dom module");
	dom->init();

	# ---- construction + append ordering -----------------------------------
	doc := dom->newdoc();
	html := dom->newelem("html", nil);
	doc.append(html);
	body := dom->newelem("body", nil);
	html.append(body);
	t->ok(body.parent == html, "append sets parent");
	t->ok(html.firstkid == body && html.lastkid == body, "single child: first==last");

	p1 := dom->newelem("p", ("id", "a") :: nil);
	p2 := dom->newelem("p", ("id", "b") :: nil);
	p3 := dom->newelem("p", ("id", "c") :: nil);
	body.append(p1);
	body.append(p2);
	body.append(p3);
	t->eqs(orderids(body), "a b c", "append preserves document order");
	t->ok(body.firstkid == p1 && body.lastkid == p3, "first/last after appends");
	t->ok(p2.prevsib == p1 && p2.nextsib == p3, "sibling links wired");

	# ---- insert before ----------------------------------------------------
	px := dom->newelem("p", ("id", "x") :: nil);
	body.insert(px, p2);			# before "b"
	t->eqs(orderids(body), "a x b c", "insert before a middle child");
	py := dom->newelem("p", ("id", "y") :: nil);
	body.insert(py, nil);			# nil `before` => append
	t->eqs(orderids(body), "a x b c y", "insert with nil-before appends");

	# ---- remove -----------------------------------------------------------
	body.remove(p1);
	t->eqs(orderids(body), "x b c y", "remove first child");
	t->ok(p1.parent == nil && body.firstkid == px, "removed node detached; first updated");
	body.remove(p3);			# interior "c"
	t->eqs(orderids(body), "x b y", "remove interior child relinks siblings");

	# ---- move semantics: re-appending an attached node detaches it --------
	html.append(p2);			# p2 was under body
	t->ok(p2.parent == html, "re-append moves node to a new parent");
	t->eqs(orderids(body), "x y", "old parent loses the moved node");

	# ---- attributes -------------------------------------------------------
	e := dom->newelem("div", ("id", "d1") :: ("class", "foo bar") :: nil);
	t->eqs(e.attr("id"), "d1", "attr read");
	t->eqs(e.getid(), "d1", "getid");
	t->ok(e.hasclass("bar") && !e.hasclass("baz"), "hasclass membership");
	e.setattr("id", "d2");
	t->eqs(e.attr("id"), "d2", "setattr replaces existing");
	e.setattr("data-x", "1");
	t->eqs(e.attr("data-x"), "1", "setattr adds new attribute");
	e.delattr("class");
	t->ok(!e.hasclass("foo"), "delattr removes attribute");

	# ---- byid (depth-first over descendants) ------------------------------
	doc2 := dom->newdoc();
	h2 := dom->newelem("html", nil);		doc2.append(h2);
	b2 := dom->newelem("body", nil);		h2.append(b2);
	dx := dom->newelem("div", ("id", "X") :: nil);	b2.append(dx);
	sy := dom->newelem("section", ("id", "Y") :: nil);	b2.append(sy);
	sp := dom->newelem("span", ("id", "Z") :: nil);	sy.append(sp);
	t->ok(doc2.byid("Z") == sp, "byid finds a deeply nested descendant");
	t->ok(doc2.byid("X") == dx, "byid finds a shallow descendant");
	t->ok(doc2.byid("nope") == nil, "byid miss returns nil");

	# ---- bytag (document order) -------------------------------------------
	dx.append(dom->newelem("span", nil));		# a second span, under div
	spans := doc2.bytag("span");
	t->eqi(big len spans, big 2, "bytag count");
	t->eqi(big len doc2.bytag("*"), big 6, "bytag * matches every element");

	# ---- textContent ------------------------------------------------------
	para := dom->newelem("p", nil);
	para.append(dom->newtext("Hello, "));
	bold := dom->newelem("b", nil);
	para.append(bold);
	bold.append(dom->newtext("world"));
	para.append(dom->newtext("!"));
	t->eqs(para.text(), "Hello, world!", "textContent concatenates descendant text");

	# ---- Builder: stack-driven construction -------------------------------
	bld := Builder.new();
	bld.open("html", nil);
	bld.open("body", nil);
	bld.open("p", ("id", "greet") :: nil);
	bld.addtext("hi");
	bld.close("p");
	bld.void("br", nil);
	bld.open("p", nil);
	bld.addtext("bye");			# deliberately not closed: test tolerance
	bld.close("body");
	bld.close("html");
	r := bld.root;
	t->ok(r.byid("greet") != nil, "builder: byid after build");
	t->eqs(r.byid("greet").text(), "hi", "builder: text under a built element");
	t->eqi(big len r.bytag("p"), big 2, "builder: two paragraphs");
	t->eqi(big len r.bytag("body"), big 1, "builder: one body");
	t->eqs(r.text(), "hibye", "builder: full-document textContent");
	bld.close("nosuchtag");			# stray end tag: must be a harmless no-op
	t->ok(1, "builder: stray end tag ignored without crashing");

	# ---- HTML serialization (the re-render bridge) ------------------------
	sdoc := dom->newdoc();
	pel := dom->newelem("p", ("id", "x") :: ("class", "y") :: nil);
	sdoc.append(pel);
	pel.append(dom->newtext("a < b & \"c\""));
	t->eqs(sdoc.html(), "<p id=\"x\" class=\"y\">a &lt; b &amp; \"c\"</p>",
		"html() serializes attrs + escapes text");
	bel := dom->newelem("b", nil);
	pel.append(bel);
	bel.append(dom->newtext("z"));
	t->eqs(sdoc.html(), "<p id=\"x\" class=\"y\">a &lt; b &amp; \"c\"<b>z</b></p>",
		"html() nests children in document order");

	t->summary();
}

# space-join the ids of an element's direct element children, in document order
orderids(n: ref Node): string
{
	s := "";
	for(c := n.firstkid; c != nil; c = c.nextsib){
		if(c.ty == Dom->Nelement){
			if(s != "")
				s += " ";
			s += c.getid();
		}
	}
	return s;
}
