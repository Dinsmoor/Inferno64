# Charon — Inferno's web browser

Charon is Inferno's graphical web browser, written entirely in Limbo. It runs
on the Dis VM, so it is fully portable across every Inferno platform (hosted
and native). Its original baseline was mid-1990s web standards (HTML 3.2 /
Netscape Navigator 3, HTTP 1.0/1.1, FTP, ECMAScript-262 2nd Edition ≈
JavaScript 1.1); on top of that it now speaks modern HTTPS (TLS 1.2/1.3 via
mbedTLS), gzip/deflate and chunked transfer, UTF-8 by default, real CSS (a
CSS2.1 cascade plus the CSS3 pieces real sites rely on), RFC 6265 cookies,
localStorage, HTML5 semantic tags, a retained DOM, and a `<canvas>` 2D **and**
3D context. The "Modern-web support" section at the end says exactly what
works and what is still open.

---

## Source Layout

```
appl/charon/        — Limbo source (.b) and module interfaces (.m)
dis/charon/         — compiled .dis bytecode (one per module)
dis/charon.dis      — top-level entry point
fonts/charon/       — 4 styles × 5 sizes = 20 .font files
fonts/minicharon/   — same set for the mini variant
icons/charon/       — toolbar .bit bitmaps
icons/minicharon/   — toolbar bitmaps for mini variant
lib/wmcharon        — shell script: launches Charon under wm
man/1/charon        — man page
appl/lib/ecmascript/— ECMAscript engine (separate from charon/)
```

### Key source files in `appl/charon/`

| File | Module | Purpose |
|------|--------|---------|
| `charon.b` | `Charon` | Top-level: event loop, navigation (`go`/`goproc`/`get`), history, form submit, JS URL dispatch |
| `chutils.b` | `CharonUtils` | Shared utilities: config, transport dispatch, network connections (`Netconn`), image cache, media-type table |
| `layout.b` | `Layout` | HTML layout engine: `Frame`, `Line`, `Loc`, `Control` widgets, scrollbars, drawing |
| `build.b` | `Build` | HTML tree builder: `Item` pick ADT, `Docinfo`, `Form`, `Table`, `Anchor`, parser state |
| `lex.b` | `Lex` | HTML tokeniser: produces `Token`/`TokenSource` from a `ByteSource` |
| `http.b` | `Transport` (HTTP) | HTTP/1.0, HTTP/1.1, HTTPS via `Dial->pushtls` (`#T` devtls/mbedTLS, TLS 1.2/1.3); pipelining; proxy. (Legacy `SSL3->Context` fields remain in the header ADT but are unused.) |
| `ftp.b` | `Transport` (FTP) | FTP plain-text retrieval |
| `file.b` | `Transport` (FILE) | Local file access with MIME sniffing |
| `gzipfilter.b` | `Gzipfilter` | HTTP `Content-Encoding: gzip`/`deflate` decoder; wraps the inflate `Filter` (`/dis/lib/inflate.dis`) |
| `dechunk.b` | `Dechunk` | HTTP/1.1 `Transfer-Encoding: chunked` decoder (synchronous state machine) |
| `img.b` | `Img` | GIF87a/89a (with animation), JPEG, XBitmap, Inferno BIT decoder |
| `gui.b` | `Gui` | Tk/tkclient wrapper: toolbar, URL bar, status line, progress panel, popups |
| `event.b` | `Events` | `Event` pick ADT (Ekey, Emouse, Ego, Esubmit, …); `ScriptEvent` for JS |
| `jscript.b` | `Script` | ECMAscript bridge: loads `ecmascript.dis`, routes `ScriptEvent` |
| `cookiesrv.b` | `Cookiesrv` | Cookie server: persistent storage, per-session `Client` handle |
| `dom.b` | `Dom` | Retained element-node tree (`Node` ADT); near-pure data structure, builds/unit-tests headless. Backs render-from-DOM and the JS DOM API |
| `domjs.b` | `Domjs` | JavaScript DOM binding — `document`/element host objects and the `<canvas>` context, over the `Dom` tree |
| `csseng.b` | `Csseng` | CSS cascade engine: selector matching, specificity, origin cascade over the W3C CSS2.1 parser (`module/css.m`); pure computation, unit-tested headless |
| `url.b` | `Url` | RFC 1808 URL parser/resolver (`Parsedurl`, `mkabs`) |
| `ctype.b` | `Ctype` | Character classification table (whitespace, alpha, etc.) |
| `date.b` | `Date` | HTTP date parsing (for cookies, Last-Modified) |
| `paginate.b` | — | Print/paginate support (partial) |

The main program binary is `charon.b`; the rest are loaded as Limbo modules at runtime (`load Module Module->PATH`).

---

## Module Architecture

Charon is composed of loosely coupled Limbo modules. The central hub is `CharonUtils` (`CU`), which holds shared state and routes all inter-module calls. The startup chain is:

