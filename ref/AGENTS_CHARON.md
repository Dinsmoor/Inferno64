# Charon — Inferno Web Browser Agent Reference

Charon is Inferno's graphical web browser, written entirely in Limbo. It runs on the Dis VM, so it is fully portable across every Inferno platform (hosted and native). It targets mid-1990s web standards: HTML 3.2 / Netscape Navigator 3 compatibility, HTTP 1.0/1.1, HTTPS (SSL 2/3), FTP, and ECMAScript-262 2nd Edition (≈ JavaScript 1.1).

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
| `http.b` | `Transport` (HTTP) | HTTP/1.0, HTTP/1.1, HTTPS; SSL 2/3 via `ssl3.dis`; pipelining; proxy |
| `ftp.b` | `Transport` (FTP) | FTP plain-text retrieval |
| `file.b` | `Transport` (FILE) | Local file access with MIME sniffing |
| `img.b` | `Img` | GIF87a/89a (with animation), JPEG, XBitmap, Inferno BIT decoder |
| `gui.b` | `Gui` | Tk/tkclient wrapper: toolbar, URL bar, status line, progress panel, popups |
| `event.b` | `Events` | `Event` pick ADT (Ekey, Emouse, Ego, Esubmit, …); `ScriptEvent` for JS |
| `jscript.b` | `Script` | ECMAscript bridge: loads `ecmascript.dis`, routes `ScriptEvent` |
| `cookiesrv.b` | `Cookiesrv` | Cookie server: persistent storage, per-session `Client` handle |
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
    ↓
Layout->layout(f, bs, linkclick)  # line-breaking, float placement, table layout
    ↓
Frame.cim                         # pixels on screen
```

### Lex (`lex.b`)

Tokenises raw bytes into `Token` values with `tag` (one of ~90 `T*` consts) and an attribute list (`list of Attr` where each `Attr` has `attid` and `value`). The tokeniser handles charset conversion via a pluggable `Btos` function obtained from `convcs.dis`. It is incremental: `gettoks` returns an array of new tokens each time more `ByteSource` data arrives.

### Build (`build.b`)

An `ItemSource` wraps a `TokenSource` and maps tags to Items. It maintains a `Pstate` (parsing state) stack for nested formatting, and builds `Docinfo`, `Form`, `Table`, and `Anchor` lists alongside the item list. Tables use a two-pass algorithm described by RFC 1942 (min/max width per column, then distribute).

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
- SSL: loads `ssl3.dis`, negotiates SSL2 or SSL3 (or both, using the SSLv23 probe). Inferno `ssl3` supports a broad set of cipher suites including RC4-128, DES, 3DES, and FORTEZZA.
- Proxy: if `config.httpproxy` is set and the host is not in `config.noproxydoms`, the `CONNECT` method is used for HTTPS tunnelling.
- Pipelining: `nc.pipeline` is true when multiple requests are queued on one connection; the header reader advances `nc.gocur`.
- Redirections: handled inside `CU->hdraction`; up to `Maxredir = 10` hops before giving up.
- Authentication: HTTP Basic only; credentials are base64-encoded in `charon.b:tobase64`.

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

---

## JavaScript Support (`jscript.b`)

The `Script` module bridges Charon to `appl/lib/ecmascript/` (loaded as `ecmascript.dis`). It is **not loaded by default**; `config.doscripts` must be non-zero.

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
    getcookies: fn(c: self ref Client, host, path: string, secure: int): string;
};
```

Cookie handling is **off by default** (`config.docookies = 0`). Only HTTP Basic auth is supported; there is no cookie-domain scoping beyond exact host match.

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

Progress states: `Pstart → Pconnected → Psslconnected → Phavehdr → Phavedata → Pdone` (or `Perr`/`Paborted`). Each in-flight `ByteSource` has its own progress slot identified by `bsid`.

Charon detects whether `wm` is running at startup; if so it uses `tkclient` to create a managed window; otherwise it takes the whole draw device.

---

## Configuration

Config is loaded from `config.userdir + "/config"` (default `/usr/<user>/charon/config`) or `/services/config/charon.cfg`. Command-line flags (`-key value`) override the file. Both formats use the same key names.

Key options and defaults:

