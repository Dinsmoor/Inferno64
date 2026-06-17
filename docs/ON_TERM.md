# Term — an embeddable VT100/ANSI terminal widget

`Terminal` (`module/term.m`, `appl/lib/term.b`, built to `/dis/lib/term.dis`) is
a reusable terminal-emulator widget: a cell grid that interprets VT100/ANSI
escape sequences and renders into an offscreen image shown in a Tk panel,
decoupled from whatever is on the other end of the byte stream (a shell, a
telnet/ssh session, a serial line, a debugger console). `wm/vt` is a thin
embedder over it; the emulator core no longer lives in `wm/vt` itself.

The escape/CSI parser and screen model descend from the original `wm/vt` (a
port of decade-old C). The widget reworks that core into the Tkwidgets-style
contract and fixes the rendering, input encoding, and shell plumbing.

## The widget contract

Like the `Tkwidgets` megawidgets, a `Term` does not spawn its own proc. It owns
a `chan of string` named `ev` that fires with each raw Tk key; add it to your
application's `alt` and call the widget's methods in that same proc.

```limbo
terminal := load Terminal Terminal->PATH;
terminal->init();

term := Term.new(win, ctxt.display, ".t", 80, 24, "");  # "" => default font
tk->cmd(win, "pack .t");
tkclient->onscreen(win, nil);          # window image must exist before show()
term.show();                           # binds the panel image and paints

tio := terminal->attach(ctxt, "sh" :: "-n" :: nil);     # a shell over /dev/cons

for(;;) alt {
... kbd / ptr / ctl as usual, with tk->keyboard(win, s) ...
key := <-term.ev =>  tio.send(term.onkey(key));   # keystroke -> process input
out := <-tio.out  =>  reply := term.output(out);  # process output -> screen
                      if(reply != "") tio.send(reply);   # device replies (DA/DSR)
}
```

| Method | Use |
|---|---|
| `Term.new(top, disp, path, cols, rows, font)` | build the frame+panel at `path`; `font==""` uses `Term->FONT` (a fixed-width font) |
| `show()` | **call once, after `tkclient->onscreen()`** — allocates the display images and paints |
| `output(s): string` | feed program bytes (text + escapes); returns any device reply to send back |
| `onkey(key): string` | encode a Tk key (incl. the View/KF private-use runes) into terminal input bytes |
| `redraw()` | repaint the whole grid (e.g. on a Configure/expose) |
| `clear()`, `sizereq()` | clear+home; the frame's wanted pixel size |

`onkey` maps the arrow/Home/End/PgUp/PgDn/Ins/Del/F1–F12 keys to their xterm
sequences and passes printable runes through; unmapped specials are dropped.

## Termio — wiring a command to the terminal

`Terminal->attach(ctxt, cmd)` runs `cmd` (default: an interactive `sh`) with its
stdin/stdout/stderr on a private `/dev/cons` (a `file2chan`), and returns a
`Termio` whose `out` channel carries bytes to display (program output plus
cooked-mode echo). `tio.send(s)` delivers a keystroke to the process; an
`iomanager` proc services the console with a minimal cooked line discipline
(backspace + line buffering) and a raw passthrough toggled by `/dev/consctl`.

The embedder pumps `tio.out → term.output` and `term.ev → tio.send(term.onkey)`.

## Rendering model

The screen is a grid of cells, one rune string + one packed colour/attr byte
string per row. `output()` runs the parser (which mutates the grid and marks
dirty rows), then a flush renders the dirty rows into the offscreen image and
repaints the panel's dirty region. SGR colours use a 16-entry palette (the 8
base colours + bright). The cursor is a reverse-video block on its cell.

Partial-region clears (`ESC[K` erase-to-end-of-line, `ESC[J`, `ESC[X`) are
**column-honest**: `CLEAR` erases the requested column span, not the whole line.
This matters because the shell's line editor redraws every line with a trailing
`ESC[K`; a whole-line clear there would wipe the prompt the editor just drew.
Every multi-row clear/scroll call passes the full width, so the same rectangular
clear serves both.

Four rules make the panel actually display — each was a bug while the emulator
"worked" but showed black:

1. **Palette colours come from `display.rgb(r,g,b)`**, not
   `display.newimage(..., rgb2cmap(r,g,b))`. `rgb2cmap` returns a colourmap
   *index*, which as a `newimage` fill value is garbage — the original `wm/vt`
   had this bug (its blank red screen).
2. **The offscreen image is allocated from the window's display**
   (`top.image.display`, valid only after `onscreen`), not from the construction
   `ctxt.display` — an image from another display will not show through the panel.
3. **`putimage` happens in `show()`, after `onscreen`** — the window image a
   panel binds to does not exist earlier, so a `putimage` in `new()` is dropped.
4. **A Tk `<Key>` binding `{send chan {%A}}` delivers the char at index 1**
   (index 0 is the brace), as wm/sh does; reading index 0 sends `{c}` per key.

## Shell plumbing gotcha

`attach` opens the console fds and **keeps the FD references live** for the
command's whole run. Dropping them (e.g. `sys->open(...)` with the result
discarded) lets the GC close the console out from under the shell, which then
runs non-interactively (no prompt) and reads garbage.

Because the VT is a real ANSI terminal, the inner shell runs its own raw-mode
line editor (`readline.b`): Tab completion, history, and emacs-style editing,
all drawn with the small CSI subset this widget renders. So `attach` does **not**
set `$noreadline` (unlike `wm/sh`, which does its line editing in Tk and opts
out). When the editor is active the console is in raw mode, so the widget's
`iomanager` does no echo; the editor echoes. While a command reads stdin the
console is cooked and the `iomanager` supplies a minimal echo/backspace line
discipline. `\n` is treated as newline+return (Plan 9 convention), so programs
that emit bare `\n` and those that emit `\r\n` both lay out correctly.

## Limitations / next steps

- Fixed `cols × rows` (no live resize yet) and no scrollback buffer.
- Scrolls are whole-line; insert/delete-char (ICH/DCH) shift whole-line runs, so
  some partial-region ops are approximate (`ESC[K`/`ESC[J`/`ESC[X` erases are
  column-honest, which is what the shell editor and most apps need).
- No alt-screen (`?1049`) yet, so full-screen apps don't restore the screen on
  exit.

See [`ON_TK_WIDGETS.md`](ON_TK_WIDGETS.md) for the widget contract this follows
and [`ON_GRAPHICS.md`](ON_GRAPHICS.md) for the Draw/Tk panel model.