```
charon.b: init()
  └─ initc()
       ├─ load CharonUtils → CU->init()   # binds all sub-modules
       ├─ load Layout, Build, Lex …       # via CU.L, CU.B, etc.
       ├─ G->init()                       # create Tk/tkclient window
       ├─ L->init()                       # load font table
       ├─ (CU->imcache).init()            # image cache
       └─ spawn go(startspec)             # fetch start page
```

`CU` exports references to all sub-modules so that every component loads once and shares instances:

```limbo
# in CharonUtils module interface (chutils.m):
C: Ctype;    E: Events;  G: Gui;
L: Layout;   I: Img;     B: Build;
LX: Lex;     J: Script;  CH: Charon;
CK: Cookiesrv; DI: Dial;
```

This means code in `layout.b` calls `CU->G->setstatus(...)` rather than reloading `gui.dis` itself.

---

## Key Data Structures

### ByteSource (`chutils.m`)

The universal async data handle. Transport puts bytes into `data[0:edata]`; consumers read up to `lim`. The `eof` flag signals completion. `err` carries any transport error.

```limbo
ByteSource: adt {
    id:     int;
    req:    ref ReqInfo;
    hdr:    ref Header;        # filled after headers received
    data:   array of byte;     # ring/growing buffer
    edata:  int;               # valid extent
    err:    string;
    net:    cyclic ref Netconn;
    eof:    int;
    lim:    int;               # consumer's read position
    seenhdr: int;
    free:   fn(bs: self ref ByteSource);
};
```

`CU->startreq(ri)` starts a fetch and returns a `ByteSource`. `CU->waitreq(bsl)` blocks until one in the list has headers ready.

### Netconn (`chutils.m`)

Represents one persistent TCP (or SSL) connection to a host. Up to `config.nthreads` connections are pooled in `netconns[10]`. Pipelining is supported for HTTP/1.1.

```
state:  NCfree → NCidle → NCconnect → NCgethdr → NCgetdata → NCdone/NCerr
```

Transport modules (`http.b`, `ftp.b`, `file.b`) implement the `Transport` interface: `connect`, `writereq`, `gethdr`, `getdata`.

### Item (`build.m`) — the core layout atom

Every renderable element is an `Item` pick ADT:

```limbo
Item: adt {
    next:     cyclic ref Item;   # linked list
    width, height, ascent: int;
    anchorid: int;               # -1 if not in anchor
    state:    int;               # IFbrk | IFwrap | IFrjust | … (bit flags)
    genattr:  ref Genattr;       # id/class/style/events

    pick {
        Itext    => s: string; fnt, fg, voff: int; ul: byte;
        Irule    => align, noshade, size, wspec: …;
        Iimage   => imageid, ci, imwidth, imheight, altrep, map, …;
        Iformfield => formfield: ref Formfield;
        Itable   => table: ref Table;
        Ifloat   => item, x, y, side: …;
        Ispacer  => spkind, fnt: int;
    }
};
```

Items are allocated in a single piece (targeting 128-byte quanta). `IFindentshift`/`IFindentmask` encode indent level in the state word; `Voffbias` is added to vertical offset to keep it non-negative.

### Frame (`layout.m`)

One browser viewport. Frames nest for `<FRAMESET>`.

| Field | Purpose |
|-------|---------|
| `id` | unique serial; used by JavaScript and event routing |
| `doc` | `ref Docinfo` — all global doc attributes |
| `layout` | `ref Lay` — the doubly-linked `Line` list |
| `sublays` | `array of ref Lay` — table cells and captions |
| `controls` | `array of ref Control` — all interactive widgets |
| `cim` | `ref Draw->Image` — where contents are painted |
| `r` | full rectangle (including scrollbars) in parent image coords |
| `cr` | content rectangle (inside margins, excluding scrollbars) |
| `viewr` | which slice of `totalr` is currently visible |
| `parent` / `kids` | frame tree (cyclic refs) |

### Control (`layout.m`) — interactive widget

```limbo
Control: adt {
    f:     cyclic ref Frame;
    ff:    ref Build->Formfield;  # nil if not a form element
    r:     Draw->Rect;
    flags: int;                   # CFactive, CFenabled, CFhasfocus, …
    popup: ref Gui->Popup;
    pick {
        Cbutton    => pic, picmask, dpic, dpicmask, label, dorelief;
        Centry     => s, sel, left, linewrap, onchange;
        Ccheckbox  => isradio;
        Cselect    => nvis, first, options;
        Clistbox   => …;
        Cscrollbar => top, bot, mindelta, deltaval, ctl;
        Canimimage => cim, cur, redraw, ts, bg;
        Clabel     => s;
    }
};
```

`domouse` returns `(action, newgrab)` where `action` is one of `CAbuttonpush`, `CAkeyfocus`, `CAchanged`, `CAdopopup`, etc.

### GoSpec — navigation command

```limbo
GoSpec: adt {
    kind:     int;           # GoNormal, GoReplace, GoLink, GoHistnode, GoSettext
    url:      ref Parsedurl;
    meth:     int;           # HGet or HPost
    body:     string;        # POST body
    target:   string;        # "_top", "_self", frame name
    auth:     string;
    histnode: ref HistNode;  # for GoHistnode
};
```

