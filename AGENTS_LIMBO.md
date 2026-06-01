# Limbo Language and Compiler — Agent Reference

Limbo is the application programming language of Inferno. It compiles to Dis bytecode and runs on the Dis VM. This document covers the language itself, the module system, and the compiler pipeline.

---

## Overview

Limbo is a statically typed, concurrent, garbage-collected language. Its key influences are C (syntax), CSP (concurrency via channels), and Modula-3 (modules and ADTs). It compiles to Dis bytecode which is fully portable across all Inferno platforms.

**Key files**:
- `limbo/` — the compiler source
- `module/*.m` — module interface definitions (the standard library API)
- `appl/**/*.b` — application source files
- `dis/**/*.dis` — compiled output (pre-built, checked in)
- `include/isa.h` — Dis opcodes the compiler emits

---

## Language Syntax

### Module Declaration

Every `.b` file begins with an implementation statement and includes for modules it uses:

```limbo
implement MyModule;

include "sys.m";
    sys: Sys;

include "draw.m";
    draw: Draw;

MyModule: module {
    PATH: con "$MyModule";
    init: fn(ctxt: ref Draw->Context, argv: list of string);
};
```

- `implement MyModule` — names this file's implementation.
- `include "sys.m"` — imports the interface definitions from a `.m` file.
- `sys: Sys;` — declares a variable `sys` of type `Sys` (module reference, initially nil).
- The module body defines the public interface (what callers can import).
- `PATH` is the conventional constant giving the module's `.dis` file path.

### Loading Modules

```limbo
sys = load Sys Sys->PATH;
```

- `load` takes a module type and a string path, returns a module reference.
- Fails at runtime if the `.dis` file is not found or has a type mismatch.
- The returned reference is used to call functions: `sys->write(...)`.

### init Function

The entry point for most Limbo programs:

```limbo
init(ctxt: ref Draw->Context, argv: list of string)
{
    sys = load Sys Sys->PATH;
    # ...
}
```

`ctxt` is the graphics context (nil for non-graphical programs). `argv` is the argument list.

---

## Type System

### Scalar Types

| Type     | Size    | Description |
|----------|---------|-------------|
| `byte`   | 8-bit   | Unsigned byte |
| `int`    | 32-bit  | Signed integer |
| `big`    | 64-bit  | Signed 64-bit integer |
| `real`   | 64-bit  | IEEE-754 double |
| `string` | —       | Immutable Unicode string |

### Compound Types

```limbo
# Array (mutable, fixed length after creation)
a: array of int;
a = array[10] of int;   # allocate
a[0] = 42;

# List (immutable singly-linked)
l: list of string;
l = "hello" :: "world" :: nil;
head := hd l;           # first element
tail := tl l;           # rest of list

# Tuple (fixed-size anonymous product)
pair: (int, string);
pair = (1, "one");
(n, s) := pair;         # destructure

# Reference (heap-allocated, GC'd)
p: ref MyAdt;
p = ref MyAdt(x, y);
```

### ADTs (Abstract Data Types)

ADTs are Limbo's struct/union. They can have pick (tagged union) variants:

```limbo
Tree: adt {
    val: int;
    pick {
    Leaf =>
        # no extra fields
    Node =>
        left:  ref Tree;
        right: ref Tree;
    }
};

# Construction
leaf := ref Tree.Leaf(42);
node := ref Tree.Node(0, leaf, leaf);

# Pattern matching (tagof)
case tagof t {
Tree.Leaf =>
    sys->print("leaf %d\n", t.val);
Tree.Node =>
    # t is now type Tree.Node, can access t.left, t.right
    process(t.left);
}
```

### Channels

Channels are the primary concurrency primitive:

```limbo
# Unbuffered channel
c := chan of int;

# Buffered channel (buffer size 10)
c := chan[10] of int;

# Send
c <-= 42;

# Receive
v := <-c;
```

### Functions

```limbo
add: fn(a, b: int): int
{
    return a + b;
}

# Function value (first-class)
f: fn(int, int): int;
f = add;
result := f(1, 2);
```

---

## Concurrency

### Spawning Threads

```limbo
spawn worker(channel);
```

Creates a new Limbo thread (Prog) that executes `worker(channel)`. Threads share no mutable state except through channels (or explicit shared refs — avoid these).

### Alt Statement (Select)

