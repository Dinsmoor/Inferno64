# Charon `<canvas>` 3D Context — Wiring Design

Status: **design / not yet implemented.** Depends on the `raylib-limbo` branch
(`$Raster3` + `Raymath`) landing on master. This document is the implementation
plan for adding a 3D rendering context to Charon's `<canvas>`, alongside the
existing 2D context (`appl/charon/domjs.b`).

It is written so the work can be picked up cold: every integration point names a
real file/function as it exists today.

---

## 1. The key insight: the blit path is already done

The 2D canvas (`getContext('2d')`) established the whole retained-render
plumbing. A 3D context reuses **all of it** and only swaps out what happens
*inside* the backing image:

```
                       2D context                3D context
                    ┌────────────────┐        ┌────────────────────────────┐
  JS draw call ───► │ Image.draw/    │        │ Raymath transform (Limbo)  │
  (onload / event)  │ poly/fillpoly/ │   vs   │   → $Raster3.drawmesh (C)  │
                    │ text           │        │   → Image.writepixels      │
                    └───────┬────────┘        └─────────────┬──────────────┘
                            │                               │
                            ▼                               ▼
                    node.canvasim  (ref Draw->Image, retained on the DOM node)
                            │
                            ▼  (unchanged for both contexts)
              layout.b drawline: Icanvas arm → im.draw(rect, canvasim, ...)
```

Everything below the dashed `node.canvasim` line — the retained image on the
node, the `Item.Icanvas` display item, the `canvasbacking()` lazy alloc, the
`drawline` blit, and the re-render survival story — is **already built and
verified**. A 3D context is purely: *produce pixels into `node.canvasim` a
different way.*

Why retained state must live on the node (not in JS, not in the display list):
`havenewdoc`/`makeframeex` rebuild the JS exec context on every re-render, and
`Lay` discards all display items on every re-layout. The DOM node is the only
thing that survives both. The 2D context already relies on this
(`Node.Element.canvasim`, `dom.m:47`); the 3D buffers follow the same rule.

---

## 2. The reference render flow (from `raycube3.b`)

`appl/wm/raycube3.b` on the raylib branch is the canonical
Raymath→Raster3→image pipeline. Per frame it does:

```limbo
raster->clearcolor(pix, W, H, 12, 12, 18);          # bg
raster->cleardepth(zbuf, 1e30);                       # far
# vertex stage in Limbo (Raymath): build screen-space Vtx[] from a mvp matrix
view := Matrix.lookat(eye, target, up);
proj := Matrix.perspective(45.0*DEG2RAD, real W/real H, 0.1, 100.0);
mvp  := model.mul(view).mul(proj);
# ... fill verts[] via projvtx() (NDC→screen, perspective iw) ...
raster->drawmesh(pix, zbuf, W, H, verts, tris, nil, 0, 0, mode, cull);
fbimg.writepixels(fbimg.r, pix);                      # blit byte buffer → image
```

`Raster3.Vtx` is the *post-projection* screen-space vertex (`x,y` pixels,
`z` NDC depth, `iw=1/w_clip`, `u,v`, `r,g,b,a`). Vertex processing stays in
Limbo; only the per-pixel inner loop is C. Buffers are caller-owned Limbo arrays
in `Draw->XRGB32` order, blitted with `Image.writepixels`. (See
`module/raster3.m` and `module/raymath.m`.)

The 3D context wraps exactly this, with `pix`/`zbuf`/`canvasim` living on the
DOM node and the mesh + matrices coming from JS instead of being hard-coded.

---

## 3. File-by-file changes

### 3.1 `appl/charon/dom.m` — node-resident 3D buffers

Add two plain arrays to the `Element` variant, next to `canvasim`. They are
working buffers reused across frames; keeping them on the node means a re-render
(which rebuilds the JS context) does not throw away allocated framebuffers.
**No `Raster3` dependency in `dom.m`** — they are just `byte`/`real` arrays.

