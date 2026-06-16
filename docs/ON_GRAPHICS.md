# Graphics: Draw, Tk, and Prefab

> **The one LP64 rule for graphics code.** A draw "word" is **32 bits**
> (`u32int`), matching the packed layout used by the draw protocol, image
> files, fonts and `win-x11a.c`. libmemdraw/libdraw model an image scan line
> as an array of words; computing a stride as `sizeof(ulong)` silently doubles
> it on LP64 and the compositor walks off the screen image (segfault in
> `boolcalc*`). **If you touch pixel/scan-line code, never use `sizeof(ulong)`
> for a draw word** — the stride is `sizeof(u32int)` and pixel pointers are
> `u32int*` (`libdraw/bytesperline.c`,
> `libmemdraw/{alloc,draw,defont,load,unload,line}.c`). FreeType 2.13.2 is
> vendored under `libfreetype/libfreetype/`; `libfreetype/mkfile` builds the
> upstream `src/` against the small Inferno glue (`libfreetype/freetype.c`).
> The wider LP64 story, including the exception-unwind `NOPC` sentinel that
> can break `wmsetup`/`plumber`, is ON_C_IN_DIS.md.

## Architecture Overview

```
Limbo app
    ↓  Draw module ADTs (Image, Display, Screen, Font, Point, Rect)
    ↓  Tk module (widget commands as strings)
    ↓  Prefab module (pre-composed UI elements)
devdraw (emu/port/devdraw.c)  — kernel device driver, manages images server-side
    ↓
libmemdraw                     — portable in-memory drawing (all actual pixel work)
    ↓
X11 backend (emu/port/win-x11a.c) — copies completed Memimage to X display
```

All graphics go through `devdraw`. The X11 layer just blits finished pixels — it does not drive rendering. This makes the rendering path the same on all platforms.

## The Draw Module (Limbo)

`module/draw.m` defines the entire Limbo graphics API.

### Point and Rect

```limbo
Point: adt {
    x, y: int;
    add:  fn(p: self Point, q: Point): Point;
    sub:  fn(p: self Point, q: Point): Point;
    mul:  fn(p: self Point, i: int):   Point;
    div:  fn(p: self Point, i: int):   Point;
    eq:   fn(p: self Point, q: Point): int;
    in:   fn(p: self Point, r: Rect):  int;
};

Rect: adt {
    min, max: Point;
    canon:   fn(r: self Rect): Rect;           # normalize so min<=max
    dx, dy:  fn(r: self Rect): int;
    size:    fn(r: self Rect): Point;
    Xrect:   fn(r: self Rect, s: Rect): int;   # non-empty intersection?
    inrect:  fn(r: self Rect, s: Rect): int;
    clip:    fn(r: self Rect, s: Rect): (Rect, int); # clipped rect + flag
    combine: fn(r: self Rect, s: Rect): Rect;  # bounding union
};
```

### Display

`Display` represents a connection to `devdraw` — the frame buffer.

```limbo
Display: adt {
    image:       ref Image;   # the screen itself
    white, black: ref Image;  # 1×1 replicated, for composition
    opaque, transparent: ref Image;

    allocate:    fn(dev: string): ref Display;  # dev=nil → "/dev/draw"
    newimage:    fn(d: self ref Display, r: Rect, chans: Chans, repl, color: int): ref Image;
    color:       fn(d: self ref Display, color: int): ref Image; # 1×1 repl image
    rgb:         fn(d: self ref Display, r, g, b: int): ref Image;
    colormix:    fn(d: self ref Display, c1, c2: int): ref Image;
    namedimage:  fn(d: self ref Display, name: string): ref Image;
    open:        fn(d: self ref Display, name: string): ref Image; # load from file
    readimage:   fn(d: self ref Display, fd: ref Sys->FD): ref Image;
    writeimage:  fn(d: self ref Display, fd: ref Sys->FD, i: ref Image): int;
    publicscreen: fn(d: self ref Display, id: int): ref Screen;
    startrefresh: fn(d: self ref Display);  # spawn refresh event handler
};
```