```limbo
alt {
case v = <-chan1 =>
    # received v from chan1
case chan2 <-= data =>
    # sent data to chan2
* =>
    # default: none ready (only in non-blocking alt)
}
```

`alt` blocks until at least one of the listed channel operations can proceed, then executes exactly one branch. If multiple are ready, one is chosen at random (fair selection).

### Typical Producer-Consumer Pattern

```limbo
producer(out: chan of int)
{
    for(i := 0; i < 100; i++)
        out <-= i;
    out <-= -1;    # sentinel
}

consumer(in: chan of int)
{
    for(;;) {
        v := <-in;
        if(v == -1)
            break;
        sys->print("%d\n", v);
    }
}

# Main
ch := chan of int;
spawn producer(ch);
consumer(ch);
```

---

## Exception Handling

```limbo
{
    result := risky_operation();
} exception e {
    if e == "specific error" =>
        handle_specific();
    else
        raise e;    # re-raise
}
```

- The block after `exception` catches any exception raised in the protected block.
- `e` is bound to the exception string.
- `raise "msg"` raises a new exception (also `raise e` to re-raise).
- Runtime VM exceptions (nil dereference, bounds, zero divide) are also catchable.

---

## Module Interface Files (.m)

`.m` files define the public API of a module — like C headers or Go interfaces.

```limbo
# module/bufio.m
Bufio: module {
    PATH: con "$Bufio";

    EOF:  con -1;
    ERROR: con -2;

    Iobuf: adt {
        # opaque — callers do not access fields directly
        name:  string;

        read:  fn(b: self ref Iobuf, n: int): array of byte;
        write: fn(b: self ref Iobuf, d: array of byte, n: int): int;
        close: fn(b: self ref Iobuf);
        gets:  fn(b: self ref Iobuf, sep: int): string;
    };

    open:   fn(file: string, omode: int): ref Iobuf;
    fopen:  fn(fd: ref Sys->FD, omode: int): ref Iobuf;
    create: fn(file: string, omode, perm: int): ref Iobuf;
};
```

**Key conventions in .m files**:
- `PATH: con "$ModuleName"` — the runtime path, resolved via the namespace.
- `adt` — defines a struct type (fields accessed via `.` on a `ref`).
- `fn(b: self ref Iobuf, ...)` — method syntax: `self` binds to the receiver.
- Functions taking no arguments: `fn(): T`.
- Constants: `con value`.

---

## Standard Modules

### sys.m — System Calls

```limbo
sys = load Sys Sys->PATH;

# File I/O
fd := sys->open("/file", Sys->OREAD);
n  := sys->read(fd, buf, len buf);
n  = sys->write(fd, buf, n);
sys->close(fd);       # explicit close (GC also closes)

# Print
sys->print("hello %s %d\n", name, count);

# Process
sys->sleep(1000);     # sleep milliseconds
sys->pctl(Sys->NEWPGRP, nil);  # new process group

# Bind/mount
sys->bind("/net", "/net", Sys->MREPL);
sys->mount(fd, nil, "/", Sys->MREPL, "");

# Stat
(ok, dir) := sys->stat("/file");

# Pipe
fds := array[2] of ref Sys->FD;
sys->pipe(fds);
```

### draw.m — Graphics

```limbo
draw = load Draw Draw->PATH;

# Context (from init's ctxt parameter)
display := ctxt.display;
screen  := ctxt.screen;

# Create an image
img := display.newimage(r, Draw->RGBA32, 0, Draw->White);

# Draw operations
img.draw(r, src, mask, p);         # draw src onto img
img.line(p0, p1, Draw->Endsquare, Draw->Endsquare, 1, black, p0);
img.text(p, font, "hello", black);

# Flush to display
display.flush();
```

### Other Important Modules

| Module      | Path                 | Purpose |
|-------------|----------------------|---------|
| `Draw`      | `module/draw.m`      | 2D graphics |
| `Tk`        | `module/tk.m`        | Tcl/Tk GUI widgets |
| `Prefab`    | `module/prefab.m`    | Higher-level GUI widgets |
| `Dial`      | `module/dial.m`      | Network connections |
| `Auth`      | `module/auth.m`      | Authentication |
| `Keyring`   | `module/keyring.m`   | Key management |
| `Regex`     | `module/regex.m`     | Regular expressions |
| `Bufio`     | `module/bufio.m`     | Buffered file I/O |
| `Styx`      | `module/styx.m`      | 9P protocol server |
| `Math`      | `module/math.m`      | Math functions |
| `Crypt`     | `module/crypt.m`     | Cryptographic ops |
| `SSL`       | `module/ssl3.m`      | TLS/SSL |
| `String`    | `module/string.m`    | String utilities |

