# Limbo Language Reference for Inferno OS

Limbo is the primary language for Inferno. It is statically typed, garbage collected, and has first-class concurrency via channels and threads. Its syntax is C-like but its type system and module system are different enough to trip up anyone expecting C or Go.

## Module System

### The Two-File Pattern

Every module has two files:

- **`.m` file** — the interface (declarations only, no code)
- **`.b` file** — the implementation

```
module/sys.m       ← declares Sys module: types, constants, fn signatures
appl/lib/sys.b     ← implements Sys (or it may be built-in)
```

An `.m` file contains a module block:

```limbo
Sys: module
{
    PATH:    con "$Sys";       # load path; "$Sys" means built-in
    Maxint:  con 2147483647;

    Qid: adt {
        path:  big;
        vers:  int;
        qtype: int;
    };

    open:  fn(s: string, mode: int): ref FD;
    read:  fn(fd: ref FD, buf: array of byte, n: int): int;
    # ...
};
```

### implement

Every `.b` file begins with `implement`:

```limbo
implement Echo;     # appl/cmd/echo.b:1
```

This declares which module is being implemented. The compiler checks that the file provides everything the `.m` declares.

### include and Module Variables

`include` brings an `.m` file's declarations into scope. After including, you declare a module variable to hold the loaded instance:

```limbo
include "sys.m";
    sys: Sys;         # module variable — nil until load succeeds

include "draw.m";
    draw: Draw;
    Context: import Draw;   # lift one name into scope

include "bufio.m";
    bufio: Bufio;
    Iobuf: import bufio;    # import from variable, not type
```

`include` happens at compile time. The variable `sys` is nil at runtime until `load` is called.

### load

`load` is a builtin that dynamically loads a `.dis` file and returns a module reference:

```limbo
sys  = load Sys  Sys->PATH;
bufio = load Bufio Bufio->PATH;
```

`load` returns nil on failure. **Always check for nil before calling any function through the module variable.** Calling through nil gives `"dereference of nil"`.

```limbo
sys = load Sys Sys->PATH;
if(sys == nil)
    raise "fail:cannot load Sys";
```

PATH constants follow two conventions:

```limbo
PATH: con "$Sys";                  # built-in kernel module
PATH: con "/dis/lib/bufio.dis";    # user module at fixed path
```

Each `load` call creates an independent instance; two loads of the same `.dis` do not share global state.

### import

`import` pulls specific names from a module type or variable into the local scope:

```limbo
FD, Dir: import Sys;               # constants and types from the type
Iobuf: import bufio;               # type from the variable (must have been loaded)
One, Thing: import M;              # general form
```

After `import Sys`, you write `FD` instead of `Sys->FD`. After `import bufio`, `Iobuf` works directly.

### The init Convention

Commands have this exact signature:

```limbo
MyCmd: module {
    init: fn(nil: ref Draw->Context, nil: list of string);
};

init(ctxt: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    # ...
}
```

The shell passes `ctxt` (graphics context, nil for console-only apps) and `args` (argv including `args[0]` = command name). There is no return value; the command exits when `init` returns.

---

## Types

### Scalar Types

| Type | Width | Notes |
|------|-------|-------|
| `int` | 32-bit signed | default integer |
| `big` | 64-bit signed | use for file offsets, Qid.path |
| `byte` | 8-bit unsigned | elements of `array of byte` |
| `real` | 64-bit IEEE double | |
| `string` | Unicode | immutable; indexing yields int (codepoint) |

`byte` only appears as the element type of `array of byte`. You cannot declare a standalone `byte` variable.

`big` literals: `big 0`, `big 1024`, `big n` (cast from int). Suffix `L` is not used.

### Reference Types

All reference types have zero value `nil`. Passing them copies the reference, not the data.

| Type | Notes |
|------|-------|
| `array of T` | fixed-length; `array[n] of T` allocates |
| `list of T` | singly-linked, immutable structure |
| `chan of T` | see AGENTS_CONCURRENCY.md |
| `ref T` | pointer to an ADT instance |
| module type | handle to a loaded module |