| Key | Default | Notes |
|-----|---------|-------|
| `userdir` | `/usr/<user>/charon/` | bookmarks, cookies, config |
| `starturl` | `file://localhost/services/webget/start.html` | |
| `homeurl` | same as starturl | |
| `helpurl` | `file://localhost/services/webget/help.html` | |
| `httpproxy` | (empty) | `host:port` URL |
| `noproxydoms` | (empty) | semicolon/comma-separated |
| `usessl` | off | `v2`, `v3`, or both |
| `defaultwidth` | 630 | pixels |
| `defaultheight` | 450 | main panel height |
| `imagelvl` | `ImgFull` | 0=none, 1=no-anim, 2+=full |
| `imagecachenum` | 60 | max cached images |
| `imagecachemem` | 80% of system image mem | bytes |
| `docookies` | 0 (off) | |
| `doscripts` | 0 (off) | |
| `http` | 1.0 | set to 1.1 for pipelining |
| `nthreads` | 4 | concurrent downloads |
| `offersave` | 0 | prompt to save unsupported MIME types |
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
- **Frameset frames** are fetched one at a time, not in parallel.
- **`Window.open()`** silently replaces the current document instead of opening a new window.
- **`document.onunload`** is never raised.
- **`document.applets`/`document.embeds`** are always empty (no Java).
- **History** can get confused with links clicked in framesets before the frameset finishes loading.
- **Save-as** is only offered when `config.offersave = 1`, and even then only for unsupported MIME types; in-progress streaming state is not preserved across the dialog.
- No general disk cache; only the in-memory image cache persists across page loads within a session.
- Only HTTP Basic authentication is supported; no Digest, no NTLM.
- SSL certificate verification (X.509 chain) is done by `ssl3.dis`; certificate rejection is not surfaced as a user-visible error in all cases.

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

## Modernisation Plan

What follows is a prioritised plan to make Charon usable on the contemporary web. Items are grouped into four tiers by impact: P0 items each individually lock out the majority of the web; P1 items cover the most common gaps once P0 is solved; P2/P3 cover important but narrower segments.

A note on what Inferno already provides that is relevant here:

- `emu/port/devtls.c` (`man/3/tls`) — the `#a` kernel device implements the TLS 1.0/SSL 3.0 **record layer** (`0x0300`/`0x0301`). The handshake is done in userspace (`appl/lib/crypt/ssl3.b`). Upgrading to TLS 1.2/1.3 means upgrading the handshake; the kernel device needs only a minor version-number change.
- `appl/lib/inflate.b`, `appl/lib/deflate.b`, `appl/cmd/gzip.b` — zlib inflate/deflate and gzip exist and are used by other parts of Inferno. The `Filter` module (`module/filter.m`, `DEFLATEPATH`/`INFLATEPATH`) provides a channel-based streaming interface ideal for wrapping a `ByteSource`.
- `appl/lib/ecmascript/` — the existing ECMAscript-262 2nd ed engine. Extending vs. replacing is a genuine choice.

---

### P0 — Without these, 95%+ of the web is inaccessible

#### P0.1 · TLS 1.2 (with SNI and modern cipher suites)

**Why it is blocking.** Essentially every HTTPS server in 2024 requires TLS 1.2 at minimum; SSL 2/3 and TLS 1.0 connections are rejected outright (RFC 8996). Without this, HTTPS is completely non-functional.

**What needs to change.**

1. **Handshake upgrade (`appl/lib/crypt/ssl3.b` → new `tls12.b`).** TLS 1.2 (RFC 5246) changes the PRF (to HMAC-SHA-256/SHA-384), adds the `signature_algorithms` extension, and changes the `Finished` MAC. The existing code structure in `ssl3.b` is the right starting point; most of the record-layer plumbing carries over.

2. **ECDHE key exchange.** Inferno stdlib has RSA and DSA but no elliptic curve primitives. Need to implement or add as a native module:
   - `x25519` / Curve25519 for key agreement (mandatory in TLS 1.3, dominant in TLS 1.2)
   - `P-256` (NIST secp256r1) as the fallback — required by most servers
   - `ECDSA` signature verification for ECDSA certificates

3. **AES-GCM cipher suite.** `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256` (`0xC02B`) is the universal mandatory suite. The kernel TLS device currently only implements RC4-128 and 3DES-CBC; it needs AES-128-GCM (AEAD). This may require updating `devtls.c` or bypassing the kernel device and doing AEAD in Limbo using a raw AES module.

4. **SNI extension** (RFC 6066). Without Server Name Indication, TLS handshakes to virtually all CDN-hosted and virtually-hosted sites fail. One extra extension field in the `ClientHello`: `server_name` with type `host_name`. This is a small change but has enormous practical impact.

