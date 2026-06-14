implement Tkwidgets;

#
# Reusable Tk "megawidgets" for Inferno - see module/tkwidgets.m for the API
# and docs/ON_TK_WIDGETS.md for the guide.  Everything here is built from the
# primitives Inferno Tk actually has (frame/label/listbox/scrollbar/canvas/
# button) plus the `grid` geometry manager, which (unlike pack) sizes children
# reliably via -weight/-minsize/-sticky.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "tkwidgets.m";

# unique-name counter for the per-widget event channels
seq := 0;

# tunables
SASH:	con 6;		# sash thickness, pixels
MINPANE: con 16;	# smallest a dragged pane may become
SASHCOL: con "#9c9c9c";
PBCOL:	con "#3a6ea5";	# progress-bar fill

init()
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
}

uniq(prefix: string): string
{
	seq++;
	return prefix + string seq;
}

iserr(s: string): int
{
	return s != nil && s[0] == '!';
}

cmds(top: ref Toplevel, a: array of string): string
{
	for(i := 0; i < len a; i++){
		e := tk->cmd(top, a[i]);
		if(iserr(e))
			return a[i] + ": " + e;
	}
	return "";
}

cmdl(top: ref Toplevel, a: list of string): string
{
	for(; a != nil; a = tl a){
		e := tk->cmd(top, hd a);
		if(iserr(e))
			return hd a + ": " + e;
	}
	return "";
}

# ---------------------------------------------------------------- Scrolledlist

Scrolledlist.new(top: ref Toplevel, path: string, w, h: int, opts: string): ref Scrolledlist
{
	sl := ref Scrolledlist;
	sl.top = top;
	sl.fr = path;
	sl.lb = path + ".lb";
	sl.n = 0;
	sl.ev = chan of string;
	evn := uniq("tkwsl");
	tk->namechan(top, sl.ev, evn);

	sb := path + ".sb";
	tk->cmd(top, "frame " + path);
	tk->cmd(top, "listbox " + sl.lb + " -yscrollcommand {" + sb + " set} " + opts);
	tk->cmd(top, "scrollbar " + sb + " -orient vertical -command {" + sl.lb + " yview}");
	# grid + weights makes the listbox fill the frame; with a fixed-size frame
	# and propagate 0 the requested w/h is honoured (the bare listbox ignores it).
	tk->cmd(top, "grid " + sl.lb + " -row 0 -column 0 -sticky nsew");
	tk->cmd(top, "grid " + sb + " -row 0 -column 1 -sticky ns");
	tk->cmd(top, "grid rowconfigure " + path + " 0 -weight 1");
	tk->cmd(top, "grid columnconfigure " + path + " 0 -weight 1");
	if(w > 0 || h > 0){
		tk->cmd(top, sys->sprint("%s configure -width %d -height %d", path, w, h));
		tk->cmd(top, "grid propagate " + path + " 0");
	}
	tk->cmd(top, "bind " + sl.lb + " <ButtonRelease-1> {send " + evn + " select}");
	tk->cmd(top, "bind " + sl.lb + " <Double-Button-1> {send " + evn + " activate}");
	return sl;
}

Scrolledlist.setitems(sl: self ref Scrolledlist, items: array of string)
{
	tk->cmd(sl.top, sl.lb + " delete 0 end");
	for(i := 0; i < len items; i++)
		tk->cmd(sl.top, sl.lb + " insert end " + tk->quote(items[i]));
	sl.n = len items;
	tk->cmd(sl.top, "update");
}

Scrolledlist.insert(sl: self ref Scrolledlist, item: string)
{
	tk->cmd(sl.top, sl.lb + " insert end " + tk->quote(item));
	sl.n++;
}

Scrolledlist.clear(sl: self ref Scrolledlist)
{
	tk->cmd(sl.top, sl.lb + " delete 0 end");
	sl.n = 0;
	tk->cmd(sl.top, "update");
}

Scrolledlist.count(sl: self ref Scrolledlist): int
{
	return sl.n;
}

Scrolledlist.get(sl: self ref Scrolledlist, i: int): string
{
	return tk->cmd(sl.top, sl.lb + " get " + string i);
}

Scrolledlist.cursel(sl: self ref Scrolledlist): int
{
	s := tk->cmd(sl.top, sl.lb + " curselection");
	if(s == nil || iserr(s))
		return -1;
	(nil, toks) := sys->tokenize(s, " \t");
	if(toks == nil)
		return -1;
	return int hd toks;
}

