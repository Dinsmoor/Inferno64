implement Dom;

#
# Charon's retained element-node tree.  See dom.m for the rationale.
#
# Near-pure data structure: depends on Sys (tokenize/print) and Draw (only for
# the <canvas> backing-image type on Node.Element; no Draw module is loaded
# here).  It still builds and unit-tests headless, independent of the rest of
# Charon and of the ECMAScript engine.
#

include "sys.m";
include "draw.m";
include "dom.m";

sys: Sys;

init()
{
	sys = load Sys Sys->PATH;
}

# ------------------------------------------------------------- constructors

newdoc(): ref Node
{
	return ref Node.Document(Ndocument, nil, nil, nil, nil, nil);
}

newelem(tag: string, attrs: list of (string, string)): ref Node
{
	return ref Node.Element(Nelement, nil, nil, nil, nil, nil, tag, attrs, nil);
}

newtext(data: string): ref Node
{
	return ref Node.Text(Ntext, nil, nil, nil, nil, nil, data);
}

newcomment(data: string): ref Node
{
	return ref Node.Comment(Ncomment, nil, nil, nil, nil, nil, data);
}

# --------------------------------------------------------------- mutation

# append c as n's last child (detaching it from any previous parent first).
Node.append(n: self ref Node, c: ref Node)
{
	if(c == nil)
		return;
	if(c.parent != nil)
		c.parent.remove(c);
	c.parent = n;
	c.prevsib = n.lastkid;
	c.nextsib = nil;
	if(n.lastkid != nil)
		n.lastkid.nextsib = c;
	else
		n.firstkid = c;
	n.lastkid = c;
}

# insert c immediately before child `before`; nil `before` means append.
Node.insert(n: self ref Node, c, before: ref Node)
{
	if(c == nil)
		return;
	if(before == nil) {
		n.append(c);
		return;
	}
	if(before.parent != n)		# `before` is not our child: nothing sensible to do
		return;
	if(c.parent != nil)
		c.parent.remove(c);
	c.parent = n;
	c.nextsib = before;
	c.prevsib = before.prevsib;
	if(before.prevsib != nil)
		before.prevsib.nextsib = c;
	else
		n.firstkid = c;
	before.prevsib = c;
}

# detach direct child c from n.
Node.remove(n: self ref Node, c: ref Node)
{
	if(c == nil || c.parent != n)
		return;
	if(c.prevsib != nil)
		c.prevsib.nextsib = c.nextsib;
	else
		n.firstkid = c.nextsib;
	if(c.nextsib != nil)
		c.nextsib.prevsib = c.prevsib;
	else
		n.lastkid = c.prevsib;
	c.parent = nil;
	c.prevsib = nil;
	c.nextsib = nil;
}

# --------------------------------------------------------------- attributes

# value of attribute `name`, or "" if absent / not an element.
Node.attr(n: self ref Node, name: string): string
{
	pick e := n {
	Element =>
		for(al := e.attrs; al != nil; al = tl al) {
			(nm, v) := hd al;
			if(nm == name)
				return v;
		}
	}
	return "";
}

# set (replacing) or add attribute `name`; preserves source order, new attrs
# go at the end.  No-op on non-elements.
Node.setattr(n: self ref Node, name, val: string)
{
	pick e := n {
	Element =>
		rev: list of (string, string);
		found := 0;
		for(al := e.attrs; al != nil; al = tl al) {
			(nm, v) := hd al;
			if(nm == name) {
				rev = (name, val) :: rev;
				found = 1;
			} else
				rev = (nm, v) :: rev;
		}
		if(!found)
			rev = (name, val) :: rev;	# after the final reverse, lands last
		e.attrs = revattrs(rev);
	}
}

Node.delattr(n: self ref Node, name: string)
{
	pick e := n {
	Element =>
		rev: list of (string, string);
		for(al := e.attrs; al != nil; al = tl al) {
			(nm, v) := hd al;
			if(nm != name)
				rev = (nm, v) :: rev;
		}
		e.attrs = revattrs(rev);
	}
}

