implement Domjs;

#
# JavaScript DOM binding.  See domjs.m.  domjs is itself the ESHostobj for the
# document + element objects it creates (me = load ESHostobj SELF), dispatching
# in get/put/call below; everything else delegates to the engine.
#

include "sys.m";
include "draw.m";
include "math.m";
include "ecmascript.m";
include "dom.m";
include "domjs.m";

sys: Sys;
draw: Draw;
	Image, Display, Font, Rect, Point: import draw;
math: Math;
ES: Ecmascript;
	Exec, Obj, Val, Ref, Builtin: import ES;
dom: Dom;
	Node: import dom;
me: ESHostobj;

docproto, elemproto, ctxproto: ref Obj;	# shared prototypes (methods live here)
nodetab: array of ref Node;		# index -> node
objtab:  array of ref Obj;		# index -> host obj (lazily created, for identity)
ntab: int;
reflowfn: ref fn();			# called after a DOM-structure mutation (may be nil)
canvasdirtyfn: ref fn();		# called after a canvas-only pixel draw (may be nil)

CFILL, CCLEAR, CSTROKE: con iota;	# canvas rectangle op modes

# Current path, accumulated by beginPath/moveTo/lineTo/arc and consumed by
# stroke/fill.  JS is single-threaded, so one global path serves all contexts.
pathx, pathy, pathsub: array of int;	# point coords + 1==starts a new subpath
pathn: int;

init(es: Ecmascript)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;		# for canvas 2D ops (image/display methods)
	math = load Math Math->PATH;		# sin/cos for canvas arc()
	ES = es;				# share the caller's initialised engine
	dom = load Dom Dom->PATH;
	if(dom != nil)
		dom->init();
	me = load ESHostobj SELF;
	nodetab = array[16] of ref Node;
	objtab = array[16] of ref Obj;
	ntab = 0;
}

install(ex: ref Exec, scope: ref Obj, root: ref Dom->Node, reflow: ref fn()): ref Obj
{
	if(docproto == nil)
		mkprotos(ex);
	reflowfn = reflow;
	doco := ES->mkobj(docproto, "Domdoc");
	doco.host = me;
	ES->put(ex, doco, "@PRIVdomix", ES->numval(real nodeix(root)));
	if(scope != nil)
		ES->put(ex, scope, "document", ES->objval(doco));
	return doco;
}

setreflow(reflow: ref fn())
{
	reflowfn = reflow;
}

setcanvasdirty(reflow: ref fn())
{
	canvasdirtyfn = reflow;
}

serialize(root: ref Dom->Node): string
{
	if(root == nil)
		return "";
	return root.html();
}

# ensure the shared prototypes exist (needs an Exec for objproto/funcproto).
setup(ex: ref Exec)
{
	if(docproto == nil)
		mkprotos(ex);
}

elembyid(ex: ref Exec, root: ref Dom->Node, id: string): ref Val
{
	setup(ex);
	if(root == nil)
		return ES->null;
	return domval(ex, root.byid(id));
}

elembytag(ex: ref Exec, root: ref Dom->Node, tag: string): ref Val
{
	setup(ex);
	return nodelist(ex, root, tolower(tag));
}

createelem(ex: ref Exec, tag: string): ref Val
{
	setup(ex);
	if(dom == nil)
		return ES->null;
	return domval(ex, dom->newelem(tolower(tag), nil));
}