Scrolledlist.select(sl: self ref Scrolledlist, i: int)
{
	tk->cmd(sl.top, sl.lb + " selection clear 0 end");
	tk->cmd(sl.top, sl.lb + sys->sprint(" selection set %d", i));
	tk->cmd(sl.top, sl.lb + sys->sprint(" see %d", i));
	tk->cmd(sl.top, "update");
}

# ------------------------------------------------------------------- Notebook

Notebook.new(top: ref Toplevel, path: string): ref Notebook
{
	nb := ref Notebook;
	nb.top = top;
	nb.fr = path;
	nb.names = nil;
	nb.cur = "";
	nb.ev = chan of string;
	nb.evname = uniq("tkwnb");
	tk->namechan(top, nb.ev, nb.evname);

	tk->cmd(top, "frame " + path);
	tk->cmd(top, "frame " + path + ".tabs");
	tk->cmd(top, "frame " + path + ".body");
	tk->cmd(top, "pack " + path + ".tabs -side top -fill x");
	tk->cmd(top, "pack " + path + ".body -side top -fill both -expand 1");
	return nb;
}

Notebook.add(nb: self ref Notebook, name, label: string): string
{
	top := nb.top;
	btn := nb.fr + ".tabs." + name;
	pg := nb.fr + ".body." + name;
	tk->cmd(top, "button " + btn + " -text " + tk->quote(label) +
		" -relief raised -command {send " + nb.evname + " " + name + "}");
	tk->cmd(top, "pack " + btn + " -side left");
	tk->cmd(top, "frame " + pg + " -relief flat");
	nb.names = name :: nb.names;
	if(nb.cur == "")
		nb.select(name);
	return pg;
}

Notebook.select(nb: self ref Notebook, name: string)
{
	top := nb.top;
	for(l := nb.names; l != nil; l = tl l){
		pn := hd l;
		tk->cmd(top, "pack forget " + nb.fr + ".body." + pn);
		tk->cmd(top, nb.fr + ".tabs." + pn + " configure -relief raised");
	}
	tk->cmd(top, "pack " + nb.fr + ".body." + name + " -fill both -expand 1");
	tk->cmd(top, nb.fr + ".tabs." + name + " configure -relief sunken");
	nb.cur = name;
	tk->cmd(top, "update");
}

Notebook.page(nb: self ref Notebook, name: string): string
{
	return nb.fr + ".body." + name;
}

# --------------------------------------------------------------------- Paned

Paned.new(top: ref Toplevel, path: string, orient: int, sizes: array of int): ref Paned
{
	pn := ref Paned;
	pn.top = top;
	pn.fr = path;
	pn.orient = orient;
	pn.n = len sizes;
	pn.stretch = pn.n - 1;
	pn.panes = array[pn.n] of string;
	pn.sizes = array[pn.n] of int;
	pn.dragi = -1;
	pn.ev = chan of string;
	evn := uniq("tkwpn");
	tk->namechan(top, pn.ev, evn);

	tk->cmd(top, "frame " + path);
	# make the cross axis fill
	if(orient == Tkwidgets->Vert)
		tk->cmd(top, "grid columnconfigure " + path + " 0 -weight 1");
	else
		tk->cmd(top, "grid rowconfigure " + path + " 0 -weight 1");

	for(i := 0; i < pn.n; i++){
		pn.sizes[i] = sizes[i];
		pn.panes[i] = path + ".p" + string i;
		tk->cmd(top, "frame " + pn.panes[i]);
		gridcell(top, pn.panes[i], orient, 2*i, "nsew");
		if(i == pn.stretch)
			beamcfg(top, path, orient, 2*i, 1, 0);
		else
			beamcfg(top, path, orient, 2*i, 0, sizes[i]);
		if(i < pn.n - 1){
			s := path + ".s" + string i;
			if(orient == Tkwidgets->Vert)
				tk->cmd(top, "frame " + s + " -height " + string SASH + " -bg " + SASHCOL);
			else
				tk->cmd(top, "frame " + s + " -width " + string SASH + " -bg " + SASHCOL);
			gridcell(top, s, orient, 2*i+1, sashsticky(orient));
			beamcfg(top, path, orient, 2*i+1, 0, SASH);
			bindsash(top, s, evn, i, orient);
		}
	}
	return pn;
}

