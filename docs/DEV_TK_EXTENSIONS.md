# DEV_TK_EXTENSIONS — candidate Tk UI extensions / reusable widgets

Inferno's Tk is frozen at roughly Tk 8.0 (circa 1997–2001). Mainstream Tk and
the wider GUI world gained a great deal since: themed widgets (ttk), a notebook
(tabs), treeview, combobox, spinbox, panedwindow, richer text-widget features,
and so on. When building an application here we keep hitting places where a
modern widget would be the natural tool and Inferno's Tk has nothing for it.

This file is the running log of those gaps. The recurring ones graduate into the
**reusable megawidget library** `Tkwidgets` (`module/tkwidgets.m`,
`appl/lib/tkwidgets.b`; see [ON_TK_WIDGETS.md](ON_TK_WIDGETS.md)) — Limbo
megawidgets built on the primitives we do have and the `grid` geometry manager
— rather than every application re-hand-rolling the same workaround. A real C
widget in `libtk` is the nicer end state for some, but a Limbo megawidget is the
cheap first step and the default home for entries here.

When you fill a gap by adding a widget to `Tkwidgets`, delete its entry below.

For each entry: what was needed, where it came up, what exists today, the
workaround used (if any), and a sketch of what a reusable element would be.

## Format

```
### <widget/feature> — <short need>
- Needed by: <app/feature>
- Today: <what Inferno Tk offers, or nothing>
- Workaround: <what we did instead, or "blocked">
- Reusable shape: <megawidget vs C widget; rough API>
- Effort/notes: <…>
```

## Filled (now in Tkwidgets — see ON_TK_WIDGETS.md)

`Notebook` (tabs), `Paned` (resizable panes with draggable sashes),
`Scrolledlist` (listbox + scrollbar with an honoured size), `Tree` (collapsible
tree), `Statusbar`, and `Progressbar`. The reliable-sizing problem the old
panedwindow/listbox entries described is solved by laying these out with `grid`
(`-weight`/`-minsize`/`-sticky`) instead of `pack`.

## Log

### Scrolledtext — a text widget + scrollbar with an honoured size (HIGH VALUE)
- Needed by: wm/bible — hand-rolled the *same* text+scrollbar-in-a-sized-frame
  **three times** (the reading pane, the two Notebook context pages, the note
  editor).  It is the obvious sibling of `Scrolledlist` and its absence is felt
  immediately once you adopt the suite.
- Today: nothing; you build `frame`(fixed `-width`/`-height` + `grid/pack
  propagate 0`) + `text` (`-fill both -expand 1`/grid `-sticky nsew`) +
  `scrollbar` by hand each time.
- Reusable shape: `Scrolledtext.new(top, path, w, h, opts): ref Scrolledtext`
  mirroring `Scrolledlist` — fields `fr`/`t`/`ev` (a click event carrying the
  `@x,y` like the listbox does, so apps can hit-test tags), methods
  `clear`/`insert(s, tags)`/`get`/`see`/`tagconfig`/`tagadd`.  An editable
  variant (or an `-editable` opt) would also cover note/compose editors.
- Effort/notes: small; same grid+weights recipe Scrolledlist already uses.

### "use grid" footgun — mixing pack and grid in one master fails opaquely
- Not a missing widget; a doc/ergonomics gap.  ON_TK_WIDGETS says "reach for
  grid" for your own composites (correct).  But if *any* child has already been
  packed into a master, `grid <child> <master>` returns the bare `!not a grid`
  (libtk/grids.c:529) with no hint which manager or which child is the culprit.
  This bites especially with Inferno's default-master rule: `pack .a.b.c` with
  no `-in` packs into `.a.b.c`'s *name parent* `.a.b`, so a mis-named widget
  silently taints a frame you meant to grid.  A one-paragraph "gotchas" note in
  ON_TK_WIDGETS ("a master is pack-or-grid, never both; watch the name-parent
  default; the error is just 'not a grid'") would save the next person the hunt.

### text-widget word lookup is OK — `wordstart`/`wordend`/`-offset` exist (no gap)
- Note (not a gap): the `text` widget *does* support the `wordstart`/`wordend`
  index modifiers (double-click word -> dictionary works) and tag `-offset`
  (real superscript verse numbers).  Recorded so we don't re-investigate.
