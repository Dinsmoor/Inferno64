# The Inferno Shell (sh)

> *So you want to use or hack on the Inferno shell?* This is the reference.

`sh` is Inferno's command language (`appl/cmd/sh/sh.b`, interface `module/sh.m`,
compiled to `/dis/sh.dis`). It is **not** a Bourne/`rc` clone with extra commands —
it is a small language where *everything is a command* and *every value is a list of
strings*, control flow is provided by **loadable builtin modules**, and the parser is
a real yacc grammar (`sh.y`). The original design is the paper
[`docs/ref/sh.pdf`](ref/sh.pdf) ("The Inferno Shell"); this doc is the living
fork-specific counterpart.

> **This repo differs from stock Inferno** in three ways that matter at the prompt:
> 1. **Bash-like interactive line editing, history, and Tab completion** (the
>    `Readline` module — commit `58f946cb`). Stock `sh` reads the console cooked,
>    one line at a time, with no recall.
> 2. **Recompile-on-ABI-mismatch**: running a `.dis` built for the wrong Dis ABI
>    width transparently rebuilds it from source instead of failing (commits
>    `0f4d1c68` + `f728bcdf`; see `ON_DIS_ARCH.md`).
> 3. **`-l` login shells** run an rc script (`/lib/sh/profile`).
>
> A model trained on stock Inferno `sh` will not expect any of these.

---

## The model in one paragraph

A shell value is a **list of strings**. A bare word is a one-element list; `()` is the
empty list; `(a b c)` is a three-element list; **concatenation** distributes
(`a^(b c)` → `(ab ac)`). There is no separate "command" type: a command is just a
list whose head names something to run, and a **brace block `{ … }`** is a first-class
value (an unevaluated command) you can pass to other commands. That is why control
flow is *commands*, not syntax: `if`, `while`, `for` are builtins that take brace
blocks as arguments. `$name` substitutes a variable (itself a list); `` `{cmd} ``
substitutes a command's output (split into a list); `${builtin …}` calls a
substitution builtin. Quoting is single-quote with doubled-quote escape:
`'it''s'` → `it's`.

---

## Invocation & flags

```
sh [ -ilxnev ] [ -c command ] [ file [ arg ... ] ]
```

| Flag | Meaning (`Context` option / behaviour) |
|---|---|
| `-i` | force **interactive** (`Context.INTERACTIVE`) even if stdin isn't a console |
| `-l` | **login** shell — run the rc script `/lib/sh/profile` (`LIBSHELLRC`) before anything else. Also implied when `argv[0]` begins with `-`. |
| `-n` | do **not** fork the namespace (`pctl FORKNS` is skipped) |
| `-e` | `ERROREXIT` — exit on the first command that fails |
| `-x` | `EXECPRINT` — trace: echo each command before running it |
| `-v` | verbose |
| `-c command` | run `command` (wrapped in `{…}`) and exit (unless also `-i`) |
| *file args* | run `file` as a script with `$0`=file, `$*`=args |

With no `file` and no `-c`, `sh` reads from stdin; if stdin is a real console
(`isconsole`, compared against `/dev/cons`) it goes interactive. On startup it always
`pctl(FORKFD)` and, unless `-n`, `pctl(FORKNS)`.

---

## Variables, scope, and the environment

- **Assignment** is `name = value` (value is a list): `x = (a b c)`; `path = /dis .`.
- `$name` expands; `$#name` is the list length; `$"name"` joins the list into one
  string with spaces.
- **Scope**: `local name = …` makes a variable local to the enclosing brace block;
  ordinary `=` sets it in the current environment. The `Context` keeps a stack of
  local frames (`push`/`pop`, `Localenv`); a forked command (`&`, pipes) gets a
  copy.
- Variables are exported to spawned `.dis` commands as the Inferno environment
  (`#e`/`/env`); `Var.NOEXPORT` suppresses that.
- `$*` is the argument list, `$0` the script name, `$apid` the pid of the last `&`,
  `$status` the last command's exit status.

---

## Loadable builtin modules

The shell core knows almost no commands; it gains them by **loading modules** that
register builtins into the `Context`. This is the central extensibility mechanism.

```
load std        # control flow + list ops (almost always wanted)
load expr       # integer arithmetic
load regex      # regular expressions
load string     # string utilities
```

A loaded module implements the `Shellbuiltin` interface (`module/sh.m`):

```limbo
Shellbuiltin: module {
    initbuiltin: fn(c: ref Sh->Context, sh: Sh): string;
    runbuiltin:  fn(c, sh, cmd: list of ref Sh->Listnode, last: int): string;
    runsbuiltin: fn(c, sh, cmd: list of ref Sh->Listnode): list of ref Sh->Listnode;
    whatis:      fn(c, sh, name: string, wtype: int): string;
    getself:     fn(): Shellbuiltin;
    BUILTIN, SBUILTIN, OTHER: con iota;
};
```

Two kinds of builtin:

- **builtins** (`addbuiltin`) are *commands* — they run for a status string and side
  effects: `if`, `while`, `for`, `and`, `or`, `~` (match), `!` (negate), `apply`,
  `fn`/`subfn` (define a shell function), `status`, `raise`, `rescue`, `pctl`,
  `flag`, `getlines`, `no`. (All from `std.b`.)
- **substitution builtins** (`addsbuiltin`) are called as `${name …}` and return a
  *list*: `hd`, `tl`, `index`, `split`, `join`, `pid`, `parse`, `env`, `pipe`.

`load`, `unload`, `loaded`, `builtin`, `whatis` are themselves shell builtins for
managing this table. Control flow therefore reads as ordinary commands:

```
if {~ $#* 0} {echo no args} {echo $#* args}
for i in `{ls} { echo got $i }
while {test cond} { … }
```

Other loadable modules in `appl/cmd/sh/`: `expr`/`mpexpr` (arithmetic), `regex`,
`string`, `test`, `tk` (Tk from the shell), `file2chan`, `sexprs`, `csv`, `echo`,
`arg`, `mload`.

---

## Running external programs

`runexternal` (`sh.b`) resolves a command name against `$path` (default `/dis .`),
appends `.dis` unless the name already ends in `.dis`, and `load`s it as the
`Command` module (`init(ctxt, argv)`). The last command in a pipeline runs in-process;
others are `spawn`ed. If the name isn't a `.dis` but is an executable file, `sh` reads
a `#!` header and runs it as a script (`runhashpling`).

### Recompile-on-ABI-mismatch (fork-specific)

When `load Command` fails because the `.dis` was compiled for a **different Dis ABI
width** (e.g. an ILP64 module on this LP64 build — the loader raises
`"… wrong Dis ABI width"`), `sh` does not just error out:

1. `wrongwidth()` matches the loader error suffix.
2. `discsrc()` reads the source path embedded at the tail of the `.dis` (the Limbo
   `source` directive — a trailing NUL-terminated absolute path), decoded
   **width-agnostically** so it works regardless of the module's ABI.
3. If that source exists, `recompilemod()` prints a diagnostic and runs
   `limbo -I /module -o <path> <src>` to rebuild it with the running system's
   compiler, then retries the load **once**.

This is what lets a tree of mixed-ABI `.dis` files self-heal at first use rather than
silently corrupting or hard-failing. The magic/width machinery it keys off is
documented in **`ON_DIS_ARCH.md`** (`.dis` magic per ABI).

---

## Interactive line editing, history & completion (fork-specific)

Stock `sh` reads the console in cooked mode. This fork attaches a raw-mode line
editor, the **`Readline`** module (`appl/cmd/sh/readline.b`, interface
`module/readline.m`, `/dis/sh/readline.dis`), whenever the shell is interactive and
stdin is a real console (`setupreadline`).

- **Raw mode is scoped to the keystroke loop**: the editor flips `/dev/consctl` to
  raw only while a line is being typed and restores cooked mode before the command
  runs, so spawned programs see a normal console. Editing/redraw use a small subset of
  ANSI/VT sequences understood by xterm-like terminals.
- **Key bindings** (`readline.b`): `C-a` home, `C-e` end, `C-b`/`C-f` left/right,
  `C-h`/DEL backspace, `C-d` EOF (empty line) / delete-forward, `C-k` kill to
  end-of-line, `C-u` kill to start, `C-w` kill previous word, `C-l` clear screen,
  `C-p`/`C-n` previous/next history, `C-c` cancel the line, **Tab** filename/command
  completion.
- **Persistent history**: kept in `$home/lib/sh_history` (falls back to
  `/tmp/lib/sh_history`), bounded to `histmax` 200 entries; `loadhist` on start,
  `addhist`/`savehist` as you go.
- **Prompt**: the shell sets `lex.prompt1` from `$prompt` and lets the editor draw it;
  it only echoes the prompt itself when reading a cooked (non-editor) console.
- **Opting out**: set `$noreadline` to disable the editor. The Tk shell window
  (`wm/sh`) does its own editing and sets this so `sh` doesn't spray escape sequences
  at it. The editor also declines gracefully (returns nil from `open`, falling back to
  cooked reads) on pipes, scripts, and consoles it can't drive in raw mode.

---

## The Sh module interface (embedding the shell)

`module/sh.m` exposes the shell to other Limbo programs:

| Entry | Use |
|---|---|
| `init(ctxt, argv)` | run as a command (the `Command` interface) |
| `system(ctxt, cmd)` | parse + run a command string, return status |
| `run(ctxt, argv)` | run an already-tokenised argument list |
| `parse(s)` → `(ref Cmd, err)` | parse to a syntax tree (`Node`) without running |
| `cmd2string` / `quoted` | render a tree / quote a value list back to source |
| `Context` | the execution environment: `new`, `get`/`set`/`setlocal`, `push`/`pop`, `copy`, `run`, `add*builtin`, `options`/`setoptions` |

`wm/sh` and any app that wants "run this shell line" use `system`/`run`; tools that
manipulate shell source (formatters, the debugger) use `parse`/`cmd2string`.

---

## Key files

| File | Purpose |
|---|---|
| `appl/cmd/sh/sh.b` | the shell core: parser glue, evaluation, external exec, recompile-on-mismatch |
| `appl/cmd/sh/sh.y` | the yacc grammar |
| `module/sh.m` | `Sh` / `Command` / `Shellbuiltin` interfaces, node types |
| `appl/cmd/sh/std.b` | control-flow + list builtins (`if`/`while`/`for`/`~`/`hd`/`tl`/…) |
| `appl/cmd/sh/readline.b`, `module/readline.m` | the raw-mode line editor (history, completion) |
| `appl/cmd/sh/{expr,mpexpr,regex,string,test,tk,sexprs,csv,file2chan,echo,arg,mload}.b` | other loadable builtin modules |
| `man/1/sh`, `man/2/sh` | the command manual / the `Sh` module manual |

**Cross-references:** `ON_DIS_ARCH.md` (the `.dis` ABI-width magic the recompile
feature keys off) · `ON_LIMBO.md` (the language the shell and its modules are
written in) · `ON_NAMESPACE.md` (`pctl FORKNS`, the per-shell namespace) ·
`ON_GRAPHICS.md` (`wm/sh`, the Tk shell window) · `docs/ref/sh.pdf` (the original
design paper).
