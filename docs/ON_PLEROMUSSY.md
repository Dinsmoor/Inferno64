# Pleromussy — a Fediverse (Pleroma/Mastodon-API) client for Inferno

`wm/pleromussy` is a graphical client for the Mastodon client API and its
Pleroma extensions: timelines, notifications, threads, profiles, composing,
the interaction verbs (favourite/boost/bookmark), media viewing, and Pleroma
emoji reactions. It talks HTTPS directly over the in-tree TLS stack — no host
`curl`, no browser engine — and renders into a single Tk text widget. It is on
the wm launcher (`Pleromussy`, from `/lib/wmsetup`).

The API itself is documented separately in
[`ref/pleroma.api.md`](ref/pleroma.api.md) (a digest of all 274 endpoints and
the entity schemas) with the raw OpenAPI in `ref/pleroma.openapi.json`. This doc
is about *the client*: how the two layers are split, the GUI's event model, and
the gotchas that bite.

## The two layers

The client is deliberately split so the network/parsing half can be exercised
headless, with no GUI:

| layer | files | what it owns |
|---|---|---|
| **library** (GUI-free) | [`module/masto.m`](../module/masto.m), [`appl/lib/masto.b`](../appl/lib/masto.b) | transport, OAuth, JSON→ADT parsing, all API verbs, token persistence |
| **GUI** | [`appl/wm/pleromussy.b`](../appl/wm/pleromussy.b) | the Tk toplevel, rendering, async fetches, navigation, dialogs |

Build them with the in-tree compiler (the host has no `limbo` on `PATH`):

```
./Linux/aarch64/bin/limbo -I$PWD/module -gw -o dis/lib/masto.dis      appl/lib/masto.b
./Linux/aarch64/bin/limbo -I$PWD/module -gw -o dis/wm/pleromussy.dis  appl/wm/pleromussy.b
```

or via the mkfiles (`appl/lib/mkfile`, `appl/wm/mkfile` already list both
targets). Command harnesses build to `dis/` and run under emu directly, e.g.
`emu -r$PWD /dis/mastoextra.dis`.

## The library: `Masto`

`Masto` (`/dis/lib/masto.dis`) is a pure-Limbo HTTP/JSON client. An includer
must `include "bufio.m"` and `include "json.m"` *before* `masto.m`, because the
interface names `Bufio->Iobuf` and `JSON->JValue`.

### Transport

`api(c, method, path, query, jbody)` performs one request and returns a `Resp`
(`code`, `body` as an in-memory `Iobuf`, `next` max_id from a `Link:` header,
`err`). It always:

- dials `tcp!<host>!443` through **`Dial->dialtls`** (the mbedTLS `#T` devtls
  path — see [`ON_NETWORK.md`](ON_NETWORK.md) §"Modern TLS"), keeping the TLS
  control fd alive until the body is fully drained;
- writes an HTTP/1.1 request with `Connection: close`, adding
  `Authorization: Bearer <token>` when the `Client` carries one;
- reads the response body honouring **both** `Content-Length` and
  `Transfer-Encoding: chunked`.

`fetchurl(url)` is the no-auth sibling for arbitrary media/avatar URLs: it
follows up to four redirects, handles http and https, and is the one used by the
media viewer. It **soft-retries** (`fetchonce` wrapped in a `FETCHTRIES`=3 loop
with a 250/500 ms backoff): networks drop and TLS handshakes flake, so a failed
fetch is re-attempted. `retryable()` skips retries for permanent failures (a real
4xx, an oversize body, a redirect loop, a bad URL). Crucially, a body that stops
mid-stream is caught: `readn` returns a *truncated* buffer with **no error**, so
`httpfetch` compares the bytes read against `Content-Length` and turns a short
read into a `short read: N of M bytes` error — otherwise a truncated image would
be handed back as success and only fail later at decode, with no retry.

> **Follow-up (not done):** true *partial resume* (HTTP `Range:` requests to
> continue from the byte we stopped at) and short-read detection for the
> `Transfer-Encoding: chunked` path. Current behaviour re-fetches the whole body,
> which is fine for images but wasteful for large media.