```limbo
Element =>
    tag:       string;
    attrs:     list of (string, string);
    canvasim:  ref Draw->Image;     # blit target (see §3.4: now always XRGB32)
    canvaspix: array of byte;       # w*h*4, XRGB32 framebuffer for $Raster3
    canvasz:   array of real;       # w*h depth buffer (smaller == nearer)
```

### 3.2 `appl/charon/layout.b` — make the canvas image XRGB32

`$Raster3` writes `XRGB32` bytes, so the blit target must be `XRGB32`.
The simplest, lowest-risk choice is to allocate **all** canvas images as
`XRGB32` (the 2D Draw ops — `draw`/`poly`/`fillpoly`/`text` — work on any
channel format, so this is transparent to the 2D context; the only cost is a
format conversion on the final `im.draw` blit, which is negligible). This avoids
having to know the context kind at alloc time (the image is allocated during the
*first* layout's paint, before any `getContext` call runs in JS).

`canvasbacking()` (`layout.b:2434`), one-line change:

```limbo
e.canvasim = display.newimage(Rect((0,0),(i.width,i.height)),
    Draw->XRGB32, 0, D->White);     # was: f.cim.chans
```

The `Icanvas` blit arm in `drawline` (`layout.b:2370`) is **unchanged** —
`im.draw` handles the XRGB32→screen conversion.

### 3.3 `appl/charon/domjs.b` — the context object + render

This is the bulk of the work. It mirrors the 2D additions already in the file
(`ctxproto`, `ctxval`, `canvasimof`, the `Domctx.prototype.*` call arms).

**Loads** (in `init`, beside `draw`/`math`):

```limbo
raster: Raster3;
rm:     Raymath;
...
raster = load Raster3 Raster3->PATH;
rm     = load Raymath  Raymath->PATH;
if(rm != nil) rm->init();          # Raymath.init() loads $Math
Vtx: import Raster3;
Matrix, Vector3: import Raymath;
```

**`getContext` kind dispatch** — extend the existing arm
(`domjs.b`, `"Domelem.prototype.getContext"`). The 2D path returns a `Domctx`;
add a 3D kind that returns a `Domgl` host object bound to the same node:

```limbo
"Domelem.prototype.getContext" =>
    kind := argstr(ex, args, 0);
    case kind {
    "webgl" or "experimental-webgl" or "3d" =>
        v = glval(ex, nodeof(ex, this));    # new, parallels ctxval()
    * =>
        v = ctxval(ex, nodeof(ex, this));   # "2d" (existing)
    }
```

`glval` parallels `ctxval` (`domjs.b:437`): make `ES->mkobj(glproto, "Domgl")`,
set `o.host = me`, stash the node index in `@PRIVdomix`. Register `glproto`
methods in `mkprotos` exactly like `ctxproto`.

**Recommended minimal API surface.** A faithful WebGL 1.0 is out of scope
(shaders, GLSL, the full state machine). Mirror instead what the raylib stack
actually does — submit a mesh + a model matrix, rasterize. Honest naming: this
is a small immediate-mode 3D context, advertised under the `webgl` kind for
convenience but **not** spec-conformant.

```
Domgl methods (all on glproto):
  clearColor(r, g, b)          # 0..255; stored as JS props, read at clear()
  clear()                      # clearcolor(pix) + cleardepth(zbuf, 1e30)
  perspective(fovyDeg, near, far)   # sets projection (aspect from canvas w/h)
  lookAt(ex,ey,ez, tx,ty,tz, ux,uy,uz)   # sets view matrix
  loadModel(rot_xyz, trans_xyz)          # sets model matrix (or identity)
  drawMesh(verts, tris, mode)  # verts: flat JS [x,y,z, r,g,b] array;
                               # tris:  flat JS [i0,i1,i2,...] index array
  flush()                      # writepixels + mutated()  (triggers reblit)
```

State (matrices, clear colour) is stored as ordinary JS properties on the
`Domgl` object — survives within one draw call, recomputed each call, same as
`fillStyle` in the 2D context.

**Reading JS arrays into Limbo.** The one genuinely new mechanic. A JS Array is
an `Obj` with a numeric `length` and indexed properties; pull it into a Limbo
`array of real` element by element:

```limbo
jsarray(ex: ref Exec, v: ref Val): array of real
{
    o := ES->toObject(ex, v);
    if(o == nil) return nil;
    n := int ES->toNumber(ex, ES->get(ex, o, "length"));
    a := array[n] of real;
    for(i := 0; i < n; i++)
        a[i] = ES->toNumber(ex, ES->get(ex, o, string i));
    return a;
}
```

This is O(n) `get`s — fine for a spike / a few thousand verts; a later
optimization is to accept the engine's typed-array backing store directly if it
exposes one. (Check `ecmascript.m` for an array fast-path before optimizing.)

**The render method** (the heart — `drawMesh` + `flush`), pulling the buffers
off the node and running the `raycube3.b` flow:

```limbo
glmesh(ex: ref Exec, glo: ref Obj, vflat, iflat: array of real, mode: int)
{
    (n, img) := canvasbufs(ex, glo);   # ensures node.canvaspix/canvasz; returns dims+image
    if(img == nil || raster == nil || rm == nil)
        return;
    w := img.r.dx(); h := img.r.dy();
    pick e := n { Element =>
        pix := e.canvaspix; zbuf := e.canvasz;
        mvp := glmvp(ex, glo, w, h);            # model.mul(view).mul(proj) from stored props
        nv := len vflat / 6;                     # x,y,z,r,g,b per vertex
        verts := array[nv] of Vtx;
        for(k := 0; k < nv; k++){
            b := k*6;
            p := Vector3(vflat[b], vflat[b+1], vflat[b+2]);
            verts[k] = projvtx(p, mvp, vflat[b+3], vflat[b+4], vflat[b+5], w, h);
        }
        tris := array[len iflat] of int;
        for(k := 0; k < len iflat; k++) tris[k] = int iflat[k];
        raster->drawmesh(pix, zbuf, w, h, verts, tris, nil, 0, 0,
            mode, Raster3->CULLNEG);
    }
}
```

`projvtx` is copied from `raycube3.b:114` (NDC→screen + perspective `iw`),
parameterized on `w,h`. `clear()`/`flush()` are thin wrappers over
`raster->clearcolor`/`cleardepth` and `img.writepixels(img.r, pix)` +
`canvasdamaged()` (the cheap repaint signal — see §4). `canvasbufs` lazily
allocates `e.canvaspix = array[w*h*4] of byte` and `e.canvasz = array[w*h] of
real` once the image exists.

### 3.4 Module loads & emu

- `module/raster3.m`, `module/raymath.m` — provided by the raylib branch.
- `$Raster3` is a C builtin; the raylib branch already adds the `raster3` entry
  to `emu/Linux/{emu,emu-g}` and the `libinterp` gen rule. `$Math` (for Raymath)
  is already linked. **No new emu wiring needed** once raylib is merged.
- `Raymath` is pure Limbo (`/dis/lib/raymath.dis`) — built by `make all`.

---

## 4. Animation: both prerequisites now exist

3D's whole point is animation. Its two prerequisites are already in place, so
a 3D context can animate the same way the 2D one does:

1. **Frame clock — DONE.** Charon's JS engine has working
   `setTimeout`/`setInterval`/`clearTimeout`/`clearInterval`
   (`jscript.b`: `addtimeout`/`dotimeout`/`timeout`/`clrtimeout`, dispatched via
   `SEtimeout`/`SEinterval` on `jevchan`). A `setInterval('frame()', ms)` drives
   redraws; JS globals (e.g. a rotation angle) accumulate across ticks because
   the timer path does **not** rebuild the exec context. There is still no
   `requestAnimationFrame` (a thin alias over `setTimeout(~16ms)` would add it),
   but it is not required. Gotcha worth repeating in page code: a timer id can
   legitimately be `0`, so use a separate boolean to track "running", not
   `id != 0` (see `tests/web/fixtures/canvas_anim.html`).

2. **Canvas-damage fast path — DONE.** Canvas-only draws no longer trigger a full
   `domrender`. `domjs.b`'s 2D ops call `canvasdamaged()` (a `canvasdirty`
   callback) instead of `mutated()`; after a handler, `jscript.b` sends
   `Ecanvasrefresh(frameid)` when only a canvas changed (vs `Edomrefresh` for a
   real DOM mutation, which wins if both happened). `charon.b` handles it with
   `L->canvasrefresh(f)` = `f.dirty(f.totalr) + drawall(f)` — repaint from the
   retained layout (`drawall`'s `Icanvas` arm re-blits `node.canvasim`), no
   relayout, no cascade, no item-gen, no exec-context rebuild. **The 3D `flush()`
   reuses this verbatim:** `img.writepixels(img.r, pix)` then `canvasdamaged()`,
   and the spinning mesh repaints cheaply.

   Remaining optimization (not blocking): `canvasrefresh` currently repaints the
   whole frame's retained items (still far cheaper than relayout). A finer path
   would dirty only the canvas item's screen rect — cache that rect on the node
   when `drawline`'s `Icanvas` arm paints it, and dirty just that. Worth doing
   only if a busy page animates a small canvas and the full-frame repaint shows.

---

## 5. Risks & notes

- **JS-context rebuild** is the load-bearing constraint: all retained 3D state
  (image + pix + zbuf) lives on the DOM node, never in the `Domgl` object or
  module globals (both die on re-render). Already true for 2D `canvasim`.
- **Buffer/format coupling:** `canvaspix` must be `w*h*4` `XRGB32` and the image
  must be `XRGB32` (§3.2). If the canvas is resized (width/height attr change
  on re-render), `canvasbufs` must detect the dim change and realloc all three
  (image + pix + zbuf) together.
- **GC pressure:** `drawMesh` allocates `verts`/`tris` per call from the JS
  arrays; reuse scratch arrays on the node if profiling shows churn.
- **Threading:** drawing runs on the JS thread; the blit (`drawline`) runs on
  the layout/draw thread. `writepixels` into the node image then a
  `canvasdamaged()` hand-off (→ `Ecanvasrefresh` → `drawall`) is the existing 2D
  pattern and is safe because the image is the only shared object and the blit
  reads it whole.
- **`CULL` winding** (`CULLNEG`/`CULLPOS`) is empirical per vertex winding — pick
  it the way `raycube3.b` does and expose a flag if pages need both.

---

## 6. Milestones

1. **M0 (prereq):** raylib branch merged; `make all` builds `$Raster3` into emu
   and `raymath.dis` into the tree. Confirm `raycube3`/`rayteapot` run.
2. **M1 — static 3D context:** §3.1–3.4. `getContext('webgl')` →
   `clear`/`perspective`/`lookAt`/`loadModel`/`drawMesh`/`flush`. Fixture:
   a single lit, depth-buffered triangle/cube drawn on load. Verify live on `:3`
   and that 2D canvas still renders (XRGB32 change).
3. **M2 — mesh from JS data:** `jsarray` marshaling; draw a cube/teapot whose
   vertices come from a JS array literal in the page. Extend `tests/web`
   fixtures (a 3D fixture; the headless suites can at least type-check + run the
   marshaling logic).
4. **M3 — animation:** the frame clock (`setInterval`) and the canvas-damage
   fast path (§4) **already exist on master**, so this reduces to a page that
   `setInterval`s a `drawMesh` with an advancing rotation matrix. Spinning cube
   in a page — the payoff, now mostly wiring once M1/M2 land.

---

## 7. Why this is clean

The 2D context already proved the hard parts: retained per-node render state
that survives both re-layout and JS-context rebuild, lazy display-side image
allocation, and the `Icanvas` blit. The 3D context is **additive** — a second
`getContext` kind and a different pixel producer behind the same node image. The
only true new surface area is (a) marshaling mesh data out of the JS engine and
(b) a frame clock + damage-only repaint for animation. Both are isolated and
independently landable.