5. **Certificate chain verification.** The existing code verifies the leaf certificate against a trusted root. Modern PKI requires walking the full chain. Build a `ca-bundle` file (PEM format, e.g. from Mozilla) stored at `/services/tls/ca-bundle` and load it at startup.

**TLS 1.3 (stretch goal within this item).** TLS 1.3 (RFC 8446) simplifies the handshake to 1-RTT, drops all legacy cipher suites, and requires x25519 + AES-128-GCM or ChaCha20-Poly1305. Once x25519 is implemented for TLS 1.2, TLS 1.3 is substantially the same crypto with a restructured handshake.

**Effort:** Large. ECDHE/AES-GCM crypto primitives are the bulk of the work. Plan 9 (from Bell Labs and 9front) has Limbo-adjacent C implementations that could be adapted.

---

#### P0.2 · HTTP Content-Encoding: gzip / deflate

**Why it is blocking.** Virtually every HTTP/1.1 server compresses responses with gzip or deflate (`Content-Encoding: gzip`). Without decompression, the `ByteSource` consumer receives raw compressed bytes and `lex.b` sees garbage. This single omission makes most pages unreadable even when connectivity works.

**What needs to change.** The infrastructure already exists — this is the lowest-effort P0 item:

1. **Send `Accept-Encoding: gzip, deflate`** in `http.b:writereq`. One line change.

2. **After `gethdr`, wrap `ByteSource` in a decompressing filter** if `Content-Encoding: gzip` or `deflate` is present. The `Filter` module (`module/filter.m`) provides exactly the right abstraction: `Filter->start(INFLATEPATH)` returns a `chan of ref Rq`; the wrapper goroutine reads raw bytes from the network `ByteSource`, sends `Fill` messages through the filter, and writes decompressed bytes back into the same `ByteSource.data` buffer.

3. **gzip envelope stripping.** `appl/cmd/gzip.b` already strips the gzip 10-byte header and CRC32 trailer. Reuse that logic as a library call before feeding bytes to `inflate.b`.

The change is entirely in `http.b` and a new `gzipfilter.b` helper; no other module needs to change. Add a `zstd` entry to the plan once a zstd decoder exists (it is the newest Content-Encoding).

**Effort:** Small. Two days of work including testing.

---

#### P0.3 · UTF-8 as default charset everywhere

**Why it is blocking.** HTML5 mandates UTF-8 as the document default when no charset declaration is present. Charon's tokeniser falls back to Latin-1 (`ISO_8859_1`) — the HTML 3.2 default — when no `<meta charset>` is found. The result is Mojibake for any page without an explicit charset declaration (i.e., most modern pages, since they rely on the browser defaulting to UTF-8).

**What needs to change.**

1. In `lex.b:TokenSource.new`, default `chset` to `"utf-8"` instead of `"ISO_8859_1"`. One-line change.
2. Add `<meta charset="utf-8">` short-form parsing (HTML5 syntax) alongside the existing `<meta http-equiv="content-type">` path in `build.b`. The short form is `<meta charset="...">` — the existing parser only recognises the verbose form.
3. Handle the BOM (`0xEF 0xBB 0xBF`) at the start of a UTF-8 stream by stripping it.

**Effort:** Trivial.

---

### P1 — Most modern pages are broken or unreadable without these

#### P1.1 · Tolerant HTML5 parsing

**Why it is blocking.** Modern HTML is authored against HTML5 error-recovery rules — omitted end tags, mis-nested elements, implicit `<tbody>`, unclosed `<p>` before block elements, etc. The HTML5 tokeniser and tree-construction algorithm (WHATWG Living Standard) define a precise error-recovery state machine. Charon's current `lex.b` follows HTML 3.2 rules and silently drops or mis-parses most real-world pages.

**What needs to change.**

1. **HTML5 tokeniser** — rewrite `lex.b` as a state machine matching the WHATWG spec's 80-state tokeniser. Key additions: proper handling of `RCDATA`/`RAWTEXT`/`SCRIPT DATA` states (for `<style>`, `<script>`, `<textarea>`), named character references (full HTML5 entity table), and self-closing syntax for void elements.

2. **Tree construction** — `build.b` needs adoption agency algorithm for mis-nested formatting elements (e.g., `<b><i></b></i>`), automatic `<tbody>` insertion, implicit `<p>` closing before block elements. The full 8-phase insertion mode machine is specified in the WHATWG standard.

3. **New semantic elements** — `<article>`, `<section>`, `<nav>`, `<header>`, `<footer>`, `<main>`, `<aside>`, `<figure>`, `<figcaption>`, `<template>`, `<picture>`, `<source>` — treat unknown/new block elements as `<div>` and new inline elements as `<span>` at minimum, so they degrade gracefully rather than being dropped.