---

## Compiler Pipeline

**Directory**: `limbo/`

### Source Files

| File           | Lines | Role |
|----------------|-------|------|
| `limbo.y`      | —     | YACC grammar → `y.tab.c` |
| `lex.c`        | 1453  | Lexical analyzer |
| `com.c`        | 1510  | Semantic analysis, instruction generation |
| `ecom.c`       | 2558  | Expression compilation |
| `gen.c`        | 1096  | Low-level code generation |
| `typecheck.c`  | 3627  | Type checking |
| `types.c`      | 4745  | Type representation and equivalence |
| `decls.c`      | —     | Declaration processing |
| `nodes.c`      | —     | AST node operations |
| `optim.c`      | 1803  | Peephole optimization |
| `asm.c`        | 6558  | Output: text assembly or binary .dis |
| `sbl.c`        | —     | Symbol table management |
| `dtocanon.c`   | —     | Floating-point canonical form |
| `dis.c`        | —     | Binary .dis writer |
| `stubs.c`      | —     | Built-in function stubs |

### Compilation Phases

```
1. LEXICAL ANALYSIS (lex.c)
   Input: UTF-8 .b source
   Output: token stream
   
   Handles:
   - Keywords: implement, include, module, adt, fn, spawn, load,
               alt, case, pick, for, while, if, else, return, raise, etc.
   - Literals: integers (decimal, hex with 16r prefix), reals, strings, big
   - Comments: # to end of line
   - Unicode identifiers

2. PARSING (limbo.y → y.tab.c)
   Input: token stream
   Output: AST of Node and Decl structures
   
   Grammar highlights:
   - Module declarations with pick ADTs
   - Channel types with optional buffer size
   - Function types with exception lists
   - Alt statements with case branches

3. DECLARATION PROCESSING (decls.c)
   Input: AST
   Output: annotated AST with resolved symbols
   
   - Builds symbol tables (package scope, function scope)
   - Handles imports: include "foo.m" pulls in Foo's interface
   - Assigns stack offsets to local variables
   - Assigns module-data offsets to globals

4. TYPE CHECKING (typecheck.c, types.c)
   Input: annotated AST
   Output: fully typed AST
   
   - Type inference for variables declared with :=
   - ADT method resolution (self ref T)
   - Channel type compatibility
   - Function signature checking at load points
   - Exception type analysis

5. CODE GENERATION (com.c, ecom.c, gen.c)
   Input: typed AST
   Output: Inst[] (Dis instruction array)
   
   - Expression compilation: ecom.c handles all expression forms
   - Statement compilation: com.c handles control flow
   - Temporaries: allocated in frame (like registers)
   - IFRAME/ICALL/IRET for function calls
   - ISPAWN for goroutines
   - IALT/INBALT for channel select
   - IRAISE/exception handlers for try/catch

6. OPTIMIZATION (optim.c)
   Peephole passes:
   - Dead code elimination
   - Constant folding
   - Copy propagation
   - Jump shortening

7. OUTPUT (asm.c, dis.c)
   - asm.c: human-readable assembly (for debugging: limbo -S)
   - dis.c: binary .dis file (production output)
   - Emits type descriptors with GC pointer maps
   - Emits data section with initializers
   - Emits link table for external references
```

### AST Data Structures

```c
// AST node (limbo.h)
struct Node {
    Src  src;           // source location
    uchar op;           // Oadd, Osub, Oif, Ofor, Ocall, ...
    uchar addable;      // address mode hint for code gen
    Node *left, *right; // child nodes
    Type *ty;           // resolved type
    Decl *decl;         // declaration this refers to
    Long val;           // constant integer value
    Real rval;          // constant real value
};

// Declaration (limbo.h)
struct Decl {
    Src   src;
    uchar store;        // Dglobal, Dlocal, Dfn, Dtype, Dconst, ...
    Type  *ty;          // declared type
    Sym   *sym;         // name
    long  offset;       // stack or module-data offset
    Node  *init;        // initializer expression
    Desc  *desc;        // type descriptor for GC
    Decl  *next;        // linked list in scope
};

// Type (limbo.h)
struct Type {
    uchar kind;         // Tadt, Tarray, Tchan, Tfn, Tint, Tstring,
                        // Treal, Tbig, Tbyte, Tlist, Tref, ...
    long  size;         // size in bytes
    Type  *tof;         // element type (for arrays, refs, chans)
    Decl  *ids;         // members (for adts), parameters (for fns)
    Decl  *tags;        // pick variant tags (for adts)
};
```

