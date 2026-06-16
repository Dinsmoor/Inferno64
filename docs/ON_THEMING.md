# Theming: cursors, colours, fonts, and window chrome

How the desktop's look is controlled at runtime: the Tk palette and default
font, the window titlebar, and the mouse cursor. One command, **`wm/theme`**,
is the front end for all of it; the wm relays changes live and persists the
login default. This is the durable reference — for the Draw/Tk drawing model
itself see [`ON_GRAPHICS.md`](ON_GRAPHICS.md), and for decoding the image assets
a theme uses see [`ON_IMAGEIO.md`](ON_IMAGEIO.md).

## System theming (colours and font)

Inferno Tk has no option/resource database, so a single choke point themes the
whole desktop: every toplevel gets its palette and default font from
`tkdefaultenv()` (`libtk/utils.c`), which calls `tksetenvcolours()`
(`libtk/colrs.c`) to fill `env->colors[]` from the global `TkTheme tktheme`.
Widgets COW-share their toplevel's env (`tkdupenv`), and window chrome and the
toolbar are themselves ordinary Tk widgets, so changing `tktheme` and rebuilding
a toplevel's env recolours every default-styled widget at once. A widget keeps
any colour or font it sets explicitly (the COW preserves it).

The runtime control is the **`theme`** Tk command (`libtk/thm.c`), reachable from
any program with `tk->cmd(top, "theme …")`:

```
theme set <key> <val> …   keys: fg bg activebg activefg select selectbg
                          selectfg disablefg titlebg titlefg titlefocusbg
                          font borderwidth relief
                          (colours are #RGB, #RRGGBB, #RRGGBBAA or X11 names)
theme reset               restore the built-in light-grey palette + default font
theme get                 report the current theme as "key val …"
theme reapply             rebuild this toplevel's env and repaint its widget tree
```

`theme set` mutates the process-wide `tktheme`; `theme reapply` is what makes a
change visible on an existing window (it re-runs `tksetenvcolours` on the top's
env, reopens the font if it changed, and marks the tree dirty).

> Colour macros (`(R<<24)|…`) overflow `int` and sign-extend into the 64-bit
> `ulong` of `tktheme`; this is harmless because every draw path masks per byte,
> but text that reports a colour (`theme get`) must mask `& 0xffffffff` or it
> prints 16 hex digits.

### The window titlebar

The window titlebar (`appl/lib/titlebar.b`) sets its colours explicitly (it is
not a default-styled widget), so it has three dedicated theme keys: `titlebg`
(unfocused bar), `titlefocusbg` (focused bar), and `titlefg` (text).
`titlebar.b` reads them from `theme get` when it builds the bar and re-reads on
live re-theme via `titlebar->retheme()`, which `tkclient` calls in its `theme`
ctl verb. Defaults match the historical look (grey bar, blue on focus, white
text), so an untouched theme is unchanged.

This is also the seam for **image-based chrome** (the planned castle/cobblestone
showcase): Tk labels take `-image`, so a width-sized generated titlebar texture
can replace the flat `-bg` later. Tk frames cannot tile a background and
decorative borders need wm-side compositing, so the texture/decoration layer is
a separate step beyond these colour keys.

### Driving it from the desktop

`wm/wm` is the theme authority (it stays Tk-free and only relays). It serves
`/chan/wmtheme`, holds the current resolved `set …` line, **pushes it to each
client as the client joins** (so windows are born themed), and **broadcasts it
on change** for a live re-theme. Clients apply it through `tkclient`'s `theme`
ctl verb, which runs the `set`, calls `titlebar->retheme()`, then `theme reapply`
on the client toplevel.

The login default is persisted to `$home/lib/theme` and read by the wm at
startup. Home is resolved from `/dev/user` (`/usr/<user>/lib/theme`), not
`/env/home`, because no login script has set `/env/home` yet when `wm/wm` runs.

`wm/theme` is the front end:

