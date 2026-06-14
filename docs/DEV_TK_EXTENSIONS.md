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

### text-widget word lookup is OK — `wordstart`/`wordend`/`-offset` exist (no gap)
- Note (not a gap): the `text` widget *does* support the `wordstart`/`wordend`
  index modifiers (double-click word -> dictionary works) and tag `-offset`
  (real superscript verse numbers).  Recorded so we don't re-investigate.