Predefined color constants: `Draw->Black`, `Draw->White`, `Draw->Red`, `Draw->Green`, `Draw->Blue`, `Draw->Yellow`, `Draw->Cyan`, `Draw->Magenta`, `Draw->Palebluegreen`, `Draw->Darkblue`, etc.

Channel descriptors: `Draw->GREY1`, `Draw->GREY8`, `Draw->CMAP8`, `Draw->RGB15`, `Draw->RGB24`, `Draw->RGBA32`, `Draw->ARGB32`.

### Image

`Image` is the central drawing object. It may be a window, an off-screen buffer, a 1×1 replicated color, or any rectangle of pixels.

```limbo
Image: adt {
    r:       Rect;       # image rectangle in display coordinate space
    clipr:   Rect;       # clipping rectangle (drawing is clipped to this)
    depth:   int;        # bits per pixel
    chans:   Chans;      # pixel channel layout
    repl:    int;        # 1 = image tiles infinitely (r is one tile)
    display: ref Display;
    screen:  ref Screen; # non-nil iff this image is a window

    # Core drawing
    draw:    fn(dst: self ref Image, r: Rect, src, matte: ref Image, p: Point);
    gendraw: fn(dst: self ref Image, r: Rect, src: ref Image, p0: Point,
                matte: ref Image, p1: Point);
    drawop:  fn(dst: self ref Image, r: Rect, src, matte: ref Image, p: Point, op: int);

    # Geometry
    line:      fn(dst: self ref Image, p0, p1: Point, end0, end1, radius: int,
                  src: ref Image, sp: Point);
    poly:      fn(dst: self ref Image, p: array of Point, end0, end1, radius: int,
                  src: ref Image, sp: Point);
    fillpoly:  fn(dst: self ref Image, p: array of Point, wind: int, src: ref Image, sp: Point);
    ellipse:   fn(dst: self ref Image, c: Point, a, b, thick: int, src: ref Image, sp: Point);
    fillellipse: fn(dst: self ref Image, c: Point, a, b: int, src: ref Image, sp: Point);
    arc:       fn(dst: self ref Image, c: Point, a, b, thick, alpha, phi: int,
                  src: ref Image, sp: Point);
    bezier:    fn(dst: self ref Image, p0, p1, p2, p3: Point, end0, end1, radius: int,
                  src: ref Image, sp: Point);

    # Text
    text:      fn(dst: self ref Image, p: Point, src: ref Image, sp: Point,
                  font: ref Font, str: string): Point;  # returns next pen position

    # Pixel access
    readpixels:  fn(src: self ref Image, r: Rect, data: array of byte): int;
    writepixels: fn(dst: self ref Image, r: Rect, data: array of byte): int;

    # Window management (only meaningful when screen != nil)
    top:    fn(dst: self ref Image);
    bottom: fn(dst: self ref Image);
    origin: fn(dst: self ref Image, log, scr: Point): int;  # scroll window
    flush:  fn(dst: self ref Image, func: int);

    # Sharing
    name:   fn(src: self ref Image, name: string, in: int): int;  # publish/withdraw
};
```

The `draw` operation is: `dst[r] = src[r-p+src.r.min] * matte[r-p+matte.r.min]`. The compositing operator is Porter-Duff SrcOver by default. `drawop` takes an explicit operator.

### Screen and Windows

A `Screen` is a layered collection of windows all drawn on the same underlying `Image` (typically the display framebuffer).

```limbo
Screen: adt {
    id:      int;
    image:   ref Image;   # backing image (usually display.image)
    fill:    ref Image;   # color to expose when a window moves away
    display: ref Display;

    allocate:  fn(image, fill: ref Image, public: int): ref Screen;
    newwindow: fn(s: self ref Screen, r: Rect, backing, color: int): ref Image;
    top:       fn(s: self ref Screen, wins: array of ref Image);
    bottom:    fn(s: self ref Screen, wins: array of ref Image);
};
```

`newwindow` returns an `Image` with `screen != nil`. Its `r` field is in screen coordinates. `top`/`bottom` control Z-order. `origin` scrolls the window's viewport.

### Font