```
theme --apply <name>        apply + persist a preset from /lib/themes/<name>
theme --theme key=val …     live ad-hoc overrides (not persisted)
theme --font <path>         live default-font override (not persisted)
theme --list                list presets in /lib/themes
```

Presets live in `/lib/themes/` as `key value` text files (`#` starts a comment
line): `default` (the built-in grey), `dark`, `temple`. `--apply` resolves the
file to a `set …` line, writes it to `/chan/wmtheme`, and saves it for next
login.

Two boundaries remain. Apps built on **`wmclient`** directly (e.g. `wm/clock`),
rather than `tkclient`, don't process the `theme` ctl push, so they aren't
re-themed. And an app that styles its own text widgets (explicit
`-foreground`/`-font`) picks up a theme **at launch** (new windows are born
themed) but does not live-update on `--apply`, because its COW'd envs hold the
colours it chose.

### Planned: theming the app suite

The system theme covers every *default-styled* widget, but much of the existing
app suite predates it and hardcodes its own look, so those apps sit outside the
theme. Two distinct problems, each with a different fix:

1. **`wmclient`-only apps** (`wm/clock`, `acme/gui`, `wm/drawmux/dmwm`) never
   receive the `theme` ctl push — only `tkclient` decodes that verb. Fix: give
   `wmclient` the same `theme` ctl handling (run the `set` + `reapply` on its
   toplevel), or convert the app to `tkclient`.

2. **`tkclient` apps that set explicit options** override the palette on the
   widgets they touch, so those widgets are *not* born-themed and never
   live-update. Two sub-patterns: the pervasive `-bg white` on `text`/`entry`
   widgets (`wm/bible`, `wm/pleromussy`, many others), and per-tag styling tables
   built with explicit `-foreground #…` / `-background #…` / `-font` (e.g.
   `wm/pleromussy`'s NAME/META/BTN/RXN/RXME tags, `wm/bible`'s HEAD/VNUM/HL_*
   tags).

The enabling pieces to build first, before touching individual apps:

- **A Limbo palette-query helper** so apps stop hardcoding hex. Something like
  `tkclient->themecolour(top, key): string` (wrapping `tk->cmd(top,"theme get")`
  and the whole-word parse `titlebar.b` already does in `themeval`), so an app
  builds its tag table from the live palette instead of literals.
- **A theme-changed hook.** `tkclient`'s `theme` ctl verb already re-runs
  `reapply`; extend it to also notify the app (a callback or a readable event)
  so an app that owns a tag table can rebuild it from the new palette on a live
  `--apply`. Without this, app-styled text can only ever be born-themed.

Then the per-app work is mechanical: drop `-bg white` where the palette default
is wanted, and rebuild explicit tag tables from `themecolour()` in the hook.
Tracked in `DEV_INPRO.md` §Active.

## The mouse cursor (mono, colour, and animated)

