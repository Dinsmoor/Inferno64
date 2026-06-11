# Image decoding: $Imageio, Imageload, and vendored stb

> *So you want to decode an image into a Draw image?* This is the reference.

Native decoding of common image formats (PNG, JPEG, BMP, TGA, GIF, PSD, HDR,
PIC, PNM) into Draw images, backed by the vendored **stb** single-header
libraries. Use this when you need a real raster image *inside* Inferno (a
texture for `$Raster3`, an `<img>`/`<canvas>` bitmap for Charon, a sprite for a
wm app) without host-side conversion.

There is also a pure-Limbo decoder family (`RImagefile`: `appl/lib/readpng.b`,
`readjpg.b`, `readgif.b`, …) — fine for simple cases, but `imageremap` only
targets the legacy 8-bit CMAP8 cube. `$Imageio` gives you true-colour RGBA in
one call and is the path the 3D texture work uses.

See also: [ON_STB.md](ON_STB.md) (the full vendored stb suite — what else
is available and where it's useful), [ON_3D.md](ON_3D.md) (`$Raster3`
textures consume these images), [ON_GRAPHICS.md](ON_GRAPHICS.md) (Draw
channels), [ON_LIMBO.md](ON_LIMBO.md) (reserved words).

---

## Layers

| Layer | Kind | Files | Purpose |
|-------|------|-------|---------|
| stb | vendored C | `libstb/stb/` (all upstream single-headers + LICENSE; commit pinned in `UPSTREAM_COMMIT`) | The codecs. Plain ISO C. |
| `stbwrap` | C, libstb | `libstb/stbwrap.c` → `libstb.a` | The ONLY translation unit that pulls in stb `*_IMPLEMENTATION`, behind a tiny Inferno-free C API. Must NOT include `lib9.h`. |
| `$Imageio` | C builtin | `module/imageio.m`, `libinterp/imageio.c` | Limbo face: `decode(data): (w, h, rgba, err)` and `encode(w, h, rgba): (png, err)`. Graphics-free (no Draw/Memimage dependency) — works in raw RGBA8 bytes. |
| `Imageload` | pure Limbo | `module/imageload.m`, `appl/lib/imageload.b` | Convenience: `read`/`readfile` → a ready `ref Draw->Image`. |

This mirrors the libmbedtls vendoring exactly (vendored upstream tree, built
with the Inferno `$CC` as one static lib, leaf C that never sees `lib9.h`).

## The key fact: RGBA8 == Draw ABGR32

`$Imageio.decode` always returns 8-bit **RGBA**, top-to-bottom, byte order
`R,G,B,A` per pixel (stb is forced to 4 channels). That byte layout is exactly
Draw's **`ABGR32`** = `CHAN4(CAlpha,CBlue,CGreen,CRed)` (last channel in the
macro is the lowest address ⇒ `R` at offset 0). So `Imageload.read` builds the
image with a single `writepixels` and **no per-pixel reordering**:

```limbo
img := display.newimage(r, draw->ABGR32, 0, draw->Black);
img.writepixels(img.r, rgba);
```

`memmesh` (the `$Raster3` kernel) samples any 8-bit channel order via
`chanoff()`, so an `ABGR32` texture Just Works as the `tex` argument.

`BGR24`/`ABGR32`/`XBGR32` were added to `module/draw.m` (they already existed in
the C `include/draw.h`); the Limbo `Draw` module had only declared up to
`XRGB32`.

## Usage

```limbo
include "draw.m";   # MUST precede imageload.m (for Draw->Display/Image)
include "imageload.m";
    imageload: Imageload;

imageload = load Imageload Imageload->PATH;
(img, err) := imageload->readfile(display, "/lib/models/teapot_tex.png");
# or imageload->read(display, bytes) for in-memory data
```

`$Imageio` can also be used directly (`load Imageio Imageio->PATH; decode(data)`)
when you want the raw bytes — e.g. Charon decoding into a canvas node image.

**Encoding (RGBA8 → PNG):** `encode(w, h, rgba): (array of byte, string)` is the
inverse, backed by `stb_image_write` (`stbwrap_encode_png`, memory callback — no
host file IO). Input is the same `R,G,B,A` top-to-bottom layout `decode` produces,
so a Draw `ABGR32` image's `readpixels` bytes encode directly. Used by
`tests/jitperf/stft.b` to write a spectrogram PNG. Only PNG is wired today
(stb_image_write can also do BMP/TGA/JPG/HDR — see [ON_STB.md](ON_STB.md)).

## Gotchas (learned the hard way)

- **A library that calls Draw *methods* must `load Draw` itself.** `Imageload`
  uses `display.newimage`/`img.writepixels`; these dispatch through the calling
  module's own Draw linkage, so a nil `draw` handle in the library raises
  `"module not loaded"` — even though the caller has Draw loaded and even though
  `draw->ABGR32`/`draw->Black` (constants) inline fine without a handle. This is
  why `Imageload.init` loads Sys, **Draw**, and Imageio.
- `imageremap->remap` is the wrong tool for textures (CMAP8 dither). Build the
  image from `$Imageio` RGBA instead.
- The teapot `.obj` ships no UVs; `rayteapot.b` generates an ugly spherical wrap
  for the demo. Texturing needs UVs regardless of the decoder.

## Build wiring

- `libstb/mkfile` builds `libstb.a` (one TU: `stbwrap.c`, `-Istb` implicit via
  relative include).
- `Makefile` `EMUDIRS` includes `libstb` (before `emu`); `emu/Linux/emu` and
  `emu-g` list `stb` in the `lib` section and `imageio` in the `mod` section.
- `$Imageio` registered in `emu/Linux/emu.c` (`imageiomodinit`), wired into
  `libinterp/mkfile` (OFILES, MODULES, `imageiomod.h` gen rule + dep + nuke) and
  `module/runt.m` like any other builtin.
- Generated `libinterp/imageiomod.h` is **not** committed (`.gitignore`).

## Tests

`appl/cmd/raytest.b` decodes an embedded 2×2 RGBA PNG and asserts the four
texels (incl. a non-255 alpha), checks junk input fails gracefully, and renders
a textured quad through `memmesh` from an `ABGR32` texture (which also validates
the byte order end-to-end). Headless decode runs without a display; the textured
quad needs one. `raytest: PASS 24/24` under `emu -g320x240 /dis/raytest.dis`.
