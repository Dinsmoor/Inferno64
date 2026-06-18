# tk_baseline — golden "before" screenshots for the Tk/ttk modernization

These PNGs are the visual correctness reference for the work planned in
[`docs/DEV_TK_MODERN.md`](../../../docs/DEV_TK_MODERN.md). They show each
Tk-driving userspace app **before** any ttk modernization. A pixel change in a
*classic* widget after the work is a compatibility regression by definition;
diff against these.

- One PNG per app, named by friendly name (see the table in DEV_TK_MODERN §11).
- `_contact_sheet.png` is a labelled montage of all of them.
- Regenerate with `../tk_baseline_shots.sh` (one `emu -g1024x768 wm/wm <app>`
  per app under Xvfb, root-window grab via ImageMagick `import`).

## Caveats (these are first-render references, not pixel-exact acceptance)

- Each app is launched cold with **no document/argument**, so editors and
  terminals (`acme`, `edit`, `shell`, `vt-terminal`) show an empty buffer +
  chrome; `bible` shows its frame before content loads.
- `tkwdemo` is captured **maximized** (double-click titlebar) to show the full
  megawidget gallery — Notebook tabs, Paned sash, Scrolledlist, Scrolledtext,
  status bar — i.e. exactly the widgets being absorbed into ttk.
- For acceptance testing, drive the full desktop and open real content per
  `DEV_TK_MODERN.md` §7, rather than trusting these first-render frames.
