# Tkwidgets — reusable megawidgets for Inferno Tk

Inferno's Tk is frozen near Tk 8.0 and never gained the widgets the wider GUI
world added since: the ttk **notebook** (tabs), **treeview**, **panedwindow**,
**progressbar**, and reliably-sized scrolled containers. `Tkwidgets`
(`module/tkwidgets.m`, `appl/lib/tkwidgets.b`, built to `/dis/lib/tkwidgets.dis`)
supplies those, built from the primitives Inferno Tk does have plus the working
`grid` geometry manager. Custom GUI apps in this fork use these instead of
re-hand-rolling the same scaffolding; new recurring gaps are logged in
[DEV_TK_EXTENSIONS.md](DEV_TK_EXTENSIONS.md).

The companion app `appl/wm/tkwdemo.b` (`/dis/wm/tkwdemo.dis`, **Demo → Tk
Widgets** equivalent — run it directly) shows every widget; `tkwdemo -test`
drives them headless and prints `tkwdemo: ok`.

## Why grid, not pack

`pack` cannot give stacked widgets independent, honoured sizes: a frame's
requested size is ignored unless its container has a fixed size **and**
`pack propagate <w> 0`, and `-fill both -expand 1` makes a child grab *all*
slack rather than its share. `grid` solves this directly: cells size by
`-weight` and `-minsize`, and `-sticky nsew` makes a child fill its cell. Every
widget here that has to size children reliably is laid out with `grid`. When you
build your own composite layouts, reach for `grid` first.

## The event contract (read this once)

Tk is single-threaded per window: only the proc that owns the `Toplevel` may
issue Tk commands. So an interactive megawidget does **not** spawn its own
proc. Instead each one owns a `chan of string` named `ev`. Add it to your
application's main `alt`, and when it fires call the widget's handler **in the
same proc**:

```limbo
tkw := load Tkwidgets Tkwidgets->PATH;
tkw->init();

nb := Notebook.new(win, ".nb");
pn := Paned.new(win, ".pn", Tkwidgets->Horiz, array[] of {180, 360});
tr := Tree.new(win, ".tr", 0, 0);
sl := Scrolledlist.new(win, ".sl", 0, 0, "-selectmode browse");
...
for(;;) alt {
... kbd / ptr / ctl as usual ...
name := <-nb.ev =>  nb.select(name);              # tab clicked
s    := <-pn.ev =>  pn.drag(s);                   # sash dragged
s    := <-tr.ev =>  id := tr.click(s);            # branch toggled / row picked
e    := <-sl.ev =>  i  := sl.cursel();            # "select" | "activate"
}
```

A constructor creates a container frame at the path you give it but does **not**
geometry-manage that frame — you `pack`/`grid` it wherever you want:

```limbo
nb := Notebook.new(win, ".nb");
tk->cmd(win, "pack .nb -fill both -expand 1");
```

Mutators that represent a discrete user-facing change (`select`, `setitems`,
`drag`, `set`, …) call `update` for you. The low-level `insert` does not, so you
can batch a build and `update` once.

## Helpers

```limbo
cmds: fn(top: ref Tk->Toplevel, a: array of string): string;
cmdl: fn(top: ref Tk->Toplevel, a: list of string): string;
```

Apply a sequence of Tk commands in order, stopping at and returning the first
that produced a Tk error (a result beginning with `!`), prefixed with the
offending command; `""` means every command succeeded. Use these for the
common "array of widget-config strings" idiom instead of a hand-rolled loop
that silently ignores failures.

## Scrolledlist — a listbox that honours its size

A listbox + vertical scrollbar in one frame. The bare `listbox` ignores
`-width`/`-height`; here pass `w`/`h` as container pixels (`0` = grow to fill
the parent instead), and the size is honoured (fixed-size frame + grid weights).
`opts` is extra listbox options.

```limbo
sl := Scrolledlist.new(win, ".nav", 160, 0, "-selectmode browse -bg white");
tk->cmd(win, "pack .nav -side left -fill y");
sl.setitems(array[] of {"Genesis", "Exodus", "Leviticus"});
...
e := <-sl.ev =>           # "select" (single click) | "activate" (double)
    i := sl.cursel();     # -1 = nothing selected
    if(i >= 0)
        chosen := sl.get(i);
```

