# DEV_TK_EXTENSIONS — candidate Tk UI extensions / reusable widgets

Inferno's Tk is frozen at roughly Tk 8.0 (circa 1997–2001). Mainstream Tk and
the wider GUI world gained a great deal since: themed widgets (ttk), a notebook
(tabs), treeview, combobox, spinbox, panedwindow, richer text-widget features,
and so on. When building an application here we keep hitting places where a
modern widget would be the natural tool and Inferno's Tk has nothing for it.

This file is the running log of those gaps. The intent is that the recurring
ones graduate into a **reusable in-tree UI-element library** (Limbo megawidgets
built on the primitives we do have, and/or new C widgets in `libtk`), rather
than every application re-hand-rolling the same workaround.

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

## Log

### panedwindow / reliable fixed-split container — stacked resizable panes
- Needed by: wm/bible nav (a Books list above a Chapters list); generally any
  app that wants two scrollable widgets sharing a column with independent sizes.
- Today: nothing. No `panedwindow`. Worse, the packer makes this hard by hand:
  a frame's requested `-width`/`-height` is only honoured when its container has
  a fixed size set via `-width/-height` **and** `pack propagate <frame> 0`;
  packing a frame `-fill x` without `-expand` does NOT give it its requested
  height, and packing it `-fill both -expand 1` makes it grab *all* the leftover
  space (not its requested size).  Two stacked listboxes therefore can't be
  given independent heights: asymmetric `-expand` reorders them side-by-side,
  symmetric `-expand` makes both collapse to nothing.
- Workaround: a single drill-down listbox (Books -> that book's Chapters -> a
  "<< Books" item to go back).  Robust, but loses the at-a-glance two-pane view.
- Reusable shape: a `panedwindow` C widget (sashes, per-pane min/size), or a
  Limbo `Paned` megawidget that lays out N children at fixed/relative fractions
  of a parent and reliably sizes each (wrapping the propagate-0 + fixed-size
  idiom so callers don't have to rediscover it).
- Effort/notes: a Limbo megawidget is the cheap first step; a real C panedwindow
  with draggable sashes is the nice end state.

### listbox -width/-height not reliably honoured; no -font fill behaviour
- Needed by: wm/bible nav list (wanted a stable ~18-char-wide column).
- Today: `listbox -width N` (chars) and `-height N` (rows) are not honoured the
  way stock Tk does; the listbox ends up sized to its content, and `-fill both
  -expand 1` fills height (inside a fixed-size propagate-0 frame) but not width.
- Workaround: wrap the listbox in a fixed-size frame with `pack propagate 0`;
  accept content-driven width.
- Reusable shape: a `Scrolledlist` megawidget (listbox + scrollbar + a fixed,
  honoured -width/-height) used everywhere a scrollable list is needed.
- Effort/notes: small Limbo wrapper; pairs naturally with the Paned element.

### text-widget word lookup is OK — `wordstart`/`wordend`/`-offset` exist (no gap)
- Note (not a gap): the `text` widget *does* support the `wordstart`/`wordend`
  index modifiers (double-click word -> dictionary works) and tag `-offset`
  (real superscript verse numbers).  Recorded so we don't re-investigate.
