implement DomjsTest;

#
# Tests the JavaScript DOM binding (domjs.b) end-to-end: it drives the real
# ECMAScript engine over a real Dom tree (built with Build->htmltodom from
# synthetic Lex tokens) and asserts the results of evaluating JavaScript.
#
# Each test runs a snippet that ends by assigning to the global `R`, then reads
# R back -- robust regardless of how the engine reports statement completion
# values.  Snippets share one engine + tree, so later tests see earlier
# mutations (ordered accordingly).
#

include "common.m";		# lex/dom/build (+deps), charon url.m wins
include "ecmascript.m";
include "domjs.m";
include "testing.m";

sys: Sys;
ES: Ecmascript;
dom: Dom;
lex: Lex;
	Token, Attr: import lex;
build: Build;
domjs: Domjs;
t: Testing;
ex: ref Ecmascript->Exec;

DomjsTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();

	ES = load Ecmascript Ecmascript->PATH;
	dom = load Dom Dom->PATH;
	lex = load Lex Lex->PATH;
	build = load Build Build->PATH;
	domjs = load Domjs Domjs->PATH;
	if(ES == nil || dom == nil || lex == nil || build == nil || domjs == nil){
		t->ok(0, "load Ecmascript + Dom + Lex + Build + Domjs");
		t->summary();
		return;
	}
	t->ok(1, "load modules");

	if(ES->init() != nil){
		t->ok(0, "Ecmascript init");
		t->summary();
		return;
	}
	dom->init();
	domjs->init(ES);
	ex = ES->mkexec(nil);

	# <html><body><div id=main class="box"><p id=greet>Hello <b>world</b></p></div></body></html>
	toks := list of {
		mko(Lex->Thtml), mko(Lex->Tbody),
		mko2(Lex->Tdiv, Lex->Aid, "main", Lex->Aclass, "box"),
		mko1(Lex->Tp, Lex->Aid, "greet"),
		mkd("Hello "), mko(Lex->Tb), mkd("world"), mke(Lex->Tb),
		mke(Lex->Tp), mke(Lex->Tdiv),
		mko(Lex->Tscript), mkd("var z = 1;"), mke(Lex->Tscript),
		mke(Lex->Tbody), mke(Lex->Thtml)
	};
	root := build->htmltodom(lex, toks);
	domjs->install(ex, ex.global, root, nil);
	t->ok(root != nil, "built + installed DOM tree");

	# --- read-only queries -------------------------------------------------
	chk("getElementById + tagName",
		"R = document.getElementById('greet').tagName", "P");
	chk("className property",
		"R = document.getElementById('main').className", "box");
	chk("textContent flattens nested inline",
		"R = document.getElementById('greet').textContent", "Hello world");
	chk("getElementById miss is null",
		"R = document.getElementById('nope')", "null");
	chk("nodeType of element is 1",
		"R = document.getElementById('main').nodeType", "1");
	chk("getElementsByTagName length",
		"R = document.getElementsByTagName('p').length", "1");
	chk("documentElement tagName",
		"R = document.documentElement.tagName", "HTML");
	chk("element.getElementsByTagName",
		"R = document.getElementById('main').getElementsByTagName('p').length", "1");

	# --- createElement (detached) ------------------------------------------
	chk("createElement tagName",
		"R = document.createElement('span').tagName", "SPAN");

	# --- mutation: setAttribute / getAttribute -----------------------------
	chk("setAttribute then getAttribute",
		"var e=document.getElementById('main'); e.setAttribute('data-x','7'); R = e.getAttribute('data-x')", "7");

	# --- mutation: appendChild + createElement + textContent set -----------
	chk("appendChild a new element grows textContent",
		"var b=document.createElement('b'); b.textContent='!'; " +
		"var g=document.getElementById('greet'); g.appendChild(b); R = g.textContent",
		"Hello world!");
	chk("textContent setter replaces children",
		"var g=document.getElementById('greet'); g.textContent='Bye'; R = g.textContent", "Bye");

	# --- mutation: id setter is reflected by getElementById ----------------
	chk("setting id is visible to getElementById",
		"document.getElementById('main').id='main2'; R = document.getElementById('main2').tagName", "DIV");
	chk("old id no longer resolves",
		"R = document.getElementById('main')", "null");

	# --- the re-render bridge: serialize the mutated DOM (what Esettext sends) --
	h := domjs->serialize(root);
	t->ok(!contains(h, "script"), "serialized DOM omits <script> (no re-run on refresh)");
	t->ok(contains(h, "main2"), "serialized DOM reflects the id mutation");
	t->ok(contains(h, "Bye"), "serialized DOM reflects the textContent mutation");

	t->summary();
}

# run snippet (which assigns to global R), read R back as a string, compare.
chk(name, src, want: string)
{
	c := ES->eval(ex, src);
	if(c.kind == ES->CThrow){
		t->eqs("THROW:" + ex.error, want, name);
		return;
	}
	rv := ES->get(ex, ex.global, "R");
	t->eqs(ES->toString(ex, rv), want, name);
}

# --- synthetic Lex token constructors -----------------------------------
mko(tag: int): ref Token			{ return ref Token(tag, "", nil); }
mko1(tag, a0: int, v0: string): ref Token	{ return ref Token(tag, "", Attr(a0, v0) :: nil); }
mko2(tag, a0: int, v0: string, a1: int, v1: string): ref Token
{
	return ref Token(tag, "", Attr(a0, v0) :: Attr(a1, v1) :: nil);
}
mke(tag: int): ref Token			{ return ref Token(tag + Lex->RBRA, "", nil); }
mkd(s: string): ref Token			{ return ref Token(Lex->Data, s, nil); }

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}