### HistNode / History

The history is a DAG (not a simple list) to handle framesets:

```limbo
HistNode: adt {
    topconfig:  cyclic ref DocConfig;         # URL + target for top frame
    kidconfigs: cyclic array of ref DocConfig;# one per kid frame
    preds:      cyclic list of ref HistNode;  # back edges
    succs:      cyclic list of ref HistNode;  # forward edges
};

History: adt {
    h: array of ref HistNode;  # LRU-ordered; h[n-1] is current
    n: int;
};
```

`History.find(+1)` follows `succs`, `find(-1)` follows `preds`, `find(0)` returns current. `find(delta)` for JavaScript's `History.go(n)` walks the graph with cycle detection.

---

## HTML Parsing Pipeline

```
ByteSource
    ↓
Lex->TokenSource.gettoks()        # HTML tokeniser (handles charset conversion)
    ↓
Build->ItemSource.getitems()      # tag-action table → Item list + Docinfo
    │       ←─ Csseng cascade     # computed CSS properties per element (Cssctx)
    ↓
Layout->layout(f, bs, linkclick)  # line-breaking, float placement, table layout
    ↓
Frame.cim                         # pixels on screen
```

Charon also builds a **retained DOM tree** alongside this pipeline (`dom.b`,
the `Node` ADT) and can render directly from it without re-serialising to
HTML, which keeps JS event handlers live across re-renders. The JS DOM API
(`domjs.b`) operates on that tree. The token→item flow above still does the
actual line-breaking and drawing; the DOM tree sits in front of it as the
mutable document model.

### Lex (`lex.b`)

Tokenises raw bytes into `Token` values with `tag` (one of ~90 `T*` consts) and an attribute list (`list of Attr` where each `Attr` has `attid` and `value`). The tokeniser handles charset conversion via a pluggable `Btos` function obtained from `convcs.dis`. It is incremental: `gettoks` returns an array of new tokens each time more `ByteSource` data arrives.

### Build (`build.b`)

An `ItemSource` wraps a `TokenSource` and maps tags to Items. It maintains a `Pstate` (parsing state) stack for nested formatting, and builds `Docinfo`, `Form`, `Table`, and `Anchor` lists alongside the item list. Tables use a two-pass algorithm described by RFC 1942 (min/max width per column, then distribute).

This is also where CSS lands. `build.b` loads the `CSS` parser and `Csseng`
cascade engine at init (both optional — if either module is missing, CSS is
simply disabled) and keeps all per-document CSS state in a `Cssctx`: the
document's AUTHOR-origin `Engine`, an open-element stack of `Elem` nodes for
selector matching, and a pending list of form fields whose stylesheet had not
been seen when they were built. `<style>` blocks and `<link rel=stylesheet>`
sheets are parsed and added to the engine as they stream in; as each element
opens, the cascade computes its `Props` and `build.b` translates them onto its
font/colour/box state (the engine itself is pure computation — see the
`csseng.b` row in the source table). A sheet that arrives after styled form
fields triggers their re-resolution rather than a full re-layout.

### Layout (`layout.b`)

Takes the item list and performs:
1. **Line breaking** — walks items left-to-right, inserting `Line` nodes at forced breaks (`IFbrk`) or when width overflows.
2. **Float placement** — tracks `Ifloat` items in `lay.floats`; adjusts line widths accordingly.
3. **Table layout** — delegates per-cell content to sub-layouts stored in `frame.sublays`.
4. **Drawing** — `drawall(f)` walks the `Line` linked list and draws each item into `f.cim`.

Fonts are named by `fnt = style * NumSize + size` where `style` ∈ {`FntR`, `FntI`, `FntB`, `FntT`} and `size` ∈ {`Tiny` … `Verylarge`}. Font files live at `/fonts/charon/<style>.<size>.font`.

---

## Transport Layer

`CharonUtils` maintains a pool of up to 10 `Netconn` slots. The `schemes` table maps URL schemes to transport indices:

| Scheme | Transport | Module |
|--------|-----------|--------|
| `http`, `https` | `THTTP` | `http.b` |
| `ftp` | `TFTP` | `ftp.b` |
| `file` | `TFILE` | `file.b` |

Each transport implements the `Transport` interface (`transport.m`): `connect`, `writereq`, `gethdr`, `getdata`. `chutils.b` calls these in sequence, managing connection reuse and pipelining.

### HTTP transport (`http.b`)

- HTTP/1.0 default; HTTP/1.1 available via `config.httpminor = 1`.
- HTTPS: `connect()` layers TLS onto the dialed fd with
  `DI->pushtls(nc.conn.dfd, nc.host)` — the `#T` devtls device backed by vendored
  mbedTLS (TLS 1.2/1.3, SNI, modern AEAD suites, cert verification). The ctl fd is
  kept in `nc.tlsctl` and closing it tears down the conversation. The legacy
  `ssl3.dis` SSL2/3 path is unused (the `nc.sslx`/`SSL3->Context` fields are
  vestigial). See ON_NETWORK.md §"Modern TLS".
