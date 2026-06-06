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

See also: [AGENTS_GRAPHICS.md](AGENTS_GRAPHICS.md) (Draw/Tk/wm — including how to
host a software-rendered animated frame in a window), [AGENTS_LIMBO.md](AGENTS_LIMBO.md)
(language; mind the reserved words), [AGENTS_DIS.md](AGENTS_DIS.md) (why C kernels).

---

## Components

| Module | Kind | Files | Purpose |
|--------|------|-------|---------|
| `Raymath` | pure Limbo | `module/raymath.m`, `appl/lib/raymath.b` | Vector2/3/4, 4×4 Matrix, quaternions, easings. Mechanical port of raylib `raymath.h`. Backed by `$Math`. |
| `Raster3` | **C builtin** | `module/raster3.m`, `libinterp/raster3.c` | Per-pixel rasterizer + z-buffer, and the C vertex stage. The one focused C effort. |
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

## $Raster3 (the C kernel)

`module/raster3.m` declares the builtin `PATH: con "$Raster3"`. All buffers are
**caller-owned Limbo arrays** — there is no Memimage/devdraw coupling; you blit
the result yourself with `Image.writepixels`.

```limbo
Vtx: adt {                  # a vertex already projected to screen space
    x, y: real;             # screen pixel coordinates
    z:    real;             # depth (NDC z); smaller is nearer
    iw:   real;             # 1/w_clip, for perspective-correct interpolation
    u, v: real;             # texture coordinates 0..1
    r, g, b, a: real;       # colour 0..1
};

cleardepth:  fn(zbuf: array of real, val: real);                  # use 1e30
clearcolor:  fn(pix: array of byte, w, h, r, g, b: int);          # 0..255
drawmesh:    fn(pix: array of byte, zbuf: array of real, w, h: int,
                verts: array of Vtx, tris: array of int,
                tex: array of byte, tw, th: int, mode, cull: int);
projectmesh: fn(out: array of Vtx, pos, nrm, uv: array of real, nv: int,
                mvp, nmat: array of real, w, h: real,
                light: array of real, ambient: real, base: array of real);
```

- **modes**: `FLAT` (vertex-a colour), `GOURAUD` (interpolated), `TEXTURED`
  (perspective-correct texture modulated by colour). **cull**: `CULLNONE`,
  `CULLNEG`/`CULLPOS` (by signed screen area — pick per winding).
- `drawmesh` is an edge-function rasterizer with a per-pixel z-buffer (smaller =
  nearer; z is NDC z, screen-linear). Texturing is perspective-correct via `iw`.
- `projectmesh` runs the **entire vertex stage in C**: model→clip transform,
  perspective divide, viewport map, and optional directional Gouraud shading,
  filling the `Vtx` array in one call. Pre-pack model-space `pos`/`nrm` into flat
  `array of real` once (3 reals/vertex); pass `mvp`/`nmat` as the 16-real
  `Matrix.m`. Normals are used **un-renormalised** (faithful to `Vector3.transform`
  + dot shading), so `nmat` must be a rotation and input normals unit.

### Pixel format (critical)

The framebuffer is **XRGB32**: 4 bytes/pixel in memory order **B, G, R, X**
(the word `X<<24 | R<<16 | G<<8 | B` that `win-x11a.c` expects on a little-endian
host). Allocate the destination Draw image with `Draw->XRGB32` and blit with
`Image.writepixels`. The depth buffer is one `real` per pixel. (Derived from
`win-x11a.c`; it was correct first try — if red/blue ever swap, flip the B/R
store order in `raster3.c`.)

### Locking model

`raster3.c` holds the VM lock for the whole call: it only reads/writes
caller arrays already on the heap, never allocates and never re-enters Dis, so
the arrays cannot move under it. **No `release()`/`acquire()`** — that pattern is
for long C calls that might block or call back into the VM (see FreeType/mbedTLS);
it would be *wrong* here because we hold raw pointers into Limbo arrays.

---

## The pipeline

1. Load/parse mesh (Objloader, Limbo). Centre + uniformly scale to ~[-1,1].
2. Per frame: build `mvp = model·view·proj`; `projectmesh` (C) → `Vtx[]`.
3. `clearcolor` + `cleardepth`, then `drawmesh` (C) into the `pix`/`zbuf` arrays.
4. `writepixels` the XRGB32 `pix` into a Draw image; blit to the window.

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

## Build wiring (builtin-module checklist)

`$Raster3` follows the FreeType/mbedTLS builtin precedent:
- `module/raster3.m` (`PATH: con "$Raster3"`) and an include in `module/runt.m`.
- `libinterp/raster3.c` with `raster3modinit()` → `builtinmod("$Raster3", …)`.
- `libinterp/mkfile`: add `raster3.$O` to OFILES, a `raster3mod.h` gen rule
  (`limbo -t Raster3`), the `.c → mod.h` dependency, `GENHFILES`, and nuke.
  (`raster3mod.h` is generated — gitignored, not checked in.)
- `emu/Linux/emu` and `emu/Linux/emu-g`: add `raster3` to the `mod` section
  (regenerates `emu/Linux/emu.c`).

`make all` force-regenerates all generated module headers per-ABI, so a 32↔64
ABI switch can't leave a stale `raster3mod.h`.

### Gotchas

- **Reserved words** bit this port repeatedly: `fn`, `load`, `tl`, `hd` are Limbo
  keywords and **cannot be identifiers**. (`readobj` not `load`, `tlist` not `tl`,
  `fnorm`/`dfar` not `fn`.) See AGENTS_LIMBO.md — there is a per-turn reminder hook
  in `.claude/`.
- A bare boot module that returns makes `emu` exit 137/SIGKILL — harmless; for
  `raytest`, grep the printed `PASS n/n`, don't check the exit code.

---

## Testing

- `appl/cmd/raytest.b` — headless self-test, **PASS 15/15**: Raymath identities
  (I·T, invert, cross/dot/length/normalize, rotate preserves length, lookat) and
  `$Raster3` z-buffer behaviour (near-over-far, far-rejected), plus a check that
  `projectmesh` (C) reproduces the Limbo `transformp` path numerically.
  Run: `emu /dis/raytest.dis`.
- `make test_all_unit` (cunit) covers the underlying libs.
- Visual: `wm/rayteapot` (menu: Games → Teapot (3D)); `wm/raycube`, `wm/raycube3`.