### Strings vs Byte Arrays

Strings are Unicode character sequences. `array of byte` is raw bytes (typically UTF-8). Convert between them:

```limbo
s := "Ångström";
a := array of byte s;    # encode to UTF-8
s  = string a;           # decode from UTF-8

# Individual character (Unicode codepoint as int)
c := s[3];               # int
# Byte slice
sub := s[1:4];           # string
```

### nil and Zero Values

- Module-level variables: arithmetic types are 0, reference types are nil
- Local variables inside functions: **undefined** (not zero) — always initialize
- `nil` can be assigned to any reference type

---

## Declarations

### Constants (con)

```limbo
MAXSIZE: con 4096;
VERSION: con "9P2000";
FLAG:    con 1 << 3;
```

Constants must be compile-time expressions. You cannot use `con` with a runtime value.

### iota

In a comma-separated constant declaration, `iota` starts at 0 and increments for each name:

```limbo
Pready, Palt, Psend, Precv, Pexiting, Pbroken: con iota;
# Pready=0, Palt=1, Psend=2, Precv=3, Pexiting=4, Pbroken=5

M0, M1, M2, M3: con (1 << iota);
# M0=1, M1=2, M2=4, M3=8
```

### Variable Declaration

```limbo
x := 42;             # declare + assign (type inferred)
var y: int;          # declare without assign (module-level only)
x = x + 1;          # assign to existing variable
```

`:=` declares a new variable in the current scope. `=` assigns to an existing one. At module level, use `var` for declarations without initialization.

### Type Aliases

```limbo
Line: type int;
```

Transparent alias — `Line` and `int` are fully interchangeable.

---

## ADTs

An ADT is a struct that can also have methods.

```limbo
Point: adt {
    x, y: int;

    add: fn(p: self Point, q: Point): Point;
    eq:  fn(p: self Point, q: Point): int;
};
```

`self` makes the receiver implicit — `p.add(q)` works without passing `p` explicitly.

Implement methods outside the ADT body:

```limbo
Point.add(p: self Point, q: Point): Point
{
    return (p.x + q.x, p.y + q.y);
}
```

Allocate with `ref`:

```limbo
p := ref Point(10, 20);   # allocates, returns ref Point
p.x = 5;
```

### Pick ADTs (Discriminated Union)

`pick` is a tagged union. Every value carries a runtime tag identifying which variant it is. A `pick` ADT can only be used as `ref`.

```limbo
Tmsg: adt {
    tag: int;           # fields before pick are shared by all variants
    pick {
    Version =>
        msize:   int;
        version: string;
    Attach =>
        fid, afid: int;
        uname, aname: string;
    Walk =>
        fid, newfid: int;
        names: array of string;
    Clunk or Stat or Remove =>   # grouped variants share the same fields
        fid: int;
    }
};
```

Rules:
- `pick` must be the last member
- Only one `pick` block per ADT
- Use `or` to group variants that share fields
- Can only be used as `ref Tmsg`, never as a value type

**Pattern matching** with `pick`:

```limbo
pick t := tmsg {
Version =>
    sys->print("version %s\n", t.version);   # t has type ref Tmsg.Version
Attach =>
    sys->print("attach fid=%d\n", t.fid);    # t has type ref Tmsg.Attach
Clunk or Stat or Remove =>
    sys->print("fid=%d\n", t.fid);
* =>
    # default case
}
```

Inside each arm, the bound variable has the specific variant type with its fields accessible directly.

**`tagof`** — get the tag of a pick variant at compile time or runtime:

```limbo
if(tagof m == tagof Rmsg.Readerror)
    handle_error(m);

# Build dispatch table indexed by tag
table := array[tagof Rmsg.Stat + 1] of string;
table[tagof Rmsg.Version] = "version";
table[tagof Rmsg.Attach]  = "attach";
```

---

## Functions

### Declaration

