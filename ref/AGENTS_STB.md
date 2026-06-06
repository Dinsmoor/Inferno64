# libstb: the vendored stb suite (what's there, and where it's useful)

The whole [stb](https://github.com/nothings/stb) single-header collection is
vendored at `libstb/stb/` (public domain / MIT; upstream commit pinned in
`libstb/stb/UPSTREAM_COMMIT`). Today **only image decoding is wired** (see
[AGENTS_IMAGEIO.md](AGENTS_IMAGEIO.md)); everything else is present as source and
ready to activate. This doc is the catalogue: what each library does, where it
would earn its place in an Inferno/Limbo program, and how to wire one.

stb is small, dependency-light ISO C — a good fit for the Inferno philosophy
(no host GL/GPU, identical on every emu host, leaf C that never touches
`lib9.h`). The trade-off is the same as the 3D port: it's all CPU/software.

See also: [AGENTS_IMAGEIO.md](AGENTS_IMAGEIO.md) (the one wired module + the
vendoring/build pattern), [AGENTS_3D.md](AGENTS_3D.md) (`$Raster3`, the obvious
consumer of textures/atlases), [AGENTS_GRAPHICS.md](AGENTS_GRAPHICS.md),
[AGENTS_CHARON.md](AGENTS_CHARON.md) (the browser — images/fonts/audio/canvas).

---

## The catalogue

Effort key: **S** = thin C wrapper + reuse an existing builtin; **M** = new
`$Builtin` + small Limbo lib (like `$Imageio`/`Imageload`); **L** = needs a new
subsystem (audio device, editor widget) around it.

| Header | Does | Where it's useful in Inferno/Limbo | Effort | Notes / overlap |
|--------|------|------------------------------------|--------|-----------------|
| **stb_image.h** | Decode PNG/JPEG/BMP/TGA/GIF/PSD/HDR/PIC/PNM → RGBA8 | **WIRED** as `$Imageio`. Textures for `$Raster3`; Charon `<img>`/`<canvas>` bitmaps; wm sprites. | — | Done. RGBA8 == Draw `ABGR32`. Beats `RImagefile`+`imageremap` (CMAP8). |
| **stb_image_write.h** | Encode PNG/BMP/TGA/JPG/HDR (to memory via callback) | Screenshots of any Draw image; Charon `canvas.toDataURL`/save-image; export `$Raster3` renders; a true-colour replacement for `writegif`. | **M** | Highest-value next step. Add `stbwrap_encode_png(rgba,w,h)` + extend `$Imageio` with `encode`. Use `stbi_write_*_to_func` (no host FS). |
| **stb_image_resize2.h** | High-quality image resample (up/down) | Charon `<img width/height>` scaling; texture mip/downscale; thumbnails; DPI scaling of decoded assets. | **S/M** | Operates on the RGBA8 buffers `$Imageio` already produces; add a `resize` call alongside decode. |
| **stb_truetype.h** | Rasterize TTF/OTF glyphs; metrics; kerning | Real outline/antialiased fonts for Tk and Charon beyond Inferno's bitmap subfonts; arbitrary sizes. | **M/L** | **Overlaps libfreetype** (already vendored + `$Freetype` builtin). Prefer freetype unless you want stb's zero-config simplicity; don't ship two font stacks without a reason. |
| **stb_rect_pack.h** | 2D rectangle bin-packing | Glyph atlases (pairs with truetype), sprite/texture atlases for `$Raster3`, packing UI assets into one Draw image. | **S** | Pure compute; pairs naturally with whatever rasterizes into the atlas image. |
| **stb_perlin.h** | Perlin/fractal noise | Procedural textures, terrain/heightfields for the 3D demos, animated backgrounds. | **S** | Trivial to expose; nice for `$Raster3` content. |
| **stb_easy_font.h** | Dead-simple quad-based ASCII font | Debug HUD/overlay text in `$Raster3` scenes without a font subsystem. | **S** | Emits quads you feed to `memmesh`/Draw; ugly but instant. |
| **stb_vorbis.c** | Decode Ogg Vorbis → PCM | Audio playback via `devaudio`; Charon `<audio>`/sound effects in games. | **L** | High value *if* audio is on the roadmap; needs an audio output path. Note: a `.c`, not an `.h`. |
| **stb_hexwave.h** | Bandlimited audio waveform synth | Procedural sound/synth on top of `devaudio`. | **L** | Same audio-subsystem dependency as vorbis. |
| **stb_textedit.h** | Text-editor state machine (cursor/selection/undo) | Backing for editable widgets: Tk entry/text, Charon `<input>`/`<textarea>`, acme-like editors. | **M/L** | Logic only; you provide layout + drawing. |
| **stb_dxt.h** | DXT/BC1-5 block compression | Compressed textures — only worth it with a GPU; with software `$Raster3` it adds decode cost. | — | Low value here (no GPU). |
| **stb_ds.h** | C dynamic arrays + hashmaps | Internal bookkeeping inside other C wrappers (e.g. atlas builders). | S | Limbo has arrays/lists/`Strhash`; only useful inside C glue, not exposed to Limbo. |
| **stb_sprintf.h** | Fast portable `snprintf` (full `%f`) | C-side formatting if a wrapper needs it. | — | emu already has `print`/`snprint`; rarely needed. |
| **stb_c_lexer.h** | Small C-like tokenizer | Parsing config/DSLs inside a C wrapper. | S | Limbo-side parsing usually belongs in Limbo. |
| **stb_divide.h** | Well-defined trunc/floor div+mod | Correctness helper inside C wrappers. | — | Implementation detail. |
| **stb_leakcheck.h** | malloc/free leak tracker | Dev-time leak hunting in vendored C. | — | Tooling, not shipped. |
| **stb_include.h** | `#include` expander for text/shader files | Preprocessing text assets. | — | Niche; no shaders here. |
| **stb_connected_components.h** | Incremental grid connectivity | Pathfinding/maze/region queries on tile grids. | S | Niche/game. |
| **stb_herringbone_wang_tile.h** | Wang-tile map generation | Procedural tile maps for games. | S | Niche/game; pairs with a tile renderer. |
| **stb_tilemap_editor.h** | In-app tilemap editor UI | A tile editor — needs your input + renderer wired in. | L | Niche; large integration. |
| **stb_voxel_render.h** | Voxel mesh generation | Voxel/blocky worlds — **assumes an OpenGL backend**. | — | Poor fit (no GL); mesh-gen ideas could feed `$Raster3` but it's a big lift. |

**Quick read:** the natural near-term wins are **stb_image_write** (export/screenshots/canvas-save), **stb_image_resize2** (scaling), and **stb_rect_pack (+ truetype)** for glyph/sprite atlases. **stb_vorbis** is the big one if audio is ever in scope. The rest are situational or overlap existing Inferno facilities.

---

## How to activate another stb module

Follow the `$Imageio` pattern exactly (it mirrors the libmbedtls vendoring):

1. **Expose a tiny C API in `libstb/stbwrap.c`.** Add the module's
   `#define STB_<X>_IMPLEMENTATION` and `#include "stb/stb_<x>.h"`, then write
   small functions over plain C types (no Inferno types). `stbwrap.c` must stay
   `lib9.h`-free — it sees only libc + stb. Add the new header to the
   `stbwrap.$O:` prerequisite list in `libstb/mkfile`.
2. **Memory across the boundary:** stb uses host libc `malloc`/`free`. Allocate
   in stb, copy into a Limbo heap array on the Inferno side, then free with your
   `stbwrap_free` — symmetric, independent of the Inferno pool (see
   `libinterp/imageio.c`).
3. **Surface it to Limbo:** either extend `$Imageio` (for image-family calls
   like encode/resize) or add a new builtin `$<Name>` the same way — `.m` in
   `module/`, C in `libinterp/`, registered in `emu/Linux/emu.c` +
   `emu`/`emu-g` mod sections, wired into `libinterp/mkfile`
   (OFILES/MODULES/`<name>mod.h` gen rule + dep + nuke) and `module/runt.m`.
   Keep heavy compute in C; keep the builtin a thin marshaller.
4. **Draw-image results:** prefer returning RGBA8 and letting a Limbo lib build
   the image as `ABGR32` (one `writepixels`, no reorder) — and remember a Limbo
   library that calls Draw *methods* must `load Draw` itself (the bug that ate a
   debug cycle; see [AGENTS_IMAGEIO.md](AGENTS_IMAGEIO.md)).
5. **Build/commit:** `make all` (full, cheap). Generated `*mod.h` headers are
   build artifacts — keep them out of git (`.gitignore`). `libstb.a`/`.o` are
   already ignored.

Everything in `libstb/stb/` is leaf C with no pointer-width assumptions that
affect the Limbo ABI, so it's dual-ABI-safe by construction (it links into emu;
it never participates in the Dis frame layout).