mkprotos(ex: ref Exec)
{
	docproto = ES->mkobj(ex.objproto, "Domdoc");
	instm(ex, docproto, "Domdoc", "getElementById", array[] of {"id"});
	instm(ex, docproto, "Domdoc", "getElementsByTagName", array[] of {"tag"});
	instm(ex, docproto, "Domdoc", "createElement", array[] of {"tag"});
	elemproto = ES->mkobj(ex.objproto, "Domelem");
	instm(ex, elemproto, "Domelem", "getAttribute", array[] of {"name"});
	instm(ex, elemproto, "Domelem", "setAttribute", array[] of {"name", "value"});
	instm(ex, elemproto, "Domelem", "appendChild", array[] of {"child"});
	instm(ex, elemproto, "Domelem", "removeChild", array[] of {"child"});
	instm(ex, elemproto, "Domelem", "getElementsByTagName", array[] of {"tag"});
	instm(ex, elemproto, "Domelem", "getContext", array[] of {"kind"});
	# minimal CanvasRenderingContext2D
	ctxproto = ES->mkobj(ex.objproto, "Domctx");
	instm(ex, ctxproto, "Domctx", "fillRect", array[] of {"x", "y", "w", "h"});
	instm(ex, ctxproto, "Domctx", "clearRect", array[] of {"x", "y", "w", "h"});
	instm(ex, ctxproto, "Domctx", "strokeRect", array[] of {"x", "y", "w", "h"});
	instm(ex, ctxproto, "Domctx", "fillText", array[] of {"text", "x", "y"});
	instm(ex, ctxproto, "Domctx", "beginPath", array[0] of string);
	instm(ex, ctxproto, "Domctx", "closePath", array[0] of string);
	instm(ex, ctxproto, "Domctx", "moveTo", array[] of {"x", "y"});
	instm(ex, ctxproto, "Domctx", "lineTo", array[] of {"x", "y"});
	instm(ex, ctxproto, "Domctx", "arc", array[] of {"x", "y", "r", "a0", "a1", "ccw"});
	instm(ex, ctxproto, "Domctx", "stroke", array[0] of string);
	instm(ex, ctxproto, "Domctx", "fill", array[0] of string);
}

instm(ex: ref Exec, proto: ref Obj, class, name: string, args: array of string)
{
	ES->biinst(proto, Builtin(name, class + ".prototype." + name, args, len args),
		ex.funcproto, me);
}

# ---- node <-> host-object registry -------------------------------------

nodeix(n: ref Node): int
{
	for(i := 0; i < ntab; i++)
		if(nodetab[i] == n)
			return i;
	if(ntab >= len nodetab){
		nn := array[2 * len nodetab] of ref Node;
		no := array[2 * len objtab] of ref Obj;
		nn[0:] = nodetab;
		no[0:] = objtab;
		nodetab = nn;
		objtab = no;
	}
	nodetab[ntab] = n;
	return ntab++;
}

# JS value for a node: a (cached) Domelem host object, or null for nil.
domval(ex: ref Exec, n: ref Node): ref Val
{
	if(n == nil)
		return ES->null;
	ix := nodeix(n);
	if(objtab[ix] == nil){
		o := ES->mkobj(elemproto, "Domelem");
		o.host = me;
		ES->put(ex, o, "@PRIVdomix", ES->numval(real ix));
		objtab[ix] = o;
	}
	return ES->objval(objtab[ix]);
}

nodeof(ex: ref Exec, o: ref Obj): ref Node
{
	v := ES->get(ex, o, "@PRIVdomix");
	if(!ES->isnum(v))
		return nil;
	ix := ES->toInt32(ex, v);
	if(ix < 0 || ix >= ntab)
		return nil;
	return nodetab[ix];
}

# ---- ESHostobj suite ----------------------------------------------------

get(ex: ref Exec, o: ref Obj, property: string): ref Val
{
	case o.class {
	"Domelem" =>
		n := nodeof(ex, o);
		if(n != nil){
			case property {
			"tagName" or "nodeName" =>
				return ES->strval(toupper(elemtag(n)));
			"nodeType" =>
				return ES->numval(real nodetype(n));
			"id" =>
				return ES->strval(n.getid());
			"className" =>
				return ES->strval(n.attr("class"));
			"textContent" or "innerText" =>
				return ES->strval(n.text());
			"parentNode" =>
				return domval(ex, n.parent);
			"firstChild" =>
				return domval(ex, n.firstkid);
			"nextSibling" =>
				return domval(ex, n.nextsib);
			}
		}
	"Domdoc" =>
		root := nodeof(ex, o);
		if(root != nil){
			case property {
			"documentElement" =>
				return domval(ex, firstelem(root));
			"body" =>
				return domval(ex, firstbytag(root, "body"));
			}
		}
	}
	return ES->get(ex, o, property);
}