Methods: `setitems`, `insert`, `clear`, `count`, `get(i)`, `cursel`,
`select(i)`. The item count is tracked in Limbo because the listbox cannot
report it unambiguously (`index end` returns `0` for both empty and one item).

## Scrolledtext — a text widget that honours its size and wraps

The text-widget sibling of `Scrolledlist`: a `text` + vertical scrollbar in one
frame, sized the same way (`w`/`h` container pixels, `0` = fill the parent).
`opts` is extra text options; omit `-state disabled` for an editable pane. It
gives the text a tiny *requested* size, so in fill mode it wraps to the width it
is actually given instead of forcing its container to the text widget's ~80-char
default (which overflows a narrow column). The text widget's built-in wheel and
page-key bindings still apply.

```limbo
xt := Scrolledtext.new(win, ".ctx", 0, 0, "-state disabled -wrap word -bg white");
tk->cmd(win, "pack .ctx -fill both -expand 1");
xt.tagconfig("HEAD", "-foreground #404040");
xt.clear();
xt.insert("Romans 5:8\n", "HEAD");
xt.insert("But God commendeth his love toward us...\n", "");
...
e := <-xt.ev =>                    # "<x> <y>" on Button-1 (widget focused first)
    tags := xt.tagsat(...);       # hit-test a clicked tag
```

Methods: `clear`, `insert(s, tags)`, `get`, `see(idx)`, `atend` (the
`{end -1c}` index), `tagconfig`/`tagadd`/`tagremove`/`tagranges`, and
`tagsat(x, y)`. `Button-1` focuses the widget and fires `ev` with the click
coordinates so the owner can hit-test tags (e.g. a clickable cross-reference).

## Notebook — tabbed pages

A strip of tab buttons over a stack of pages; only the selected page shows.
`add(name, label)` returns the page's **frame path** — fill it with your
widgets. On `ev` (a tab was clicked) call `select(name)`.

```limbo
nb := Notebook.new(win, ".nb");
tk->cmd(win, "pack .nb -fill both -expand 1");
p1 := nb.add("home", "Home");        # p1 == ".nb.body.home"
tk->cmd(win, "label " + p1 + ".hi -text {hello}");
tk->cmd(win, "pack " + p1 + ".hi");
nb.add("prefs", "Preferences");
...
name := <-nb.ev => nb.select(name);
```

The first page added is shown automatically. `page(name)` returns a page's
frame path; `cur` is the current page name.

## Paned — resizable panes with draggable sashes

`N` panes laid out with grid weights so they track the parent's size, separated
by draggable sashes. One pane (default the last) "stretches" to absorb slack;
the rest hold a pixel size you set with `setsize` or the user drags. `pane(i)`
is the i-th pane's frame path. `new` takes an orientation (`Tkwidgets->Vert`
stacks rows, `Horiz` lays out columns) and the initial pixel sizes.

```limbo
pn := Paned.new(win, ".pn", Tkwidgets->Horiz, array[] of {200, 500});
tk->cmd(win, "pack .pn -fill both -expand 1");
# fill pane 0 with a list, pane 1 with content:
sl := Scrolledlist.new(win, pn.pane(0) + ".l", 0, 0, "");
tk->cmd(win, "pack " + sl.fr + " -fill both -expand 1");
...
s := <-pn.ev => pn.drag(s);          # forward sash events to make it draggable
```

`setstretch(i)` changes which pane absorbs slack; `setsize(i, px)` sets a
non-stretch pane's size programmatically. Dragging a sash transfers pixels
to/from the adjacent fixed pane; the stretch pane takes up the difference.

## Tree — a collapsible tree

A tree rendered into a Scrolledlist (so it scrolls). Build it with
`add(parentid, id, label)` — `""` parent makes a root item — then on `ev` call
`click(s)`, which toggles a branch or selects a leaf and returns the row's `id`.
Branch rows are prefixed `+ ` (collapsed) / `- ` (expanded); leaves are
indented by depth.

```limbo
tr := Tree.new(win, ".tr", 0, 0);
tk->cmd(win, "pack .tr -fill both -expand 1");
tr.add("", "src", "src/");
tr.add("src", "main.b", "main.b");
tr.setexpand("src", 1);
...
s := <-tr.ev =>
    id := tr.click(s);               # toggles a branch, or selects a leaf
    if(id != "")
        open(id);
```

