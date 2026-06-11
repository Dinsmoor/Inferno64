# `docs/ref/` — reference material we didn't write

This folder holds the **original Bell Labs / Vita Nuova Inferno manual** plus a
couple of other outside references. It is here for provenance and background
reading — it describes *upstream* Inferno, not necessarily this fork. Where a
paper has a living, fork-specific counterpart, the **"see"** column points at the
`ON_*.md` doc that supersedes it; read that first if you want current behaviour.

## Layout

- **`*.pdf`** (and a few `*.html`) — the rendered manual, one file per paper.
- **[`sources/`](sources/)** — the troff `*.ms` originals + the `mkfile`s that
  rendered them. Kept intact for historical preservation. It is **not** wired into
  the build (`mk all`/`make all` never descend here) and isn't runnable as-is on a
  modern host anyway — it wants the Plan 9 `mk`/`rc`/`dpost` toolchain, and the
  PDFs beside this README are already the committed output. If we ever want to
  maintain these, porting `sources/` to LaTeX (or Markdown) is the likely path.
- **[`limbobyexample/`](limbobyexample/)** — Sean "henesy" Hinchee's worked Limbo
  examples (his own repo, vendored for convenience), not part of the manual.

## Index

### Overview
| paper | what it is | see |
|---|---|---|
| [`bltj.pdf`](bltj.pdf) | "The Inferno Operating System" — the Bell Labs Technical Journal overview paper | [`ON_EMU.md`](../ON_EMU.md) |

### The Dis virtual machine
| paper | what it is | see |
|---|---|---|
| [`dis.pdf`](dis.pdf) | "Dis Virtual Machine Specification" — the bytecode/instruction reference | [`ON_DIS.md`](../ON_DIS.md), [`ON_DIS_ARCH.md`](../ON_DIS_ARCH.md) |
| [`hotchips.pdf`](hotchips.pdf) | "The Design of the Inferno Virtual Machine" — the design rationale talk | [`ON_DIS.md`](../ON_DIS.md) |

### Limbo
| paper | what it is | see |
|---|---|---|
| [`limbo.pdf`](limbo.pdf) | "The Limbo Programming Language" — the language reference | [`ON_LIMBO.md`](../ON_LIMBO.md) |
| [`addendum.pdf`](addendum.pdf) ([`.html`](addendum.html)) | Addendum to the Limbo reference (later language additions) | [`ON_LIMBO.md`](../ON_LIMBO.md) |
| [`descent.pdf`](descent.pdf) ([`.html`](descent.html)) | "A Descent into Limbo" — gentle tutorial introduction | [`ON_LIMBO.md`](../ON_LIMBO.md), [`limbobyexample/`](limbobyexample/) |
| [`tk.pdf`](tk.pdf) | "An Overview of Limbo/Tk" — the Tk GUI toolkit | [`ON_GRAPHICS.md`](../ON_GRAPHICS.md) |
| [`lprof.pdf`](lprof.pdf) | "Limbo profilers in Inferno" | [`ON_DEBUGGING.md`](../ON_DEBUGGING.md) |
| — | (modern worked examples) | [`limbobyexample/`](limbobyexample/) |

### Styx / distributed
| paper | what it is | see |
|---|---|---|
| [`styx.pdf`](styx.pdf) | "The Styx Architecture for Distributed Systems" — Inferno's 9P | [`ON_9P.md`](../ON_9P.md) |
| [`lego.pdf`](lego.pdf) | "Styx-on-a-Brick" — Styx on a Lego Mindstorms RCX (small-device case study) | [`ON_9P.md`](../ON_9P.md) |

### Tools & the Plan 9 toolchain
| paper | what it is | see |
|---|---|---|
| [`sh.pdf`](sh.pdf) | "The Inferno Shell" | — |
| [`mk.pdf`](mk.pdf) | "Maintaining Files on Plan 9 with Mk" — the `mk` build tool | [`ON_BUILDING.md`](../ON_BUILDING.md) (we use `make`) |
| [`compiler.pdf`](compiler.pdf) | "Plan 9 C Compilers" — the dialect/toolchain Inferno's C is written in | [`ON_C_IN_INFERNO.md`](../ON_C_IN_INFERNO.md) |
| [`asm.pdf`](asm.pdf) | "A Manual for the Plan 9 Assembler" | [`ON_JIT.md`](../ON_JIT.md) |
| [`acidpaper.pdf`](acidpaper.pdf) | "Acid: A Debugger Built From A Language" | [`ON_EMU_DEBUG.md`](../ON_EMU_DEBUG.md) |
| [`acidtut.pdf`](acidtut.pdf) | "Native Kernel Debugging with Acid" — tutorial | [`ON_EMU_DEBUG.md`](../ON_EMU_DEBUG.md) |
| [`acid.pdf`](acid.pdf) | "Acid Reference Manual" | [`ON_EMU_DEBUG.md`](../ON_EMU_DEBUG.md) |
| [`acme.pdf`](acme.pdf) | "Acme: A User Interface for Programmers" — the Acme editor | — |

### Porting, building, development
| paper | what it is | see |
|---|---|---|
| [`port.pdf`](port.pdf) | "Inferno Ports: Hosted and Native" | [`ON_PORTING.md`](../ON_PORTING.md), [`ON_AARCH64_PORT.md`](../ON_AARCH64_PORT.md) |
| [`real.pdf`](real.pdf) | "Real Inferno" — running native rather than hosted | [`ON_KERNEL.md`](../ON_KERNEL.md) |
| [`dev.pdf`](dev.pdf) | "Program Development under Inferno" | [`ON_BUILDING.md`](../ON_BUILDING.md), [`ON_DEBUGGING.md`](../ON_DEBUGGING.md) |
| [`perform.pdf`](perform.pdf) | "Reliable Benchmarking with Limbo on Inferno" | — |
| [`install.pdf`](install.pdf) | "Installing the Inferno Software" (historical; see `sources/INSTALL1.ms` too) | [`ON_BUILDING.md`](../ON_BUILDING.md) |
| [`gridinstall.pdf`](gridinstall.pdf) | "Installing the Vita Nuova Grid Software" | — |

### Applications / case studies
| paper | what it is | see |
|---|---|---|
| [`ebookimp.pdf`](ebookimp.pdf) | "Navigating Large XML Documents on Small Devices" — an e-book reader case study | — |

### Release notes & change history
| paper | what it is | see |
|---|---|---|
| [`changes.pdf`](changes.pdf) | "System and Interface Changes to Inferno" | — |
| [`20010618.pdf`](20010618.pdf) | Inferno 3rd Edition — June 2001 revision notes | — |
| [`20011003.pdf`](20011003.pdf) | Inferno 3rd Edition — 3 October 2001 update | — |
| [`20020628.pdf`](20020628.pdf) | Inferno 3rd Edition — 28 June 2002 update | — |
| `sources/20020715.ms` | Inferno 3rd Edition — 15 July 2002 experimental update (source only, no committed PDF) | — |
| [`frontmatter.pdf`](frontmatter.pdf), [`backmatter.pdf`](backmatter.pdf) | the assembled manual's cover / front- and back-matter | — |

### Also here
| file | what it is |
|---|---|
| [`limbo.html`](limbo.html) | HTML render of the Limbo reference |
| [`sources/`](sources/) | all troff `*.ms` originals + the `mkfile`s (see *Layout* above) |
| [`limbobyexample/`](limbobyexample/) | henesy's worked Limbo examples |
