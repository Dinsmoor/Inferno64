implement Csseng;

#
# Charon CSS cascade engine (see csseng.m).  Selector matching, specificity,
# origin cascade over the W3C CSS2.1 parser's output.  Pure computation.
#

include "sys.m";
	sys: Sys;
include "css.m";
include "csseng.m";

# combinators (the int stored in a Selector entry by css.b)
DESC:	con ' ';	# descendant
CHILD:	con '>';	# child
ADJ:	con '+';	# adjacent sibling (not supported -> never matches)

# inline `style=` gets specificity above any selector
INLINESPEC:	con (1<<28);

# named colour table (HTML4 + a few greys), filled by init()
Namedcol: adt { name: string; r, g, b: int; };
namedcols: array of Namedcol;

init()
{
	sys = load Sys Sys->PATH;
	namedcols = array[] of {
		Namedcol("black",	0,   0,   0),
		Namedcol("white",	255, 255, 255),
		Namedcol("red",		255, 0,   0),
		Namedcol("green",	0,   128, 0),
		Namedcol("blue",	0,   0,   255),
		Namedcol("yellow",	255, 255, 0),
		Namedcol("cyan",	0,   255, 255),
		Namedcol("aqua",	0,   255, 255),
		Namedcol("magenta",	255, 0,   255),
		Namedcol("fuchsia",	255, 0,   255),
		Namedcol("gray",	128, 128, 128),
		Namedcol("grey",	128, 128, 128),
		Namedcol("silver",	192, 192, 192),
		Namedcol("maroon",	128, 0,   0),
		Namedcol("olive",	128, 128, 0),
		Namedcol("lime",	0,   255, 0),
		Namedcol("teal",	0,   128, 128),
		Namedcol("navy",	0,   0,   128),
		Namedcol("purple",	128, 0,   128),
		Namedcol("orange",	255, 165, 0),
	};
}

new(): ref Engine
{
	return ref Engine(nil, 0, nil);
}

# --- Elem ----------------------------------------------------------------

Elem.new(tag: string, parent: ref Elem): ref Elem
{
	return ref Elem(tolower(tag), "", nil, nil, parent);
}

Elem.mk(tag, id, class: string, parent: ref Elem): ref Elem
{
	e := ref Elem(tolower(tag), id, nil, nil, parent);
	e.classes = splitws(class);
	return e;
}

Elem.hasclass(e: self ref Elem, c: string): int
{
	for(l := e.classes; l != nil; l = tl l)
		if(hd l == c)
			return 1;
	return 0;
}

Elem.attr(e: self ref Elem, name: string): (string, int)
{
	for(l := e.attrs; l != nil; l = tl l){
		(n, v) := hd l;
		if(n == name)
			return (v, 1);
	}
	return ("", 0);
}

# --- Engine build --------------------------------------------------------

Engine.addsheet(e: self ref Engine, ss: ref CSS->Stylesheet, origin: int)
{
	if(ss == nil)
		return;
	for(sl := ss.statements; sl != nil; sl = tl sl)
		addstmt(e, hd sl, origin);
}

addstmt(e: ref Engine, st: ref CSS->Statement, origin: int)
{
	pick s := st {
	Ruleset =>
		addrules(e, s.selectors, s.decls, origin);
	Media =>
		if(mediascreen(s.media))
			for(rl := s.rules; rl != nil; rl = tl rl){
				r := hd rl;
				addrules(e, r.selectors, r.decls, origin);
			}
	Page =>
		;	# paged media: ignored for screen rendering
	}
}

# include a @media block only if it applies to screen rendering
mediascreen(media: list of string): int
{
	if(media == nil)
		return 1;
	for(; media != nil; media = tl media){
		m := tolower(hd media);
		if(m == "screen" || m == "all")
			return 1;
	}
	return 0;
}

addrules(e: ref Engine, sels: list of CSS->Selector, decls: list of ref CSS->Decl, origin: int)
{
	for(; sels != nil; sels = tl sels){
		arr := toarray(hd sels);
		r := ref Rule(arr, decls, origin, specof(arr), e.nrules++);
		e.rules = r :: e.rules;	# prepend; compute reverses to source order
	}
}

