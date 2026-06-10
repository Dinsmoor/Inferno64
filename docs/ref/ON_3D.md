# 3D / raylib-in-Limbo: Raymath, $Raster3, Objloader

A software 2D/3D graphics stack layered on Inferno's native Draw, ported from
raylib's feature set. **It is a Limbo port over Draw, not an FFI binding.**
Design rationale: native desktop integration (composites into `wm/wm`), no
GLFW/GL/X host dependencies, GC'd, and identical on every emu host (the Inferno
philosophy). Trade-off: software-only, no GPU/shaders.

The one hard constraint is that Dis is a bytecode VM (~10–50× slower than C), so
per-pixel and per-vertex loops in pure Limbo are too slow for real-time 3D. The
resolution is **hybrid**: the hot rasterizer and vertex kernels are **C** (the
`$Raster3` builtin); the API, math, and asset parsers are **Limbo**.

See also: [ON_GRAPHICS.md](ON_GRAPHICS.md) (Draw/Tk/wm — including how to
host a software-rendered animated frame in a window), [ON_LIMBO.md](ON_LIMBO.md)
(language; mind the reserved words), [ON_DIS.md](ON_DIS.md) (why C kernels),
[ON_IMAGEIO.md](ON_IMAGEIO.md) (decoding PNG/JPEG/… into textures via stb).

---

## Components

| Module | Kind | Files | Purpose |
|--------|------|-------|---------|
| `Raymath` | pure Limbo | `module/raymath.m`, `appl/lib/raymath.b` | Vector2/3/4, 4×4 Matrix, quaternions, easings. Mechanical port of raylib `raymath.h`. Backed by `$Math`. |
| `memmesh` | **C, libmemdraw** | `libmemdraw/mesh.c` | The native primitive: triangle fill + per-pixel z-buffer + the vertex stage, writing into any `Memimage`. Portable (hosted + native os/). |
| `drawmesh3` | **C, devdraw** | `emu/port/devdraw.c` | Thin bridge: resolves a Draw image id → `Memimage`, takes the draw qlock, calls `memmesh`. |
| `Raster3` | **C builtin** | `module/raster3.m`, `libinterp/raster3.c` | Limbo face: marshals args, calls `drawmesh3`/`memmeshproject`. Renders straight into a Draw image. |
| `Objloader` | pure Limbo | `module/objloader.m`, `appl/lib/objloader.b` | Wavefront `.obj` reader (v/vt/vn, fan-triangulation, smooth normals, bbox). |
| demos | Limbo | `appl/wm/raycube.b`, `raycube3.b`, `rayteapot.b`; `appl/cmd/raytest.b` | cube (painter), interpenetrating cubes (z-buffer), teapot viewer (windowed), headless self-test. |

