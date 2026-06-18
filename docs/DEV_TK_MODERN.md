# DEV_TK_MODERN — bringing Inferno's Tk up to a modern (Tk 8.6 + ttk) feature set, in C

> **Status:** in progress. Phase 0 (substrate) and Phase 1 (ttk engine) are
> done; Phase 2 (basic ttk widgets) is largely done; Phase 3 has started
> (`ttk::progressbar`). See §12 for the live state. This document is the
> cold-start briefing; it captures how `libtk` actually works (with `file:line`
> anchors), the gap to modern Tk/ttk, and a phased plan. Read it top to bottom
> once before touching code.
>
> **Decision already taken (do not relitigate):**
> 1. Implement everything **natively in C inside `libtk`** — do *not* port the
>    real Tcl/Tk codebase, and do *not* add a Tcl interpreter (Limbo is Inferno's
>    scripting layer; a `tk->cmd` string substrate is all Tk needs).
> 2. Target the **real ttk architecture** — a style/element/layout engine plus a
>    widget state machine — not a cheap "appearance bridge."
> 3. The Limbo megawidget library `Tkwidgets` is the **prototype/spec** for the
>    native widgets and will be **absorbed** into `libtk` over time (its ADTs
>    become thin wrappers, then are deprecated).
> 4. **Compatibility is the governing constraint:** ~140 apps drive Tk through
>    command strings + `module/tk.m`. Every change is **purely additive** — never
>    change an existing command's semantics, an option default, or a classic
>    widget's default appearance/geometry.

Related docs: [ON_GRAPHICS.md](ON_GRAPHICS.md) (Draw/Tk/Prefab overview),
[ON_TK_WIDGETS.md](ON_TK_WIDGETS.md) (the megawidgets being absorbed),
[DEV_TK_EXTENSIONS.md](DEV_TK_EXTENSIONS.md) (the gap log megawidgets graduated
from), [ON_THEMING.md](ON_THEMING.md) (the existing `theme` command — the seed of
the style engine), [ON_C_IN_INFERNO.md](ON_C_IN_INFERNO.md) (Plan 9 C dialect),
[ON_C_IN_DIS.md](ON_C_IN_DIS.md) (LP64/dual-ABI rules — relevant at the
Limbo boundary in `libinterp/tk.c`).

---

## 0. What Inferno's Tk is (and is not)

Inferno's Tk is **not Tcl/Tk**. It is an independent C reimplementation of the Tk
*command language*, written by Vita Nuova / Bell Labs circa 1996, that:

- has **no Tcl underneath** — the "interpreter" is a thin command dispatcher in
  `libtk` (`tkexec`, `libtk/utils.c:1706`) driven from Limbo by passing command
  strings to `tk->cmd`;