`selectedid()` returns the current row's id; `setexpand(id, on)` expands or
collapses a node programmatically; `clear()` empties the tree. The id you pass
to `add` is what comes back from `click`/`selectedid`, so make it your own
key (a path, a record index, …).

## Statusbar — bottom message bar

A thin bar with a left message that fills, plus optional right-aligned info
cells. Pack it at the bottom of your window.

```limbo
sb := Statusbar.new(win, ".sb");
tk->cmd(win, "pack .sb -side bottom -fill x");
sb.addcell("pos");                   # a right-aligned cell named "pos"
sb.msg("ready");                     # left message
sb.set("pos", "12,40");              # update a named cell
```

## Progressbar — determinate bar

A bar drawn on a canvas; `set(frac)` with `frac` in `0.0 .. 1.0`.

```limbo
pb := Progressbar.new(win, ".pb", 300, 20);
tk->cmd(win, "pack .pb -side top -pady 8");
pb.set(0.4);
```

## Combobox — an entry with a live autocomplete dropdown

An `entry` with a suggestion `listbox` that opens under it as you type. The
widget is **content-agnostic**: it does not know what to suggest, so the owner
supplies candidates on every edit. Feed each `ev` keyword to `event()`, which
updates the widget (moves the highlight, fills/hides the list) and returns the
gist — `"changed"` (recompute and call `suggest`), `"select"` (the user
committed), or `""` (handled internally).

```limbo
cb := Combobox.new(win, ".cb", 40);     # 40-column entry
tk->cmd(win, "pack .cb -fill x");
cb.focus();
...
e := <-cb.ev =>
    case cb.event(e) {
    "changed" => cb.suggest(matchesfor(cb.text()), nil);
    "select"  => run(cb.text());
    }
```

- **`suggest(display, value)`** populates the dropdown: `display` is shown,
  `value` (`nil` ⇒ same as `display`) is what lands in the entry when a row is
  picked. So a launcher can list bare names yet commit a full path/line. An empty
  `display` array hides the list.
- **Keys**: Up/Down move the highlight, Return or a click pick the highlight
  (`ev` → `"select"`), Tab fills the highlight and re-suggests, Escape closes the
  list. Printable keys fire `"changed"`.
- **Why the key specs are braced** (`{<Key-\t>}` etc.): the Tab spec carries a
  literal tab (`0x09`), which `tkword` treats as an argument separator —
  unbraced, the `bind` command splits and the stray remnant clobbers the entry's
  own insert binding. Braces make `tkword` read the spec as one token; this is
  the general rule for binding any whitespace key (Tab) — newline and the
  private-use arrow runes (Up `0xE012` / Down `0xE013`, from `keyboard.h`) survive unbraced, but bracing all
  of them is uniform and safe.

The Run dialog (`appl/wm/toolbar.b`) is the live user: it suggests `$path`
programs and files, so typing `wm/c` lists the matching `/dis/wm` commands.

## Adding a widget to the suite

Keep the contract uniform: a constructor `new(top, path, …)` that creates a
container frame at `path` (caller positions it), an `ev: chan of string` for any
interaction, and methods the owning proc calls. Lay out with `grid` and weights
so the widget resizes sanely. Register each event channel with a unique name via
`tk->namechan` (use the module's `uniq` counter pattern). Detect Tk errors with
the `'!'`-prefix convention. Then add the `.dis` to `appl/lib/mkfile` and a
dependency line on `module/tkwidgets.m`.

## Key files

| File | Purpose |
|------|---------|
| `module/tkwidgets.m` | the API: Scrolledlist, Scrolledtext, Notebook, Paned, Tree, Statusbar, Progressbar, Combobox |
| `appl/lib/tkwidgets.b` | implementation |
| `appl/wm/tkwdemo.b` | demo + `-test` headless self-check |
| `docs/DEV_TK_EXTENSIONS.md` | running log of remaining Tk gaps |
| `docs/ON_GRAPHICS.md` | Draw/Tk/Prefab overview and the tkclient app skeleton |
| `libtk/grids.c` | the `grid` geometry manager these widgets rely on |
| `docs/ON_TERM.md` | the `Term` VT100/ANSI terminal widget — same contract, its own module (`module/term.m`) since it is a full subsystem, not a Tk composite |