```limbo
Font: adt {
    name:    string;
    height:  int;   # total line height (ascent + descent)
    ascent:  int;   # baseline to top
    display: ref Display;

    open:   fn(d: ref Display, name: string): ref Font;
    build:  fn(d: ref Display, name, desc: string): ref Font;
    width:  fn(f: self ref Font, str: string): int;   # pixel width of string
    bbox:   fn(f: self ref Font, str: string): Rect;
};
```

Font files live in `/fonts/`. The default font is `/fonts/pelm/unicode.9.font`.

### Context and Wmcontext

When a Limbo application is launched by the window manager, it receives a `ref Draw->Context` as its first argument to `init`:

```limbo
Context: adt {
    display: ref Display;
    screen:  ref Screen;   # the WM's mux screen; create windows on this
    wm:      chan of (string, chan of (string, ref Wmcontext));
};
```

`Wmcontext` has the per-window channels:

```limbo
Wmcontext: adt {
    kbd:    chan of int;            # keycode events (Unicode codepoints)
    ptr:    chan of ref Pointer;    # mouse events
    ctl:    chan of string;         # WM→app: "exit", "rect x y x y", etc.
    wctl:   chan of string;         # app→WM
    images: chan of ref Image;      # new window image after resize
    connfd: ref Sys->FD;
    ctxt:   ref Context;
};
```

## Writing a GUI App

### Pattern 1: Tk with tkclient (recommended)

`tkclient` handles WM negotiation, window creation, and keyboard/pointer routing. It is the highest-level, least boilerplate option.

```limbo
implement MyApp;

include "sys.m";    sys: Sys;
include "draw.m";   draw: Draw;
include "tk.m";     tk: Tk;
include "tkclient.m"; tkclient: Tkclient;

MyApp: module { init: fn(ctxt: ref Draw->Context, nil: list of string); };

init(ctxt: ref Draw->Context, nil: list of string)
{
    sys = load Sys Sys->PATH;
    tk = load Tk Tk->PATH;
    tkclient = load Tkclient Tkclient->PATH;
    tkclient->init();

    (win, winctl) := tkclient->toplevel(ctxt, nil, "My App", Tkclient->Appl);

    # Build widget tree
    evts := chan of string;
    tk->namechan(win, evts, "evts");

    tk->cmd(win, "frame .f -bg white");
    tk->cmd(win, "label .f.lbl -text {Hello, Inferno}");
    tk->cmd(win, "button .f.btn -text Quit -command {send evts quit}");
    tk->cmd(win, "pack .f.lbl .f.btn -side top -pady 4");
    tk->cmd(win, "pack .f -fill both -expand 1");

    tkclient->onscreen(win, nil);
    tkclient->startinput(win, "kbd" :: "ptr" :: nil);

    for(;;) alt {
    s := <-win.ctxt.kbd =>
        tk->keyboard(win, s);
    p := <-win.ctxt.ptr =>
        tk->pointer(win, *p);
    c := <-win.ctxt.ctl or c = <-winctl =>
        if(c == "exit") return;
        tkclient->wmctl(win, c);
    e := <-evts =>
        if(e == "quit") return;
    }
}
```

### Pattern 2: Direct Draw (no WM, full screen or embedded)

```limbo
init(nil: ref Draw->Context, nil: list of string)
{
    sys = load Sys Sys->PATH;
    draw = load Draw Draw->PATH;

    display := draw->Display.allocate(nil);
    screen := display.image;

    red   := display.color(Draw->Red);
    white := display.color(Draw->White);
    font  := draw->Font.open(display, "*default*");

    # Fill background
    screen.draw(screen.r, white, nil, screen.r.min);

    # Draw a colored rectangle
    screen.draw(((50,50),(200,150)), red, nil, (50,50));

    # Draw text
    screen.text((60, 60), display.black, (0,0), font, "Hello");

    # Keep alive
    sys->sleep(5000);
}
```

### Pattern 3: wmclient (window with WM, but without Tk)