# place widget w in pane slot `pos` (a grid row for Vert, column for Horiz)
gridcell(top: ref Toplevel, w: string, orient, pos: int, sticky: string)
{
	if(orient == Tkwidgets->Vert)
		tk->cmd(top, "grid " + w + " -row " + string pos + " -column 0 -sticky " + sticky);
	else
		tk->cmd(top, "grid " + w + " -row 0 -column " + string pos + " -sticky " + sticky);
}

beamcfg(top: ref Toplevel, path: string, orient, pos, weight, minsize: int)
{
	axis := "rowconfigure";
	if(orient == Tkwidgets->Horiz)
		axis = "columnconfigure";
	tk->cmd(top, sys->sprint("grid %s %s %d -weight %d -minsize %d", axis, path, pos, weight, minsize));
}

sashsticky(orient: int): string
{
	if(orient == Tkwidgets->Vert)
		return "ew";
	return "ns";
}

bindsash(top: ref Toplevel, s, evn: string, i, orient: int)
{
	coord := "%Y";
	if(orient == Tkwidgets->Horiz)
		coord = "%X";
	tk->cmd(top, "bind " + s + " <Button-1> {send " + evn + " press " + string i + " " + coord + "}");
	tk->cmd(top, "bind " + s + " <Motion-Button-1> {send " + evn + " drag " + string i + " " + coord + "}");
}

Paned.pane(pn: self ref Paned, i: int): string
{
	return pn.panes[i];
}

Paned.setstretch(pn: self ref Paned, i: int)
{
	old := pn.stretch;
	if(old == i)
		return;
	beamcfg(pn.top, pn.fr, pn.orient, 2*old, 0, pn.sizes[old]);
	beamcfg(pn.top, pn.fr, pn.orient, 2*i, 1, 0);
	pn.stretch = i;
	tk->cmd(pn.top, "update");
}

Paned.setsize(pn: self ref Paned, i, px: int)
{
	if(i < 0 || i >= pn.n || i == pn.stretch)
		return;
	if(px < MINPANE)
		px = MINPANE;
	pn.sizes[i] = px;
	beamcfg(pn.top, pn.fr, pn.orient, 2*i, 0, px);
	tk->cmd(pn.top, "update");
}

Paned.drag(pn: self ref Paned, s: string)
{
	(nil, toks) := sys->tokenize(s, " \t");
	if(toks == nil)
		return;
	kind := hd toks;
	toks = tl toks;
	case kind {
	"press" =>
		if(toks == nil || tl toks == nil)
			return;
		pn.dragi = int hd toks;
		pn.danchor = int hd tl toks;
		if(pn.dragi >= 0 && pn.dragi < pn.n)
			pn.dbase = pn.sizes[pn.dragi];
	"drag" =>
		if(toks == nil || tl toks == nil || pn.dragi < 0)
			return;
		i := int hd toks;
		now := int hd tl toks;
		if(i != pn.dragi)
			return;
		pn.setsize(i, pn.dbase + (now - pn.danchor));
	}
}

# ---------------------------------------------------------------------- Tree

Tree.new(top: ref Toplevel, path: string, w, h: int): ref Tree
{
	t := ref Tree;
	t.top = top;
	t.fr = path;
	t.sl = Scrolledlist.new(top, path, w, h, "-selectmode browse -bg white");
	t.ev = t.sl.ev;
	t.root = ref Treenode("", "", -1, 1, nil);
	t.vis = array[0] of ref Treenode;
	return t;
}

Tree.add(t: self ref Tree, parentid, id, label: string): int
{
	p := t.root;
	if(parentid != ""){
		p = findnode(t.root, parentid);
		if(p == nil)
			return -1;
	}
	node := ref Treenode(id, label, p.depth + 1, 0, nil);
	p.kids = appendnode(p.kids, node);
	relayout(t);
	return 0;
}

Tree.clear(t: self ref Tree)
{
	t.root.kids = nil;
	relayout(t);
}

Tree.click(t: self ref Tree, nil: string): string
{
	i := t.sl.cursel();
	if(i < 0 || i >= len t.vis)
		return "";
	node := t.vis[i];
	if(node.kids != nil){
		node.expanded = !node.expanded;
		relayout(t);
		ni := visindex(t, node);
		if(ni >= 0)
			t.sl.select(ni);
	}
	return node.id;
}

Tree.selectedid(t: self ref Tree): string
{
	i := t.sl.cursel();
	if(i < 0 || i >= len t.vis)
		return "";
	return t.vis[i].id;
}