4. **`<meta viewport>`** — respect `width=device-width` for initial layout width, rather than always defaulting to the window pixel width.

**Effort:** Large. The WHATWG tokeniser and tree construction algorithm are precisely specified but non-trivial. A reference implementation in Limbo is ~3,000 lines. Consider porting `html5lib-tests` for validation.

---

#### P1.2 · CSS 2.1 engine (box model + basic selectors)

**Why it is blocking.** Virtually every modern page relies on CSS for layout. Without CSS, floats, widths, and positioning all come from HTML attributes that almost no modern page uses, producing walls of unstyled text or completely broken layouts.

**What to implement first (highest leverage):**

| Feature | Why |
|---------|-----|
| `display: none` | Hides navigation, popups, scripts — critical for legibility |
| `display: block / inline / inline-block` | Basic layout model |
| Box model: `width`, `height`, `max-width`, `min-width`, `padding`, `margin`, `border` | Page structure |
| `color`, `background-color`, `font-size`, `font-weight`, `font-style`, `font-family` | Text legibility |
| `text-align`, `line-height`, `text-decoration` | Text rendering |
| `float: left/right; clear` | Column layouts (already partially implemented from HTML attrs) |
| `position: relative / absolute`; `top/left/right/bottom` | Overlaid UI elements |
| Type, class, and ID selectors (`.foo`, `#bar`, `div`) | Covers ~80% of real-world rules |
| Descendant combinator (`div p`) | Common compound rules |
| Pseudo-classes: `:hover`, `:visited`, `:focus`, `:first-child` | Link colouring, forms |
| `list-style-type` | List rendering |
| `overflow: hidden / scroll / auto` | Scroll containers |

**Architecture.** Add a new module `css.b` / `css.m`:
- **Parser** — tokenise CSS text (lexer for tokens, declarations, rule sets, `@media` blocks, `@import`).
- **Cascade + specificity engine** — for each element, collect matching rules, sort by specificity, resolve `inherit` and `initial`.
- **Integration with `build.b`** — `Pstate` already carries `curfont`, `curfg`, `curbg`; extend it to carry a computed-style struct. The CSS engine feeds computed values into `Pstate` at item-building time.
- **`<link rel="stylesheet">` and `<style>` blocks** — fetch external sheets as sub-resources via `CU->startreq` during layout; inline sheets are parsed before item building.

**Defer for later:** Flexbox, CSS Grid, CSS animations/transitions, `calc()`, custom properties (`--foo`), media queries beyond `max-width`, `transform`, `z-index` (stacking contexts).

**Effort:** Very large. A minimal but functional CSS 2.1 subset is 4,000–8,000 lines of Limbo. The cascade engine is the core complexity; the layout integration is manageable because `build.b`/`layout.b` already have the right hooks.

---

#### P1.3 · ECMAScript 5.1 + core DOM API

**Why it is blocking.** The existing engine is ECMAScript 2nd edition (1998). ES5.1 (2011) is the minimum that most library shims target. Missing built-ins cause immediate script errors on almost every site.

**Minimum viable JS additions:**

*Language:*
- `Array.prototype.forEach`, `map`, `filter`, `reduce`, `indexOf`, `some`, `every`, `isArray`
- `Object.keys`, `Object.create`, `Object.defineProperty` (basic), `Object.getPrototypeOf`
- `Function.prototype.bind`
- `String.prototype.trim`, `split` with limit, `indexOf`, `lastIndexOf`, `replace` with RegExp
- `JSON.parse`, `JSON.stringify`
- Strict mode (`"use strict"`)
- Getter/setter syntax (`get foo()`, `set foo(v)`)
- `Date` object improvements (ISO 8601 parsing)

*DOM API (host objects):*
- `document.querySelector(sel)` / `querySelectorAll(sel)` — prerequisite for almost all modern DOM manipulation
- `Element.addEventListener(type, fn)` / `removeEventListener` — supersedes `on*` attributes
- `Element.classList` (`.add`, `.remove`, `.toggle`, `.contains`)
- `Element.getAttribute` / `setAttribute` / `removeAttribute`
- `Element.style` (read/write inline styles)
- `Element.innerHTML` setter (critical: many sites update DOM via `innerHTML`)
- `window.location` object (`.href`, `.pathname`, `.search`, `.hash`, `.replace()`, `.assign()`)
- `window.history.pushState` / `replaceState` (SPA routing)
- `XMLHttpRequest` — see P1.4