```limbo
include "wmclient.m"; wmclient: Wmclient;

init(ctxt: ref Draw->Context, nil: list of string)
{
    wmclient = load Wmclient Wmclient->PATH;
    wmclient->init();

    w := wmclient->window(ctxt, "My Window", Wmclient->Appl);
    w.reshape(Draw->Rect((0,0),(400,300)));
    w.onscreen(nil);

    img := w.image;    # draw into this
    img.draw(img.r, w.display.white, nil, img.r.min);

    for(;;) alt {
    p := <-w.ctxt.ptr =>
        w.pointer(*p);    # forward to wmclient for resize handles etc.
    c := <-w.ctxt.ctl =>
        if(c == "exit") return;
        w.wmctl(c);       # let wmclient handle reshape/move
    ni := <-w.ctxt.images =>
        # WM gave us a new image (after resize)
        img = ni;
        img.draw(img.r, w.display.white, nil, img.r.min);
    }
}
```

## Tk Command Reference Summary

Tk commands are sent as strings via `tk->cmd(win, "...")`. Return value is the result string.

Widget creation:
```
frame .w [-bg color] [-width n] [-height n] [-relief raised|sunken|flat|groove|ridge] [-bd n]
label .w -text {string} [-font f] [-fg color] [-bg color]
button .w -text {string} -command {send channame value}
entry .w [-textvariable varname] [-width n]
text .w [-state normal|disabled] [-wrap word|char|none] [-width n] [-height n]
listbox .w [-selectmode single|multiple] [-yscrollcommand {.sb set}]
scrollbar .w -orient vertical|horizontal -command {.w yview}
canvas .w [-width n] [-height n] [-bg color]
checkbutton .w -text {str} -variable var -onvalue 1 -offvalue 0
radiobutton .w -text {str} -variable var -value val
scale .w -from n -to n -orient horizontal|vertical
menu .w [-tearoff 0]
menubutton .w -text {str} -menu .w.m
```

Layout:
```
pack .w [-side top|bottom|left|right] [-fill x|y|both|none] [-expand 1] [-padx n] [-pady n]
place .w -x n -y n [-width n] [-height n]
```

Queries:
```
.w cget -option         # get widget option
.w configure -opt val   # set option
tk->rect(win, ".w", 0)  # get widget rectangle via API (not cmd)
```

Canvas operations:
```
.c create rectangle x0 y0 x1 y1 -fill color -outline color -tags {tag}
.c create oval x0 y0 x1 y1 -fill color
.c create text x y -text {str} -font f -fill color -anchor nw
.c create line x0 y0 x1 y1 -fill color -width n
.c delete tag
.c coords tag x0 y0 x1 y1   # move/resize item
.c bind tag <ButtonPress-1> {send chan click}
```

## Prefab: Pre-built Composite Elements

Prefab (`module/prefab.m`) provides styled, composable UI blocks without requiring Tk. It is lower level than Tk but higher level than raw Draw.

```limbo
include "prefab.m"; prefab: Prefab;
Environ, Style, Element, Compound, Layout: import prefab;

# Set up style
sty := ref Style(titlefont, textfont, elemcolor, edgecolor, titlecolor, textcolor, highlightcolor);
env := ref Environ(screen, sty);

# Create elements
icon := Element.icon(env, iconRect, iconImg, mask);
txt  := Element.text(env, "Hello", textRect, Prefab->EText);

# Compose into a container
vbox := Element.elist(env, nil, Prefab->EVertical);
vbox.append(icon);
vbox.append(txt);

# Put in a window
c := Compound.box(env, origin, "Title", vbox);
c.draw();

# Menu selection
(which, nclicks, selected) := c.select(vbox, 0, clickchan);
```

## WM Protocol Details

When a window manager (e.g., `wm/wm`) is running, it owns `ctxt.screen`. Apps communicate through `ctxt.wm`:

1. App sends `(request_string, reply_chan)` to `ctxt.wm`
2. WM parses request, allocates window, sends `(ack, wmcontext)` on reply_chan
3. App receives `Wmcontext` with `kbd`, `ptr`, `ctl`, `images` channels

The `tkclient` and `wmclient` modules hide this entirely. Only write to `ctxt.wm` directly if building custom WM clients.

Named images let processes share pixel data:

```limbo
# Publisher
img.name("cursor/arrow", Draw->Publish);

# Consumer
shared := display.namedimage("cursor/arrow");
```

