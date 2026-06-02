# Graphics in Inferno OS: Draw, Tk, and Prefab

> **LP64-port note (2026-06):** the current build is `CONF=emu-g` (graphics-less)
> because the upstream `libfreetype` sources were never vendored into this tree, so
> `freetype`/`tk`/`draw` cannot link. A **graphical session is a planned roadmap
> item** (after the `$Loader` LP64 fix). To revive the GUI: vendor the FreeType
> `src/` + `ft2build.h`, build `CONF=emu` (restores `libfreetype`/`libtk`/`libdraw`
> and the X11 backend `win-x11a.c`), and re-verify the draw/Tk path under LP64 (the
> `Image`/`Display`/`Memimage` structs and `devdraw` command marshalling are the
> places to audit for pointer-width assumptions). See AGENTS_INPRO.md
> ("GUI stack" and the roadmap) for the disabled-components detail.

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

## Key Files

| File | Purpose |
|------|---------|
| `module/draw.m` | Limbo Draw ADTs: Display, Image, Screen, Font, Point, Rect |
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
| `appl/demo/chat/chat.b` | Tk text interface example |
| `appl/wm/colors.b` | Tk + image manipulation example |
| `man/2/draw-display` | Display operations reference |
| `man/2/draw-image` | Image operations reference |
| `man/2/draw-example` | Complete working example |
| `man/2/tk` | Tk module reference |
| `man/2/prefab-intro` | Prefab overview |
| `man/2/tkclient` | tkclient reference |
| `man/2/wmclient` | wmclient reference |