**JavaScript engine options:**

| Option | Pros | Cons |
|--------|------|------|
| Extend existing `appl/lib/ecmascript/` | Pure Limbo, familiar codebase | ES5 additions are large; ES6+ would require a near-rewrite |
| Port **QuickJS** (Fabrice Bellard, ~210 KLOC C, ES2020) as a native Inferno module | Complete, spec-compliant, compact | Requires C→Inferno native module wrapper; JIT not available |
| Port **Duktape** (ES5.1 compliant, ~150 KLOC C) | Smaller than QuickJS, ES5.1 complete | Same native module overhead |

**Recommendation:** Wrap QuickJS or Duktape as a native module (`/dis/lib/jsengine.dis` backed by `libjs.so` or compiled into `emu`). The `Script` module interface is already an abstraction layer — swap the implementation behind `JSCRIPTPATH` without touching `charon.b`. This is less elegant than pure Limbo but delivers complete, tested ES compliance immediately.

**Effort:** Medium (native module wrapper) to Very Large (pure Limbo ES5 implementation). The native module route is the pragmatic choice.

---

#### P1.4 · XMLHttpRequest (AJAX)

**Why it is blocking.** `XMLHttpRequest` is the foundation of AJAX. Any site that fetches data after initial load — forms, infinite scroll, auto-complete, dynamic content — requires it. Without XHR, SPAs show blank pages and static sites lose critical features.

**What needs to change.**

XHR is a host object exposed to the JS engine. It maps onto existing Charon infrastructure:

1. Expose an `XMLHttpRequest` constructor to the JS engine (in `jscript.b`).
2. `open(method, url, async)` — create a `ReqInfo`.
3. `send(body)` — call `CU->startreq(ri)` in a spawned goroutine; signal `onreadystatechange` callbacks at each state transition via `ScriptEvent`.
4. `readyState` transitions: 0 (UNSENT) → 1 (OPENED) → 2 (HEADERS_RECEIVED) → 3 (LOADING) → 4 (DONE). Each transition raises `SE-readystatechange` on `J->jevchan`.
5. `responseText` / `responseXML` / `response` — populated from `ByteSource.data`.
6. `setRequestHeader` / `getResponseHeader` — map to `ReqInfo` and `Header`.
7. `abort()` — kill the spawned goroutine.

The Limbo concurrency model (channels + spawn) is well-suited to the async XHR state machine.

**Effort:** Medium. The transport plumbing already exists; this is mostly host object wiring in `jscript.b`.

---

#### P1.5 · Parallel sub-resource loading

**Why it is blocking (performance + correctness).** Charon fetches frameset children serially. More critically, it fetches `<img>`, `<script>`, and `<link rel="stylesheet">` sub-resources through the same sequential path. Modern pages have 20–100 sub-resources. Serial fetching makes pages load 10–50× slower than they should, and `<script>` blocks layout until downloaded.

**What needs to change.**

1. **Frameset kids** — already noted as a known bug. Fix: spawn one `getproc` per kid into `kdone` channel; wait on all. This is already the pattern; remove the serial loop.

2. **Sub-resource pipeline in `build.b`** — as `ItemSource.getitems` encounters `<img src>`, `<link href>`, `<script src>` tags, immediately call `CU->startreq` for each (up to `config.nthreads` concurrent). Store the `ByteSource` in the `Item`. When `layout.b` encounters the item for drawing, call `CU->waitreq` only then. This is speculative prefetch.

3. **`<script>` async/defer** — `async` scripts should not block layout; `defer` scripts run after parse completes. The `Script` module needs corresponding `evalasync` / `evaldefer` entry points.

**Effort:** Medium. The `Netconn` pool and `nthreads` config already support concurrency; this is about wiring up the call sites correctly.

---

### P2 — Common features, growing segments of the web

#### P2.1 · HTTP/2

HTTP/2 (RFC 7540) multiplexes requests over a single TLS connection, eliminating head-of-line blocking and reducing connection setup overhead. It is now used by ~65% of websites. HTTP/2 is required for servers that have dropped HTTP/1.1 support (rare now but growing).