```limbo
add(a, b: int): int
{
    return a + b;
}
```

Parameters with the same type can be grouped: `a, b: int`. Return type follows the colon.

### Multiple Return Values

```limbo
splitl(s, cl: string): (string, string)
{
    for(i := 0; i < len s; i++)
        if(in(s[i], cl))
            return (s[0:i], s[i:]);
    return (s, "");
}

# Caller
(left, right) := splitl("hello:world", ":");
(result, nil) := splitl("hello", ":");   # discard second value
```

### Variadic

Only built-in functions (`sys->print`, `sys->sprint`, `sys->fprint`) are variadic (declared with `*`). User-defined functions cannot be variadic.

---

## Control Flow

### if / else

```limbo
if(x > 0)
    positive();
else if(x < 0)
    negative();
else
    zero();
```

The condition must be `int` (or `big`). Non-zero is true.

### for / while

```limbo
for(i := 0; i < len a; i++)
    process(a[i]);

while(list != nil) {
    x := hd list;
    list = tl list;
    process(x);
}
```

Both `for` and `while` have `break` and `continue`. Labels are supported:

```limbo
outer: for(i := 0; i < n; i++)
    for(j := 0; j < m; j++)
        if(done(i, j))
            break outer;
```

### case

```limbo
case c {
'a' or 'e' or 'i' or 'o' or 'u' =>
    vowel++;
'a' to 'z' =>
    consonant++;
* =>
    other++;
}
```

Works on `int`, `big`, and `string`. Cases do not fall through. `to` denotes an inclusive range. `*` is the default. Each arm is a separate scope.

---

## Expressions

### Send and Receive

```limbo
c <- = value;        # send: c <-= value (note: no space between <- and =)
x  := <-c;          # receive
```

The `<-=` operator sends. The `<-` prefix expression receives. Both block if the channel is not ready (unless in an alt with `*`).

Receiving from an array of channels yields an index and value:

```limbo
(i, v) := <-a;    # a is array of chan of T; i is which channel fired
```

### List Operations

```limbo
new_list := element :: existing_list;   # cons: prepend
first    := hd list;                    # head
rest     := tl list;                    # tail

# Iteration idiom
for(; l != nil; l = tl l)
    process(hd l);
```

`hd nil` and accessing through nil is a runtime error.

### Tuple Unpacking

```limbo
(x, y)    := point;           # unpack a tuple or ADT into two vars
(x, nil)  := splitl(s, ":");  # discard second value
(a, b, c) = tuple_expr;       # assign to existing vars
```

### Slicing

Slicing works on strings and arrays:

```limbo
sub  := s[i:j];      # s[i] through s[j-1]
rest := s[i:];       # from i to end
head := s[:j];       # from start to j-1
a[2:] = b;           # copy b into a starting at index 2
```

String indexing with a single subscript yields an `int` (Unicode codepoint):

```limbo
c := s[0];           # int, not string
```

### Arithmetic on big

Use `big` casts when mixing with int:

```limbo
offset := big n * big BLOCKSIZE;
n      := int (offset / big 512);
```

The `~` operator is bitwise complement: `~big 0` is all-ones (64-bit).

---

## Exception Handling

```limbo
{
    do_something();
} exception e {
"fail:*" =>
    sys->fprint(stderr, "command failed: %s\n", e[5:]);
"out of memory:*" =>
    handle_oom();
"*" =>
    sys->fprint(stderr, "unexpected: %s\n", e);
    raise;     # re-raise the caught exception
}
```

- The exception handler wraps a block, not a function
- Patterns are glob-matched against the exception string
- `*` is a wildcard (matches any suffix, including empty)
- `raise;` (no argument) re-raises the current exception
- `raise "string"` raises a new exception

**The `"fail:reason"` convention**: commands raise `"fail:something"` to signal non-zero exit. The shell reads the reason after `fail:` as the exit status string. Use it for user-visible errors.

```limbo
raise "fail:usage";
raise "fail:cannot open " + path;
```