### Compiler Invocation

```sh
limbo [-o outfile] [-I incdir] file.b

# Flags:
#  -o out.dis   output file (default: file.dis)
#  -I dir       add to include search path
#  -a           generate abstract header (for C interface generation)
#  -S           output assembly text instead of binary
#  -G           emit debug info
#  -g           enable bounds checking
```

The `limbo -a module.m` invocation generates C header files (`runt.h`, `sysmod.h`, etc.) used by `libinterp` to define the C-side function stubs for built-in modules. This is how Limbo calls into C (e.g., `sys->read` calls C code in `libinterp`).

---

## Built-in Modules (C-Implemented)

Some modules have no `.b` implementation — they are implemented entirely in C, linked directly into the emulator binary. Their `.m` interface files describe the API; the C stubs are generated by `limbo -a`.

Key built-in modules:
- `Sys` — all system calls (open, read, write, pipe, mount, bind, etc.)
- `Draw` — all drawing operations
- `Math` — math functions (`sin`, `cos`, `sqrt`, etc.)
- `Keyring` — low-level crypto operations

Non-built-in modules (pure Limbo, in `appl/lib/`) include Auth, Bufio, Regex, String, etc.

---

## Common Patterns

### Error Handling Without Exceptions

```limbo
(n, err) := sys->stat(path);
if(n < 0) {
    sys->print("stat failed: %s\n", err);
    return;
}
```

### Reading a File

```limbo
include "sys.m";
    sys: Sys;

readfile(path: string): array of byte
{
    fd := sys->open(path, Sys->OREAD);
    if(fd == nil)
        return nil;
    buf := array[8192] of byte;
    n := sys->read(fd, buf, len buf);
    if(n <= 0)
        return nil;
    return buf[0:n];
}
```

### Spawning with a Channel

```limbo
reply := chan of string;
spawn background(reply);
result := <-reply;

background(c: chan of string)
{
    # ... do work ...
    c <-= "done";
}
```

### Working with Lists

```limbo
# Build a list
items: list of int = nil;
for(i := 0; i < 10; i++)
    items = i :: items;      # prepend (:: is cons)

# Reverse it
rev: list of int = nil;
for(l := items; l != nil; l = tl l)
    rev = hd l :: rev;

# Iterate
for(l := rev; l != nil; l = tl l)
    sys->print("%d\n", hd l);
```

### String Operations

```limbo
include "string.m";
    str: String;
str = load String String->PATH;

# Split
parts := str->split(line, " \t");

# Trim
s := str->drop(s, " \t\n");      # drop leading whitespace
s  = str->dropr(s, " \t\n");     # drop trailing whitespace

# Find
idx := str->find(haystack, needle);
```

---

## dis/ Directory

The `dis/` directory contains pre-compiled `.dis` files for all applications. When Inferno runs, it reads from `dis/`, not from `appl/`. This means:

- Editing a `.b` file in `appl/` requires recompiling to update `dis/`.
- The `dis/` files are checked into the repo so Inferno can run without a working Limbo compiler.

```sh
# Recompile a single app
limbo -o dis/cmd/myapp.dis appl/cmd/myapp.b

# Recompile all apps (using mk)
cd appl && mk install
```

---

## Debugging Tips

- `limbo -S file.b` — dump assembly to see what instructions are generated.
- `disdump dis/cmd/myapp.dis` — disassemble a .dis file.
- `prof` — Limbo profiler (counts instruction executions per source line).
- Add `sys->print(...)` calls liberally — Limbo has no debugger breakpoints in standard operation.
- Exception string `"dereference of nil"` → check every `load` return value and every `ref` usage.
- `raise "custom error"` can be caught by a parent's `exception` block for structured error passing.