## Image Allocation Notes

**Off-screen images** (for double-buffering, textures, icons):

```limbo
buf := display.newimage(Rect((0,0),(width,height)), Draw->RGB24, 0, Draw->White);
# Draw into buf, then blit to screen:
screen.draw(dest_rect, buf, nil, buf.r.min);
```

**Replicated/tiled images** (`repl=1`): treat `r` as one tile, clip to a large rectangle for seamless tiling. Used for patterns and solid colors (`display.color(...)` returns a 1×1 replicated image).

**Freeing images**: Images are garbage collected when all Limbo references drop. No explicit free is needed. `devdraw` uses reference counting on the server side.

**Screen ownership**: A `Screen` is bound to a specific `Display`. All windows on that `Screen` must be created from the same `Display`. Mixing displays is not supported.

## Hosting a software-rendered (animated) frame in a WM window

If you compute pixels yourself (a software renderer, a video frame, the
`$Raster3` 3D rasterizer — see [ON_3D.md](ON_3D.md)) and want them in a
*normal managed window* (titlebar, resize, hide) rather than full-screen, use a
`tkclient` toplevel with a **`panel`** widget as the drawing surface:

```limbo
# in win_config, build a panel that grows with the window:
"panel .pbd.p -width 512 -height 384",
"pack .pbd.p -fill both -expand 1",     # WITHOUT -expand the panel caps at its
"pack .pbd -side top -fill both -expand 1",   # requested size: it shrinks but
                                              # will not grow past 512x384.

# (re)allocate when the panel size changes (initial load AND every reshape):
setimage(win: ref Toplevel): int {
    w := int tk->cmd(win, ".pbd.p cget -actwidth");   # ACTUAL size, not -width
    h := int tk->cmd(win, ".pbd.p cget -actheight");
    disp  = win.image.display.newimage(((0,0),(w,h)), win.image.chans, 0, Draw->Black);
    fbimg = win.image.display.newimage(((0,0),(w,h)), Draw->XRGB32, 0, Draw->Black);
    tk->putimage(win, ".pbd.p", disp, nil);           # bind image to the panel
    # ... reallocate your pixel/depth buffers to w*h, recompute aspect/projection
}

# per frame: render into your XRGB32 byte buffer, then:
fbimg.writepixels(fbimg.r, pix);          # raw bytes -> XRGB32 scratch image
disp.draw(disp.r, fbimg, nil, fbimg.r.min);  # converts to the panel's channels
tk->cmd(win, sys->sprint(".pbd.p dirty 0 0 %d %d", w, h));
tk->cmd(win, "update");                    # flush the dirty region to screen
```

Two gotchas that produce exactly-broken-looking windows:

- **`-fill both -expand 1` on the panel**, or the render area shrinks correctly
  but refuses to grow past its requested size.
- **Forward *all* WM control messages to `tkclient->wmctl`**, not just the ones
  you recognise. A loop that special-cases `"exit"` and reshape (`!…`) but drops
  the rest leaves *only close working* — resize/minimize/move silently die:

  ```limbo
  c := <-wmcmd =>
      case c {
      "exit" => return;                    # (kill your render proc first)
      *      => tkclient->wmctl(win, c);   # everything else, incl. reshape
                if(c != nil && c[0] == '!') setimage(win);  # rebuild on reshape
      }
  ```

Animate with a separate ticker proc sending on a channel that the main `alt`
selects on alongside `win.ctxt.kbd/ptr/ctl` and `wmcmd`; do the render in the
main proc on each tick so all image ops stay single-threaded.

The pattern above (XRGB32 scratch → `writepixels` → `disp.draw`) suits any
producer of raw pixel bytes. If a C primitive can write the panel image's
`Memimage` directly (the `$Raster3` 3D rasterizer does — see ON_3D.md), skip
the scratch image and rasterize straight into the panel image, then `.p dirty` +
`update`. `appl/wm/rayteapot.b` is that worked example; `appl/wm/polyhedra.b` is
the older in-tree precedent for the panel/ticker loop.

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

### The `theme` command