- Proxy: if `config.httpproxy` is set and the host is not in `config.noproxydoms`, the `CONNECT` method is used for HTTPS tunnelling.
- Pipelining: `nc.pipeline` is true when multiple requests are queued on one connection; the header reader advances `nc.gocur`.
- Redirections: handled inside `CU->hdraction`; up to `Maxredir = 10` hops before giving up.
- Authentication: HTTP Basic only; credentials are base64-encoded in `charon.b:tobase64`.
- Content-Encoding: `writereq` sends `Accept-Encoding: gzip, deflate`. `hdrconv` records the response `Content-Encoding` into `Header.encoding`; gzip/deflate bodies are decoded transparently on the producer side (`chutils.b:decodepump`/`rawfeeder`) using `gzipfilter.b`, so consumers still see a plain decoded `ByteSource`. Any other encoding falls back to a save-as prompt.
- Transfer-Encoding: `hdrconv` sets `Header.chunked` when the response is `chunked`. The producer-side pump strips chunked framing first (`dechunk.b`), so the full body pipeline is `network → dechunk → gunzip → consumer`. `dechunk` stops at the terminating zero-length chunk, which matters on keep-alive connections that do not close after the body. (Pipelining is not preserved across a chunked body — bytes past the terminator in the same read are dropped; harmless with the default HTTP/1.0.)

### Transport state machine

```
NCfree → connect() → NCconnect
       → writereq() sends HTTP request
       → gethdr()  → NCgethdr
       → getdata() → NCgetdata
       → (eof)     → NCdone
```

---

## Image Handling (`img.b`)

`Img->ImageSource` wraps a `ByteSource` and decodes images frame-by-frame:

```limbo
getmim(is: self ref ImageSource) : (int, ref MaskedImage)
# returns Mimerror, Mimnone, Mimpartial, or Mimdone
```

Supported formats:

| Format | Notes |
|--------|-------|
| GIF87a / GIF89a | Full LZW decode; animated GIFs loop forever |
| JPEG | Full baseline + progressive; uses Huffman `Jpegstate` |
| XBitmap | Two-colour |
| Inferno BIT | Native format (`image(6)`) |

Images are cached in `CU->imcache` (an `ImageCache`): an LRU chain of `CImage` values, bounded by both `config.imagecachenum` and `config.imagecachemem` (also capped at 80% of available system image memory). Animated images are driven by `Canimimage` controls with a per-frame `delay` field.

`config.imagelvl` controls image loading:
- `ImgNone` — no images downloaded.
- `ImgNoAnim` — download but freeze on first frame.
- `ImgProgressive` / `ImgFull` — full processing with animation.

---

## Event Loop

The main loop in `charon.b:initc` receives `Event` values from `ech` (a `chan of ref Event`):

```
Ekey       → handlekey() → keyfocus.dokey()
Emouse     → handlemouse() → mainwinmouse() or ctlmouse()
Ereshape   → redraw(1), reload current HistNode
Equit      → finish()
Estop      → CU->abortgo(gopgrp)
Eback      → go(GoHistnode, history.find(-1))
Efwd       → go(GoHistnode, history.find(+1))
Eform      → form_submit() or form_reset()
Eformfield → formfield_{blur,focus,click,select,redraw}()
Ego        → go(GoSpec)
Esubmit    → go(GoSpec with method/body)
Escroll    → f.scrollabs(pt)
Escrollr   → f.scrollrel(pt)
Esettext   → settext(g, f, body)   # JS document.write
Edismisspopup → popupctl.donepopup()
```

`Gui` generates the raw input events (from Tk). `Events` (`event.b`) forwards them to the `ech` channel. JavaScript script events travel on the separate `J->jevchan : chan of ref ScriptEvent`.

Navigation is always done by `spawn go(g)`, which creates a new process group (`gopgrp`). Stopping navigation calls `CU->abortgo(gopgrp)` which kills the group.

### Mouse handling detail

`mainwinmouse` calls `top.find(p, nil)` which returns a `Loc` — a path from the top frame down to the innermost element at pixel `p`. The `Locelem` kind determines action:
- `LEitem` with `anchorid >= 0` → follow anchor on button-1-up; show URL on button-2-up.
- `LEcontrol` → delegate to `ctlmouse(e, ctl, grab)`.

Mouse-over anchor events are tracked via `mouseover`/`mouseoverfr` globals and routed to JavaScript via `SEonmouseover`/`SEonmouseout`.

**Mouse-wheel scrolling.** Inferno delivers the wheel as Tk buttons 4 (up) / 5 (down). `gui.b:framebinds` binds `<ButtonPress-4>`/`<ButtonPress-5>` on the page frame `.f` to the `wheelup`/`wheeldn` gctl commands; `evhandle` turns each notch into three synthetic `Event.Ekey(Kaup)`/`Ekey(Kadown)` events, so the wheel reuses the arrow-key line-scroll path (`curframe.yscroll(CAscrollline, ±1)`) rather than the JS-only `Escroll`/`Escrollr` events.

