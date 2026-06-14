# Image decoding: $Imageio, Imageload, and vendored stb

Native decoding of common image formats (PNG, JPEG, BMP, TGA, GIF, PSD, HDR,
PIC, PNM) into Draw images, backed by the vendored **stb** single-header
libraries, plus **WebP** (lossy VP8, lossless VP8L, the VP8X container and
animation) via the vendored **libwebp** decoder. Use this when you need a real
raster image *inside* Inferno (a texture for `$Raster3`, an `<img>`/`<canvas>`
bitmap for Charon, a sprite for a wm app) without host-side conversion.
Animated GIF and WebP play through the [`Imageanim`](#animation) library.

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
| libwebp | vendored C | `libwebp/webpdec.h` (libwebp decode+demux+anim, amalgamated; license in `COPYING`/`PATENTS`, commit in `UPSTREAM_COMMIT`) | The WebP codec. Generic-C only (no SIMD/threads/file IO). |
| `webpwrap` | C, libwebp | `libwebp/webpwrap.c` → `libwebp.a` | The ONLY TU that pulls in the WebP impl, same Inferno-free contract as `stbwrap`. Sniffs the `RIFF/WEBP` magic. |
| `$Imageio` | C builtin | `module/imageio.m`, `libinterp/imageio.c` | Limbo face: `decode`/`decodefit`/`encode` (still) and `animopen` → an `Anim` handle (animated). Routes WebP to libwebp, the rest to stb. Graphics-free — raw RGBA8 bytes. |
| `Imageload` | pure Limbo | `module/imageload.m`, `appl/lib/imageload.b` | Convenience: `read`/`readfile` → a ready `ref Draw->Image` (one still frame). |
| `Imageanim` | pure Limbo | `module/imageanim.m`, `appl/lib/imageanim.b` | Plays an animation into a Draw image on its own pacing proc. See [Animation](#animation). |

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

**Decoding with a size cap:** `decodefit(data, maxw, maxh): (w, h, rgba, err)`
is `decode` plus a downscale — if the source exceeds `maxw × maxh` it is reduced
(aspect-preserving) **in C** via `stb_image_resize2` (`stbwrap_decode_fit`), so a
huge image is never allocated in the Dis heap (whose main arena is ~32 MB —
`emu/port/alloc.c`; a 4000×3000 photo is 48 MB of RGBA and overflows it). The
returned `w, h` are the reduced dimensions. `maxw`/`maxh` ≤ 0 means no cap. Use
this, not a Limbo-side downscale, whenever the source size is untrusted (e.g. a
fetched-from-the-web image) — a post-decode downscale can't help because the
full-resolution buffer has to exist first.

**Encoding (RGBA8 → PNG):** `encode(w, h, rgba): (array of byte, string)` is the
inverse, backed by `stb_image_write` (`stbwrap_encode_png`, memory callback — no
host file IO). Input is the same `R,G,B,A` top-to-bottom layout `decode` produces,
so a Draw `ABGR32` image's `readpixels` bytes encode directly. Used by
`tests/jitperf/stft.b` to write a spectrogram PNG. Only PNG is wired today
(stb_image_write can also do BMP/TGA/JPG/HDR — see [ON_STB.md](ON_STB.md)).

## Animation

Animated GIF and animated WebP decode through one extra `$Imageio` call,
`animopen`, which returns an **`Anim`** handle instead of a single buffer.  Any
still (PNG/JPEG/static WebP/…) comes back as a **one-frame** `Anim`, so a caller
can treat every image uniformly.

```limbo
include "imageio.m";
	imageio: Imageio;
	Anim: import imageio;	# bind Anim's methods to the loaded instance

(anim, err) := imageio->animopen(data);
# anim.w, anim.h, anim.nframes, anim.loop (0 = forever)
(delayms, rgba, ferr) := anim.frame(i);	# frame i as w*h*4 RGBA, + its delay
anim.close();				# optional; the GC also frees it
```

**Memory model — frames live in C, one at a time in Dis.** `animopen` decodes
*all* frames (GIF via stb's `stbi_load_gif_from_memory`, WebP via libwebp's
`WebPAnimDecoder`), each full-canvas composited, and keeps the whole frame store
plus the per-frame delays in **C `malloc`**, hung off the back of the `Anim` ADT
(the freetype `Face` idiom: a GC-managed handle with hidden native pointers and
a `dtype` finalizer).  `frame(i)` copies just that one frame into the Dis heap.
So an animation costs **one frame of Dis heap at a time**, not all of them —
important because the main Dis arena is small (~32 MB; see
[`dis-heap-pool-sizes`]).  Hard caps in the C wrappers (per-side dimension, 64
Mpx area, 256 MB aggregate, frame count) keep an untrusted file from asking for
gigabytes.  Frame delays are milliseconds (stb converts GIF centiseconds; WebP
timestamps are differenced).

### Imageanim — playing one

`Imageanim` (`appl/lib/imageanim.b`) drives an `Anim` into a single **ABGR32**
Draw image on its **own proc**, so the UI thread never blocks on frame timing:

```limbo
include "imageanim.m";
	imageanim: Imageanim;
	Player: import imageanim;

imageanim->init();			# loads Sys, Draw, Imageio
(p, err) := imageanim->open(display, data, updated);	# updated: chan of int or nil
# p.img is the surface (frame 0 already drawn); p.w, p.h, p.nframes, p.loop
p.start();				# spawn the pacing proc
# ... p.pause(); p.play(); p.stop();
```

The player writes each frame into `p.img` (a plain Draw op, safe from its proc)
and, if `updated` is non-nil, pulses it with the frame index; the **consumer**
issues its own repaint from whichever proc owns the UI.  In wm that repaint is a
`panel`'s `dirty`/`update` — the per-region repaint mechanism — so only the image
rectangle is redrawn.  Pacing uses a buffered one-shot sleeper proc that stays
responsive to the control channel and never leaks (the buffer lets a leftover
sleeper finish its send and exit even after a stop).

`wm/gifview file` (`appl/wm/gifview.b`) is the worked demo: open a Player on the
file, `putimage` `p.img` into a panel, and on each `updated` pulse mark the panel
dirty.  Note it takes the display from **`ctxt.display`**, not `win.image` —
`win.image` is nil until `tkclient->onscreen()`.

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
- **stb's GIF decoder can report fewer frames than other tools** on some
  optimised/disposal-heavy GIFs (a known stb limitation, passed straight
  through). The frames it does return are correct and full-canvas composited;
  WebP animation (libwebp) does not have this quirk. If GIF fidelity ever
  matters, that's the place to look.

## Build wiring

- `libstb/mkfile` builds `libstb.a` (one TU: `stbwrap.c`, `-Istb` implicit via
  relative include); `libwebp/mkfile` builds `libwebp.a` the same way (`webpwrap.c`
  + `webpdec.h`).
- `Makefile` `EMUDIRS` includes `libstb` and `libwebp` (before `emu`);
  `emu/Linux/emu` and `emu-g` list `stb` **and** `webp` in the `lib` section and
  `imageio` in the `mod` section.  Both vendored libs are in `CACHED_LIBS`
  (content-cached; skipped unless their sources change).
- `$Imageio` registered in `emu/Linux/emu.c` (`imageiomodinit`), wired into
  `libinterp/mkfile` (OFILES, MODULES, `imageiomod.h` gen rule + dep + nuke) and
  `module/runt.m` like any other builtin.  `imageiomodinit` also registers
  `TAnim` (`dtype` with the `freeanim` finalizer).
- Generated `libinterp/imageiomod.h` (and the `Imageio_Anim` struct/map in
  `runt.h`) are **not** committed (`.gitignore`); regenerated every `make all`.
- `imageanim.dis` (lib) and `gifview.dis` (wm) carry per-target `.m` deps in
  their mkfiles so an `imageio.m`/`imageanim.m` interface change forces a rebuild
  (a stale hash fails the runtime link typecheck: `load → nil`).

## Tests

`appl/cmd/raytest.b` decodes an embedded 2×2 RGBA PNG and asserts the four
texels (incl. a non-255 alpha), checks junk input fails gracefully, and renders
a textured quad through `memmesh` from an `ABGR32` texture (which also validates
the byte order end-to-end). Headless decode runs without a display; the textured
quad needs one. `raytest: PASS 24/24` under `emu -g320x240 /dis/raytest.dis`.

`appl/cmd/webptest.b file` decodes a WebP via `decode` + `decodefit`;
`appl/cmd/animtest.b file` exercises `animopen`/`Anim.frame` on any image
(prints geometry, per-frame delays, and the out-of-range / post-`close` guards).
Both are headless. `wm/gifview file` is the interactive playback demo.
