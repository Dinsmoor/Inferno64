# Local patches to vendored stb

These are deliberate, in-tree modifications to the upstream stb single-headers
(pinned in `UPSTREAM_COMMIT`). **Re-apply them whenever you re-vendor.** Each is
marked inline with a `[LOCAL PATCH]` comment.

## stb_image.h — GIF "deferred clear code" (animation frame truncation)

`stbi__gif_load_next` (the LZW raster loop) aborted with `"too many codes"` once
the 4096-entry LZW table filled, because it kept growing `avail` past the table
instead of freezing it. Per the GIF spec's *deferred clear code* behaviour, a
decoder must keep using a full table until the encoder emits an explicit clear
code; many encoders rely on this. stb's abort returned NULL mid-animation, and
the multi-frame path (`stbi__load_gif_main`) then silently returned only the
frames decoded so far.

Symptom: `lib/images/hell.gif` (10 frames) decoded as 4. Browsers/giflib read
all 10.

Fix: stop adding table entries once full (`if (avail < 8192)`) instead of
erroring; decoding continues with the frozen table. Codes are 12-bit (max 4095),
so the never-referenced upper entries are harmless and the decoded output is
unchanged for well-formed streams. Affects every animated GIF, not just the
in-tree asset (matters for fediverse/Charon content).
