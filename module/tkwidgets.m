# Tkwidgets - a suite of reusable "megawidgets" for Inferno's Tk.
#
# Inferno's Tk is frozen near Tk 8.0 and lacks the widgets the wider GUI world
# gained since (ttk notebook, treeview, panedwindow, combobox, progressbar...).
# This library builds those out of the primitives we do have (frame/label/
# listbox/scrollbar/canvas/button) and the working `grid` geometry manager,
# so custom GUI apps in this fork don't each re-hand-roll the same scaffolding.
#
# Event contract (read this once):
#   Every interactive widget owns a `chan of string` named `ev`.  Add it to
#   your application's main alt and, when it fires, call the widget's handler
#   in the SAME proc that owns the Toplevel (Tk is single-threaded per window):
#
#       nb := Notebook.new(win, ".nb");
#       ...
#       for(;;) alt {
#       ...
#       name := <-nb.ev => nb.select(name);      # Notebook
#       s    := <-pn.ev => pn.drag(s);           # Paned (sash drag)
#       s    := <-tr.ev => id := tr.click(s);    # Tree  (toggle/select)
#       e    := <-sl.ev => i  := sl.cursel();    # Scrolledlist
#       }
#
# A widget's constructor creates a container frame at the path you give it but
# does NOT geometry-manage that frame: you `pack`/`grid` it wherever you like.
# See docs/ON_TK_WIDGETS.md for the full guide and worked examples.

Tkwidgets: module
{
	PATH:	con "/dis/lib/tkwidgets.dis";

	# orientation for Paned
	Vert, Horiz: con iota;

	init:	fn();

	# Apply tk commands in order; stop at and return the first command that
	# produced a Tk error (a result beginning with '!'), prefixed with the
	# offending command.  Returns "" when every command succeeded.
	cmds:	fn(top: ref Tk->Toplevel, a: array of string): string;
	cmdl:	fn(top: ref Tk->Toplevel, a: list of string): string;

	# Scrolledlist: a listbox + vertical scrollbar in one frame, with a size
	# that is actually honoured (the bare listbox ignores -width/-height; here
	# w/h are container pixels, 0 = grow to fill the parent instead).  `opts`
	# is extra listbox options, e.g. "-selectmode browse -font /fonts/...".
	Scrolledlist: adt {
		top:	ref Tk->Toplevel;
		fr:	string;			# container frame (you pack/grid this)
		lb:	string;			# the listbox widget path
		ev:	chan of string;		# "select" | "activate" (dbl-click)
		n:	int;			# item count (tracked; listbox can't report it)

		new:		fn(top: ref Tk->Toplevel, path: string, w, h: int, opts: string): ref Scrolledlist;
		setitems:	fn(sl: self ref Scrolledlist, items: array of string);
		insert:		fn(sl: self ref Scrolledlist, item: string);
		clear:		fn(sl: self ref Scrolledlist);
		count:		fn(sl: self ref Scrolledlist): int;
		get:		fn(sl: self ref Scrolledlist, i: int): string;
		cursel:		fn(sl: self ref Scrolledlist): int;	# -1 = nothing
		select:		fn(sl: self ref Scrolledlist, i: int);
	};

	# Notebook: a strip of tab buttons over a stack of pages; only the
	# selected page is shown.  add() returns the page's frame path: fill it
	# with your widgets.  On `ev` (a tab was clicked) call select(name).
	Notebook: adt {
		top:	ref Tk->Toplevel;
		fr:	string;
		ev:	chan of string;		# clicked tab's page name
		evname:	string;			# ev's registered namechan name
		names:	list of string;		# pages, in add order (reversed-append)
		cur:	string;			# current page name

		new:	fn(top: ref Tk->Toplevel, path: string): ref Notebook;
		add:	fn(nb: self ref Notebook, name, label: string): string;
		select:	fn(nb: self ref Notebook, name: string);
		page:	fn(nb: self ref Notebook, name: string): string;
	};

	# Paned: N resizable panes separated by draggable sashes, laid out with
	# grid weights so they track the parent's size.  One pane (default the
	# last) "stretches" to absorb slack; the rest hold a pixel size you can
	# set programmatically or the user can drag.  pane(i) is the i-th pane's
	# frame path.  Feed `ev` strings to drag().
	Paned: adt {
		top:	ref Tk->Toplevel;
		fr:	string;
		orient:	int;			# Vert (rows) | Horiz (columns)
		n:	int;
		panes:	array of string;
		sizes:	array of int;		# current pixel size of each pane
		stretch: int;			# index of the slack-absorbing pane
		ev:	chan of string;
		# transient sash-drag anchor
		dragi:	int;
		danchor: int;
		dbase:	int;

		new:		fn(top: ref Tk->Toplevel, path: string, orient: int, sizes: array of int): ref Paned;
		pane:		fn(pn: self ref Paned, i: int): string;
		setstretch:	fn(pn: self ref Paned, i: int);
		setsize:	fn(pn: self ref Paned, i, px: int);
		drag:		fn(pn: self ref Paned, s: string);
	};

	# Treenode: one node of a Tree's model.
	Treenode: adt {
		id:		string;
		label:		string;
		depth:		int;
		expanded:	int;
		kids:		list of ref Treenode;
	};

	# Tree: a collapsible tree, rendered into a Scrolledlist (so it scrolls).
	# Build it with add(parentid,id,label) ("" parent = a root item), then on
	# `ev` call click(s): it toggles a branch / selects a row and returns the
	# row's id ("" if none).
	Tree: adt {
		top:	ref Tk->Toplevel;
		sl:	ref Scrolledlist;
		fr:	string;
		ev:	chan of string;		# == sl.ev
		root:	ref Treenode;		# synthetic, not displayed
		vis:	array of ref Treenode;	# currently visible rows

		new:		fn(top: ref Tk->Toplevel, path: string, w, h: int): ref Tree;
		add:		fn(t: self ref Tree, parentid, id, label: string): int;
		clear:		fn(t: self ref Tree);
		click:		fn(t: self ref Tree, s: string): string;
		selectedid:	fn(t: self ref Tree): string;
		setexpand:	fn(t: self ref Tree, id: string, on: int);
	};

	# Statusbar: a thin bottom bar - a left message that fills, plus optional
	# right-aligned info cells added left-to-right.
	Statusbar: adt {
		top:	ref Tk->Toplevel;
		fr:	string;
		ncell:	int;

		new:	fn(top: ref Tk->Toplevel, path: string): ref Statusbar;
		msg:	fn(sb: self ref Statusbar, s: string);
		addcell: fn(sb: self ref Statusbar, name: string): string;
		set:	fn(sb: self ref Statusbar, name, s: string);
	};

	# Progressbar: a determinate bar drawn on a canvas; set(frac) 0.0..1.0.
	Progressbar: adt {
		top:	ref Tk->Toplevel;
		fr:	string;
		w, h:	int;

		new:	fn(top: ref Tk->Toplevel, path: string, w, h: int): ref Progressbar;
		set:	fn(pb: self ref Progressbar, frac: real);
	};
};