---

## JavaScript Support (`jscript.b`)

The `Script` module bridges Charon to `appl/lib/ecmascript/` (loaded as `ecmascript.dis`). `config.doscripts` defaults to **1 (on)**, so JS is loaded when the engine is available (a failed load is non-fatal — `J` is set to nil and scripting is silently disabled); set `doscripts = 0` to force it off.

```limbo
Script: module {
    jevchan:   chan of ref Events->ScriptEvent;  # main → JS
    frametreechanged: fn(top: ref Frame);         # on frameset change
    framedone:        fn(f: ref Frame, hasscripts: int);
    evalscript:       fn(f: ref Frame, s: string): (string, string, string);
};
```

`charon.b` sends `ScriptEvent` values on `J->jevchan` for DOM events:

| Event kind | When fired |
|-----------|-----------|
| `SEonload` | after all sub-frames + images loaded |
| `SEonclick` | button-1 release on anchor with `onclick` handler |
| `SEonmouseover`/`SEonmouseout` | pointer enters/leaves anchored item |
| `SEonsubmit`/`SEonreset` | form submit/reset, with reply channel for cancellation |
| `SEscript` | `javascript:` URL execution; reply channel carries return value |
| `SEtimeout`/`SEinterval` | JS timer events |

Known JS limitations: `Window.open()` never creates a new window (replaces current); `document.onunload` is never raised; Java applets (`document.applets`) are not supported.

---

## Cookie Handling (`cookiesrv.b`)

`Cookiesrv` runs as an independent server process started by `CU->init`. It stores cookies in `config.userdir + "/cookies"` and flushes periodically (default interval configurable). The main browser talks to it through a `Client` handle:

```limbo
Client: adt {
    set:        fn(c: self ref Client, host, path, cookie: string);
    getcookies: fn(c: self ref Client, host, path: string, secure, fromjs: int): string;
};
```

Cookie handling is **on by default** (`config.docookies = 1`). Domains are scoped by a Netscape-style match (`getdoms`/`ckcookie`: suffix match plus a TLD dot-count check), not bare exact-host match.

Attribute parsing (`parsecookie`) covers `Domain`, `Path`, `Expires`, `Secure`, plus the RFC 6265 additions `Max-Age` (takes precedence over `Expires`), `HttpOnly`, and `SameSite` (`Strict`/`Lax`/`None`, stored but not yet enforced on cross-site requests). `getcookies` takes a `fromjs` flag: HTTP requests pass `0`, `document.cookie` (`jscript.b`) passes `1`, and `HttpOnly` cookies are withheld when `fromjs` is set. The on-disk format is seven tab-separated columns (the last two are `httponly` and `samesite`); the loader also reads old 5-column files.

---

## GUI (`gui.b`)

`Gui` wraps Tk / `tkclient` to provide:

| Function | Purpose |
|----------|---------|
| `G->init(ctxt, cu)` | create window, toolbar, URL bar, status line, progress panel |
| `G->setstatus(s)` | update status text |
| `G->seturl(s)` | update URL bar |
| `G->progress <-= msg` | update download progress indicator |
| `G->backbutton(en)` / `G->fwdbutton(en)` | enable/disable nav buttons |
| `G->auth(realm)` | modal dialog for HTTP Basic credentials |
| `G->alert(msg)` / `G->confirm(msg)` / `G->prompt(msg,dflt)` | JS dialogs |
| `G->getpopup(r)` / `G->cancelpopup()` | `<select>` drop-down popups |
| `G->snarfput(s)` | copy URL to snarf buffer |

`G->mainwin` is the `ref Draw->Image` for the page viewport; `G->display` is the `ref Draw->Display`.

The toolbar nav buttons (`.ctlf.back`/`.ctlf.stop`/`.ctlf.fwd`) render as the `/icons/charon/{redleft,stop,redright}.bit` bitmaps via Tk's `-bitmap @<abspath>` form (the `@` prefix loads an absolute file path instead of the default `/icons/tk/` directory). `backbutton`/`fwdbutton`/`stopbutton` toggle their enabled/disabled state with background colouring (lime / red / grey), not by swapping the bitmap.

Progress states: `Pstart → Pconnected → Psslconnected → Phavehdr → Phavedata → Pdone` (or `Perr`/`Paborted`). Each in-flight `ByteSource` has its own progress slot identified by `bsid`.

Charon detects whether `wm` is running at startup; if so it uses `tkclient` to create a managed window; otherwise it takes the whole draw device.

---

## Configuration

Config is loaded from `config.userdir + "/config"` (default `/usr/<user>/charon/config`) or `/services/config/charon.cfg`. Command-line flags (`-key value`) override the file. Both formats use the same key names.

Key options and defaults:

| Key | Default | Notes |
|-----|---------|-------|
| `userdir` | `/usr/<user>/charon/` | bookmarks, cookies, config |
| `starturl` | `file:/services/webget/start.html` | |
| `homeurl` | same as starturl | |
| `helpurl` | `file://localhost/services/webget/help.html` | |
| `httpproxy` | (empty) | `host:port` URL |
| `noproxydoms` | (empty) | semicolon/comma-separated |
| `usessl` | `v3` | vestigial — drives only the legacy `ssl3` path; live HTTPS uses `Dial->pushtls` regardless |
| `charset` | `utf-8` | default when the document declares no charset |
| `defaultwidth` | 640 | pixels |
| `defaultheight` | 480 | main panel height |
| `imagelvl` | `ImgFull` | 0=none, 1=no-anim, 2+=full |
| `imagecachenum` | 120 | max cached images |
| `imagecachemem` | 80% of system image mem | bytes |
| `docookies` | 1 (on) | |
| `doscripts` | 1 (on) | |
| `http` | 1.0 | set to 1.1 for pipelining |
| `nthreads` | 4 | concurrent downloads |
| `offersave` | 1 | prompt to save unsupported MIME types |
| `plumbport` | `web` | plumbing port name |

`CU->saveconfig()` writes the current config back to the user file.

---

## Plumbing Integration

Charon listens on the plumbing port (`config.plumbport`, default `"web"`) in a background goroutine (`plumbwatch`). Incoming `text`-kind plumb messages navigate to the contained URL. Outgoing plumbs (`plumbsend`) are sent for URLs with unsupported schemes (e.g., `mailto:`).

---

## Font System

Layout uses a 4×5 font matrix:

| Style const | Description |
|-------------|-------------|
| `FntR` | plain / roman |
| `FntI` | italic |
| `FntB` | bold |
| `FntT` | typewriter (monospace) |

Size consts: `Tiny`, `Small`, `Normal`, `Large`, `Verylarge`.

Font index: `fnt = style * NumSize + size`. Font files: `/fonts/charon/<style>.<size>.font` (or `/fonts/minicharon/…` for the mini variant). Fonts are loaded on demand and cached in the `fonts` array in `layout.b`.

---

## Authentication

HTTP Basic auth is the only supported scheme. Challenge parsing looks for `"basic realm="` prefix (case-insensitive). On first challenge, Charon calls `G->auth(realm)` to show a credentials dialog. On success, credentials are stored in the process-local `auths: list of ref AuthInfo` and reused for subsequent requests to the same realm without re-prompting.

Credentials are base64-encoded inline (`charon.b:tobase64`).

---

## Framesets

When a document is a frameset, `frame.kids` holds child `Frame` refs; each child has its own `ByteSource`, layout, and control set. Navigation history tracks both the top config and an array of `DocConfig` values — one per kid. `findnamedframe(f, name)` walks the tree depth-first to resolve `target=` attributes. `_top`, `_self`, `_parent`, `_blank` are handled as standard; `_blank` silently reuses the top frame (Charon is single-window).

Child frames in a frameset are fetched **serially** (one at a time), not concurrently — a known limitation.

---

## Client-side Image Maps

`Build->Map` / `Area` carry shape/coords for `<MAP>` elements. `charon.b:findhit` does point-in-shape testing for `rect`, `circle`, and `poly` (even-odd winding rule for polygon). Server-side maps append `?x,y` to the URL.

---

## Debugging

`config.dbg` is an array of bytes indexed by ASCII letter. Set letters to enable specific tracing:

| Letter | Area |
|--------|------|
| `d` | basic navigation |
| `e` | event timing |
| `h` | HTML item building |
| `i` | image conversion |
| `l` | layout |
| `n` | transport / network |
| `p` | ByteSource/Netconn protocol |
| `r` | resource usage snapshots |
| `s` | scripts |
| `t` | table layout |
| `w` | recoverable page warnings |
| `x` | lex tokens |

`ResourceState` snapshots (heap, image mem, timestamps) are printed at key phases when `dbgres` is non-zero. `pctoloc` maps Dis PC values to source locations using `.sbl` symbol files — only works for the modules that have an `.sbl` entry in the switch table.

Set `config.dbgfile` to redirect debug output to a file instead of stdout.

---

## Known Bugs and Limitations

