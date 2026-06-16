# Cursor sets

Mouse-cursor art for the system, organised one directory per set.  Files are
Windows cursor format (`.cur` static, `.ani` animated) and are decoded natively
by the `Curfile` library — see `docs/ON_GRAPHICS.md`.

Install one with `wm/theme`:

```
theme --cursor uo/gauntlet-anim.ani     # one-shot: show this cursor now
theme --cursor-default templeos/arrow_dark-outline.cur   # the desktop default
```

`--cursor-default` sets the cursor the desktop and plain windows fall back to
(applied at wm login); a window can request its own cursor while the pointer is
over it, and the wm restores the default on the way out.

## Sets

- **`templeos/`** — recreations of the TempleOS pointer (public domain, by
  anon129).  Plain arrows; `arrow_dark-outline.cur` is the conservative login
  default.  `arrow.cur` is the exact inverting original (not representable in
  straight alpha, so it shows blank — kept for reference).
- **`uo/`** — Ultima Online set (public domain, by THTH): the gauntlet pointer
  and its animated form, plus `grab` and `quill` for context cursors, and the
  `busy` hourglass.

Per-set licences are in each directory's `LICENSE.txt`.