revattrs(l: list of (string, string)): list of (string, string)
{
	r: list of (string, string);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# ----------------------------------------------------------------- queries

Node.getid(n: self ref Node): string
{
	return n.attr("id");
}

Node.hasclass(n: self ref Node, cl: string): int
{
	c := n.attr("class");
	if(c == "")
		return 0;
	(nil, toks) := sys->tokenize(c, " \t\r\n\f");
	for(; toks != nil; toks = tl toks)
		if(hd toks == cl)
			return 1;
	return 0;
}

# depth-first search of descendants (not n itself) for the first element whose
# id == `id`.  Mirrors document.getElementById semantics.
Node.byid(n: self ref Node, id: string): ref Node
{
	for(c := n.firstkid; c != nil; c = c.nextsib) {
		if(c.ty == Nelement && c.getid() == id)
			return c;
		r := c.byid(id);
		if(r != nil)
			return r;
	}
	return nil;
}

# all descendant elements with the given tag (lower-cased), in document order;
# "*" matches every element.
Node.bytag(n: self ref Node, tag: string): list of ref Node
{
	rev := collect(n, tag, nil);
	out: list of ref Node;
	for(; rev != nil; rev = tl rev)
		out = hd rev :: out;
	return out;
}

collect(n: ref Node, tag: string, acc: list of ref Node): list of ref Node
{
	for(c := n.firstkid; c != nil; c = c.nextsib) {
		pick e := c {
		Element =>
			if(tag == "*" || e.tag == tag)
				acc = c :: acc;
		}
		acc = collect(c, tag, acc);
	}
	return acc;
}

# textContent: concatenation of all descendant text data, in document order.
Node.text(n: self ref Node): string
{
	pick t := n {
	Text =>
		return t.data;
	}
	s := "";
	for(c := n.firstkid; c != nil; c = c.nextsib)
		s += c.text();
	return s;
}

# serialize the subtree back to HTML.  Re-parseable by htmltodom (build.b), so it
# is the bridge that lets a mutated DOM re-drive Charon's render pipeline.
Node.html(n: self ref Node): string
{
	pick x := n {
	Text =>
		return esctext(x.data);
	Comment =>
		return "<!--" + x.data + "-->";
	Element =>
		# <script> is excluded: html() serializes the *rendered* DOM state for
		# re-layout, and the scripts have already executed -- re-emitting them
		# would re-run on reparse (and loop a mutation->refresh cycle).
		if(x.tag == "script" || x.tag == "noscript")
			return "";
		s := "<" + x.tag + attrhtml(x.attrs) + ">";
		for(c := n.firstkid; c != nil; c = c.nextsib)
			s += c.html();
		return s + "</" + x.tag + ">";
	Document =>
		s := "";
		for(c := n.firstkid; c != nil; c = c.nextsib)
			s += c.html();
		return s;
	}
	return "";
}

# escape text content / attribute values for re-parseable HTML.
esctext(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'&' =>	out += "&amp;";
		'<' =>	out += "&lt;";
		'>' =>	out += "&gt;";
		* =>	out[len out] = s[i];
		}
	return out;
}

escattr(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++)
		case s[i] {
		'&' =>	out += "&amp;";
		'"' =>	out += "&quot;";
		* =>	out[len out] = s[i];
		}
	return out;
}

attrhtml(attrs: list of (string, string)): string
{
	s := "";
	for(; attrs != nil; attrs = tl attrs){
		(nm, v) := hd attrs;
		s += " " + nm + "=\"" + escattr(v) + "\"";
	}
	return s;
}

# the Document root at the top of the parent chain.
Node.root(n: self ref Node): ref Node
{
	p: ref Node = n;
	while(p.parent != nil)
		p = p.parent;
	return p;
}

# ------------------------------------------------------------------- debug

Node.dump(n: self ref Node, depth: int)
{
	ind := "";
	for(i := 0; i < depth; i++)
		ind += "  ";
	pick x := n {
	Document =>
		sys->print("%s#document\n", ind);
	Element =>
		sys->print("%s<%s%s>\n", ind, x.tag, attrstr(x.attrs));
	Text =>
		sys->print("%s#text %q\n", ind, x.data);
	Comment =>
		sys->print("%s<!--%s-->\n", ind, x.data);
	}
	for(c := n.firstkid; c != nil; c = c.nextsib)
		c.dump(depth + 1);
}

attrstr(attrs: list of (string, string)): string
{
	s := "";
	for(; attrs != nil; attrs = tl attrs) {
		(nm, v) := hd attrs;
		s += " " + nm + "=\"" + v + "\"";
	}
	return s;
}

# ------------------------------------------------------------- tree builder

Builder.new(): ref Builder
{
	d := newdoc();
	return ref Builder(d, d, d :: nil);
}

# push a new element as a child of the current node and make it current.
Builder.open(b: self ref Builder, tag: string, attrs: list of (string, string)): ref Node
{
	e := newelem(tag, attrs);
	b.cur.append(e);
	b.stack = e :: b.stack;
	b.cur = e;
	return e;
}

# pop back through the nearest open element whose tag matches; a stray/unmatched
# end tag is ignored.  The Document root is never an element, so it is never
# popped and `cur` always stays valid.
Builder.close(b: self ref Builder, tag: string)
{
	for(s := b.stack; s != nil; s = tl s) {
		pick e := hd s {
		Element =>
			if(e.tag == tag) {
				b.stack = tl s;		# everything below the match
				b.cur = hd b.stack;	# its parent (root is always present)
				return;
			}
		}
	}
}

# add a self-closing / void element (e.g. <br>, <img>) without pushing.
Builder.void(b: self ref Builder, tag: string, attrs: list of (string, string)): ref Node
{
	e := newelem(tag, attrs);
	b.cur.append(e);
	return e;
}

Builder.addtext(b: self ref Builder, data: string): ref Node
{
	t := newtext(data);
	b.cur.append(t);
	return t;
}

Builder.addcomment(b: self ref Builder, data: string): ref Node
{
	c := newcomment(data);
	b.cur.append(c);
	return c;
}