- **Table layout** uses RFC 1942 min/max width algorithm; results differ from modern browsers on edge cases.
- **Window resize** forces a full document reload (no reflow).
- **Frameset frames** are fetched one at a time, not in parallel (see the
  roadmap's "Parallel sub-resource loading").
- **`Window.open()`** silently replaces the current document instead of opening a new window.
- **`document.onunload`** is never raised.
- **`document.applets`/`document.embeds`** are always empty (no Java).
- **History** can get confused with links clicked in framesets before the frameset finishes loading.
- **Save-as** is only offered when `config.offersave = 1`, and even then only for unsupported MIME types; in-progress streaming state is not preserved across the dialog.
- No general disk cache; only the in-memory image cache persists across page loads within a session.
- Only HTTP Basic authentication is supported; no Digest, no NTLM.
- TLS certificate-chain verification happens inside the `#T` devtls device
  (mbedTLS, against the system CA bundle); a verify failure surfaces as a
  connection error, with no per-site override UI.

---

## Quick Reference: Adding a New MIME Type Handler

1. Add a constant to the `mnames` table in `chutils.b` and a matching constant in `chutils.m` (keep alphabetical order; the index is the enum value).
2. In `charon.b:get`, extend the `if(hdr.mtype == CU->TextHtml || ...)` condition.
3. Implement a decoder that reads from a `ByteSource` and either produces a `Layout->Frame` layout or a save-as dialog.

## Quick Reference: Adding a New URL Scheme

1. Add an entry to `schemes[]` in `chutils.b` pointing to one of the `THTTP/TFTP/TFILE` transport slots (or add a new slot).
2. Implement the `Transport` interface in a new `.b` file.
3. Add the scheme to `CU->schemeok()` so Charon does not immediately plumb it away.
4. Register the `.dis` path in `chutils.b:tpaths[]`.

---

## Modern-web support — what works today

Charon's original baseline was mid-1990s web standards. The features below are
current behaviour; where one touches a subsystem, the body sections above carry
the detail.

- **HTTPS — TLS 1.2/1.3.** `http.b:connect` layers TLS onto the dialed fd with
  `Dial->pushtls` (the `#T` devtls device, backed by vendored mbedTLS: SNI,
  modern AEAD suites, ALPN, certificate-chain verification against the system
  CA bundle). This is system-wide infrastructure, not Charon-specific — see
  [ON_NETWORK.md](ON_NETWORK.md) §"Modern TLS". The legacy `devssl`/`ssl3.dis`
  SSL 2/3 path still exists in the tree; Charon does not use it.
- **Content and transfer decoding.** `writereq` sends
  `Accept-Encoding: gzip, deflate`; the producer-side pump runs
  `network → dechunk → gunzip → consumer` (`dechunk.b`, then `gzipfilter.b`
  over the stdlib inflate `Filter`), so consumers always see a plain decoded
  `ByteSource`. Encodings Charon cannot decode fall back to a save-as prompt.
- **UTF-8 by default.** `config.charset` defaults to `utf-8`; `build.b`
  understands the HTML5 `<meta charset="…">` short form; `lex.b` strips a
  leading UTF-8 BOM.
- **HTML5 vocabulary.** The common semantic elements
  (`article/section/nav/header/footer/main/aside/figure/figcaption`,
  `mark/time`, `video/audio/picture/source`) are registered in `lex.{b,m}`;
  the sectioning/grouping ones get block line-break behaviour via `blockbrk[]`
  in `build.b`. `<img srcset>` falls back to the first candidate when no `src`
  is present, and `<picture>` degrades through its inner `<img>`. When adding
  tags: the `tagnames[]` array and the `T*` `iota` list must stay aligned and
  alphabetically sorted — `makestrinttab` binary-searches the table and raises
  if it is unsorted.
- **Real CSS.** Stylesheets (external, `<style>`, and inline `style=`) are
  parsed by the W3C CSS2.1 parser (`module/css.m`, `appl/lib/w3c/css.b`) and
  cascaded by `csseng.b` — selector matching, specificity, and the origin
  cascade as pure computation, unit-tested headless in `tests/web/`.
  `build.b` translates computed properties onto its font/colour/box state:
  box-model lengths, colours, `display:none`, plus the CSS3 pieces real sites
  rely on — custom properties (`var(--x)`) and grid track sizing. Grid and
  flex containers are approximated as wrapping inline flows (grid with real
  column counts from `grid-template-columns`); a faithful flex algorithm is
  still open.
- **A retained DOM.** `dom.b` builds a `Node` tree alongside the item list,
  and Charon can re-render from that tree without re-serialising to HTML —
  JS event handlers stay live across re-renders. `domjs.b` exposes the JS DOM
  API (`document`/element host objects) over the same tree.
- **`<canvas>`.** A `CanvasRenderingContext2D` host object — rects, text,
  `drawImage`, and a vector path layer (`beginPath`/`moveTo`/`lineTo`/`arc`,
  `fill`/`stroke`, `lineWidth`) — rasterised into a per-canvas offscreen
  `Draw->Image` composited into the page, with a damage-tracked fast-repaint
  path for timer-driven animation. A 3D context over `$Raster3`/`Raymath`
  exists too; its design is in [ON_CHARON_CANVAS3D.md](ON_CHARON_CANVAS3D.md).
- **Cookies per RFC 6265.** `Max-Age` (takes precedence over `Expires`),
  `HttpOnly` (withheld from `document.cookie`), `SameSite` parsed and stored,
  and the `__Secure-`/`__Host-` prefix rules enforced structurally. SameSite
  is not yet *enforced* — `getcookies` has no cross-site/initiator context.
- **localStorage / sessionStorage.** A `Storage` host object on `window`:
  the method API (`getItem`/`setItem`/`removeItem`/`clear`/`key`) plus a live
  `length`. `sessionStorage` is in-memory per origin; `localStorage` persists
  under `config.userdir + "/localstorage/<origin>"`. Missing: dot/bracket key
  access, per-origin quotas, `StorageEvent`.
- **`<noscript>` degradation.** Pages that need a JS runtime Charon does not
  have (module-only single-page apps) render their `<noscript>` content
  instead of a blank page.

## Modernisation roadmap — what's still missing

Open items, roughly in impact order. Each carries enough design to start from;
the source layout above tells you which module it lands in.

**Tolerant HTML5 parsing.** `lex.b` follows HTML 3.2 rules; modern pages are
authored against the WHATWG error-recovery state machine. The work is two
halves: the 80-state HTML5 tokeniser (RCDATA/RAWTEXT/script-data states, the
full named-entity table, self-closing void elements) and tree construction in
`build.b` (adoption agency for mis-nested formatting, implicit `<tbody>`,
implicit `<p>` closing before blocks). `<meta viewport>` should set the
initial layout width. Large — a Limbo implementation is roughly 3,000 lines;
the `html5lib-tests` corpus is the natural validation source.

**Live-DOM repaint.** JS mutations to the retained DOM (`setAttribute`,
`appendChild`, …) are not yet reflected by an automatic re-render; a page must
be re-laid-out for the change to appear. The render-from-DOM path is the right
hook — the missing piece is damage tracking from `domjs.b` writes to a repaint.

**ECMAScript 5.1 and a fuller DOM API.** The engine
(`appl/lib/ecmascript/`) implements ECMA-262 2nd edition; ES5.1 is the minimum
that modern libraries target. Language gaps: the `Array`/`Object`/`Function`
ES5 built-ins, `JSON`, `String.trim`, getters/setters, strict mode. DOM gaps:
`querySelector(All)`, `addEventListener`, `classList`, `Element.style`, the
`innerHTML` setter, `window.location`, `history.pushState`. Two routes: extend
the Limbo engine (large, but keeps everything in-VM), or wrap a complete C
engine (QuickJS, Duktape) — which on this tree means either a builtin module
compiled into emu or an out-of-process Styx service
([ON_C_AT_RUNTIME.md](ON_C_AT_RUNTIME.md)); native modules cannot be loaded at
runtime ([ON_DLM.md](ON_DLM.md)). The `Script` interface is already the
abstraction seam, so the engine can be swapped without touching `charon.b`.

**XMLHttpRequest.** A host object over existing transport: `open` builds a
`ReqInfo`, `send` spawns `CU->startreq` and raises `readystatechange`
`ScriptEvent`s at each state transition, `responseText` reads
`ByteSource.data`, `abort` kills the spawned group. Mostly wiring in
`jscript.b`; channels + `spawn` fit the async state machine naturally.

**Parallel sub-resource loading.** Frameset kids and `<img>`/`<link>`/
`<script>` sub-resources are fetched serially; modern pages carry dozens.
The `Netconn` pool and `config.nthreads` already support concurrency — the
work is starting requests speculatively as `build.b` encounters the tags and
waiting only at draw time, plus `async`/`defer` script semantics.

**HTTP/2.** A new `http2.b` behind the same `Transport` interface: the binary
framing layer, HPACK header compression (static table hardcoded, dynamic table
as a ring buffer), one stream per `ByteSource`, ALPN negotiation (`h2`) with
HTTP/1.1 fallback. Large; HPACK alone is ~800 lines.

**WebP.** The RIFF container is a thin wrapper; VP8L (lossless, ~1,500 lines,
prefix codes + ARGB transforms) covers logos and screenshots, VP8 (lossy,
DCT-based, the JPEG decoder in `img.b` is a structural template) covers the
rest. Add `image/webp` to `mnames` and `Img->supported`.

**WebSockets.** An HTTP/1.1 upgrade handshake then a small framing layer
(client frames masked; TEXT/BINARY/PING/PONG/CLOSE). `ByteSource` is the wrong
shape for a bidirectional push stream — expose a channel for incoming frames
and a write function, plus the `WebSocket` host object with
`onopen`/`onmessage`/`onerror`/`onclose`.

**`<video>`/`<audio>` placeholders.** Full in-process video decoding is not
realistic in Limbo. Render a sized placeholder with a play affordance and, on
click, plumb the source URL to an external player; same pattern for audio.
`<source>` selection by `type`/`media` follows.

**Flexbox proper.** The wrapping-inline approximation handles the common
nav-bar/card cases; the real algorithm (`justify-content`, `align-items`,
`flex-wrap`, `flex: 1`) builds on the existing cascade and box-model code.

**Promises, fetch.** If the JS engine is swapped for a complete one these come
for free; extending the Limbo engine means a microtask queue plus the
`Promise` API, with `fetch()` as a thin wrapper over XHR.

**HTTP/3 and AVIF** — deferred. Every HTTP/3 server falls back to HTTP/2 or
1.1, and image servers fall back from AVIF when the `Accept` header doesn't
offer it, so the cost of waiting is low; both are very large (QUIC is a full
transport; AV1 intra decoding realistically means an out-of-process decoder).