**Architecture changes:**
- New `http2.b` implementing the `Transport` interface.
- **Binary framing layer** — 9-byte frame header (length, type, flags, stream ID), frame types: `DATA`, `HEADERS`, `PRIORITY`, `RST_STREAM`, `SETTINGS`, `PUSH_PROMISE`, `PING`, `GOAWAY`, `WINDOW_UPDATE`, `CONTINUATION`.
- **HPACK header compression** (`hpack.b`) — static table (61 entries), dynamic table with LRU eviction, Huffman encoding. The static table is small and can be hardcoded; the dynamic table is a ring buffer.
- **Stream multiplexing** — each `ByteSource` maps to one HTTP/2 stream ID (odd numbers, client-initiated). `Netconn` needs a `streams: array of ref ByteSource` indexed by stream ID.
- **Flow control** — per-stream and connection-level `WINDOW_UPDATE` frames.
- **Connection upgrade** — negotiate via ALPN extension in the TLS handshake (`h2` protocol name); fall back to HTTP/1.1 if ALPN returns `http/1.1`.

`chutils.b` selects the transport after `gethdr` based on the negotiated protocol; the rest of Charon sees only `ByteSource` and is unaffected.

**Effort:** Large. HPACK alone is ~800 lines; the framing layer is ~1,500 lines. HTTP/2 also requires TLS 1.2 (P0.1) as a prerequisite since plaintext HTTP/2 is almost never used in practice.

---

#### P2.2 · WebP image format

WebP is now the dominant image format served by Google, Facebook, most CDNs, and many e-commerce sites. Sites serving WebP-only `<img>` tags show broken image placeholders in Charon today.

**Formats to implement in `img.b`:**
- **VP8L (lossless)** — entirely separate from VP8. Uses a prefix code tree + ARGB pixel transform. Approximately 1,500 lines of Limbo. This covers ~25% of WebP usage (logos, icons, screenshots).
- **VP8 (lossy)** — DCT-based, similar in structure to JPEG. The existing JPEG decoder in `img.b` provides a structural template. ~3,000 lines.
- **WebP with alpha / WebP with animation** — the RIFF container (`RIFF`, `WEBP`, `VP8L`/`VP8`/`VP8X` chunks) is a thin wrapper; implement the container parser first, then plug in the format decoders.

Add `image/webp` to the `mnames` table in `chutils.b` and the `Img->supported` predicate.

**Effort:** Medium (VP8L) to Large (VP8 lossy).

---

#### P2.3 · WebSockets

WebSockets (RFC 6455) are used for live feeds, chat, collaborative tools, developer tools. They start as an HTTP/1.1 upgrade then switch to a framed binary/text protocol over the same TCP connection.

**Implementation:**
- Expose a `WebSocket` host object to the JS engine.
- `ws.b` — new module implementing the handshake and framing: client sends `Upgrade: websocket`, `Sec-WebSocket-Key` (random base64), `Sec-WebSocket-Version: 13`; server replies with `101 Switching Protocols` and `Sec-WebSocket-Accept` (SHA1 of key + magic GUID). After upgrade, the connection uses 2–10 byte frame headers (FIN/RSV/opcode/mask bits + payload length).
- Framing: `TEXT`, `BINARY`, `PING`, `PONG`, `CLOSE` opcodes. Client frames must be masked.
- `ByteSource` is inappropriate for WebSocket (it is push-based and bidirectional); expose a separate `chan of array of byte` for incoming frames and a write function for outgoing frames.
- JS callbacks: `onopen`, `onmessage`, `onerror`, `onclose`.

**Prerequisite:** TLS (P0.1) for `wss://`.

**Effort:** Medium. The handshake is small; the framing layer is ~500 lines.

---

#### P2.4 · HTML5 `<video>` and `<audio>` — placeholder + external handoff

A full in-process video decoder (H.264, VP9, AV1) is not realistic in Limbo. The practical approach:

1. **Render a placeholder** — draw a grey box with the video dimensions, a play-button icon, and the `<video>` title/alt text. This prevents layout from collapsing.
2. **Plumb to an external player on click** — on button-1 click, extract the `src` URL (or the first `<source>` with a supported type) and call `plumbsend(url, "video")`. `plumber` rules can route `video` messages to `mpv`, `mplayer`, or whatever the platform provides.
3. **`<audio>`** — same pattern; plumb to an audio player.
4. **`<picture>`** / `srcset` parsing — `<picture>` with `<source type="image/webp">` and a fallback `<img>` is the modern responsive image pattern. Parse `<picture>`, evaluate `media` and `type` attributes, select the best source the browser can render (use WebP if P2.2 is implemented, otherwise fall back to `<img>`).

**Effort:** Small (placeholder + plumb), Medium (srcset/picture parsing).

---

#### P2.5 · Modern cookie handling

