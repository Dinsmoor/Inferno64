# 9front → Inferno64: draw / memdraw / memlayer ideas

Mined from `9front:sys/src/{libdraw,libmemdraw,libmemlayer}` git history (2011–2026)
and compared against `inferno-os:{libdraw,libmemdraw,libmemlayer}`. These three
libraries share *actual Plan 9 C lineage* with Inferno — `libmemdraw` and
`libmemlayer` are nearly pure pixel-pushing (no I/O), so their fixes/features
port almost verbatim. `libdraw`'s I/O half (devdraw protocol, `/dev/mouse`,
`/dev/cons` keyboard ioproc, event loop, screen ids) maps *poorly* because
Inferno wraps draw differently (libdraw → emu `devdraw` → the `Draw` Limbo
module), so client-side commits there are mostly not transferable and are
omitted below.

**Scope note:** these are *ideas to consider*, not a commitment. Some duplicate
work you may instead get for free by vendoring. The headline new features
(affine warp, correlation) are recent (2025–2026), authored largely by `rodri`,
and are genuine capability additions.

Status legend: ✅ already in Inferno · ❌ absent · ⚠️ present but worth auditing/hardening · 🔧 directly applicable fix

---

## Tier A — New capabilities Inferno lacks

### A1. `affinewarp(2)` / `memaffinewarp()` — affine image transforms ❌
Rotate / scale / shear / translate an image via a 3×2 affine matrix, with
fixed-point sampling. Active 2025–2026 line of work; well factored:
- `9beb62647`, `e4dbc62f2` (2026-05) "rewarp" — the matured API
- `ebc86924d` (2025-09) implement `affinewarp(2)`, move `mkwarp(2)` memdraw→draw
- `e24ce8adb` fixed-point sampling; `9b89cb2a1` matrix inversion in `mkwarp()`
- `89a03efcb`/`5c200bf53` per-channel optimized get/putpixel; `b6e9166e2` BGR15 fast path
- `58f32b9ab` avoid division in the hot `k[124]` routines; `7f349c015` 13-bit precision
- `e532d0990` (2025-12) **`memlaffinewarp()`** — warp into a memlayer (windowed)
- `3af6069b0`/`139bfdc46` Drawop / race cleanups

