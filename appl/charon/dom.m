Dom: module
{
	PATH:	con "/dis/charon/dom.dis";

	#
	# Charon's in-memory element representation: a retained document tree.
	#
	# The flat display-item list (Build->Item, linked by .next) is a render
	# stream -- it cannot express nesting, container or non-rendered elements
	# (<head>, <script>, an empty <div>), or an addressable parent chain.  This
	# tree is that missing structural model.  It is built once while parsing
	# (see Builder, driven from build.b) and is deliberately independent of both
	# the display items and the ECMAScript engine: layout/selectors read it, and
	# a later DOM/JS binding layer exposes its nodes as host objects.
	#
	# Node is a pick adt -- the natural fit for a heterogeneous tree whose kinds
	# share structure (parent/kids) but dispatch at run time.  (Not generics:
	# there is no varying type parameter here, only varying node kinds.)
	#

	# node kinds; n.ty caches `tagof n` for convenient case-dispatch
	Ndocument, Nelement, Ntext, Ncomment: con iota;

	# Children use child + sibling pointers (the canonical DOM shape) rather than
	# a Limbo `list`: that gives O(1) ordered append/insert/remove and maps 1:1
	# onto the firstChild/nextSibling navigation the JS binding will expose.
	# Iterate with:  for(c := n.firstkid; c != nil; c = c.nextsib) ...
	Node: adt
	{
		ty:		int;				# Ndocument / Nelement / Ntext / Ncomment
		parent:	cyclic ref Node;		# nil for the document root
		firstkid:	cyclic ref Node;		# first child (nil if none)
		lastkid:	cyclic ref Node;		# last child  (nil if none)
		nextsib:	cyclic ref Node;		# next sibling under the same parent
		prevsib:	cyclic ref Node;		# previous sibling

		pick {
		Document =>
			# the root; one per parsed document
		Element =>
			tag:	string;				# lower-cased tag name ("div", "p", ...)
			attrs:	list of (string, string);	# raw attributes, in source order
			# Retained render state lives on the node (it must survive re-layout,
			# which discards the display items, and the JS exec context, which is
			# rebuilt each re-render).  For <canvas>: the backing image the 2D
			# context draws into and layout blits.  nil for every other element.
			canvasim: ref Draw->Image;
		Text =>
			data:	string;				# character data
		Comment =>
			data:	string;				# <!-- ... --> content
		}

		#
		# tree mutation (maintain parent links + document order)
		#
		append:	fn(n: self ref Node, c: ref Node);		# c becomes last child
		insert:	fn(n: self ref Node, c, before: ref Node);	# insert c before child `before` (nil => append)
		remove:	fn(n: self ref Node, c: ref Node);		# detach direct child c

		#
		# attribute access (Element only; no-op / "" elsewhere)
		#
		attr:		fn(n: self ref Node, name: string): string;	# "" if absent
		setattr:	fn(n: self ref Node, name, val: string);	# replace or add
		delattr:	fn(n: self ref Node, name: string);

		#
		# convenience queries
		#
		getid:	fn(n: self ref Node): string;			# attr "id"
		hasclass:	fn(n: self ref Node, cl: string): int;		# membership in class= list
		byid:		fn(n: self ref Node, id: string): ref Node;	# depth-first; nil if none
		bytag:	fn(n: self ref Node, tag: string): list of ref Node;	# all descendants, document order
		text:		fn(n: self ref Node): string;			# textContent (descendant text, concatenated)
		html:		fn(n: self ref Node): string;			# serialize subtree back to HTML (re-parseable)
		root:		fn(n: self ref Node): ref Node;			# walk up to the Document node

		dump:		fn(n: self ref Node, depth: int);		# debug: indented tree
	};

	# free constructors
	newdoc:	fn(): ref Node;
	newelem:	fn(tag: string, attrs: list of (string, string)): ref Node;
	newtext:	fn(data: string): ref Node;
	newcomment:	fn(data: string): ref Node;

	#
	# Stack-driven tree builder, so build.b can grow the tree as it walks the
	# token stream without owning the bookkeeping.  open() pushes an element and
	# makes it current; close() pops (tolerant of unbalanced/implied end tags);
	# void()/addtext()/addcomment() add a child to the current element without
	# pushing.  HTML's optional-end-tag and misnesting rules stay in build.b; the
	# builder just keeps a well-formed tree from whatever sequence it is given.
	#
	Builder: adt
	{
		root:	ref Node;		# the Document node
		cur:		ref Node;		# current open element (or the document root)
		stack:	list of ref Node;	# open-element stack (cur is its head)

		new:		fn(): ref Builder;
		open:		fn(b: self ref Builder, tag: string, attrs: list of (string,string)): ref Node;
		close:	fn(b: self ref Builder, tag: string);
		void:		fn(b: self ref Builder, tag: string, attrs: list of (string,string)): ref Node;
		addtext:	fn(b: self ref Builder, data: string): ref Node;
		addcomment:	fn(b: self ref Builder, data: string): ref Node;
	};

	init:	fn();
};