The current `cookiesrv.b` is RFC 2109 (1997). Modern cookies use RFC 6265 (2011) semantics:

- **`SameSite=Strict/Lax/None`** attribute — needed to avoid sending cookies on cross-site requests.
- **`HttpOnly`** — prevents JS from reading the cookie; `cookiesrv.b` must not expose HttpOnly cookies to `jscript.b`.
- **`Max-Age`** attribute (takes precedence over `Expires`).
- **Cookie prefixes** (`__Secure-`, `__Host-`) — cookies with these prefixes must be on HTTPS-only paths.
- **`SameSite=None; Secure`** — required for third-party cookies on HTTPS (if ever needed).
- **Domain-scoping** — the current implementation lacks full subdomain matching per RFC 6265 §5.1.3.

**Effort:** Small to Medium. Mostly additive changes to `cookiesrv.b`; new attributes need parser extension and storage fields.

---

#### P2.6 · localStorage / sessionStorage

Many sites use `localStorage` as a simple key-value store (preferences, cached state, auth tokens). Without it, sites that depend on it may fail to initialise or lose state between visits.

**Implementation:**
- Two host objects in `jscript.b`: `window.localStorage` and `window.sessionStorage`.
- `localStorage` — backed by a file in `config.userdir + "/localstorage/<origin-hash>"` (keyed by scheme+host+port). `getItem`, `setItem`, `removeItem`, `clear`, `key(n)`, `length`.
- `sessionStorage` — same API but backed by an in-memory hash table, discarded on tab close.
- Storage quota: enforce a per-origin limit (e.g., 5 MB).
- `StorageEvent` — raised on `localStorage` changes in other Charon windows via plumbing.

**Effort:** Small. ~300 lines of Limbo for the host objects and file backend.

---

### P3 — Emerging or niche, but growing

#### P3.1 · CSS Flexbox (partial)

Flexbox is now the dominant layout primitive. `display: flex` with `flex-direction`, `justify-content`, `align-items`, and `flex-wrap` covers the majority of real-world usage. The layout algorithm is specified in CSS Flexible Box Layout Module Level 1. Without any flexbox support, navigation bars, card grids, and header layouts are completely broken.

**Minimum viable subset:** `display: flex`, `flex-direction: row/column`, `justify-content: flex-start/center/flex-end/space-between`, `align-items: stretch/center/flex-start/flex-end`, `flex: 1` shorthand. Defer `order`, `align-content`, `align-self`, `flex-basis`, `flex-grow`, `flex-shrink` fine-tuning.

**Effort:** Large. Requires the CSS engine (P1.2) as a prerequisite.

---

#### P3.2 · Promises + async/await (ES6)

Promises are the standard async primitive in modern JS. `fetch()`, `async` functions, and virtually all modern APIs return Promises. Without them, any page that uses `async/await` or `.then()` chains produces immediate syntax or type errors.

If the JS engine is replaced with QuickJS/Duktape (P1.3), Promises come for free. If extending the existing engine, implement:
- `Promise` constructor, `.then()`, `.catch()`, `.finally()`
- `Promise.resolve`, `Promise.reject`, `Promise.all`, `Promise.race`
- Microtask queue (Promise reactions must run before the next macrotask)
- `async function` / `await` desugaring

**Effort:** Medium, but only relevant if the existing JS engine is extended rather than replaced.

---

#### P3.3 · Fetch API

`fetch()` is the modern replacement for XHR. It returns a `Promise<Response>`. If Promises (P3.2) and XHR (P1.4) are both implemented, `fetch()` is a thin wrapper:

```js
fetch(url, options) → Promise resolving to Response
Response.text() / .json() / .arrayBuffer() → Promise
```

**Effort:** Small on top of P1.4 + P3.2.

---

#### P3.4 · HTTP/3 / QUIC

HTTP/3 runs over QUIC (RFC 9000/9114) — a UDP-based transport that bakes in TLS 1.3, stream multiplexing, and loss recovery. ~30% of web traffic uses HTTP/3. This is a **significant undertaking**:

- QUIC requires raw UDP sockets. Inferno's `Dial` module supports UDP, but QUIC's connection logic (packet number spaces, ACK, congestion control, retry) is a full transport layer.
- HTTP/3 uses QPACK for header compression (similar to HPACK but designed for QUIC's out-of-order delivery).
- TLS 1.3 is mandatory.

**Defer** until TLS 1.3 (P0.1), HTTP/2 (P2.1), and core features are solid. Practically, every HTTP/3 server also supports HTTP/2 as a fallback, so the impact of deferring this is minimal.

---

#### P3.5 · Canvas 2D API

`<canvas>` enables charts, games, and many interactive UIs. The 2D API exposes an immediate-mode drawing surface. Inferno's `Draw` module provides most of the primitives needed:

- `fillRect`, `strokeRect`, `clearRect` → `Draw->Image.draw`
- `fillText`, `strokeText` → `Draw->Image.text`
- `drawImage` → `Draw->Image.draw` with source sub-rect
- `beginPath`, `moveTo`, `lineTo`, `arc`, `fill`, `stroke` → Inferno has no vector path renderer; would need a new `path.b` Bresenham/anti-aliased rasteriser
- `getImageData` / `putImageData` → `Draw->Image.readpixels`/`writepixels` (if available) or pixel-by-pixel via `Image.pixel`

The host object wires JS calls to Inferno drawing operations on a per-canvas offscreen `Image` that is then composited into the page.

**Effort:** Medium to Large. The path renderer (arcs, bezier curves) is the main missing piece.

---

#### P3.6 · AVIF / HEIF images

AVIF (AV1 Image File Format) is growing rapidly — Google and many CDNs serve it by default when the browser signals support. It offers ~30% better compression than WebP.

AVIF decoding requires:
- HEIF container (ISOBMFF box parser) — ~500 lines
- AV1 intra-frame decoder — very complex (~10,000 lines); realistically a native module wrapping `libaom` or `dav1d`

**Pragmatic approach:** Signal no AVIF support (omit `image/avif` from `Accept` header). Servers will fall back to WebP or JPEG. Only implement if WebP (P2.2) is complete and a native AV1 decoder can be integrated.

---

### Modernisation Roadmap Summary

| Priority | Item | Prerequisite | Effort |
|----------|------|-------------|--------|
| **P0.1** | TLS 1.2 + SNI + ECDHE + AES-GCM | — | Large |
| **P0.2** | gzip/deflate Content-Encoding | — | Small |
| **P0.3** | UTF-8 default charset | — | Trivial |
| **P1.1** | HTML5 tolerant parser | — | Large |
| **P1.2** | CSS 2.1 engine | P1.1 | Very Large |
| **P1.3** | ECMAScript 5.1 + modern DOM | — | Large |
| **P1.4** | XMLHttpRequest | P1.3 | Medium |
| **P1.5** | Parallel sub-resource loading | — | Medium |
| **P2.1** | HTTP/2 + HPACK | P0.1 | Large |
| **P2.2** | WebP (VP8L then VP8) | — | Medium–Large |
| **P2.3** | WebSockets | P0.1 | Medium |
| **P2.4** | `<video>`/`<audio>` placeholder + plumb | — | Small |
| **P2.5** | Modern cookie RFC 6265 | — | Small–Medium |
| **P2.6** | localStorage / sessionStorage | P1.3 | Small |
| **P3.1** | CSS Flexbox subset | P1.2 | Large |
| **P3.2** | Promises + async/await | P1.3 | Medium |
| **P3.3** | Fetch API | P1.4, P3.2 | Small |
| **P3.4** | HTTP/3 / QUIC | P0.1, P2.1 | Very Large |
| **P3.5** | Canvas 2D | P1.3 | Medium–Large |
| **P3.6** | AVIF images | P2.2 | Very Large |

**Recommended execution order** for maximum impact per unit effort:

1. P0.3 (UTF-8 default) — trivial, do it immediately.
2. P0.2 (gzip Content-Encoding) — infrastructure exists, small effort.
3. P0.1 (TLS 1.2) — the biggest single unlocker; do as early as possible.
4. P2.4 (`<video>` placeholder) — small effort, prevents crashes/hangs.
5. P2.5 (cookies RFC 6265) — small, improves login compatibility.
6. P2.6 (localStorage) — small, unblocks many SPAs.
7. P1.5 (parallel loading) — medium, dramatic perceived speed improvement.
8. P1.3 (JS ES5) — large, but enables all JS-dependent features.
9. P1.4 (XHR) — medium, follows from P1.3.
10. P1.1 (HTML5 parser) — large, foundational for CSS integration.
11. P1.2 (CSS 2.1) — very large, the longest item; start in parallel with P1.1.
12. P2.2 (WebP) — medium, high visual impact once basic rendering works.
13. P2.3 (WebSockets) — medium, enables live-update sites.
14. P2.1 (HTTP/2) — large, needs TLS; yields performance gains.
15. P3.x — address based on remaining gaps.
