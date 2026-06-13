#!/usr/bin/env python3
# Vendor a curated set of emoji PNGs for wm/pleromussy (and any other Tk app
# that wants inline emoji).  Source: jdecked/twemoji, 72x72 PNGs, CC-BY 4.0.
#
# Inferno has no font covering the emoji blocks (lucidasans/unicode tops out at
# U+FB1E), so emoji are rendered as inline images instead.  This pulls the
# common single-codepoint emoji blocks (faces, gestures, hearts, symbols) into
# icons/emoji/<codepoint(s)>.png, named exactly like twemoji (lowercase hex,
# joined by '-', the U+FE0F variation selector dropped) so a Limbo client can
# map an emoji string -> filename with the same rule.
#
# Re-run to refresh/expand; existing files are overwritten.  Flags / ZWJ
# sequences (multi-codepoint) are intentionally skipped -- reactions are
# overwhelmingly single emoji, and they keep the set to a few hundred files.

import os, sys, urllib.request, concurrent.futures

BASE = "https://raw.githubusercontent.com/jdecked/twemoji/main/assets/72x72"
OUT  = os.path.join(os.path.dirname(__file__), "..", "..", "icons", "emoji")

# Curated single-codepoint ranges, high-value for reactions/common use.
RANGES = [
    (0x1F600, 0x1F64F),   # emoticons (faces)
    (0x1F900, 0x1F9FF),   # supplemental symbols & faces, gestures
    (0x1F440, 0x1F4FF),   # eyes, hands, speech, hearts-with-objects, etc.
    (0x1F300, 0x1F32F),   # weather / core pictographs
    (0x1F525, 0x1F525),   # fire (palette)
    (0x1F389, 0x1F38F),   # party / celebration
    (0x1F4A0, 0x1F4FF),   # 100, sparkles-adjacent, symbols
    (0x2600,  0x26FF),    # misc symbols (sun, star, warning, ...)
    (0x2700,  0x27BF),    # dingbats (checks, crosses, hearts)
]
# Individually useful symbols scattered outside the ranges above.
EXTRAS = [0x2764, 0x2665, 0x2B50, 0x2728, 0x2049, 0x203C, 0x2122, 0x2139,
          0x2611, 0x2714, 0x2716, 0x2733, 0x2734, 0x2744, 0x2747,
          0x2B05, 0x2B06, 0x2B07, 0x2B1B, 0x2B1C, 0x00A9, 0x00AE, 0x303D]

def candidates():
    seen = set()
    for lo, hi in RANGES:
        for cp in range(lo, hi + 1):
            seen.add(cp)
    for cp in EXTRAS:
        seen.add(cp)
    return sorted(seen)

def fetch(cp):
    name = format(cp, "x")
    url = "%s/%s.png" % (BASE, name)
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            data = r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return (cp, None)        # not an assigned emoji; skip quietly
        return (cp, "HTTP %d" % e.code)
    except Exception as e:
        return (cp, str(e))
    with open(os.path.join(OUT, name + ".png"), "wb") as f:
        f.write(data)
    return (cp, len(data))

def main():
    os.makedirs(OUT, exist_ok=True)
    cps = candidates()
    got = 0
    total = 0
    errs = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
        for cp, res in ex.map(fetch, cps):
            if res is None:
                continue
            if isinstance(res, int):
                got += 1
                total += res
            else:
                errs.append("%x: %s" % (cp, res))
    print("fetched %d emoji into %s (%.1f KB)" %
          (got, os.path.normpath(OUT), total / 1024.0))
    if errs:
        print("errors:", *errs, sep="\n  ", file=sys.stderr)

if __name__ == "__main__":
    main()