Tree.setexpand(t: self ref Tree, id: string, on: int)
{
	node := findnode(t.root, id);
	if(node != nil){
		node.expanded = on;
		relayout(t);
	}
}

relayout(t: ref Tree)
{
	rev := flatten(t.root, nil);
	# flatten returns pre-order reversed; count and fill an array forwards
	cnt := 0;
	for(l := rev; l != nil; l = tl l)
		cnt++;
	t.vis = array[cnt] of ref Treenode;
	rows := array[cnt] of string;
	i := cnt - 1;
	for(l = rev; l != nil; l = tl l){
		node := hd l;
		t.vis[i] = node;
		rows[i] = rowtext(node);
		i--;
	}
	t.sl.setitems(rows);
}

rowtext(node: ref Treenode): string
{
	indent := "";
	for(i := 0; i < node.depth; i++)
		indent += "  ";
	mark := "  ";
	if(node.kids != nil){
		if(node.expanded)
			mark = "- ";
		else
			mark = "+ ";
	}
	return indent + mark + node.label;
}

flatten(n: ref Treenode, acc: list of ref Treenode): list of ref Treenode
{
	for(k := n.kids; k != nil; k = tl k){
		child := hd k;
		acc = child :: acc;
		if(child.expanded)
			acc = flatten(child, acc);
	}
	return acc;
}

findnode(n: ref Treenode, id: string): ref Treenode
{
	for(k := n.kids; k != nil; k = tl k){
		child := hd k;
		if(child.id == id)
			return child;
		f := findnode(child, id);
		if(f != nil)
			return f;
	}
	return nil;
}

visindex(t: ref Tree, node: ref Treenode): int
{
	for(i := 0; i < len t.vis; i++)
		if(t.vis[i] == node)
			return i;
	return -1;
}

appendnode(l: list of ref Treenode, x: ref Treenode): list of ref Treenode
{
	if(l == nil)
		return x :: nil;
	return (hd l) :: appendnode(tl l, x);
}

# ------------------------------------------------------------------ Statusbar

Statusbar.new(top: ref Toplevel, path: string): ref Statusbar
{
	sb := ref Statusbar;
	sb.top = top;
	sb.fr = path;
	sb.ncell = 0;
	tk->cmd(top, "frame " + path + " -relief sunken -bd 1");
	tk->cmd(top, "label " + path + ".msg -anchor w");
	tk->cmd(top, "pack " + path + ".msg -side left -fill x -expand 1 -padx 4");
	return sb;
}

Statusbar.msg(sb: self ref Statusbar, s: string)
{
	tk->cmd(sb.top, sb.fr + ".msg configure -text " + tk->quote(s));
	tk->cmd(sb.top, "update");
}

Statusbar.addcell(sb: self ref Statusbar, name: string): string
{
	w := sb.fr + "." + name;
	tk->cmd(sb.top, "label " + w + " -anchor e -relief sunken -bd 1");
	tk->cmd(sb.top, "pack " + w + " -side right -padx 2");
	sb.ncell++;
	return w;
}

Statusbar.set(sb: self ref Statusbar, name, s: string)
{
	tk->cmd(sb.top, sb.fr + "." + name + " configure -text " + tk->quote(s));
	tk->cmd(sb.top, "update");
}

# ---------------------------------------------------------------- Progressbar

Progressbar.new(top: ref Toplevel, path: string, w, h: int): ref Progressbar
{
	pb := ref Progressbar;
	pb.top = top;
	pb.fr = path;
	pb.w = w;
	pb.h = h;
	tk->cmd(top, "frame " + path);
	cv := path + ".c";
	tk->cmd(top, sys->sprint("canvas %s -width %d -height %d -bg white -highlightthickness 0", cv, w, h));
	tk->cmd(top, "pack " + cv + " -fill both -expand 1");
	tk->cmd(top, sys->sprint("%s create rectangle 0 0 0 %d -fill %s -tags {pbbar}", cv, h, PBCOL));
	return pb;
}

Progressbar.set(pb: self ref Progressbar, frac: real)
{
	if(frac < 0.0)
		frac = 0.0;
	if(frac > 1.0)
		frac = 1.0;
	x := int (frac * real pb.w);
	tk->cmd(pb.top, sys->sprint("%s.c coords pbbar 0 0 %d %d", pb.fr, x, pb.h));
	tk->cmd(pb.top, "update");
}