**`wm/theme`** installs the cursor (and is the seam for future desktop theming):

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
                          selectfg disablefg font borderwidth relief
                          (colours are #RGB, #RRGGBB, #RRGGBBAA or X11 names)
theme reset               restore the built-in light-grey palette + default font
theme get                 report the current theme as "key val …"
theme reapply             rebuild this toplevel's env and repaint its widget tree
```

`theme set` mutates the process-wide `tktheme`; `theme reapply` is what makes a
change visible on an existing window (it re-runs `tksetenvcolours` on the top's
env, reopens the font if it changed, and marks the tree dirty).

### Driving it from the desktop

`wm/wm` is the theme authority (it stays Tk-free and only relays). It serves
`/chan/wmtheme`, holds the current resolved `set …` line, **pushes it to each
client as the client joins** (so windows are born themed), and **broadcasts it
on change** for a live re-theme. Clients apply it through `tkclient`'s `theme`
ctl verb, which runs the `set` then `theme reapply` on the client toplevel.

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

The window **titlebar** (`appl/lib/titlebar.b`) is themed by three dedicated
keys — `titlebg` (unfocused bar), `titlefocusbg` (focused bar), `titlefg`
(text) — because its colours are explicit, not inherited from the palette.
`titlebar.b` reads them from `theme get` when it builds the bar and re-reads on
live re-theme via `titlebar->retheme()`, which `tkclient` calls in its `theme`
ctl verb. This is the seam for image-based chrome (a width-sized texture behind
the bar): Tk labels take `-image`, so a generated titlebar texture can replace
the flat `-bg` later.

Two boundaries remain. Apps built on **`wmclient`** directly (e.g. `wm/clock`),
rather than `tkclient`, don't process the `theme` ctl push, so they aren't
re-themed. And an app that styles its own text widgets (explicit
`-foreground`/`-font`) picks up a theme **at launch** (new windows are born
themed) but does not live-update on `--apply`, because its COW'd envs hold the
colours it chose.

## Key Files

| File | Purpose |
|------|---------|
| `module/draw.m` | Limbo Draw ADTs: Display, Image, Screen, Font, Point, Rect |
| `module/acursor.m` | Colour/animated cursor builder (`appl/lib/acursor.b`) |
| `module/curfile.m` | Windows `.cur`/`.ani` decoder (`appl/lib/curfile.b`) |
| `appl/wm/theme.b` | `wm/theme --cursor` — install/revert the cursor |
| `icons/cursors/` | Vendored public-domain UO cursor set (gauntlet/grab/quill) |
| `include/cursor.h` | Cursor wire formats: `Drawcursor` (mono) + `Richcursor` |
| `module/tk.m` | Tk module interface |
| `module/tkclient.m` | High-level Tk window creation |
| `module/wmclient.m` | Lower-level WM window creation |
| `module/prefab.m` | Prefab composite UI elements |
| `module/wmlib.m` | WM connection helpers |
| `include/draw.h` | C Draw API: Image, Display, Screen, Font structures |
| `emu/port/devdraw.c` | Draw device driver (image management, command dispatch) |
| `emu/port/devtk.c` | Tk kernel device |
| `emu/port/win-x11a.c` | X11 display backend |
| `libdraw/alloc.c` | Image/screen allocation |
| `libdraw/init.c` | Display initialization (opens /dev/draw/new) |
| `libdraw/draw.c` | draw/gendraw primitives |
| `include/memdraw.h` | In-memory drawing structures |
| `appl/wm/clock.b` | Simple wmclient + direct draw example |
| `appl/wm/rayteapot.b` | tkclient panel + software 3D (see ON_3D.md) |
| `libinterp/raster3.c` | `$Raster3` software rasterizer / z-buffer / vertex kernel |
| `appl/demo/chat/chat.b` | Tk text interface example |
| `appl/wm/colors.b` | Tk + image manipulation example |
| `man/2/draw-display` | Display operations reference |
| `man/2/draw-image` | Image operations reference |
| `man/2/draw-example` | Complete working example |
| `man/2/tk` | Tk module reference |
| `man/2/prefab-intro` | Prefab overview |
| `man/2/tkclient` | tkclient reference |
| `man/2/wmclient` | wmclient reference |