**Why for Inferno64:** the only image-rotation/scaling primitive Inferno has is
nearest-neighbor inside apps. A clean libmemdraw affine warp would benefit
Charon (CSS transforms, image scaling), any image viewer, and Tk. Self-contained
in libmemdraw + a thin libdraw wrapper. **Effort: medium-high. Risk: low** (new
code, doesn't touch existing draw paths). Pull the *matured* 2026 version, not
the early commits.

### A2. `memimagecorrelate()` — convolution / correlation with a kernel ❌
- `2e4717b4e` (2025-09) "add image correlation and other improvements"
- `cfb8010d1` clamp() fix; `0e7087cac` alphadraw buffering opt (same series)

Convolve/correlate an image against a filter kernel → blur, sharpen, edge
detect, template match. Also replaced bit-shift pixel sampling with a single
SWAR multiply (faster on amd64/arm64 — relevant to your aarch64 target).
**Effort: medium. Risk: low.** Lower priority than A1 (fewer callers) but the
SWAR-sampling cleanup is a free perf win even without correlation.

---

## Tier B — Robustness / security guards Inferno is missing

### B1. `badrect(2)` — overflow-safe rectangle validation ❌
- `1f7c0d20c` (2013) add `badrect()`; `48d57b7af` (2026) drop the arbitrary
  `0x10000000` area cap but keep the integer-overflow check (`z=x*y; z/x==y`).

Inferno has **no** `badrect`. Malformed image dimensions (negative/zero/area
that overflows `int`) flow into allocation and stride math unchecked — a
classic memory-corruption vector when the rectangle comes off the wire (draw
protocol, image files, fonts). **Add a `badrect()` and call it at image-create /
load boundaries.** **Effort: low. Risk: low. Security-relevant.**

### B2. `icossin2()` integer overflow 🔧 — *directly applicable, low-hanging*
- `af18284d6` (2025-11) "fix icossin2() integer overflow"

Inferno's `libmemdraw/icossin2.c` has the **exact** vulnerable code:
`x = -x;` (overflows at `INT_MIN`) then `tan = 1000*x/y` (the `1000*x` multiply
overflows for large coordinates). 9front's fix: negate into `uint ux/uy`, and do
`1000*(uvlong)ux/uy`. **Port verbatim.** Affects every arc/ellipse rasterization
with large radii. **Effort: trivial. Risk: none.**

### B3. Font / subfont file validation ⚠️
- `a0955a1e0` (2015) check fontchar count in `openmemsubfont()`/`readsubfont()`
- `50349e5dc`/`42ecdf898` use `readn()` (not a single `read`) for headers + Fontchar array
- `bd3dfb0dd` (2016) fix OOB after subfont array realloc

Inferno's `readsubfont.c` reads a count `n` then reads `6*(n+1)` bytes, and uses
`libreadn`, but **does not bound `n`** before allocating — a corrupt/hostile
`.subfont`/`.font` can request a huge or overflowing allocation. Add the count
sanity checks. **Effort: low. Risk: low. Security-relevant** (fonts are
attacker-controllable via downloaded pages in Charon).

### B4. `memarc()` degenerate-angle handling ⚠️
- `0fea8e099` (2019) handle `phi == 0` and `phi <= -360`, keep alpha in bounds

Inferno's `memarc()` swaps for `phi < 0` but does not special-case `phi == 0`
or wrap `phi <= -360`; alpha isn't clamped. Audit `libmemdraw/arc.c` against the
9front version. **Effort: low.**

---

## Tier C — Correctness fixes to audit against Inferno

These are older single-purpose fixes; verify whether Inferno's copy already has
them (some predate the Inferno fork point, some don't).

| Idea | 9front | What | Inferno status |
|---|---|---|---|
| Wide-image read/write | `d294658d4`,`eca71681c`,`87de2118e` (2011) | `loadimage`/`readimage`/`unloadimage` handle images wider than one compressed chunk; `writememimage` falls back to **uncompressed** when a compressed block would exceed the chunk limit | ⚠️ verify `libmemdraw/write.c` has the uncompressed fallback |
| `byteaddr()` sign preservation | `de0679585` (2014) | sign-preserving pixel address arithmetic | ⚠️ audit |
| `memfillcolor()` byte order | `4c151697b` (2014) | endian-correct fill | ⚠️ audit |
| m8a8 (color-map + alpha) draw | `cf13f5df4` (2013) | fix drawing into color-mapped-with-alpha dst | ⚠️ audit |
| replicated src on memlayer w/ clip | `b4fd53420` (2013) | fix tiling a replicated source through a layer clip rect | ⚠️ audit `libmemlayer` |
| `memimageline` H/V fast path | `661c14037`,`1c0b2d238` (2026) | optimized rasterization for pure horizontal/vertical lines incl. non-`Endsquare` ends; fixes a 1-pixel rect error | ❌ likely worth porting (perf) |
| `Fsimple` 1×1 image tag | `7b3bb0ea7` (2026) | flag + fast path for 1×1 (solid-color) source images | ❌ small perf win |

---

## Tier D — Lower relevance to Inferno's draw model

Listed so the next person doesn't re-investigate. These touch libdraw's
client/event/I-O half, which Inferno structures differently.

- **libdraw locking revamp** (`6b250a5ca`, `139bfdc46`, `f1c2de2b3`, 2025–2026) —
  removes data races in `Drawop`/`memdraw`. Inferno's libdraw is driven per-Limbo
  prog through emu `devdraw`; the concurrency model differs, so port only if a
  concrete race is observed. The `f1c2de2b3` memdraw race is the most
  library-internal one — worth a look.
- **flushimage roundtrip-latency removals** (`4a6cba9ce`, `0849f98eb`,
  `6784bb63a`) — fewer redundant `flushimage()` calls. Inferno's flush path goes
  through emu, not a 9P round-trip; not directly applicable.
- **OCEXEC on internal fds** (`8b4f6c303`, `4049053b1`) — close-on-exec hygiene
  for `/srv`/colormap fds. Minimal relevance to hosted emu.
- **event/ioproc shutdown & note leaks** (`4b194ca0e`, `2e2969679`,
  `f29534c24`) — tied to libthread + Plan 9 notes; Inferno uses Limbo channels.

---

## Already done in Inferno (don't re-port)

- **21-bit runes** — Inferno is *already* `Rune = uint`, `Runemax = 0x10FFFF`.
  9front's 2012 "32-bit rune prep" (`015fd3278`) is not needed.
- **`bytesperline()` negative coords** — Inferno's `unitsperline()` already has
  the "make positive before divide" branch; the 9front 2025 fix (`1feadc683`)
  was a regression in *their* refactor.
- **`bezierpts()`** — present in `libdraw/bezier.c`.

---

## Suggested order of attack

1. **B2 `icossin2` overflow** — trivial, verbatim, real bug. Do first.
2. **B1 `badrect` + B3 font validation** — cheap security hardening, matters for
   Charon's attacker-controlled inputs.
3. **A1 affine warp** — the one genuinely new, high-value capability; pull the
   2026 matured form into libmemdraw + libdraw + libmemlayer.
4. **C-tier audit** (wide image, line fast path) as a batch once you're in the files.
5. A2 correlation + SWAR sampling if/when there's a consumer.