- **renders on `libdraw`** (Inferno's `Image`/`Display`), not X11/Win32/Cocoa;
- wires its **event model to Inferno channels** (named channels, the
  `Tk->Toplevel` ADT in `module/tk.m`).

Tk 8.6 / 9.0 is a different codebase welded to Tcl's object system and three
native windowing backends. There is **no merge or version-bump path** — they
share a command *vocabulary* and none of the implementation. "Modernizing"
therefore means **selectively re-implementing modern Tk's features inside
Inferno's own `libtk`**.

Today `libtk` is roughly **Tk 8.0–8.3 minus a few primitives** (no `after`, no
`place`, no `font` command, no `ttk`). The widget set renders with a fixed
classic 3D-relief look, recently made themeable by this fork's `theme` command.

---

## 1. Architecture primer (navigate `libtk` from here)

### 1.1 File map (`libtk/*.c`, sizes approximate)

| File | LOC | Role |
|---|---|---|
| `utils.c` | 2125 | **Core runtime.** Command dispatch (`tkexec`/`tksinglecmd`/`tkwidgetcmd`), `cmdmain[]` top-level table, env/colour helpers (`tkgc`/`tkgshade`/`tkcolor`/`tkgradient`), relief/bevel drawing (`tkbevel`/`tkdrawrelief`), string drawing, the **timer wrappers** (`tkrepeat`/`tkblink`), `tksorttable`. |
| `windw.c` | 693 | Toplevel/window machinery: `tknewctxt`, map/unmap, geometry change, **the draw/update loop** (`tkupdate`, `tkdrawslaves`), focus order. |
| `parse.c` | 1195 | **Option/configure parser** (`tkparse`, `tkgencget`, `tkconflist`), word lexer (`tkword`/`tkskip`), colour parse (`tkparsecolor`). |
| `ebind.c` | 1028 | **Event/bind engine**: `bind` command, `%`-substitutions, event delivery (`tkdeliver`/`tksubdeliver`), `winfo`, `focus`, sequence parsing (`tkseqparse`). |
| `xdata.c` | 217 | Static tables: **`tkmethod[]`** (type→vtable), generic option tables (`tkgeneric`/`tktop`), `TkStab` enums, error strings. |
| `packr.c` | 696 | **`pack`** geometry manager. |
| `grids.c` | 1526 | **`grid`** geometry manager. |
| `thm.c` | 178 | **`theme`** command (the style-engine seed). |
| `colrs.c` | 85 | `tksetenvcolours` — derives a widget env's 18-slot colour array from `tktheme`. |
| `image.c` | 380 | `image` command, `TkImg` management. |
| `varbl.c` | 91 | Tk variables + variable-change notification. |
| `extns.c` | 37 | Style-extension hooks (all no-ops in `std`). |
| widgets | — | `frame.c`, `label.c`, `buton.c` (button/check/radio), `menus.c` (menu/menubutton/cascade/separator/**choicebutton**), `listb.c`, `scale.c`, `scrol.c`, `entry.c`, `panel.c` |
| `text` | — | `textw.c` (3701), `textu.c`, `tindx.c`, `tmark.c`, `ttags.c`, `twind.c` |
| `canvas` | — | `canvs.c` (2220) + items `carcs.c`/`cbits.c`/`cimag.c`/`cline.c`/`coval.c`/`cpoly.c`/`crect.c`/`ctext.c`/`cwind.c`, `canvu.c` |

### 1.2 Core data structures (all in `include/tk.h`)

- **`Tk`** (`tk.h:474`) — the base widget. Fields: `type` (a `TK*` enum index),
  `name`, tree links (`siblings`/`master`/`slave`/`next`/`parent`), `flag`
  (state + control bits, `tk.h:282`), `env` (colours/font), `binds`, `req`/`act`
  geometry (`TkGeom`), `relief`/`borderwidth`/`highlightwidth`, `pad`/`ipad`,
  `dirty` rect, `grid`. **Widget-specific data is appended after the struct** and
  reached with `TKobj(type, p)` = `((type*)((p)+1))` (`tk.h:615`).
- **`TkWin`** (`tk.h:503`) — extra block for toplevel windows and menus
  (`image`, request id, menu `postcmd`/`cascade`, etc.).
- **`TkMethod`** (`tk.h:525`) — the **widget vtable**: `name`, `cmd` (subcommand
  table), `free`, `draw`, `geom`, `getimgs`, `focusorder`, `dirtychild`,
  `relpos`, `deliver`, `see`, `inwindow`, `varchanged`, `forgetsub`, `ncmd`.
- **`TkCmdtab`** (`tk.h:242`) — `{name, fn}` for one widget subcommand
  (`.w configure`, `.w cget`, …).
- **`TkOption`** (`tk.h:268`) + **`TkOptab`** (`tk.h:276`) — the configure
  machinery. An option is `{name, OPT* type, struct offset, aux}`. `OPT*` types
  are enumerated at `tk.h:82` (`OPTtext`, `OPTcolr`, `OPTfont`, `OPTstab`,
  `OPTbool`, `OPTdist`, `OPTsticky`, …).
- **`TkStab`** (`tk.h:262`) — a `{string, const}` lookup row (for enum-valued
  options like `-relief`, `-anchor`).
- **`TkEnv`** (`tk.h:406`) — per-widget colours (`colors[TkNcolor]`, 18 slots
  enumerated at `tk.h:380`), `font`, `wzero`. **COW-shared** down the tree via
  `tkdupenv`; explicit per-widget colour options break the share.
- **`TkTheme`** + global **`tktheme`** (`tk.h:421`/`tk.h:438`) — the system
  palette/font/relief the `theme` command mutates.
- **`TkTop`** (`tk.h:584`) — one toplevel: the Draw display/image/wmcontext,
  `screenr`, `ctxt`, `root` (widget list), `env`, vars, images, per-type default
  binds, error state.
- **`TkCtxt`** (`tk.h:563`) — per-display context: colour cache, scratch images,
  focus/grab/entered widget, mouse state.

### 1.3 Command dispatch path (the spine)

```
Limbo:  tk->cmd(top, "....")
  -> libinterp/tk.c  Tk_cmd          (tk.c:151) — string2c, calls tkexec
  -> libtk/utils.c   tkexec          (utils.c:1706) — splits ';', handles [] {}
  -> libtk/utils.c   tksinglecmd     (utils.c:1628)
       if first word starts with '.'  -> tklook + tkwidgetcmd  (utils.c:1507)
                                            -> binary search TkMethod.cmd[]
       else                            -> binary search cmdmain[]  (utils.c:22)
                                            -> tkframe/tkbutton/.../tkthemecmd
```

- **`cmdmain[]`** (`utils.c:22`) is the top-level command registry. It is
  **searched by binary search and is hand-sorted alphabetically in source** —
  there is no auto-sort for it. *Adding a top-level command means inserting it in
  alphabetical position.* (e.g. `after` goes **first**, before `bind`.)
- **Widget subcommand tables** (each `TkMethod.cmd`, e.g. `tkframecmd`
  `frame.c:259`) are auto-sorted at startup by **`tksorttable()`**
  (`utils.c:1607`), which also fills in `ncmd`. So those may be listed in any
  order, but **must be `nil`-terminated**.
- `tksorttable()` is the global init hook; it iterates `tkmethod[0..TKwidgets)`.

### 1.4 Anatomy of a widget — `frame.c` is the canonical template

`libtk/frame.c` (278 lines) is the smallest complete widget; copy it to add one.
The pieces:

1. **Create function** `tkframe(TkTop*, char *arg, char **ret)` (`frame.c:7`):
   `tknewobj(t, TKframe, sizeof(Tk))` allocates the `Tk` (+ widget data), build a
   `TkOptab[]` pointing at the option tables, `tkparse(t, arg, tko, &names)`,
   `tkaddchild(t, tk, &names)`, return the widget path via `tkvalue`.
2. **Option tables**: `tkgeneric` (shared, `xdata.c`) + widget-specific tables.
3. **Subcommand table** `TkCmdtab tkframecmd[]` (`frame.c:259`): `cget`,
   `configure`, `map`, `unmap`, `suspend`, `nil`-terminated. `configure`/`cget`
   delegate to `tkparse`/`tkgencget`/`tkconflist` over the option tables.
4. **Draw function** `tkdrawframe(Tk*, Point)` (`frame.c:64`): obtains the target
   `Image` via `tkimageof`, paints background with `tkgc(env, TkCbackgnd)`,
   redraws dirtied slaves, draws relief with `tkdrawrelief`.
5. **Free / focusorder** functions.
6. **`TkMethod framemethod`** (`frame.c:269`) wires the above together.

**Registration of a new widget requires four edits** (the cold session will do
this many times — keep this list):
- declare `extern char* tkfoo(TkTop*,char*,char**);` and `extern TkMethod
  foomethod;` in `include/tk.h`;
- add `&foomethod` to **`tkmethod[]`** in `xdata.c:165` **at the slot matching a
  new `TKfoo` value** added to the `TK*` enum (`tk.h:29`) — *order must match
  the enum*, and `TKwidgets` stays last;
- add `"foo", tkfoo,` to **`cmdmain[]`** (`utils.c:22`) in alpha order;
- add the new `.c` to the build list (`libtk/mkfile-std`, see §1.9).

### 1.5 Option / configure machinery

`tkparse(TkTop*, char *arg, TkOptab *tko, TkName **names)` (`parse.c`, declared
`tk.h:748`) walks `-option value` pairs, looks each up across the `TkOptab`
chain, and applies it by `OPT*` type into the struct at the recorded offset.
`tkgencget` reads one option back; `tkconflist` dumps all. A `TkOptab[]` is a
`nil`-terminated chain so a widget can compose `tkgeneric` + its own table (and
`tktop` when it is a window) — see `tkframeconf` (`frame.c:142`).

### 1.6 Drawing & the dirty model

- Each widget's `draw` method paints into the `Image` returned by `tkimageof`.
  Painting is clipped to the widget's `dirty` rect (relative to the widget).
- **`tkdirty(Tk*)`** (`utils.c:1560`) propagates dirtiness up through transparent
  parents and into canvas/text masters; `tkwidgetcmd` calls it after every
  subcommand.
- **`tkupdate(TkTop*)`** (`windw.c`, declared `tk.h:826`) is the repaint pass; it
  walks `root` and calls each widget's `draw`. The `update` Tk command and the
  Limbo `update` both reach it.
- Colour/relief helpers in `utils.c`: `tkgc(env, idx)` (a solid-colour `Image`
  for one of the 18 `TkC*` slots), `tkgshade` (lighter/darker shade for bevels),
  `tkcolor`/`tkcolormix`/`tkgradient`, `tkbevel`/`tkdrawrelief`. **The ttk
  element painters will be built from exactly these primitives.**

### 1.7 Event model

- `bind` (`ebind.c`) attaches `{event-mask, cmd}` actions. Event bits are in
  `tk.h:336` (`TkButton1P` … `TkMotion`/`TkEnter`/`TkLeave`/`TkKey`/`TkConfigure`
  /`TkDouble`). `TkEmouse`/`TkEpress`/`TkErelease` are convenience masks.
- **`%`-substitutions** are in `ebind.c:226`+: `%x %y` (widget-relative),
  **`%X %Y` (absolute pointer)**, `%b` (button), `%s` (state), `%W` (widget
  path), `%A` (ASCII), `%K` (keysym), `%w %h`.
- Delivery: `tkdeliver` (`utils.c`, declared `tk.h:778`) / `tksubdeliver` /
  the per-widget `deliver` vtable slot.
- **Gaps vs 8.6:** no virtual events (`<<Paste>>`), no `event generate`, no
  `Double/Triple` synthesis beyond `TkDouble`. ttk binding tables need these.

### 1.8 Geometry managers, focus, timer

- **`pack`** (`packr.c`) and **`grid`** (`grids.c`) exist and are complete enough
  for real layouts. The fork's megawidgets all use `grid`
  (`-weight`/`-minsize`/`-sticky`). **There is no `place`.**
- Focus order is computed per-widget via the `focusorder` vtable slot
  (`tkframefocusorder`, `frame.c:229`) + `tksortfocusorder`.
- **Timer (the keystone for `after`/tooltips/animation):** the only clock is
  **`rptproc`** (`emu/port/proc.c:225`, native: `os/port/proc.c:774`), which
  `kproc`s a helper that periodically calls back. `libtk` already wraps it for
  **scrollbar auto-repeat** (`tkrepeat`, `utils.c:1659`) and **caret blink**
  (`tkblink`, `utils.c:2061`). There is exactly **one** `autorpt`/`blinkrpt`
  proc each, multiplexed. An `after` command is built on this same machinery, not
  from scratch — but note the current design holds a single global callback
  (`rptw`/`rptcb`), so `after` needs a small registry of pending timers keyed by
  id, with `after cancel`.

### 1.9 Build & link

- `libtk/mkfile` lists ABI-neutral OFILES; the **widget set is build-selected**
  by `TKSTYLE` (`<mkfile-$TKSTYLE`). `mkconfig:12` sets `TKSTYLE=std`, i.e.
  `libtk/mkfile-std`, which names every widget object (`buton.o`, `label.o`,
  canvas items, text files, …). **New widget `.c` files are added there.** The
  `mkfile-$TKSTYLE` split + `extns.c`/`tkextn*` hooks (`tk.h:843`) is the
  intended seam for an alternate/extended widget style — a natural home for the
  ttk set (e.g. a `ttk`/`mkfile-ttk` style, or fold into `std`).
- The Limbo `$Tk` module interface header is generated: `libinterp/tkmod.h`
  (`libinterp/mkfile:93`, from `module/tk.m`). The Limbo→C entry points live in
  `libinterp/tk.c` (`Tk_cmd`, `Tk_toplevel`, `Tk_namechan`, `Tk_rect`,
  `Tk_pointer`, `Tk_keyboard`, `Tk_putimage`, …).
- **Rebuild:** `make all` from the repo root (cheap, ~55s, and the safe default —
  see memory `always-full-nuke-build`; never half-build). `libtk` is a static
  lib linked into `emu` and into the native kernel; a change rebuilds both.
- **`mk` gotcha (bit this fork repeatedly):** never put a `#` comment between a
  `foo.$O: deps` line and the next rule — `mk` treats it as `foo.$O`'s empty
  recipe. (memory `make-regen-generated-headers`.)

### 1.10 The Limbo boundary & the compatibility surface

- `module/tk.m` defines the **stable ADT** every app and `tkclient`/`wmclient`
  use: `Toplevel`, `cmd`, `namechan`, `rect`, `pointer`, `keyboard`,
  `putimage`/`getimage`, `quote`, `color`. **This ADT layout must not change**
  (it is the 140-app contract). New capability is exposed as **new Tk command
  strings**, not new `tk.m` functions, wherever possible.
- `libinterp/tk.c` is C touching the Dis VM → obey `ON_C_IN_DIS.md` (LP64 pointer
  width, `string2c`, no narrowing). `Tk_rect` returning a `Draw->Rect` was an
  ILP64 crash site historically; keep field-wise discipline if touched.

---

## 2. Current feature inventory (what exists today)

**Widgets:** `frame`, `label`, `button`, `checkbutton`, `radiobutton`,
`menubutton`, `menu` (+ `cascade`, `separator`), `choicebutton` (Inferno-only),
`listbox`, `scale`, `scrollbar`, `entry`, `text` (rich: tags, marks, search,
dump, embedded **windows**), `canvas` (full item set incl. arc/image/window),
`panel` (Inferno-only image widget).

**Commands** (`cmdmain[]`, `utils.c:22`): `bind`, `cursor`, `destroy`, `focus`,
`grab`, `grid`, `image`, `lower`, `pack`, `puts`, `raise`, `see`, `send`,
`theme`, `update`, `variable`, `winfo` (minimal), plus the widget constructors.

**Infrastructure present:** `grid` + `pack`, per-widget selection
(`entry`/`text`/`listbox` `selection` subcommands), the `theme` system + COW envs
(`ON_THEMING.md`), an internal timer (`rptproc`), `%X/%Y` absolute coords in
binds, widget state bits already in `Tk.flag`
(`Tkactive`/`Tkactivated`/`Tkdisabled`/`Tkmapped`, `tk.h:312`).

**Megawidgets (Limbo, `module/tkwidgets.m`) — to be absorbed:** `Scrolledlist`,
`Scrolledtext`, `Notebook`, `Paned`, `Tree` (+`Treenode`), `Statusbar`,
`Progressbar`, `Combobox`. These are the **behavioural specs** for the native
widgets below.

---

## 3. Gap matrix vs Tk 8.6 + ttk

Four layers, each item additive (✅ = present, ❌ = absent, ◑ = partial):

### Layer 1 — substrate primitives (small, zero compat risk, unblock the rest)

| Feature | State | Cost | Notes |
|---|---|---|---|
| `after ms cmd` / `after cancel` / `after idle` | ❌ | Low | `rptproc` plumbing exists (§1.8); needs a pending-timer registry |
| `place` geometry manager | ❌ | Med | self-contained; model on `packr.c`/`grids.c` |
| `font create`/`measure`/`metrics` + named fonts | ❌ | Med | today `-font` is option-only (`OPTfont`); `Font*` lives in `TkEnv` |
| `selection`/`clipboard` top-level + `<<Cut/Copy/Paste>>` | ◑ | Med | per-widget selection exists; no clipboard command, no virtual events |
| `event generate` + virtual events (`<<...>>`) | ❌ | Med | needed by ttk binding tables (`ebind.c`) |
| `winfo` completion (`pointerxy`, `reqwidth`, `screenwidth`, `exists`, `class`…) | ◑ | Low | `winfo` is minimal (`ebind.c:914`) |

### Layer 2 — classic-widget completeness (8.4-era)

| Feature | State | Notes |
|---|---|---|
| `spinbox` | ❌ | new widget (template: `entry.c`) |
| `labelframe` | ❌ | new widget (template: `frame.c` + a title) |
| `panedwindow` (C) | ❌ | exists as `Paned` megawidget |
| entry `-validate`/`-validatecommand` | ❌ | add to `entry.c` |
| text `-undo`/edit stack, embedded **images** | ◑ | text has embedded *windows*, search, tags; no undo, no image embed |
| listbox `-selectmode extended`/`-activestyle` | ◑ | `TKextended` enum exists (`tk.h:51`) |

### Layer 3 — ttk widgets with no classic equivalent (mostly absorb megawidgets)

| ttk widget | Megawidget today | Target |
|---|---|---|
| `ttk::notebook` | `Notebook` | native C |
| `ttk::treeview` | `Tree`/`Treenode` | native C |
| `ttk::progressbar` | `Progressbar` | native C |
| `ttk::combobox` | `Combobox` | native C |
| `ttk::panedwindow` | `Paned` | native C |
| `ttk::separator` / `ttk::sizegrip` | — | small new elements |
| `ttk::scale` / `ttk::scrollbar` | classic `scale`/`scrollbar` | restyle via engine |

### Layer 4 — the ttk **architecture** itself (the bulk of "modern Tk")

`ttk::style` + the **element/layout engine** + the **widget state machine**
(`active`, `disabled`, `focus`, `pressed`, `selected`, `readonly`, …). This is
the part whose purpose — restyling widget appearance — **collides with "don't
break existing apps,"** so it must be a **parallel widget set** (`ttk::*` names)
that leaves classic widgets and their defaults untouched. See §5.

---

## 4. Megawidget absorption plan

`Tkwidgets` (Limbo) is the prototype layer. As each native ttk widget lands:

1. Build the C widget to **match the megawidget's observable behaviour** (its
   `ev` channel contract + subcommands) so apps can switch with minimal churn.
2. Reimplement the megawidget ADT as a **thin shim** over the new C widget (keeps
   source compatibility for current callers: `wm/toolbar`, `wm/tkwdemo`,
   `wm/pleromussy`, the Run dialog's `Combobox`, etc.).
3. Once callers are migrated, **deprecate** the shim and delete its
   `DEV_TK_EXTENSIONS` "Filled" entry.

Order of absorption follows Layer 3: `Progressbar` and `Separator` first
(simplest, pure draw), then `Notebook`, `Paned`, `Combobox`, `Tree`/`treeview`
(richest). `Scrolledlist`/`Scrolledtext`/`Statusbar` are compositional and may
stay Limbo conveniences, or become ttk `-scroll` options.

---

## 5. Target architecture — a native ttk engine in `libtk`

What ttk actually is, and how each piece maps onto the existing `libtk`:

- **Widget state machine.** ttk widgets carry a *state set* and bind appearance
  to it. **Good news:** `Tk.flag` already has `Tkactive`/`Tkactivated`/
  `Tkdisabled`/`Tkmapped` (`tk.h:312`). The engine needs the fuller ttk set
  (`focus`, `pressed`, `selected`, `readonly`, `alternate`, `invalid`,
  `hover`) — extend the flag word (bits are nearly full; consider a dedicated
  `ulong state` field on the ttk widget data block instead of overloading
  `flag`), plus `state`/`instate` widget subcommands.
- **Element / layout / style engine** = the new subsystem (no analogue today).
  - An **element** draws one visual primitive (border, background, indicator,
    arrow, tab, trough, slider, focus ring) into an `Image` rect for a given
    state — built from `tkbevel`/`tkgc`/`tkgshade`/`tkgradient` (`utils.c`).
  - A **layout** composes elements with packing hints (sticky/expand) into a
    widget — reuse the geometry vocabulary already in `tk.h:282`
    (`Tksticky`/`Tkexpand`/anchors).
  - A **style** = a named map from `(element, state) → options` (colours, bevel
    widths, padding). Seed it from the existing **`tktheme`** palette
    (`thm.c`/`colrs.c`) so ttk widgets are themed by the same lever as classic
    ones, and the fork's `theme` command keeps working.
  - **`ttk::style` command** — new top-level command (`cmdmain[]`) exposing
    `configure`/`map`/`layout`/`element create`/`theme use`.
- **The ttk widgets** = new `TkMethod` entries (new `TKttk*` enum slots,
  `tkmethod[]` rows, `cmdmain[]` constructors `ttk::button` …) whose `draw`
  method calls the style engine instead of hand-painting. They are a **parallel
  set**: classic `button` is untouched; `ttk::button` is new.
- **Files:** a new cluster, e.g. `libtk/ttkstyle.c` (engine + `ttk::style`),
  `libtk/ttkelem.c` (default element painters), `libtk/ttk*.c` (widgets), added
  to `mkfile-std` (or a new `mkfile-ttk` `TKSTYLE`). Keep names `ttk*` so the
  file map stays legible.

**Why parallel, not in-place:** the compat contract forbids moving classic
defaults. A parallel set lets apps adopt `ttk::*` incrementally; `wm`'s `theme`
system already gives a global look knob, so the two coexist cleanly.

---

## 6. Phased roadmap

Each phase is independently shippable and compat-verified before the next.

- **Phase 0 — substrate (Layer 1).** `after`/`after cancel`/`after idle` on a new
  pending-timer registry over `rptproc`; then `place`; then `event generate` +
  virtual events; then `winfo` completion; `font` command + named fonts as
  needed. *Unblocks tooltips (≈20 lines of bind+after+place once this lands) and
  every ttk binding table.* Low risk, high leverage. **Start here, with `after`.**
- **Phase 1 — ttk core engine (Layer 4).** State field + `state`/`instate`;
  element/layout/style subsystem; `ttk::style`; the default theme wired to
  `tktheme`. No user-visible widgets yet — validate by drawing a single
  `ttk::frame`/`ttk::label`/`ttk::button` test trio.
- **Phase 2 — ttk basic widgets.** `ttk::frame`, `ttk::label`, `ttk::button`,
  `ttk::checkbutton`, `ttk::radiobutton`, `ttk::entry`, `ttk::menubutton`,
  `ttk::labelframe`, `ttk::separator`, `ttk::sizegrip`.
- **Phase 3 — ttk complex widgets, absorbing megawidgets (Layer 3).**
  `ttk::progressbar` ← `Progressbar`; `ttk::notebook` ← `Notebook`;
  `ttk::panedwindow` ← `Paned`; `ttk::combobox` ← `Combobox`; `ttk::treeview` ←
  `Tree`; `ttk::scale`/`ttk::scrollbar`/`ttk::spinbox`. Reimplement each
  megawidget as a shim, migrate callers, deprecate.
- **Phase 4 — classic completeness (Layer 2).** `spinbox`, entry `-validate`,
  text undo + embedded images, listbox `extended`/`activestyle` — for apps that
  stay on classic widgets.
- **Phase 5 — polish & deprecation.** Remaining megawidget shims removed; docs
  (`ON_TK_WIDGETS` → ttk migration note); `tkwdemo` extended to a ttk gallery;
  optional `ttk::style theme` presets matching `/lib/themes/{default,dark,temple}`.

---

## 7. Compatibility contract & verification harness

**Additive-only rules (non-negotiable):**
- Never change an existing command's semantics, an option's default, or a classic
  widget's default appearance/geometry.
- Never change the `module/tk.m` ADT layout. New power = new command strings.
- New top-level commands go in `cmdmain[]` in **alpha order**; new widget
  subcommands are `nil`-terminated and auto-sorted; new `TK*` enum slots keep
  `tkmethod[]` order and keep `TKwidgets` last.

**Verification (prove the 140 apps still render identically) — the real cost
driver, not the C:**
- The **GUI gauntlet**: bring up `wm` and exercise `wm/tkwdemo`, `acme`,
  `charon`, the toolbar Run/Power dialogs, `wm/pleromussy`, `wm/gifview`.
- Tooling: the shared **Xvfb/x11vnc** desktop (memory `shared-vnc-gui-workflow`;
  drive with `xdotool`, never `pkill -x emu` on a live desktop), the
  **`gui-test-xvfb`** skill for headless screenshot/inject, and
  `tests/dis/scenario.sh` (memory `inferno-autonomy-harness`) for deterministic
  headless runs with a JSON verdict.
- Always run `emu` with `EMUCRASH=1` + `ulimit -c unlimited` (memory
  `always-launch-emucrash`) so any regression drops a core.
- Per-phase: screenshot the classic-widget gallery before/after and diff — a
  pixel change in a *classic* widget is a compat failure by definition.

---

## 8. Concrete recipes (do these by rote)

**Add a top-level command (e.g. `after`):**
1. write `char* tkafter(TkTop*, char*, char**)` (new file `libtk/after.c`, or in
   `utils.c`);
2. `extern` it in `include/tk.h`;
3. insert `"after", tkafter,` **first** in `cmdmain[]` (`utils.c:22`, alpha
   order);
4. add `after.$O` to `libtk/mkfile-std` if a new file;
5. back it with a pending-timer registry over `rptproc` (§1.8) — generalise the
   single `rptw`/`rptcb` slot into a list keyed by id; `after cancel` removes by
   id; fire by re-`tkexec`-ing the stored command on the Tk proc.

**Add a widget (e.g. `ttk::button`):** copy `frame.c`; add a `TKttkbutton` enum
slot (`tk.h:29`); add `&ttkbuttonmethod` at the matching `tkmethod[]` slot
(`xdata.c:165`); add the constructor to `cmdmain[]`; add the `.c` to
`mkfile-std`; `extern` the method + constructor in `tk.h`. The `draw` method
calls the style engine (Phase 1) rather than painting directly.

**Add an option:** append a `TkOption` row `{ "-foo", OPT*, O(Struct, field),
aux }` to the widget's option table; pick the `OPT*` type from `tk.h:82`; for an
enum option add a `TkStab[]` and use `OPTstab`/`OPTflag` with the table in `aux`.

---

## 9. Risks & open questions

- **State storage:** `Tk.flag` bits are nearly exhausted (`tk.h:282` runs to
  `1<<31`). The ttk state set likely needs its own `ulong state` on the ttk
  widget data block rather than more `flag` bits. Decide early in Phase 1.
- **Engine scope creep:** real ttk's element/layout/style system is large. Scope
  Phase 1 to the minimum that renders the basic-widget trio convincingly; grow
  element types as widgets demand them.
- **Font subsystem:** named fonts + `font measure` interact with `TkEnv.font`
  (`Font*`, `wzero`) and `lockdisplay` discipline (`thm.c:139` shows the dance).
  Get the locking right (memory: cross-proc Tk/Draw hazards).
- **Megawidget migration churn:** absorbing `Combobox`/`Tree` means touching live
  apps (`wm/toolbar` Run dialog, `pleromussy`). Keep shims until callers move.
- **LP64 at the boundary:** anything added to `libinterp/tk.c` must follow
  `ON_C_IN_DIS.md` (no pointer narrowing; field-wise Draw geometry). The widget C
  in `libtk` is host-ABI plain C and largely LP64-safe already, but new code that
  stores pointers in `int` will bite.
- **`place` vs grid/pack interactions:** decide whether `place` can coexist in a
  master that also packs/grids (real Tk allows place to overlay). The
  "pack-or-grid, never both" footgun (`DEV_TK_EXTENSIONS.md`) is a precedent to
  document for `place` too.

---

## 10. Quick file/line index

| What | Where |
|---|---|
| Public header / all structs / enums | `include/tk.h` |
| `TK*` widget-type enum | `tk.h:29` |
| `Tk.flag` control + event bits | `tk.h:282`, `tk.h:336` |
| 18 colour slots (`TkC*`) | `tk.h:380` |
| `OPT*` option types | `tk.h:82` |
| `Tk` / `TkWin` / `TkMethod` / `TkTop` / `TkCtxt` / `TkEnv` / `TkTheme` | `tk.h:474` / `:503` / `:525` / `:584` / `:563` / `:406` / `:421` |
| Top-level command table `cmdmain[]` | `libtk/utils.c:22` |
| Dispatch `tkexec`/`tksinglecmd`/`tkwidgetcmd` | `utils.c:1706` / `:1628` / `:1507` |
| Cmd-table sort/init `tksorttable` | `utils.c:1607` |
| `tkmethod[]` type→vtable array | `libtk/xdata.c:165` |
| Widget template | `libtk/frame.c` |
| Option parser | `libtk/parse.c` (`tkparse`, `tkgencget`, `tkconflist`) |
| Bind/events/`winfo`/`%`-subs | `libtk/ebind.c` (`:226`, `:914`) |
| Draw/update loop | `libtk/windw.c` (`tkupdate`) |
| Colour/relief/bevel/timer helpers | `libtk/utils.c` (`tkgc`/`tkgshade`/`tkbevel`/`tkrepeat`/`tkblink`) |
| `theme` command + `tktheme` | `libtk/thm.c`, `libtk/colrs.c` |
| Timer primitive `rptproc` | `emu/port/proc.c:225`, `os/port/proc.c:774` |
| Limbo↔C boundary | `libinterp/tk.c` (`Tk_cmd:151`, `Tk_namechan:553`) |
| Stable Limbo ADT (compat contract) | `module/tk.m` |
| Build / widget-set selection | `libtk/mkfile`, `libtk/mkfile-std`, `mkconfig:12` (`TKSTYLE=std`) |
| Megawidgets to absorb | `module/tkwidgets.m`, `appl/lib/tkwidgets.b` |

---

## 11. Userspace apps to bring up to date afterwards

Once the ttk widgets land, the user-facing app suite should be migrated from
classic widgets to `ttk::*` (and off the Limbo megawidget shims). These are the
apps that drive Tk and that a user actually sees; each has a **baseline "before"
screenshot** captured to `tests/dis/tk_baseline/<name>.png` (regenerate with
`tests/dis/tk_baseline_shots.sh`). A pixel change in a *classic* widget is a
compat regression; these shots are the golden reference to diff against during
and after the migration.

Migration priority is roughly top-to-bottom (most-used / most-visible first):

| App (`.dis`) | Baseline shot | What it exercises / migration notes |
|---|---|---|
| `wm/toolbar` + `wm/wm` | (chrome in every shot) | The desktop itself: start menu, taskbar, pager, clock, the Run/Power dialogs (already use `Combobox`). Migrate first — it sets the look. |
| `wm/tkwdemo` | `tkwdemo.png` | The widget gallery; the canonical before/after for *every* widget. Opens compact — resize to see all tabs. |
| `acme` | `acme.png` | Heavy `text`/`canvas` user; tags, scrollbars. High blast radius. |
| `wm/sh` | `shell.png` | Terminal/`text` widget. |
| `wm/edit` | `edit.png` | `text` editor + menus + scrollbars. |
| `charon` | `charon.png` | Browser chrome (toolbar, entry, scrollbars) around the render area; form controls. |
| `wm/pleromussy` | `pleromussy.png` | Fediverse client; already a `Tkwidgets` consumer (`Scrolledtext`/`Combobox`). |
| `wm/bible` | `bible.png` | `Scrolledtext`/`Tree`-style navigation. |
| `wm/man` | `man.png` | Manual browser; `text` + nav. |
| `wm/ftree` | `ftree.png` | File tree — prime `ttk::treeview` (`Tree` megawidget) consumer. |
| `wm/deb` | `debugger.png` | Source debugger; `Scrolledlist`/`text`, stack/var panes. |
| `wm/rt` | `module-manager.png` | Module manager; listbox/table. |
| `wm/task` | `task-manager.png` | Process table — `ttk::treeview` candidate. |
| `wm/memory` | `memory-monitor.png` | Live canvas graph + labels. |
| `wm/about` | `about.png` | Simple label/button dialog (good minimal regression check). |
| `wm/colors` | `colours.png` | Canvas palette + entry. |
| `wm/date` | `clock.png` | Clock/calendar. |
| `wm/vt` | `vt-terminal.png` | The new VT100 terminal widget (`ON_TERM.md`). |
| `wm/tetris` | `tetris.png` | Canvas game + score labels (non-widget render sanity). |

Other Tk apps in `appl/wm/` not in the priority set but worth a pass:
`wm/calendar`, `wm/brutus`, `wm/view`, `wm/gifview`, `wm/readmail`/`sendmail`,
`wm/telnet`, `wm/keyboard`, `wm/stopwatch`, `wm/snake`/`bounce`/`reversi`/`c4`
and the other games, `wm/mand`, `wm/polyhedra`, `wm/raycube*`/`rayteapot`,
`wm/wish` (the interactive Tk shell — useful for live widget testing).

> Capture note: each shot is a first-render of `emu -g1024x768 wm/wm <app>` under
> Xvfb (one emu per app). Some apps open at a compact natural size or need a file
> argument / interaction to show full content; the shots are a visual reference,
> not a pixel-exact acceptance target. For acceptance, drive the full desktop and
> diff classic-widget regions per §7.

---

## 12. Implementation status (live)

Everything below is **additive** — classic widgets and existing apps are
untouched, verified by `wm/about` rendering byte-identical to its baseline and
by the ttk widgets exercising real `pack`/`grid` mixing without disturbing it.

**Phase 0 — substrate: DONE.**
- `after ms cmd` / `after cancel` / `after idle` / `after info` — `libtk/after.c`,
  pending-timer registry over `rptproc`. Test `tests/dis/tkafter.b` (10/10).
- `place` geometry manager (+ `winfo` geometry queries) — `libtk/place.c`,
  `ebind.c`. Placed slaves ride the shared `master->slave` list, skipped by
  pack/grid, so a master may mix placed and packed children. Test
  `tests/dis/tkplace.b` (20/20).
- `event generate` + virtual events (`<<Name>>`) — `libtk/event.c`. Concrete
  events synthesised through `tkseqparse`+`tkdeliver`; virtual events on a
  per-top `{widget,name,script}` registry. Test `tests/dis/tkevent.b` (8/8).
- `font measure|metrics|actual|families|names` — `libtk/font.c` (measurement
  subset; named-font creation deferred). Test `tests/dis/tkfont.b` (12/12).

**Phase 1 — ttk engine: DONE.** `libtk/ttk.c` + `libtk/ttk.h`.
- State machine (`active disabled focus pressed selected background alternate
  invalid readonly hover`) in a per-widget `TkTtk.state`; `state`/`instate`
  subcommands; `disabled`/`active` mirrored into `Tk.flag`.
- Named-style registry per `TkTop` (freed via `ttkfreetop`, hooked into
  `tkfreetop`): `ttk::style configure|map|lookup|theme`. Option resolution with
  dotted-prefix inheritance; colour options fall back to themed `TkEnv` slots so
  the `theme` command themes ttk too.
- Element painters (background, flat border, focus ring, indicators) over the
  existing `tkgc`/`tkbox`/`tkbevel` primitives.

**Phase 2 — basic ttk widgets: mostly done.** `libtk/ttkwidg.c`, `ttkprog.c`.
- Done: `ttk::frame` (focus traversal), `ttk::label`, `ttk::button`,
  `ttk::checkbutton`, `ttk::radiobutton`, `ttk::separator`, `ttk::labelframe`,
  `ttk::entry`.
  `-text/-textvariable/-variable/-command/-style/-anchor/-underline/-width`,
  hover/press/invoke bindings, variable binding via `varchanged`.
- `ttk::entry` (in `entry.c`, not a new file): backs the themed widget with the
  classic `TkEntry` editing core via a shared `entrymake(...,ttk)` constructor —
  the full `get/insert/delete/icursor/index/selection/xview/bbox/see` command
  set and all key/mouse bindings are reused verbatim. Only the chrome differs
  (`tkdrawentry` branches on `tke->ttk`: a flat themed `-bordercolor` border +
  `-fieldbackground` fill + focus ring, instead of the sunken relief +
  highlight box). Adds the `state`/`instate`/`style` subcommands (own
  `tstate`/`tstyle` fields, driven through the layout-agnostic engine helpers
  `ttkstateparse`/`ttkstatestr`/`ttkrestorespec`/`ttkresolve`), and `disabled`/
  `readonly` block edits. `state disabled` mirrors into `Tkdisabled`.
- **Not yet: `ttk::menubutton`, `ttk::sizegrip`.**

**Phase 3 — complex widgets: started.**
- Done: `ttk::progressbar` (`ttkprog.c`) — determinate (`-value/-maximum/
  -variable`, `step`) and indeterminate (`start`/`stop` over `tkrepeat`);
  absorbs the `Progressbar` megawidget.
- **Not yet: `ttk::notebook`, `ttk::treeview`, `ttk::combobox`,
  `ttk::panedwindow`, `ttk::scale`, `ttk::scrollbar`, `ttk::spinbox`** and the
  megawidget shims (§4). These are the bulk of the remaining work.

**Phase 4 — classic completeness: not started** (`spinbox`, entry `-validate`,
text undo + embedded images, listbox `extended`/`activestyle`).

**Phase 5 — app migration: demonstrated, not swept.** `wm/ttkdemo` is a new
gallery app proving the set (now including a `ttk::entry`) renders end-to-end
under `wm/wm`. The ~20-app migration in §11 is the remaining effort and is gated
on `ttk::treeview`/`ttk::notebook`/`ttk::combobox`, since those apps lean on
trees, tabs and comboboxes. Migration order and the golden baselines are in §11;
a pixel change in a *classic* widget remains a regression by definition.

Combined ttk test: `tests/dis/tkttk.b` (44/44) — classes, invoke, state machine,
`instate` scripts, check/radio variable binding, `ttk::style`
configure/map/lookup, dotted-style inheritance, progressbar, labelframe, and
`ttk::entry` (class, insert/get/delete via the shared core, `-style`,
`readonly`/`disabled` state gating).

**Next session, in order:** `ttk::scrollbar`/`ttk::scale` → `ttk::notebook` →
`ttk::combobox` → `ttk::treeview` → megawidget shims → migrate apps from §11
top-down, diffing classic regions each time.