put(ex: ref Exec, o: ref Obj, property: string, val: ref Val)
{
	if(o.class == "Domelem"){
		n := nodeof(ex, o);
		if(n != nil){
			case property {
			"id" =>
				n.setattr("id", ES->toString(ex, val));
				mutated();
				return;
			"className" =>
				n.setattr("class", ES->toString(ex, val));
				mutated();
				return;
			"textContent" or "innerText" =>
				settext(n, ES->toString(ex, val));
				mutated();
				return;
			}
		}
	}
	ES->put(ex, o, property, val);
}

call(ex: ref Exec, func, this: ref Obj, args: array of ref Val, nil: int): ref Ref
{
	v := ES->undefined;
	if(func == nil || func.val == nil)
		return ES->valref(v);
	case func.val.str {
	"Domdoc.prototype.getElementById" =>
		root := nodeof(ex, this);
		if(root != nil)
			v = domval(ex, root.byid(argstr(ex, args, 0)));
		else
			v = ES->null;
	"Domdoc.prototype.getElementsByTagName" =>
		v = nodelist(ex, nodeof(ex, this), tolower(argstr(ex, args, 0)));
	"Domdoc.prototype.createElement" =>
		v = domval(ex, dom->newelem(tolower(argstr(ex, args, 0)), nil));
	"Domelem.prototype.getElementsByTagName" =>
		v = nodelist(ex, nodeof(ex, this), tolower(argstr(ex, args, 0)));
	"Domelem.prototype.getAttribute" =>
		n := nodeof(ex, this);
		if(n != nil)
			v = ES->strval(n.attr(argstr(ex, args, 0)));
		else
			v = ES->null;
	"Domelem.prototype.setAttribute" =>
		n := nodeof(ex, this);
		if(n != nil){
			n.setattr(argstr(ex, args, 0), argstr(ex, args, 1));
			mutated();
		}
	"Domelem.prototype.appendChild" =>
		n := nodeof(ex, this);
		c := argnode(ex, args, 0);
		if(n != nil && c != nil){
			n.append(c);
			mutated();
			v = argval(args, 0);
		}
	"Domelem.prototype.removeChild" =>
		n := nodeof(ex, this);
		c := argnode(ex, args, 0);
		if(n != nil && c != nil){
			n.remove(c);
			mutated();
			v = argval(args, 0);
		}
	"Domelem.prototype.getContext" =>
		# only "2d" is offered; the context is bound to this canvas node.
		v = ctxval(ex, nodeof(ex, this));
	"Domctx.prototype.fillRect" =>
		ctxrect(ex, this, args, CFILL);
	"Domctx.prototype.clearRect" =>
		ctxrect(ex, this, args, CCLEAR);
	"Domctx.prototype.strokeRect" =>
		ctxrect(ex, this, args, CSTROKE);
	"Domctx.prototype.fillText" =>
		ctxtext(ex, this, argstr(ex, args, 0), argnum(ex, args, 1), argnum(ex, args, 2));
	"Domctx.prototype.beginPath" =>
		pathn = 0;
	"Domctx.prototype.closePath" =>
		pathclose();
	"Domctx.prototype.moveTo" =>
		pathadd(argnum(ex, args, 0), argnum(ex, args, 1), 1);
	"Domctx.prototype.lineTo" =>
		pathadd(argnum(ex, args, 0), argnum(ex, args, 1), 0);
	"Domctx.prototype.arc" =>
		ctxarc(ex, args);
	"Domctx.prototype.stroke" =>
		ctxstroke(ex, this);
	"Domctx.prototype.fill" =>
		ctxfill(ex, this);
	}
	return ES->valref(v);
}

# computed/host properties we own; the rest the engine resolves normally.
hasproperty(ex: ref Exec, o: ref Obj, property: string): ref Val
{
	if(o.class == "Domelem")
		case property {
		"tagName" or "nodeName" or "nodeType" or "id" or "className" or
		"textContent" or "innerText" or "parentNode" or "firstChild" or "nextSibling" =>
			return ES->true;
		}
	if(o.class == "Domdoc")
		case property {
		"documentElement" or "body" =>
			return ES->true;
		}
	return ES->hasproperty(ex, o, property);
}

