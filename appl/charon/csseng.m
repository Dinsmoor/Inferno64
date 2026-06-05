# Charon CSS cascade engine.
#
# Sits on top of the W3C CSS2.1 parser (module/css.m): given parsed
# stylesheets and an element's identity (tag/id/class/attrs + ancestor
# chain), it performs selector matching, specificity and the origin
# cascade, and returns the computed property set for that element.
#
# Pure computation: no Draw / Build / layout dependency, so it is unit
# tested headless under emu-g (tests/web/suites/02_cascade.b).  The Charon
# side (build.b) constructs Elem nodes from Genattr and translates the
# resulting Props onto its font/colour/state stacks.
#
# Requires css.m to be included first (uses CSS-> types).

Csseng: module
{
	PATH:	con "/dis/charon/csseng.dis";

	# cascade origins, low precedence to high
	UA, AUTHOR:	con iota;

	# an element's identity for selector matching.  parent gives the
	# ancestor chain for descendant/child combinators.
	Elem: adt {
		tag:		string;				# lower-cased element name
		id:		string;				# "" if none
		classes:	list of string;			# class names (verbatim, HTML-case-sensitive)
		attrs:		list of (string, string);	# other attributes: (lower name, value)
		parent:		cyclic ref Elem;

		new:	fn(tag: string, parent: ref Elem): ref Elem;
		# build from Charon Genattr-style strings (id, space-list class)
		mk:	fn(tag, id, class: string, parent: ref Elem): ref Elem;
		hasclass:	fn(e: self ref Elem, c: string): int;
		attr:		fn(e: self ref Elem, name: string): (string, int);
	};

	# computed property set for one element
	Props: adt {
		ents:	list of (string, list of ref CSS->Value);	# property -> winning values

		# raw winning value list for a property
		val:	fn(p: self ref Props, name: string): (list of ref CSS->Value, int);
		# first keyword/identifier value, lower-cased ("" if absent/not ident)
		ident:	fn(p: self ref Props, name: string): string;
		# whole value list serialised back to CSS text ("" if absent)
		str:	fn(p: self ref Props, name: string): string;
		# colour resolution: (r,g,b,found) from hex / rgb() / named colour
		color:	fn(p: self ref Props, name: string): (int, int, int, int);
		# first <length>/<number>: (value*1000 as int milli-units, units, found)
		unit:	fn(p: self ref Props, name: string): (int, string, int);
		# a <length> resolved to integer pixels: (px, found).  basepx is the
		# reference size for relative units (em/rem/ex against the element's
		# font, % against basepx).  Charon-independent; box-model consumers use it.
		lengthpx: fn(p: self ref Props, name: string, basepx: int): (int, int);
		# normalised CSS font-weight: 0 = unspecified, else 100..900
		# (normal->400, bold/bolder->700, lighter->300, numeric kept as-is)
		fontweight: fn(p: self ref Props, name: string): int;
	};

	# a compiled, specificity-tagged rule (one complex selector)
	Rule: adt {
		sel:	array of (int, list of ref CSS->Select);	# (combinator, simple-selector)
		decls:	list of ref CSS->Decl;
		origin:	int;
		spec:	int;		# packed specificity
		order:	int;		# source order (cascade tiebreak)
	};

	Engine: adt {
		rules:	list of ref Rule;	# source order
		nrules:	int;
		vars:	list of (string, string);	# CSS custom properties (--name -> value)

		addsheet:	fn(e: self ref Engine, ss: ref CSS->Stylesheet, origin: int);
		# compute the cascaded properties for el; inline = parsed `style=` decls
		compute:	fn(e: self ref Engine, el: ref Elem, inline: list of ref CSS->Decl): ref Props;

		# CSS3 custom-property support (textual preprocess before the 2.1 parser):
		# collect --name: value definitions from a sheet's text into the engine,
		addvars:	fn(e: self ref Engine, csstext: string);
		# then substitute var(--name[, fallback]) occurrences using them.
		flatten:	fn(e: self ref Engine, csstext: string): string;
	};

	init:	fn();
	new:	fn(): ref Engine;
};