The pointer image is set by writing the **cursor file** (`/dev/cursor`, the
pointer device's `cursor` qid). Two wire formats share that file; the device
tells them apart by a leading magic word.

- **Legacy mono** — `hotx hoty dx dy` (big-endian, draw-protocol `BGLONG`
  order) then a 1-bit clr/set bitmap pair. This is what `wmclient->cursorspec`
  emits from a depth-1 image, and what the kernel falls back to. A zero-length
  write reverts to the default arrow.
- **Rich (colour, optionally animated)** — a magic-tagged blob (`"Acur"`)
  carrying one or more **ARGB8888 frames** plus per-frame delays. Defined in
  `include/cursor.h`; parsed by the cursor device into a `Richcursor` and
  handed to `richcursor()`. The header is **plain big-endian** (not `BGLONG`).

Build and install a rich cursor from Limbo with the **`Acursor`** library
(`module/acursor.m`, `appl/lib/acursor.b`):

```
acur := load Acursor Acursor->PATH;
acur->init();
fd := sys->open("/dev/cursor", Sys->OWRITE);
# frames: depth-32 Draw images (any channel; normalised to ABGR32), all same
# size; hotspot measured from the top-left; per-frame delays in ms.
err := acur->set(fd, hot, frames, delays);     # or setraw(...) for raw A,R,G,B bytes
# acur->clear(fd) reverts to the default cursor.
```

The cursor is owned by the backend once written, so it keeps animating after
the writer exits. `setraw`/`mkblobraw` need **no display** — useful for
procedurally generated or file-decoded cursors from any shell. Limits:
`Crmaxdim` 64×64, `Crmaxframe` 64.

### Loading Windows cursor files (`.cur` / `.ani`)

There is a huge body of free Windows cursor art out there, so the system reads
those formats directly. The **`Curfile`** library (`module/curfile.m`,
`appl/lib/curfile.b`) decodes a `.cur` (static) or `.ani` (animated, RIFF/ACON)
into a `Curfile->Cursor` — `w`, `h`, hotspot, raw A,R,G,B `frames`, and per-frame
`delays` (the `.ani` 1/60 s rate converted to ms, honouring `rate`/`seq ` chunks).
It is pure byte-munging (DIB 1/4/8/24/32 bpp with the AND mask; PNG-embedded
entries go to `$Imageio`) and needs **no display**, so it works on the native
kernel over a serial shell too. Decoding is pixel-exact against ImageMagick on
the 32 bpp art.

### The cursor commands

```
theme --cursor                 # one-shot: the showcase animated gauntlet
theme --cursor off             # revert to the system arrow
theme --cursor file.ani        # any .cur/.ani (decoded by Curfile, no display)
theme --cursor a.png b.png …   # image files as frames (needs a display)
theme --cursor -d 120 …        # per-frame hold for formats that carry no delay
theme --cursor-default [file]  # set the desktop/login default (TempleOS arrow)
```

`--cursor` is a one-shot write.  `--cursor-default` sets the cursor the desktop
falls back to; it writes the path to the wm's `/chan/wmcursor` control file (or
the device directly when no wm is running), with no file meaning the
conservative TempleOS arrow.

Art lives in `icons/cursors/`, one directory per set (each with a `LICENSE.txt`):
`uo/` is the public-domain Ultima Online set (`gauntlet-anim.ani` showcase,
`gauntlet.cur`, `grab.cur`, `quill.cur`, `busy.ani`); `templeos/` is the
public-domain TempleOS arrows (`arrow_dark-outline.cur` is the login default).

### Per-window cursors in wm (enter/leave)

`wm/wm` owns `/dev/cursor` and switches it as the pointer crosses window borders:
the desktop and plain windows show the default (`Defcursor`, settable live via
`/chan/wmcursor`), applied at login; a client shows its own cursor while the
pointer is over it.  A client registers one with the `cursorfile <path>` wmctl
verb (`cursorfile` with no path clears it).  The wm decodes via `Curfile`,
caches by path, and restores the default on the way out — the basis for
context-sensitive cursors (grab on draggables, quill in text fields).

Backends:

- **Hosted emu / X11** (`emu/port/win-x11a.c`): colour cursors use the RENDER
  extension (`XRenderCreateCursor`); a dedicated `xcursoranim` kproc holds each
  frame for its delay and re-posts the cursor change. Needs the runtime
  `libXrender` (already pulled in by libX11; a minimal in-file declaration
  avoids the `libxrender-dev` build dependency).
- **Native kernel** (`os/drivers/screen.c`): the software cursor
  alpha-composites the premultiplied ARGB frame onto the scanout in `blit()`;
  a `cursoranim` kproc (`tsleep`) advances frames. Only active when the board
  uses a **relative** pointer (`hostcursor == 0`); an absolute pointer (the
  qemu tablet) lets qemu draw its own host cursor and the software cursor —
  mono or rich — is suppressed.