`lib/models/teapot.obj` — the Utah teapot (3644 verts / 6320 tris), bundled for
testing both the loader and the renderer (`*.obj` is gitignored; it was
`git add -f`'d).

---

## Raymath

ADTs `Vector2/3/4` carry `real` fields by value with methods (`add`, `sub`,
`scale`, `dot`, `cross`, `normalize`, `length`, `transform`, `transformp`, …).
`Matrix` is `m: array of real` of length 16, **layout-compatible with raylib**
(`Matrix.m[i] == raylib mi`), so it can be handed straight to the C kernel.

Conventions (must match across Limbo and C):
- `Matrix.mul(a, b)` == raylib `MatrixMultiply` (i.e. B·A in math order).
- Build MVP as `model.mul(view).mul(proj)`.
- Transform a point: `v.transform(mat)` (the vector transforms *itself* by the
  matrix). `transformp` returns `(Vector3, w_clip)` for the perspective divide.
- Index layout: `x = m[0]*vx + m[4]*vy + m[8]*vz + m[12]` (and 1,5,9,13 / 2,6,10,14
  / 3,7,11,15 for y/z/w). Any C that touches matrices must use this exact layout.

Call `rm->init()` once after loading (it loads `$Math`).

---

## Architecture: a native draw primitive (not a side kernel)

The rasterizer **extends the native draw system**: `memmesh` is a libmemdraw
primitive that writes directly into a Draw image's `Memimage` pixel store, in
that image's own channel order — no intermediate framebuffer, no XRGB32 array,
no manual blit. This makes it reusable (any consumer, including Charon's
`<canvas>`, can rasterize into its own node image) and native-capable.

Three layers:
- **`libmemdraw/mesh.c`** — `memmesh(dst, zbuf, verts, nv, idx, ntri, tex, mode,
  cull)` and `memmeshproject(...)`. Portable C; the actual per-pixel and
  per-vertex math. Writes any 8-bit-channel image (RGB24/XRGB32/RGBA32/BGR…).
- **`emu/port/devdraw.c` `drawmesh3`** — resolves `(client path, image id) →
  Memimage` exactly like `drawlsetrefresh`, takes the draw qlock (`sdraw.q`), and
  calls `memmesh`. The interface is primitive C types only, so no header coupling.
- **`libinterp/raster3.c`** — the `$Raster3` builtin (`PATH: con "$Raster3"`).
  Marshals Limbo args: `checkimage(dst)` → libdraw `Image*` → `(display->dataqid,
  id)` → `drawmesh3`; `projectmesh` calls `memmeshproject` directly.

```limbo
Vtx: adt {                  # a vertex already projected to screen space
    x, y: real;             # image-LOCAL pixel coordinates (0,0 == image min)
    z:    real;             # depth (NDC z); smaller is nearer
    iw:   real;             # 1/w_clip, for perspective-correct interpolation
    u, v: real;             # texture coordinates 0..1
    r, g, b, a: real;       # colour 0..1
};

cleardepth:  fn(zbuf: array of real, val: real);                  # use 1e30
drawmesh:    fn(dst: ref Draw->Image, zbuf: array of real,
                verts: array of Vtx, tris: array of int,
                tex: ref Draw->Image, mode, cull: int);
projectmesh: fn(out: array of Vtx, pos, nrm, uv: array of real, nv: int,
                mvp, nmat: array of real, w, h: real,
                light: array of real, ambient: real, base: array of real);
```

There is no `clearcolor` — clear the destination with ordinary Draw
(`img.draw(img.r, colour, nil, (0,0))`). `drawmesh` reads `w,h` from `dst.r`;
the depth buffer is one `real` per pixel of `dst.r` (`Dx*Dy`, or nil to skip the
depth test).

- **modes**: `FLAT` (vertex-a colour), `GOURAUD` (interpolated), `TEXTURED`
  (perspective-correct texture, the texture is itself a Draw image). **cull**:
  `CULLNONE`, `CULLNEG`/`CULLPOS` (by signed screen area — pick per winding).
- `projectmesh` runs the **entire vertex stage in C**: model→clip transform,
  perspective divide, viewport map, optional directional Gouraud shading. Pre-pack
  model-space `pos`/`nrm` into flat `array of real` once (3 reals/vertex); pass
  `mvp`/`nmat` as the 16-real `Matrix.m`. Normals are used **un-renormalised**
  (faithful to `Vector3.transform` + dot shading), so `nmat` must be a rotation.
- `dst` must be an **off-screen image** (not a live window/layer); render into it,
  then blit it to your window (the usual double-buffer). `Memvtx` in `memdraw.h`
  is laid out identically to the Limbo `Vtx` (10 doubles) so the array passes
  straight through.

### Pixel format

`memmesh` writes in the destination's own channel order, derived from its `chan`
descriptor (`shift[t]/8` = byte offset of channel `t`, little-endian). Any
8-bit-byte-aligned format works — RGB24, XRGB32, RGBA32, ABGR32, BGR24, GREY8;
non-8-bit formats (e.g. RGB16) are rejected. The depth buffer is one `real` per
pixel. (The old code hard-coded XRGB32 B,G,R,X; that is now just one of the
cases this derives automatically.)

### Locking / ordering model

`drawmesh3` runs under the draw qlock (`sdraw.q`), the same lock every draw op
holds, so it serializes with compositing/flush. The VM lock is held throughout
(we point into caller-owned Limbo arrays — no `release()`/`acquire()`, which
would let the GC move them).

**The ordering gotcha:** Limbo Draw ops are *buffered* and flushed lazily, but
`memmesh` writes the Memimage *immediately*. So `Raster3_drawmesh` first calls
`flushimage(dst.display, 0)` (under `lockdisplay`) to apply any pending ops — e.g.
the background clear queued just before — *before* it rasterizes. Without that
flush the clear lands on top of the mesh and you get a blank image (debugged the
hard way: the direct write was correct but `readpixels` saw black).

---

## The pipeline

1. Load/parse mesh (Objloader, Limbo). Centre + uniformly scale to ~[-1,1].
2. Allocate an off-screen Draw image + a `real` depth buffer sized to it.
3. Per frame: build `mvp = model·view·proj`; `projectmesh` (C) → `Vtx[]`.
4. Clear the image with native Draw + `cleardepth`, then `drawmesh` (C) writes
   straight into the image's pixels; blit the image to the window (or hand it to
   `<canvas>`).