toarray(sel: CSS->Selector): array of (int, list of ref CSS->Select)
{
	n := 0;
	for(l := sel; l != nil; l = tl l)
		n++;
	a := array[n] of (int, list of ref CSS->Select);
	i := 0;
	for(l = sel; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

# --- specificity ---------------------------------------------------------

specof(arr: array of (int, list of ref CSS->Select)): int
{
	a := b := c := 0;
	for(i := 0; i < len arr; i++){
		(nil, simple) := arr[i];
		for(sl := simple; sl != nil; sl = tl sl){
			pick x := hd sl {
			ID =>		a++;
			Class =>	b++;
			Attrib =>	b++;
			Pseudofn =>	b++;
			Pseudo =>	if(ispseudoelem(tolower(x.name))) c++; else b++;
			Element =>	c++;
			Any =>		;
			}
		}
	}
	return a*1000000 + b*1000 + c;
}

ispseudoelem(n: string): int
{
	return n == "before" || n == "after" || n == "first-line" || n == "first-letter";
}

# --- matching ------------------------------------------------------------

matchcomplex(arr: array of (int, list of ref CSS->Select), idx: int, el: ref Elem): int
{
	(comb, simple) := arr[idx];
	if(!matchsimple(simple, el))
		return 0;
	if(idx == 0)
		return 1;
	case comb {
	CHILD =>
		return el.parent != nil && matchcomplex(arr, idx-1, el.parent);
	ADJ =>
		return 0;	# sibling axis not tracked
	* =>			# descendant
		for(a := el.parent; a != nil; a = a.parent)
			if(matchcomplex(arr, idx-1, a))
				return 1;
		return 0;
	}
}

matchsimple(simple: list of ref CSS->Select, el: ref Elem): int
{
	for(; simple != nil; simple = tl simple){
		pick x := hd simple {
		Any =>
			;
		Element =>
			if(tolower(x.name) != el.tag)
				return 0;
		ID =>
			if(x.name != el.id)
				return 0;
		Class =>
			if(!el.hasclass(x.name))
				return 0;
		Pseudo =>
			if(!matchpseudo(tolower(x.name), el))
				return 0;
		Pseudofn =>
			return 0;	# :nth-child() etc unsupported
		Attrib =>
			if(!matchattr(x, el))
				return 0;
		}
	}
	return 1;
}

matchpseudo(name: string, el: ref Elem): int
{
	case name {
	"root" =>
		return el.parent == nil;
	"link" or "visited" =>
		return el.tag == "a";
	* =>
		# dynamic states (:hover/:focus/:active), structural (:first-child)
		# and pseudo-elements do not apply to a static render
		return 0;
	}
}

matchattr(x: ref CSS->Select.Attrib, el: ref Elem): int
{
	name := tolower(x.name);
	av: string;
	found: int;
	case name {
	"id" =>
		av = el.id; found = el.id != "";
	"class" =>
		# presence / token semantics handled below via classes
		found = el.classes != nil;
		av = "";
	* =>
		(av, found) = el.attr(name);
	}
	if(x.op == nil || x.op == "")
		return found;		# [attr] presence
	want := aval(x.value);
	case x.op {
	"=" =>
		if(name == "class")
			return el.hasclass(want);
		return found && av == want;
	"~=" =>
		if(name == "class")
			return el.hasclass(want);
		return found && tokenmember(av, want);
	"|=" =>
		return found && (av == want || (len av > len want && av[0:len want] == want && av[len want] == '-'));
	}
	return 0;
}

aval(v: ref CSS->Value): string
{
	if(v == nil)
		return "";
	pick x := v {
	Ident =>	return x.name;
	String =>	return x.value;
	}
	return "";
}

tokenmember(s, want: string): int
{
	for(l := splitws(s); l != nil; l = tl l)
		if(hd l == want)
			return 1;
	return 0;
}

# --- cascade -------------------------------------------------------------

# a property's current winner during the cascade
Best: adt { name: string; level, spec, order: int; values: list of ref CSS->Value; };

Engine.compute(e: self ref Engine, el: ref Elem, inline: list of ref CSS->Decl): ref Props
{
	# reverse to source order
	src: list of ref Rule;
	for(l := e.rules; l != nil; l = tl l)
		src = hd l :: src;

	best: list of ref Best;
	seq := 0;
	for(; src != nil; src = tl src){
		r := hd src;
		if(matchcomplex(r.sel, len r.sel - 1, el))
			for(dl := r.decls; dl != nil; dl = tl dl){
				d := hd dl;
				best = consider(best, d.property, d.values,
					level(r.origin, d.important), r.spec, seq++);
			}
	}
	# inline style="" : author origin, specificity above any selector
	for(il := inline; il != nil; il = tl il){
		d := hd il;
		best = consider(best, d.property, d.values,
			level(AUTHOR, d.important), INLINESPEC, seq++);
	}

	ents: list of (string, list of ref CSS->Value);
	for(bl := best; bl != nil; bl = tl bl){
		b := hd bl;
		ents = (b.name, b.values) :: ents;
	}
	return ref Props(ents);
}

# cascade level: higher wins.  UA<author normal; !important lifts author
# above normal; (UA-important would top all, but our UA sheet has none).
level(origin, important: int): int
{
	if(important)
		return 3 + origin;	# AUTHOR important = 4, UA important = 3
	return origin;			# UA = 0, AUTHOR = 1
}

consider(best: list of ref Best, name: string, values: list of ref CSS->Value,
	lvl, spec, order: int): list of ref Best
{
	name = tolower(name);
	for(l := best; l != nil; l = tl l){
		b := hd l;
		if(b.name == name){
			if(beats(lvl, spec, order, b.level, b.spec, b.order)){
				b.level = lvl; b.spec = spec; b.order = order;
				b.values = values;
			}
			return best;
		}
	}
	return ref Best(name, lvl, spec, order, values) :: best;
}

beats(l1, s1, o1, l2, s2, o2: int): int
{
	if(l1 != l2)
		return l1 > l2;
	if(s1 != s2)
		return s1 > s2;
	return o1 >= o2;	# later source order wins ties
}

# --- CSS custom properties / var() (CSS3, textual preprocess) ------------
#
# The W3C CSS2.1 parser drops `--x` declarations and var() values, so we
# resolve them textually BEFORE parsing: addvars() harvests every
# `--name: value` definition from a sheet into the engine (whole-sheet scan,
# so within-sheet forward refs work; called per sheet, so cross-sheet refs
# work when the defining sheet precedes the using one).  flatten() then
# rewrites var(--name[, fallback]) using that map.

Engine.addvars(e: self ref Engine, text: string)
{
	s := stripcomments(text);
	n := len s;
	i := 0;
	while(i < n){
		# a custom property starts with "--"
		if(i+1 < n && s[i] == '-' && s[i+1] == '-'){
			j := i;
			while(j < n && isnamec(s[j]))
				j++;
			name := s[i:j];
			k := j;
			while(k < n && isws(s[k]))
				k++;
			if(k < n && s[k] == ':' && j > i+2){
				k++;
				v0 := k;
				depth := 0;
				while(k < n){
					c := s[k];
					if(c == '(')
						depth++;
					else if(c == ')'){
						if(depth > 0)
							depth--;
					} else if((c == ';' || c == '}') && depth <= 0)
						break;
					k++;
				}
				setvar(e, name, trim(s[v0:k]));
				i = k;
				continue;
			}
		}
		i++;
	}
}

Engine.flatten(e: self ref Engine, text: string): string
{
	# strip comments, drop the --name:value definitions (the 2.1 lexer can't
	# tokenise a `--` ident and would mis-parse the following rule), then
	# substitute var() occurrences.
	return subvars(e, stripdefs(stripcomments(text)), 0);
}

# remove custom-property declarations (--name: value) from a sheet's text
stripdefs(s: string): string
{
	out := "";
	n := len s;
	i := 0;
	while(i < n){
		if(i+1 < n && s[i] == '-' && s[i+1] == '-'){
			j := i;
			while(j < n && isnamec(s[j]))
				j++;
			k := j;
			while(k < n && isws(s[k]))
				k++;
			if(k < n && s[k] == ':' && j > i+2){
				k++;
				depth := 0;
				while(k < n){
					c := s[k];
					if(c == '(')
						depth++;
					else if(c == ')'){
						if(depth > 0)
							depth--;
					} else if(c == ';' && depth <= 0){
						k++;		# consume the terminator
						break;
					} else if(c == '}' && depth <= 0)
						break;		# leave the block close
					k++;
				}
				i = k;
				continue;
			}
		}
		out += s[i:i+1];
		i++;
	}
	return out;
}

subvars(e: ref Engine, s: string, depth: int): string
{
	if(depth > 16)			# guard against cyclic var() definitions
		return s;
	out := "";
	n := len s;
	i := 0;
	while(i < n){
		if(i+4 <= n && s[i:i+4] == "var("){
			k := i+4;
			d := 1;
			astart := k;
			while(k < n && d > 0){
				if(s[k] == '(')
					d++;
				else if(s[k] == ')'){
					d--;
					if(d == 0)
						break;
				}
				k++;
			}
			args := s[astart:k];		# inside var(...)
			(name, fallback) := splitcomma(args);
			(val, found) := getvar(e, trim(name));
			rep: string;
			if(found)
				rep = val;
			else
				rep = trim(fallback);
			rep = subvars(e, rep, depth+1);	# value may itself use var()
			# A var() that resolves to nothing (undefined and no usable
			# fallback) is "guaranteed-invalid" per CSS Variables: the
			# declaration must still win the cascade at its specificity, then
			# compute to `unset` -- it does NOT fall back to a lower-specificity
			# rule.  Substituting the CSS-wide keyword `unset` keeps the
			# declaration present (so e.g. `.book-button{background:var(--x)}`
			# still suppresses a bare `button{background:blue}`), while the value
			# layer treats `unset`/`initial`/`inherit` as not-found -> the
			# property falls to its inherited/initial value (transparent for
			# background-color, inherited colour for `color`).
			if(trim(rep) == "")
				rep = "unset";
			out += rep;
			i = k+1;			# skip past ')'
		} else {
			out += s[i:i+1];
			i++;
		}
	}
	return out;
}

setvar(e: ref Engine, name, val: string)
{
	for(l := e.vars; l != nil; l = tl l){
		(n, nil) := hd l;
		if(n == name){
			# replace in place by rebuilding (rare; lists are short)
			nv: list of (string, string);
			for(m := e.vars; m != nil; m = tl m){
				(mn, mv) := hd m;
				if(mn == name)
					nv = (name, val) :: nv;
				else
					nv = (mn, mv) :: nv;
			}
			e.vars = nv;
			return;
		}
	}
	e.vars = (name, val) :: e.vars;
}

getvar(e: ref Engine, name: string): (string, int)
{
	for(l := e.vars; l != nil; l = tl l){
		(n, v) := hd l;
		if(n == name)
			return (v, 1);
	}
	return ("", 0);
}

# split "a, b" into ("a","b"); no comma -> ("a","")
splitcomma(s: string): (string, string)
{
	depth := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '(')
			depth++;
		else if(c == ')')
			depth--;
		else if(c == ',' && depth <= 0)
			return (s[0:i], s[i+1:]);
	}
	return (s, "");
}