canput(ex: ref Exec, o: ref Obj, property: string): ref Val
{
	if(o.class == "Domelem")
		case property {
		"id" or "className" or "textContent" or "innerText" =>
			return ES->true;
		}
	return ES->canput(ex, o, property);
}

delete(ex: ref Exec, o: ref Obj, property: string)
{
	ES->delete(ex, o, property);
}

defaultval(ex: ref Exec, o: ref Obj, tyhint: int): ref Val
{
	if(o.class == "Domelem"){
		n := nodeof(ex, o);
		if(n != nil)
			return ES->strval("<" + elemtag(n) + ">");
	}
	return ES->defaultval(ex, o, tyhint);
}

construct(ex: ref Exec, nil: ref Obj, nil: array of ref Val): ref Obj
{
	# DOM host objects are not constructors; hand back a plain object.
	return ES->mkobj(ex.objproto, "Object");
}

# ---- helpers ------------------------------------------------------------

mutated()
{
	if(reflowfn != nil)
		reflowfn();
}

# A <canvas> 2D op changed only the node's backing image (no DOM structure or
# style change), so the host can repaint its retained layout without a relayout.
# Fall back to a full reflow if the host did not register a canvas-only callback.
canvasdamaged()
{
	if(canvasdirtyfn != nil)
		canvasdirtyfn();
	else if(reflowfn != nil)
		reflowfn();
}

settext(n: ref Node, s: string)
{
	while(n.firstkid != nil)
		n.remove(n.firstkid);
	n.append(dom->newtext(s));
}

# an array-like NodeList (plain object with length + numeric indices) of the
# element host objects matching tag under root.  A plain Object avoids the
# engine's internal Array representation, which mkobj() does not initialise.
nodelist(ex: ref Exec, root: ref Node, tag: string): ref Val
{
	a := ES->mkobj(ex.objproto, "Object");
	i := 0;
	if(root != nil)
		for(l := root.bytag(tag); l != nil; l = tl l){
			ES->put(ex, a, string i, domval(ex, hd l));
			i++;
		}
	ES->put(ex, a, "length", ES->numval(real i));
	return ES->objval(a);
}

# DOM nodeType numbering (element 1, text 3, comment 8, document 9).
nodetype(n: ref Node): int
{
	case n.ty {
	Dom->Nelement =>	return 1;
	Dom->Ntext =>		return 3;
	Dom->Ncomment =>	return 8;
	Dom->Ndocument =>	return 9;
	}
	return 0;
}

elemtag(n: ref Node): string
{
	pick e := n {
	Element =>
		return e.tag;
	}
	return "";
}

# ---- canvas 2D context --------------------------------------------------

argnum(ex: ref Exec, args: array of ref Val, i: int): int
{
	if(i < len args && args[i] != nil)
		return ES->toInt32(ex, args[i]);
	return 0;
}

# a Domctx host object bound to canvas node n (carries its node index).
ctxval(ex: ref Exec, n: ref Node): ref Val
{
	if(n == nil)
		return ES->null;
	o := ES->mkobj(ctxproto, "Domctx");
	o.host = me;
	ES->put(ex, o, "@PRIVdomix", ES->numval(real nodeix(n)));
	return ES->objval(o);
}

# the backing image of the canvas this context draws into (allocated by layout).
canvasimof(ex: ref Exec, ctxo: ref Obj): ref Image
{
	n := nodeof(ex, ctxo);
	if(n == nil)
		return nil;
	pick e := n {
	Element =>
		return e.canvasim;
	}
	return nil;
}

ctxrect(ex: ref Exec, ctxo: ref Obj, args: array of ref Val, mode: int)
{
	cim := canvasimof(ex, ctxo);
	if(cim == nil)
		return;
	x := argnum(ex, args, 0);
	y := argnum(ex, args, 1);
	w := argnum(ex, args, 2);
	h := argnum(ex, args, 3);
	disp := cim.display;
	r := Rect(Point(x, y), Point(x+w, y+h));
	zp := Point(0, 0);
	case mode {
	CCLEAR =>
		cim.draw(r, disp.white, nil, zp);
	CSTROKE =>
		b := colorbrush(ex, disp, ctxo, "strokeStyle");
		lw := linewidth(ex, ctxo);
		cim.draw(Rect(r.min, Point(r.max.x, r.min.y+lw)), b, nil, zp);
		cim.draw(Rect(Point(r.min.x, r.max.y-lw), r.max), b, nil, zp);
		cim.draw(Rect(r.min, Point(r.min.x+lw, r.max.y)), b, nil, zp);
		cim.draw(Rect(Point(r.max.x-lw, r.min.y), r.max), b, nil, zp);
	* =>
		cim.draw(r, colorbrush(ex, disp, ctxo, "fillStyle"), nil, zp);
	}
	canvasdamaged();
}

