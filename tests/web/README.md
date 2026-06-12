# Charon web-rendering test bench

A controlled bench for improving **Charon**'s rendering, built around a real
testbed site (`bible.nicecrew.digital`) plus isolated fixtures. The north star
is making Charon a genuinely *graphical* browser rather than an elinks-grade
text dump; the first big piece is a **CSS engine** wired onto the in-tree
W3C CSS2.1 parser (`module/css.m` / `appl/lib/w3c/css.b`).

## Two kinds of test

Rendering has a cheap deterministic core and an expensive visual tail, so the
bench is split to match:

1. **Logic suites (`suites/*.b`)** — CSS parsing and the cascade/selector
   engine are *pure computation*, so they run headless under `emu-g` and emit
   [TAP](https://testanything.org/) (`ok` / `not ok`), exactly like
   `tests/dis`. No display, fully deterministic. This is the primary oracle.
2. **Visual fixtures (`fixtures/`)** — HTML/CSS served to a live `emu` (via
   `file://` for pure rendering, or a local HTTP server for transport
   features). Judged with a screenshot/eyeball on the shared VNC desktop.
   Reserved for genuine layout/paint questions the logic suites can't settle.

## Running the logic suites

```sh
make all                 # build Linux/<arch>/bin/{emu-g,limbo} first
tests/web/run.sh         # all suites
tests/web/run.sh cssparse # only suites/*cssparse*.b
TIMEOUT=120 tests/web/run.sh
```

The runner reuses the TAP helper from `tests/dis/lib/testing` (building it to
its canonical `/tests/dis/_build/lib/testing.dis` if needed) rather than
duplicating it. Exit status is nonzero if any suite has a `not ok` or errors.

## Layout

| Path | Purpose |
|------|---------|
| `run.sh` | host harness: compile → run under emu-g → aggregate TAP |
| `suites/01_cssparse.b` | validates the CSS2.1 parser (see below) |
| `fixtures/minimum-standards.html` | self-contained HTML5+CSS3+JS conformance smoke test — the pragmatic *minimum* render bar, each block tagged MUST/STRETCH, degrades to readable with no CSS and no JS. Load via `file://` in a live emu. |
| `fixtures/css21_default.css` | W3C CSS2.1 Appendix D default HTML4 sheet — conformance input *and* the UA default sheet for the cascade |
| `fixtures/bible/{index.html,page.css,inline.css}` | byte-for-byte capture of the live testbed page + its stylesheets |
| `_build/` | generated `.dis` (git-ignored; wiped each run) |

## Suites

- **`01_cssparse`** — proves the in-tree CSS2.1 parser is viable before the
  cascade is built on it. Strict exact-count conformance against the W3C
  Appendix D sheet (51 rulesets, `@media print` parsed), plus the real
  testbed CSS's 2.1 constructs (rulesets, declarations, attribute & pseudo
  selectors). CSS3 constructs the testbed uses — `@media` feature queries,
  custom properties (`--x`), `var()` — are reported as TAP **SKIP**s: a 2.1
  parser correctly drops them. Supporting those is a later, deliberate CSS3
  step.

## Status / roadmap

- [x] **Phase 1** — bench scaffold + CSS2.1 parser validated.
- [ ] **Phase 2** — Charon collects author CSS (`<style>`, `<link
      rel=stylesheet>`, inline `style=`).
- [ ] **Phase 3** — cascade/selector engine (specificity + origin) over the
      parsed sheets; headless TAP suite asserting computed styles per element.
- [ ] **Phase 4** — apply computed styles in `build.b` via the existing
      `Pstate` font/colour/state stacks; verify with an env-gated Item-tree
      dump on fixtures.
- [ ] **Phase 5** — visual pass on the live testbed; before/after on VNC.
- [ ] **Later** — CSS3: custom properties + `var()` (unlocks the testbed's
      colours), then feature queries, then box model / flex / grid.