---

## Arrays

```limbo
a := array[10] of int;              # 10 ints, initialized to 0
b := array[] of {1, 2, 3, 4};      # infer size from init list
c := array[5] of {* => -1};        # all elements = -1
d := array[n] of ref Foo;          # n refs, all nil

len a                               # number of elements
a[i:j]                             # slice (shares backing memory)
a[i:] = b                          # copy b's elements into a from index i
```

Array assignment copies the reference, not the data. To copy data use slice assignment:

```limbo
dst[0:] = src;   # copies min(len dst, len src) elements
```

Multi-dimensional:

```limbo
matrix := array[rows] of array[cols] of real;
matrix[i] = array[cols] of real;    # must allocate each row
matrix[i][j] = 3.14;
```

---

## Lists

```limbo
l: list of string;         # nil initially
l = "a" :: "b" :: "c" :: nil;    # build from right to left

hd l                       # "a"
tl l                       # ("b" :: "c" :: nil)
len l                      # 3

# Idiomatic traversal
for(; l != nil; l = tl l) {
    item := hd l;
    process(item);
}

# Build reversed list
result: list of string;
for(; input != nil; input = tl input)
    result = hd input :: result;
```

Lists are functional (prepend only). There is no O(1) append; to append, reverse twice or use a different structure.

---

## Common Idioms

### Error Return Pattern

The standard library convention for fallible functions:

```limbo
# Declaration
open(path: string): (ref File, string);   # (result, error)

# Implementation
open(path: string): (ref File, string)
{
    fd := sys->open(path, Sys->OREAD);
    if(fd == nil)
        return (nil, sys->sprint("cannot open %s: %r", path));
    return (ref File(fd, path), nil);
}

# Caller
(f, err) := open("/etc/config");
if(err != nil)
    raise "fail:" + err;
```

### The %r Format Verb

`sys->sprint("%r")` and `sys->fprint(stderr, "...: %r\n")` read the current OS error string (set by the last failed syscall). Use it in error messages to get the actual reason.

### Stderr

```limbo
stderr := sys->fildes(2);
sys->fprint(stderr, "%s: error: %r\n", progname);
```

### Module-Level Variable Initialization

```limbo
implement MyMod;

include "sys.m";
    sys: Sys;

var progname: string;   # module-level, initialized to nil/"" at load time

init(nil: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    if(sys == nil)
        raise "fail:cannot load Sys";
    progname = hd args;
    args = tl args;
    # ...
}
```

Module-level variables (`var`) persist for the lifetime of the loaded module. They are shared across all goroutines using that module instance. Protect them with channels if concurrent access is possible.

### Loading Optional Modules Gracefully

```limbo
tls := load TLS TLS->PATH;
if(tls == nil) {
    sys->fprint(stderr, "warning: TLS not available\n");
    # continue without TLS
}
```

### Cyclic ADT Fields

When an ADT field points back to the same or a mutually-referencing type, mark it `cyclic` to tell the GC:

```limbo
Node: adt {
    val:    int;
    next:   cyclic ref Node;   # linked list — GC needs to know about cycle
    parent: cyclic ref Tree;
};
```

Without `cyclic`, the GC may not collect circular structures.

---

## Key Files

| File | Purpose |
|------|---------|
| `doc/limbo/limbo.ms` | Full language specification (4000+ lines, authoritative) |
| `man/1/limbo` | Compiler flags and usage |
| `man/2/0intro` | Language overview, exception conventions |
| `module/sys.m` | Sys module — the foundational interface every program uses |
| `module/draw.m` | Draw module — graphics types |
| `module/bufio.m` | Buffered I/O — good ADT example |
| `module/styx.m` | Styx — good pick ADT example |
| `appl/cmd/echo.b` | Minimal command template |
| `appl/cmd/calc.b` | Larger command with exception handling, case, lists |
| `appl/lib/debug.b` | Error-return tuple idiom throughout |
| `appl/lib/string.b` | Slice and list idioms |