ctxtext(ex: ref Exec, ctxo: ref Obj, text: string, x, y: int)
{
	cim := canvasimof(ex, ctxo);
	if(cim == nil || text == "")
		return;
	disp := cim.display;
	font := Font.open(disp, "*default*");
	if(font == nil)
		return;
	# canvas fillText y is the baseline; Draw text() y is the glyph top
	cim.text(Point(x, y - font.ascent), colorbrush(ex, disp, ctxo, "fillStyle"),
		Point(0, 0), font, text);
	canvasdamaged();
}

argreal(ex: ref Exec, args: array of ref Val, i: int): real
{
	if(i < len args && args[i] != nil)
		return ES->toNumber(ex, args[i]);
	return 0.0;
}

# lineWidth as a Draw rectangle/poll thickness (>=1 pixel).
linewidth(ex: ref Exec, ctxo: ref Obj): int
{
	lw := ES->toInt32(ex, ES->get(ex, ctxo, "lineWidth"));
	if(lw < 1)
		return 1;
	return lw;
}

# ---- path building (beginPath/moveTo/lineTo/arc/closePath) --------------

pathadd(x, y, sub: int)
{
	if(pathx == nil || pathn >= len pathx){
		nn := 32;
		if(pathx != nil)
			nn = len pathx * 2;
		nx := array[nn] of int;
		ny := array[nn] of int;
		ns := array[nn] of int;
		for(i := 0; i < pathn; i++){
			nx[i] = pathx[i];
			ny[i] = pathy[i];
			ns[i] = pathsub[i];
		}
		pathx = nx; pathy = ny; pathsub = ns;
	}
	if(pathn == 0)			# the first point always opens a subpath
		sub = 1;
	pathx[pathn] = x;
	pathy[pathn] = y;
	pathsub[pathn] = sub;
	pathn++;
}

# close the current subpath by drawing back to its first point.
pathclose()
{
	if(pathn == 0)
		return;
	s := pathn - 1;
	while(s > 0 && pathsub[s] == 0)
		s--;
	pathadd(pathx[s], pathy[s], 0);
}

# append an arc to the path as line segments (canvas connects from the
# current point, so the first segment point is a lineTo).
ctxarc(ex: ref Exec, args: array of ref Val)
{
	if(math == nil)
		return;
	cx := argreal(ex, args, 0);
	cy := argreal(ex, args, 1);
	r := argreal(ex, args, 2);
	a0 := argreal(ex, args, 3);
	a1 := argreal(ex, args, 4);
	ccw := argnum(ex, args, 5);
	if(r <= 0.0)
		return;
	# sweep from a0 to a1 in the requested direction
	if(ccw){
		while(a1 > a0)
			a1 -= 2.0 * Math->Pi;
	}else{
		while(a1 < a0)
			a1 += 2.0 * Math->Pi;
	}
	sweep := a1 - a0;			# signed; a1 normalized by direction above
	mag := sweep;
	if(mag < 0.0)
		mag = -mag;
	nseg := int(mag * r / 3.0) + 1;		# ~3px chords
	if(nseg < 2)
		nseg = 2;
	if(nseg > 720)
		nseg = 720;
	for(i := 0; i <= nseg; i++){
		t := a0 + sweep * (real i / real nseg);
		x := cx + r * math->cos(t);
		y := cy + r * math->sin(t);
		pathadd(int(x + 0.5), int(y + 0.5), 0);
	}
}