**Painter's vs z-buffer.** A single convex solid (e.g. one cube) can skip the
z-buffer entirely: sort faces by view-space depth and `fillpoly` with native
Draw (`raycube.b` — no C needed). General/interpenetrating geometry needs the
per-pixel z-buffer (`raycube3.b`, `rayteapot.b` via `$Raster3`).

---

## Performance

The bottleneck was never the math — it was running the per-vertex loop as Dis
bytecode with a short-lived heap allocation per vertex per frame. Moving the
vertex stage into C (`projectmesh`) took the teapot from single-digit fps to
**~4 ms/frame compute (~250 fps raw)**, bounded only by the frame sleep.
Rasterization (C) was already fast. The remaining one-time cost is the Limbo OBJ
parse. **Rule of thumb: any per-pixel or per-vertex loop belongs in C; keep
setup, control flow, and asset I/O in Limbo.**

---

## Build wiring

The native primitive + bridge:
- `libmemdraw/mesh.c` → add `mesh.$O` to `COMMONFILES` in `libmemdraw/mkfile`
  (portable, so the common list). Declares `Memvtx`/`memmesh`/`memmeshproject`
  in `include/memdraw.h`.
- `emu/port/devdraw.c` `drawmesh3`, declared in `include/draw.h` next to
  `drawlsetrefresh` (the precedent for a devdraw function libinterp calls).

The `$Raster3` builtin follows the FreeType/mbedTLS precedent:
- `module/raster3.m` (`PATH: con "$Raster3"`) and an include in `module/runt.m`.
- `libinterp/raster3.c` with `raster3modinit()` → `builtinmod("$Raster3", …)`;
  it includes `<draw.h> <drawif.h> <memdraw.h>` for `checkimage`/`Memvtx`.
- `libinterp/mkfile`: `raster3.$O` in OFILES + the `raster3mod.h` gen rule
  (`limbo -t Raster3`) + dep + `GENHFILES` + nuke. (`raster3mod.h` is generated,
  gitignored. The `F_*`/`Raster3_Vtx` structs are emitted into `runt.h` because
  raster3.m is in `runt.m`.)
- `emu/Linux/{emu,emu-g}`: `raster3` in the `mod` section.

`make all` force-regenerates all generated module headers per-ABI, so a 32↔64
ABI switch can't leave a stale `raster3mod.h`.

### Gotchas

- **Reserved words** bit this port repeatedly: `fn`, `load`, `tl`, `hd` are Limbo
  keywords and **cannot be identifiers**. (`readobj` not `load`, `tlist` not `tl`,
  `fnorm`/`dfar` not `fn`.) See ON_LIMBO.md — there is a per-turn reminder hook
  in `.claude/`.
- A bare boot module that returns makes `emu` exit 137/SIGKILL — harmless; for
  `raytest`, grep the printed `PASS n/n`, don't check the exit code.

---

## Testing

- `appl/cmd/raytest.b` — self-test, **PASS 24/24**: Raymath identities (I·T,
  invert, cross/dot/length/normalize, rotate preserves length, lookat), `$Imageio`
  decode of an embedded 2×2 RGBA PNG, a check that `projectmesh` (C) reproduces the
  Limbo `transformp` path numerically, `$Raster3` z-buffer behaviour (fills,
  near-over-far, far-rejected), and a perspective-correct **textured** quad from an
  `ABGR32` texture. `init` hard-requires `$Raster3` and `$Imageio` (it `raise`s
  `fail:load` if either is missing), so **it does not run under `emu-g`** — that
  headless build drops `raster3` from its module list. The raster checks rasterize
  into a real Draw image and read it back, so they need a display: run
  `emu -g320x240 /dis/raytest.dis`. With no usable display, `Display.allocate(nil)`
  returns nil and the raster/texture checks self-skip — the Raymath, `$Imageio`,
  and `projectmesh` checks still run. Verified `PASS 24/24` on Linux/aarch64
  against an Xvfb display.
- `make test_all_unit` (cunit) covers the underlying libs.
- Visual: `wm/rayteapot` (menu: Games → Teapot (3D)); `wm/raycube`, `wm/raycube3`.