> **OOM guard (download).** Both readers enforce a `MAXBYTES` cap (25 MB). A
> whole-video download once exhausted emu's memory and blanked the screen with no
> core; `httpfetch` now pre-checks `Content-Length`, the chunked reader caps
> mid-loop, and `readcapped` collects fixed 16 KB chunks into a list and joins
> **once** (no O(n²) reallocation). Never remove these caps.
>
> **OOM guard (decode).** A *compressed* image under the 25 MB cap can still
> decode to far more — a 4000×3000 photo is 48 MB of RGBA, which overflows the
> Dis heap's main arena (~32 MB, `emu/port/alloc.c`; raisable with
> `emu -pmain=<bytes>`) → `arena main too large` + a failed decode. So the media
> viewer decodes via **`Imageio->decodefit(data, MAXIMGW, MAXIMGH)`**, which
> downscales a large source **in C** (stb_image_resize2) before the pixels ever
> reach the Dis heap — only the reduced image is allocated there. Decoding then
> downscaling in Limbo (the old `fit()`) can't help: the full-resolution buffer
> has to exist first.

### OAuth and persistence

`login(c, user, pass, scope)` does `registerapp` (POST `/api/v1/apps`) + the
resource-owner password grant (`passwordlogin`, POST `/oauth/token`) in one
step and returns a `Session` (token + the app's client_id/secret). Persist it
with `savesession`; reload with `loadsession`. The store is JSON at
**`/usr/<user>/lib/pleromussy/<host>.json`**, mode 0600, the directory created
on demand (`<user>` from `/dev/user`). The token is a credential: never echo it,
log it, or place it on a command line.

### Verbs

`instance`, `verifycredentials`, `publictimeline`, `hometimeline`,
`accountstatuses`, `getaccount`, `getstatus`, `statuscontext` (thread:
ancestors + descendants), `notifications`, `poststatus`, and `statusaction`
(favourite/unfavourite/reblog/unreblog/bookmark/unbookmark → the updated
`Status`). Timeline verbs return `(statuses, next_max_id, err)`; the `next` is
parsed from the RFC 5988 `rel="next"` `Link:` header for pagination.

### Pleroma emoji reactions

The one Pleroma-specific extension wired in (the rest are deferred — see below):

- `statusreactions(c, id)` → list of `Reaction` (`name`, `count`, `me`) — GET
  `/api/v1/pleroma/statuses/<id>/reactions`.
- `react(c, id, emoji)` → PUT `.../reactions/<emoji>`; `unreact` → DELETE. The
  emoji travels in the path (url-encoded), so a unicode emoji works as-is; both
  return the updated `Status`.

`Status.reactions` is also populated by `mkstatus` from the nested
`pleroma.emoji_reactions` array, so any status carries its reactions without an
extra request. On a vanilla Mastodon server these fields are simply absent and
the list is nil — the GUI renders nothing.

### Parsers

`mkaccount`/`mkstatus`/`mknotification`/`mkreaction` build the ADTs from
`JValue`s defensively: every field goes through `jstr`/`jint`/`jbool`, which
tolerate missing, null, or wrong-typed JSON. FlakeID ids are **strings** — never
parse them to int.

## The GUI: `wm/pleromussy`

A single `tkclient` toplevel with a `text` widget (`.view.t`) as the whole feed.
Text is tagged for both *style* and *hit-testing*:

- **style tags** — `NAME`, `META`, `BODY`, `MEDIA`, `BTN` (inline action
  buttons), `RXN`/`RXME` (reaction chips), `POST` (per-card margins/spacing),
  `SEP` (separator rule), `SEL` (selection highlight).
- **hit tags** — `s<i>` over a whole post block, `b<i>_<code>` over each inline
  action button, `r<i>_<j>` over each reaction chip, `med<i>_<j>` over each
  media line. A click runs `.view.t tag names @x,y` and dispatches on the first
  hit tag found (priority: media → reaction → button → select).

### Inline emoji images

No shipped Inferno font covers the emoji blocks — `lucidasans/unicode` stops at
U+FB1E — so a raw emoji renders as a missing-glyph box. Emoji are therefore
drawn as **small inline images**, not text. A curated single-codepoint subset of
the [twemoji](https://github.com/jdecked/twemoji) 72×72 PNGs is vendored under
`/icons/emoji` (CC-BY 4.0; see `icons/emoji/ATTRIBUTION`), refreshable with
`tools/emoji/fetch-twemoji.py`. The filename is the twemoji convention —
lowercase hex codepoint(s) joined by `-`, the U+FE0F variation selector dropped
(`emojiname()` reproduces it).

The mechanism, reusable for any inline image (avatars/media are the obvious next
consumers):

- `emojiimage(s)` maps an emoji string to a decoded Draw image, memoised by
  filename (the nil "no asset" result is cached too — a missing emoji is looked
  up once). It reads the local PNG and decodes via `$Imageio` (stb).
- `emojiscale` area-averages the 72px source down to `EMOJIPX` (16) with
  **alpha-weighted** colour — nearest-neighbour (`fit()`) looks jagged and
  transparent pixels would otherwise drag edges toward black.
- `emojipanel(img, bg, i, j)` creates a `panel` child of the text widget,
  embeds it inline with `.view.t window create {end -1c} -window <panel>`
  (Inferno's text widget supports embedded sub-widgets; the widget must be a
  descendant of `.view.t`), tints its background to the chip colour, and fills
  it with `tk->putimage(window, panel, img, img)` — the image doubles as its own
  matte so its alpha composites over the panel background.
- A click on an embedded panel does **not** reach `.view.t`'s tag hit-test, so
  each panel binds `<Button-1>` to send `"<i> <j>"` on the `rtog` channel, which
  toggles that reaction. The reaction chip's count stays as `r<i>_<j>`-tagged
  text, so it is clickable the ordinary way too.
- Embedded panels are real widgets that the text-widget rebuild does *not*
  destroy; `emojipanels` tracks them and `destroyemojipanels()` runs at every
  rebuild (right after `.view.t delete 1.0 end`) or they leak.

The **React…** picker (`reactpicker`) is a spawned child toplevel — a `grid` of
the same emoji image panels (a popup menu can only show text, i.e. boxes). It is
spawned, not inline, so the feed stays live; it delivers `(target, emoji)` on
`pickresult`, with `""` on Escape/close.

### Async model

Every network call runs in a spawned proc and delivers its result on a channel
that the main `alt` loop selects over: `results`, `notifresults`,
`threadresults`, `profresults`, `postresult`, `actionresult`, `reactresult`.
The UI thread never blocks on the network.

**Navigation generation (`navgen`).** Timeline and notifications results are
guarded by `curview` (a late page can't clobber a different view). But thread
and profile fetches *transition* into a new view, so they can't be guarded that
way. Instead each carries the `navgen` it was issued under; the handler drops a
result whose `gen != navgen` (the user navigated away while it was in flight).
Bump `navgen` on every view change.

**Back history.** `history` is a stack of `Snap` — a full snapshot of one view's
backing state (statuses/notifs/threadarr/profarr/selection/nextid). Navigating
pushes the current view; Back pops and restores it verbatim, with **no
server re-fetch**. Because `Snap` holds the same `Status` refs, in-place
interaction toggles survive a round-trip through history.

**Scroll preservation.** "More posts" appends an older page and rebuilds the
widget. To avoid snapping to the top, it captures `.view.t index @0,0` before the
rebuild and restores it with `.view.t yview <index>` after (valid because
appended posts go at the *end*, so existing line indices stay put).

### Interaction model

- **Inline buttons** (fav/boost/reply/⋯) act directly on their post — no
  select-then-act step. Fav/boost/bookmark are **optimistic**: toggle locally,
  re-render, then reconcile against the server's authoritative `Status` (or
  revert on failure).
- **Double-click** a post body opens its thread.
- **Right-click** posts a context menu (Reply / Favourite / Boost / React… /
  Bookmark / View thread / View profile / Copy link). Reactions are
  **non-optimistic**: ask the server, then adopt its returned reaction list
  (simpler and race-free; reactions are lower-frequency than fav).
- **Reaction chips** under a post are clickable (both the emoji image and its
  count): a click toggles your own reaction with that emoji. "React…" opens the
  image emoji picker (see *Inline emoji images*).

> **Context-menu idiom: press-drag-release.** A wm menu posts on button
> **press**, so the per-post menu binds `<Button-3>` press; the user holds,
> drags onto an item, and releases to invoke. A toolbar button's `-command`
> fires on *release*, which is too late for press-drag — that's why menus are
> posted from the press binding, not a `-command`. `runmenu` posts the popup and
> then runs a **synchronous nested event pump** (`pumpmenu`) on the main proc,
> because the popup's grab needs the window's kbd/ptr events fed to it (cf.
> `wm/ftree`'s `post()`). Do not move this to a side proc blocking on the result
> chan. (The emoji picker is *not* a popup menu — it's a spawned toplevel — so it
> does not use this idiom.)

### Child windows

Login, compose, and the media viewer are each their own toplevel with their own
event loop. Their result channels are **buffered `chan[1]`** so a helper proc
(`dologin`/`dopost`/`loadmedia`) can deliver-and-exit even if the user closed
that child mid-operation (an unbuffered send would block forever and leak the
proc).

## Gotchas

- **`cs` bootstrap.** A bare/`wm` emu has no `/net/cs` at app start, so `dialtls`
  fails with "invalid IP address". `ensurecs()` loads `/dis/ndb/cs.dis` and
  polls `/net/cs` before any fetch. If `cs` is already a boot service, it's a
  no-op.
- **Anonymous public timeline may 401.** Some instances (e.g. nicecrew.digital)
  restrict the unauthenticated public timeline; anonymous use then needs a token
  anyway. The app opens the login dialog automatically when no session is saved.
- **Hang on close.** The main loop must delegate *every* wm request — including
  `"exit"` — to `tkclient->wmctl(window, s)`. `wmctl("exit")` writes `killgrp`
  to `/prog/<pid>/ctl`, reaping the whole proc group (the `cs` daemon, in-flight
  fetch procs, child windows, and the wm input-demux proc). A bare `return` here
  leaves those alive, the window's input channels stop draining, and the wm demux
  proc wedges → freeze. Child windows do the opposite: they `return` on `"exit"`
  (they must **not** killgrp, or they'd take the whole app down).
- **`Iobuf` is the handle.** In the lib, `Iobuf: import bufio` (the handle), not
  `Bufio` (the module type), or the read methods won't resolve.
- **`tkcmd` doesn't repaint.** Setting a label's text doesn't force a redraw;
  append `"; update"` (or a separate `update`) when a status label must change
  immediately.

## Deferred Pleroma extras

`react`/`unreact` are in; the heavier Pleroma extensions are **not** yet
implemented and are the natural next slice:

- **Chats** (`/api/v1/pleroma/chats`) — a 1:1 messaging surface; needs its own
  list+thread UI, distinct from the timeline.
- **Bookmark folders** (`/api/v1/pleroma/bookmark_folders`) — folder CRUD plus a
  `folder` parameter on the bookmark action.
- Scrobbles, backups, emoji packs — lower priority.

Add new verbs to `masto.b`/`masto.m` first (headless-testable via a `cmd`
harness like `appl/cmd/mastoextra.b`), then wire the GUI.

On the GUI side, **inline avatars and media thumbnails** are the obvious next
step now that the inline-image mechanism exists (see *Inline emoji images*):
embed a `panel` per avatar/thumbnail and `tk->putimage` a decoded image. The one
extra concern over emoji is that those images are **remote** — decode must be
async (a spawned fetch like `loadmedia`, not the synchronous local-file read
emoji use) with a per-URL cache and a fixed placeholder size so layout doesn't
jump, and a generation guard so a late decode doesn't paint into a destroyed
panel. Do **not** reach for `$Raster3`/raylib — that is a software *3D*
rasteriser; 2-D image display is `$Imageio` (stb) decode → Draw image →
`tk->putimage` into a panel, which is all already in tree.

## Testing

The library is verified headless with `cmd` harnesses that load a saved session
and exercise verbs without a GUI:

- `appl/cmd/mastotest.b` — anonymous fetch.
- `appl/cmd/mastologin.b` — login + persist + smoke-fetch (reads the password
  from a **file**, never argv).
- `appl/cmd/mastoextra.b` — notifications/thread/profile + a reaction read and a
  self-react/unreact round-trip that cleans up after itself.

GUI testing is done by a human at the wm (drive it, don't script long xdotool
sessions). Use `Xvfb :7` for screenshots if a headless desktop is needed — never
`:3` (shared). Liveness is judged by pixels: emu's pthread leader thread
legitimately shows `Zl`/`<defunct>` in `ps`.