# walk subpaths; for each, draw its polyline with the stroke brush.
ctxstroke(ex: ref Exec, ctxo: ref Obj)
{
	cim := canvasimof(ex, ctxo);
	if(cim == nil || pathn < 2)
		return;
	disp := cim.display;
	b := colorbrush(ex, disp, ctxo, "strokeStyle");
	rad := (linewidth(ex, ctxo) - 1) / 2;
	zp := Point(0, 0);
	i := 0;
	while(i < pathn){
		j := i + 1;
		while(j < pathn && pathsub[j] == 0)
			j++;
		n := j - i;
		if(n >= 2){
			pts := array[n] of Point;
			for(k := 0; k < n; k++)
				pts[k] = Point(pathx[i+k], pathy[i+k]);
			cim.poly(pts, Draw->Endsquare, Draw->Endsquare, rad, b, zp);
		}
		i = j;
	}
	canvasdamaged();
}

ctxfill(ex: ref Exec, ctxo: ref Obj)
{
	cim := canvasimof(ex, ctxo);
	if(cim == nil || pathn < 3)
		return;
	disp := cim.display;
	b := colorbrush(ex, disp, ctxo, "fillStyle");
	zp := Point(0, 0);
	i := 0;
	while(i < pathn){
		j := i + 1;
		while(j < pathn && pathsub[j] == 0)
			j++;
		n := j - i;
		if(n >= 3){
			pts := array[n] of Point;
			for(k := 0; k < n; k++)
				pts[k] = Point(pathx[i+k], pathy[i+k]);
			cim.fillpoly(pts, ~0, b, zp);	# nonzero winding
		}
		i = j;
	}
	canvasdamaged();
}

# brush from a context colour property (fillStyle/strokeStyle); default black.
colorbrush(ex: ref Exec, disp: ref Display, ctxo: ref Obj, prop: string): ref Image
{
	(r, g, b) := parsecolor(ES->toString(ex, ES->get(ex, ctxo, prop)));
	return disp.rgb(r, g, b);
}

parsecolor(s: string): (int, int, int)
{
	if(s != "" && s[0] == '#'){
		h := s[1:];
		if(len h == 3)
			return (17*hexv(h[0]), 17*hexv(h[1]), 17*hexv(h[2]));
		if(len h >= 6)
			return (16*hexv(h[0])+hexv(h[1]), 16*hexv(h[2])+hexv(h[3]), 16*hexv(h[4])+hexv(h[5]));
		return (0, 0, 0);
	}
	case s {
	"red" =>	return (255, 0, 0);
	"green" =>	return (0, 128, 0);
	"blue" =>	return (0, 0, 255);
	"white" =>	return (255, 255, 255);
	"yellow" =>	return (255, 255, 0);
	"orange" =>	return (255, 165, 0);
	"purple" =>	return (128, 0, 128);
	"gray" or "grey" =>	return (128, 128, 128);
	}
	return (0, 0, 0);	# default / "black" / unknown
}

hexv(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}

firstelem(n: ref Node): ref Node
{
	for(c := n.firstkid; c != nil; c = c.nextsib)
		if(c.ty == Dom->Nelement)
			return c;
	return nil;
}

firstbytag(root: ref Node, tag: string): ref Node
{
	l := root.bytag(tag);
	if(l != nil)
		return hd l;
	return nil;
}

argval(args: array of ref Val, i: int): ref Val
{
	if(i < len args && args[i] != nil)
		return args[i];
	return ES->undefined;
}

argstr(ex: ref Exec, args: array of ref Val, i: int): string
{
	return ES->toString(ex, argval(args, i));
}

argnode(ex: ref Exec, args: array of ref Val, i: int): ref Node
{
	v := argval(args, i);
	if(ES->isobj(v))
		return nodeof(ex, v.obj);
	return nil;
}

toupper(s: string): string
{
	t := s;
	for(i := 0; i < len t; i++)
		if(t[i] >= 'a' && t[i] <= 'z')
			t[i] = t[i] - 'a' + 'A';
	return t;
}

tolower(s: string): string
{
	t := s;
	for(i := 0; i < len t; i++)
		if(t[i] >= 'A' && t[i] <= 'Z')
			t[i] = t[i] - 'A' + 'a';
	return t;
}