stripcomments(s: string): string
{
	out := "";
	n := len s;
	i := 0;
	while(i < n){
		if(i+1 < n && s[i] == '/' && s[i+1] == '*'){
			i += 2;
			while(i+1 < n && !(s[i] == '*' && s[i+1] == '/'))
				i++;
			i += 2;
		} else {
			out += s[i:i+1];
			i++;
		}
	}
	return out;
}

isnamec(c: int): int
{
	return c == '-' || c == '_' || (c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

trim(s: string): string
{
	i := 0;
	j := len s;
	while(i < j && isws(s[i]))
		i++;
	while(j > i && isws(s[j-1]))
		j--;
	return s[i:j];
}

# --- Props accessors -----------------------------------------------------

Props.val(p: self ref Props, name: string): (list of ref CSS->Value, int)
{
	name = tolower(name);
	for(l := p.ents; l != nil; l = tl l){
		(n, v) := hd l;
		if(n == name)
			return (v, 1);
	}
	return (nil, 0);
}

Props.ident(p: self ref Props, name: string): string
{
	(vals, found) := p.val(name);
	if(!found || vals == nil)
		return "";
	pick x := hd vals {
	Ident =>	return tolower(x.name);
	}
	return "";
}

Props.str(p: self ref Props, name: string): string
{
	(vals, found) := p.val(name);
	if(!found)
		return "";
	return valsstr(vals);
}

Props.color(p: self ref Props, name: string): (int, int, int, int)
{
	(vals, found) := p.val(name);
	if(!found || vals == nil)
		return (0, 0, 0, 0);
	pick x := hd vals {
	Hexcolour =>
		(r, g, b) := x.rgb;
		return (r, g, b, 1);
	RGB =>
		(r, g, b) := x.rgb;
		return (r, g, b, 1);
	Ident =>
		return namedcolor(tolower(x.name));
	Function =>
		fname := tolower(x.name);
		if(fname == "hsl" || fname == "hsla")
			return hslcolor(x.args);
	}
	return (0, 0, 0, 0);
}

# hsl()/hsla() colour resolution.  The CSS parser special-cases only rgb()
# (-> Value.RGB); every other colour function, hsl()/hsla() included, arrives
# as a generic Value.Function, so the cascade never resolved it.  Modern sheets
# lean on hsl() heavily, so convert it to an RGB triple here.  Alpha (hsla's 4th
# arg) is dropped — Charon paints opaque.  found=0 if the args are malformed.
hslcolor(args: list of ref CSS->Value): (int, int, int, int)
{
	if(args == nil || tl args == nil || tl tl args == nil)
		return (0, 0, 0, 0);
	(r, g, b) := hsl2rgb(hslnum(hd args), hslnum(hd tl args), hslnum(hd tl tl args));
	return (r, g, b, 1);
}

# the integer part of a numeric/percentage/<angle> value (hue is degrees,
# saturation/lightness are percentages given without the %)
hslnum(v: ref CSS->Value): int
{
	pick x := v {
	Number =>	return int x.value;
	Percentage =>	return int x.value;
	Unit =>		return int x.value;	# e.g. hsl(280deg, ...)
	}
	return 0;
}

# hue in degrees, saturation & lightness in 0..100 -> (r,g,b) each 0..255
hsl2rgb(hdeg, s100, l100: int): (int, int, int)
{
	h := real(((hdeg % 360) + 360) % 360);
	s := real s100 / 100.0;
	l := real l100 / 100.0;
	c := (1.0 - absr(2.0 * l - 1.0)) * s;
	hp := h / 60.0;
	m2 := hp - 2.0 * real (int (hp / 2.0));	# hp mod 2, hp>=0
	x := c * (1.0 - absr(m2 - 1.0));
	r1 := g1 := b1 := 0.0;
	if(hp < 1.0)      { r1 = c;   g1 = x;   b1 = 0.0; }
	else if(hp < 2.0) { r1 = x;   g1 = c;   b1 = 0.0; }
	else if(hp < 3.0) { r1 = 0.0; g1 = c;   b1 = x;   }
	else if(hp < 4.0) { r1 = 0.0; g1 = x;   b1 = c;   }
	else if(hp < 5.0) { r1 = x;   g1 = 0.0; b1 = c;   }
	else              { r1 = c;   g1 = 0.0; b1 = x;   }
	m := l - c / 2.0;
	return (clamp255(r1 + m), clamp255(g1 + m), clamp255(b1 + m));
}

absr(v: real): real
{
	if(v < 0.0)
		return -v;
	return v;
}

clamp255(v: real): int
{
	n := int (v * 255.0);	# Limbo int(real) already rounds to nearest
	if(n < 0)
		n = 0;
	if(n > 255)
		n = 255;
	return n;
}

Props.unit(p: self ref Props, name: string): (int, string, int)
{
	(vals, found) := p.val(name);
	if(!found || vals == nil)
		return (0, "", 0);
	return valunit(hd vals);
}

Props.lengthpx(p: self ref Props, name: string, basepx: int): (int, int)
{
	(v, units, found) := p.unit(name);	# v in milli-units
	if(!found)
		return (0, 0);
	return resolvelen(v, units, basepx);
}

# Like lengthpx but resolves the n-th (0-based) length-like value in the
# declaration, so it understands shorthands such as `padding: 8px 16px` and
# `border: 1px solid red`.  found=0 if there are fewer than n+1 length tokens.
Props.nthlengthpx(p: self ref Props, name: string, n, basepx: int): (int, int)
{
	(vals, found) := p.val(name);
	if(!found)
		return (0, 0);
	i := 0;
	for(; vals != nil; vals = tl vals){
		(v, units, ok) := valunit(hd vals);
		if(!ok)
			continue;
		if(i == n)
			return resolvelen(v, units, basepx);
		i++;
	}
	return (0, 0);
}

# Scan all values of a declaration for its first colour, so a shorthand like
# `border: 1px solid #ccc` yields #ccc.  found=0 if no colour present.
Props.anycolor(p: self ref Props, name: string): (int, int, int, int)
{
	(vals, found) := p.val(name);
	if(!found)
		return (0, 0, 0, 0);
	for(; vals != nil; vals = tl vals){
		pick x := hd vals {
		Hexcolour =>
			(r, g, b) := x.rgb;
			return (r, g, b, 1);
		RGB =>
			(r, g, b) := x.rgb;
			return (r, g, b, 1);
		Ident =>
			(r, g, b, ok) := namedcolor(tolower(x.name));
			if(ok)
				return (r, g, b, 1);
		Function =>
			fname := tolower(x.name);
			if(fname == "hsl" || fname == "hsla"){
				(r, g, b, ok) := hslcolor(x.args);
				if(ok)
					return (r, g, b, 1);
			}
		}
	}
	return (0, 0, 0, 0);
}

# Resolve an element's background colour from EITHER the `background-color`
# longhand or the `background` shorthand (`background: #0e1116`, or
# `background: var(--bg)` once flattened).  Modern stylesheets overwhelmingly
# set the page/card/button fill through the shorthand, so reading only the
# longhand leaves the whole theme unpainted.  A gradient- or image-only
# background (`background: linear-gradient(...)`) yields found=0 — there is no
# single solid colour to paint, which is the right (graceful) fallback.
# Like the CSS `background` shorthand, this does NOT inherit.
Props.bgcolor(p: self ref Props): (int, int, int, int)
{
	(r, g, b, found) := p.color("background-color");
	if(found)
		return (r, g, b, found);
	return p.anycolor("background");
}

Props.gridtrack(p: self ref Props, basepx: int): (int, int, int)
{
	(vals, found) := p.val("grid-template-columns");
	if(!found || vals == nil)
		return (0, 0, 0);
	# repeat(count-spec, track-list...)
	pick x := hd vals {
	Function =>
		if(tolower(x.name) == "repeat")
			return repeattrack(x.args, basepx);
	}
	# explicit track list: count = number of track values, mincol = first fixed one
	cnt := 0;
	mn := 0;
	for(l := vals; l != nil; l = tl l){
		cnt++;
		if(mn == 0){
			(m, ok) := tracklen(hd l, basepx);
			if(ok)
				mn = m;
		}
	}
	if(cnt == 0)
		return (0, 0, 0);
	return (mn, cnt, 1);
}

# repeat(): first arg is the count (a Number, or auto-fill/auto-fit -> 0); the
# remaining args are the repeated track list, scanned for a minimum length.
repeattrack(args: list of ref CSS->Value, basepx: int): (int, int, int)
{
	if(args == nil)
		return (0, 0, 0);
	cnt := 0;
	pick c := hd args {
	Number =>
		(cv, ok) := parseuint(trimnum(c.value));
		if(ok)
			cnt = cv;
	Unit =>
		(cv, ok) := parseuint(trimnum(c.value));
		if(ok)
			cnt = cv;
	Ident =>
		cnt = 0;	# auto-fill / auto-fit -> derive from width
	}
	mn := 0;
	for(l := tl args; l != nil; l = tl l){
		(m, ok) := tracklen(hd l, basepx);
		if(ok && (mn == 0 || m < mn))
			mn = m;
	}
	return (mn, cnt, 1);
}

# a single track size to px: a fixed length, or the minimum of a minmax(); fr /
# auto / percentage tracks have no fixed pixel minimum (ok=0).
tracklen(v: ref CSS->Value, basepx: int): (int, int)
{
	pick x := v {
	Function =>
		if(tolower(x.name) == "minmax" && x.args != nil)
			return tracklen(hd x.args, basepx);
		return (0, 0);
	* =>
		(mv, units, uok) := valunit(v);
		if(!uok)
			return (0, 0);
		case units {
		"px" or "pt" or "em" or "rem" or "ex" =>
			return resolvelen(mv, units, basepx);
		}
		return (0, 0);
	}
}

# leading integer of a numeric string ("3" / "3.0" -> "3")
trimnum(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return s[0:i];
	return s;
}

Props.fontweight(p: self ref Props, name: string): int
{
	w := p.ident(name);		# bold/bolder/lighter/normal, lower-cased
	if(w == "")
		w = p.str(name);	# numeric weights serialise here ("700")
	case w {
	"" =>		return 0;
	"normal" =>	return 400;
	"bold" or "bolder" =>	return 700;
	"lighter" =>	return 300;
	}
	(v, ok) := parseuint(w);
	if(ok && v > 0)
		return v;
	return 0;
}

# parse an all-digits string to a non-negative int; ok=0 if empty/non-digit
parseuint(s: string): (int, int)
{
	if(s == "")
		return (0, 0);
	v := 0;
	for(i := 0; i < len s; i++){
		if(s[i] < '0' || s[i] > '9')
			return (0, 0);
		v = v*10 + (s[i] - '0');
	}
	return (v, 1);
}

namedcolor(n: string): (int, int, int, int)
{
	for(i := 0; i < len namedcols; i++)
		if(namedcols[i].name == n)
			return (namedcols[i].r, namedcols[i].g, namedcols[i].b, 1);
	return (0, 0, 0, 0);
}

# --- value serialisation -------------------------------------------------

valsstr(vals: list of ref CSS->Value): string
{
	s := "";
	first := 1;
	for(; vals != nil; vals = tl vals){
		if(!first)
			s += " ";
		first = 0;
		s += valstr(hd vals);
	}
	return s;
}

valstr(v: ref CSS->Value): string
{
	pick x := v {
	String =>	return x.value;
	Number =>	return x.value;
	Percentage =>	return x.value + "%";
	Url =>		return "url(" + x.value + ")";
	Unicoderange =>	return x.value;
	Hexcolour =>	return "#" + x.value;
	RGB =>		return "rgb(" + valsstr(x.args) + ")";
	Ident =>	return x.name;
	Unit =>		return x.value + x.units;
	Function =>	return x.name + "(" + valsstr(x.args) + ")";
	}
	return "";
}

# --- small helpers -------------------------------------------------------

# parse a CSS number string into integer milli-units (1.33 -> 1330)
# extract a numeric magnitude (in milli-units) and unit suffix from one CSS
# value; ok=0 if it is not a length/number/percentage.
valunit(v: ref CSS->Value): (int, string, int)
{
	pick x := v {
	Unit =>		return (milli(x.value), tolower(x.units), 1);
	Number =>	return (milli(x.value), "", 1);
	Percentage =>	return (milli(x.value), "%", 1);
	}
	return (0, "", 0);
}

# resolve a length (milli-units + unit) to integer pixels; em/rem/ex/% are
# resolved against basepx.  found=0 only for an unrecognised unit.
resolvelen(v: int, units: string, basepx: int): (int, int)
{
	case units {
	"px" =>			return (v / 1000, 1);
	"pt" =>			return ((v * 96) / (72 * 1000), 1);
	"em" or "rem" =>	return ((v * basepx) / 1000, 1);
	"ex" =>			return ((v * basepx) / 2000, 1);	# ~0.5em
	"%" =>			return ((v * basepx) / (100 * 1000), 1);
	"" =>			return (v / 1000, 1);	# unitless (0, or treat as px)
	}
	return (0, 0);
}

milli(s: string): int
{
	i := 0;
	neg := 0;
	if(i < len s && (s[i] == '-' || s[i] == '+')){
		neg = s[i] == '-';
		i++;
	}
	whole := 0;
	for(; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		whole = whole*10 + (s[i] - '0');
	frac := 0;
	scale := 1000;
	if(i < len s && s[i] == '.'){
		i++;
		for(; i < len s && s[i] >= '0' && s[i] <= '9' && scale > 1; i++){
			scale /= 10;
			frac += (s[i] - '0') * scale;
		}
	}
	v := whole*1000 + frac;
	if(neg)
		v = -v;
	return v;
}

tolower(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] += 'a' - 'A';
	return r;
}

# split a space/tab/newline separated string into tokens
splitws(s: string): list of string
{
	l: list of string;
	i := 0;
	n := len s;
	while(i < n){
		while(i < n && isws(s[i]))
			i++;
		st := i;
		while(i < n && !isws(s[i]))
			i++;
		if(i > st)
			l = s[st:i] :: l;
	}
	# reverse to source order
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

isws(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}
