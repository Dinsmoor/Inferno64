# Limbo Language and Compiler — Agent Reference

> *So you want to write Limbo?* This is the reference.

Limbo is the application programming language of Inferno. It compiles to Dis bytecode and runs on the Dis VM. This document is the authoritative agent reference, derived from the Limbo language specification (`limbo.html`), the Vita Nuova addendum (`addendum.html`), and Kernighan's practical guide (`descent.html`).

---

## Overview

Limbo is strongly-typed, garbage-collected, and concurrent. Key properties:
- **No implicit type coercions** — every conversion is explicit.
- **Automatic GC** — reference-counting (instant-free for non-cyclic); eventual GC for cyclic structures (requires `cyclic` keyword).
- **Modules loaded dynamically** at run time with run-time type checking.
- **Threads are preemptively scheduled**; communication via typed channels only.
- **No pointers to stack objects** — `ref` only points to heap-allocated `adt` values.

**Key directories/files**:
- `limbo/` — compiler source
- `module/*.m` — module interface definitions
- `appl/**/*.b` — application source files
- `dis/**/*.dis` — compiled output (pre-built, checked in)
- `include/isa.h` — Dis opcodes

---

## Lexical Conventions

### Comments
```
# everything from # to end of line
```
No block comments. No preprocessor (`#include`, `#define`, etc. do not exist — use `include "file.m"` instead).

### Identifiers
- Letters (`a-z`, `A-Z`, `_`, Unicode > 160) and digits; first must be a letter.
- Only the first 256 characters are significant; case-sensitive.

### Keywords
```
adt      alt      array    big      break    byte
case     chan     con      continue cyclic   do
else     exit     fn       for      hd       if
implement import   include  int      len      list
load     module   nil      of       or       pick
real     ref      return   self     spawn    string
tagof    tl       to       type     while
```
`iota` and `raises` have special contextual uses but are not reserved.

### Source File Conventions
- Implementation files: suffix `.b` — begin with `implement ModuleName;`
- Interface/declaration files: suffix `.m`
- Compiled output: suffix `.dis`

---

## Type System

### Scalar Types

| Type | Size | Signedness | Notes |
|------|------|-----------|-------|
| `byte` | 8-bit | unsigned | 0–255 |
| `int` | 32-bit | signed | Two's complement |
| `big` | 64-bit | signed | Two's complement |
| `real` | 64-bit | — | IEEE 754 double |
| `string` | — | — | Row of Unicode characters; value semantics |

`byte`, `int`, `big`, `real` are collectively called **arithmetic types**.

### Value vs. Reference Types

**Value types** (copied on assignment/pass): `byte`, `int`, `big`, `real`, `string`, tuples, `adt` (non-ref).

**Reference types** (shared reference on assignment): `list`, `array`, `chan`, modules, `ref adt`, `ref fn`.

### String Type
- `s[i]` yields `int` (Unicode code point); `s[i:j]` is a substring (value copy).
- `len s` — number of Unicode characters (not bytes).
- `nil` string and `""` are **identical** for all relational operators.
- Concatenated with `+`.
- `s[len s] = ch;` — special case: extends string by one character.
- Casts:
  - `string n` where `n` is arithmetic → decimal string (`%g` format for `real`).
  - `string a` where `a` is `array of byte` → UTF-8 decode.
  - `array of byte` of a string → UTF-8 encode.
  - `int "text"` → parses decimal integer (skips leading whitespace, stops at non-digit).

### Tuple Type
```limbo
pair: (int, string);
pair = (1, "one");
(n, s) := pair;              # destructure
(n, nil) := pair;            # discard with nil on left side
```
- Ordered collection of two or more objects, possibly different types.
- Element access: `t.t0`, `t.t1`, ... (zero-based decimal index suffix).
- Type is characterized solely by order and member types; no name.

### Array Type
```limbo
array of data-type           # element type only; size not part of type
```
- Reference semantics (shared reference); indexed from 0, 0-based.
- `len a` — number of elements.
- Slices: `a[e1:e2]` — shared reference into original; `a[e:]` = `a[e:len a]`.
- `a[e:] = b;` — copies `b` into `a` starting at `e` (slice as lvalue).
- **Array slice mutations affect the original** (it is not a copy).

**Array creation forms:**
```limbo
array[n] of Type                         # all elements zero/nil
array[n] of { e0, e1, e2 }              # init list; type inferred
array[] of { e0, e1, e2 }               # size from init list
array[n] of { idx => val, ... }          # indexed initialization
array[n] of { lo to hi => val, ... }     # range init, inclusive (addendum)
array[n] of { * => val }                 # wildcard: fills all unspecified elements
```
Common pattern for 2D arrays (each element gets a fresh inner array):
```limbo
board := array[10] of {* => array[10] of int};
```

### List Type
```limbo
list of data-type
```
- Singly-linked, stack-like; reference semantics.
- `nil` is the empty list.
- **List elements are immutable** — cannot assign `hd l = x;`; must rebuild the list.
- `hd l` — head (first element); runtime error if `l == nil`.
- `tl l` — tail; runtime error if `l == nil`; `nil` if single-element list.
- `e :: l` — prepend `e` to list `l` (right-associative).
- `len l` — number of elements.
- Create: `list of { e1, e2, e3 }` or by consing: `e1 :: e2 :: e3 :: nil`.

### Channel Type
```limbo
chan of data-type            # unbuffered (synchronizing)
chan[n] of data-type         # buffered (buffer of size n)
```
- `chan of T` and `chan[0] of T` are equivalent (unbuffered).
- Buffered: send non-blocking if buffer not full; receive non-blocking if buffer non-empty.
- Declaration alone leaves channel `nil`; must be created with an expression:
```limbo
ch: chan of int;        # nil
ch = chan of int;       # create and assign
ch := chan of int;      # declare-and-create
```
- Send: `ch <-= expr;`
- Receive: `<-ch` (blocks until ready)
- Non-blocking select: use `*` arm in `alt`.

### Abstract Data Types (adt)
```limbo
Point: adt {
    x, y:  int;
    MAGIC: con 42;                              # constant member
    dist:  fn(p: Point): real;                  # function member (value receiver)
    move:  fn(self: self ref Point, dx: int);   # method with self receiver
    pick {
        A =>
            extra: string;
        B or C =>
            flag: int;
    }
};
```
- `adt` has value semantics; `ref adt` has reference semantics (heap-allocated).
- No access control, no inheritance, no constructors/destructors.
- One optional `pick` block, which must appear last.
- Members: data fields, constants (`con`), function declarations, one `pick` block.

**Instantiation (cast syntax):**
```limbo
p := Point(1, 2);              # adt value; args match data members in order; fn members ignored
pp := ref Point(1, 2);         # heap-allocated ref adt
leaf := ref Node.Leaf("tag", 42);   # pick variant
```

**Method `self` parameter:** If the first parameter is named `self`, the receiver is implicit at the call site:
```limbo
Point: adt {
    scale: fn(self: self ref Point, factor: real);
};
# call: p.scale(2.0)  — p passed implicitly; must match self type (ref or value)
```

**Method definition:**
```limbo
Point.move(self: self ref Point, dx: int)
{
    self.x += dx;
}
# Or without self:
Point.dist(p: Point, q: Point): real
{
    d := real(p.x - q.x);
    return d * d;
}
```

**ADT type equality** is **structural** (name is irrelevant):
- Two `adt` types are equal if data members have the same names and types (order insignificant; `cyclic` attribute must match).
- Constants and function members do NOT enter type comparison.
- Consequence: two differently-named `adt`s with identical data members are the same type.

### Pick ADT (Discriminated Union)
```limbo
Node: adt {
    tag: string;    # common field
    pick {
        Leaf =>
            value: int;
        Branch =>
            left, right: cyclic ref Node;
    }
};
```
- A `pick adt` **must always be used as `ref adt`**; no value (non-reference) allowed.
- `tagof expr` — unique `int` per variant; also works on variant type names: `tagof Node.Leaf`.
- `tagof` on the base adt type name gives the tag for the plain (non-variant) base.

**Pick statement (pattern match):**
```limbo
pick x := expr {
    Node.Leaf =>
        # x is ref Node.Leaf; access x.value, x.tag
    Node.Branch =>
        # x is ref Node.Branch; access x.left, x.right, x.tag
    * =>
        # default
}
```
- `expr` must be `ref PickAdt`.
- Bound variable `x` has the specific variant type within each arm.
- Variant name: `AdtName.VariantName`.

### Module Type
```limbo
Mymod: module {
    PATH: con "/dis/mymod.dis";     # conventional; not required
    CONST: con 42;
    MyType: type array of int;
    MyAdt: adt { x, y: int; };
    func: fn(a: int): string;
    init: fn();
};
```
- A module declaration creates a type.
- Constants and types accessible via type name (no loaded handle required): `Mymod->CONST`, `Mymod->MyAdt`.
- Functions require a loaded handle.

**Loading:**
```limbo
m: Mymod;
m = load Mymod Mymod->PATH;
if(m == nil)
    raise "fail:load";
m->init();
result := m->func(42);
```
- Each `load` creates a separate module instance (separate data, shared code).
- Returns `nil` on failure (file not found or interface mismatch). **Always check.**

**Module type equality:** Members must have matching names and equal types; order insignificant; constants and type members excluded from comparison.

### Function Reference Type
```limbo
fp: ref fn(int, string): int;
fp = myfunc;                  # assign from function name
fp = mod->func;               # assign from module function
result := fp(1, "x");         # call
```
- `nil` when uninitialized.
- Carries the module context at time of assignment.

### Cyclic References
```limbo
Tree: adt {
    l: cyclic ref Tree;   # cyclic permits individual field assignment
    r: cyclic ref Tree;
    val: int;
};
```
- Without `cyclic`: self-referential `ref adt` fields cannot be individually assigned (prevents non-GC-able cycles from forming accidentally).
- With `cyclic`: field assignment is allowed; these structures are GC'd eventually, not instantly.

### Fixed-Point Types (addendum)
```limbo
fpt: type fixed(2.0**-16);   # scale must be a positive real constant
x: fpt;
x = fpt(3.14);               # explicit cast to assign literal
```
- Underlying representation is `int` (32-bit).
- Support: `+`, `-`, `*`, `/`, unary `-`, comparison, `len`, `chan of`, `list of`, string casts.
- Do NOT support: `~`, `!`, `&`, `|`, `^`, `%`.
- Cast to `real` for printing.

### Polymorphic Types (addendum)
```limbo
Rd: adt[T] {
    t: T;
    ws: fn(rd: self ref Rd[T]): int;
};
rd := ref Rd[ref Iobuf](inbuf);

rev[T](l: list of T): list of T { ... }

# With interface constraint:
ismember[T](x: T, l: list of T): int
    for { T => eq: fn(a, b: T): int; }
{
    ...
    T.eq(x, hd l) ...
}
```
Implementation-defined at edges; use with care.

---

## Constants and Literals

### Integer Literals
- Decimal: `42`, `-1`
- Explicit radix: `16r1f` (= 31), `2r1010` (= 10); any base 2–36.
- Character: `'a'`, `'\n'`, `'\udddd'` (4 hex digits) — type `int`.
- Type is `big` if value > 2^31 − 1, else `int`.

### Escape Sequences
| Escape | Meaning |
|--------|---------|
| `\\` | backslash |
| `\'` | single quote |
| `\"` | double quote |
| `\a` | BEL |
| `\b` | BS |
| `\t` | HT |
| `\n` | LF |
| `\v` | VT |
| `\f` | FF |
| `\r` | CR |
| `\udddd` | Unicode (4 hex digits) |
| `\0` | NUL |

### Real Literals
- Must contain a decimal point (`3.14`, `-0.5`) or exponent (`1e10`, `1.5e-3`).

### String Literals
- Double-quoted: `"hello"`, `"a\tb\n"`. Cannot span lines.

### `nil`
- Null/empty value for: `list`, `array`, `chan`, modules, `ref adt`, `ref fn`, `string`.
- `nil` string equals `""` for all comparisons.

### `iota` (in `con` only)
```limbo
A, B, C: con iota;            # 0, 1, 2
M0, M1, M2: con (1 << iota);  # 1, 2, 4
N1, N3, N5: con 2*iota + 1;   # 1, 3, 5
```
`iota` takes the value 0 for the leftmost name, 1 for the next, etc. Only valid inside `con` expressions.

---

## Declarations

### Variable Declaration
```limbo
x: int;                     # uninitialized (undefined in fn; 0 at module level)
x: int = 42;
x, y: int = 0;              # multiple names, same type, same initializer
x := expr;                  # type inferred; declares and initializes
(a, b) := tuple_expr;       # destructure tuple into new variables
(a, nil) := tuple_expr;     # nil discards that component
```
- **Module level**: arithmetic types = 0; reference types = `nil`. Initializers must be constant.
- **Inside functions**: arithmetic types are **undefined** if not explicitly initialized.

### Constant Declaration
```limbo
Seven: con 3 + 4;
PATH:  con "/dis/foo.dis";
```
Expression must be a compile-time constant.

### Type Declaration
```limbo
MyList: type list of string;
Cmp:    type ref fn(a, b: string): int;
```

### Exception Declaration
```limbo
MyErr:   exception;                     # no parameters
MyErr2:  exception(int, string);        # with parameter tuple
```

### Import Declaration
```limbo
FD, Dir: import Sys;           # import types/constants from module type name
func:    import m;             # import function from loaded handle (handle required for fns)
```
- Constants and types: importable from the module type name.
- Functions: **must** import from a loaded handle variable.
- After import, names are usable without `->` qualifier.

### Include
```limbo
include "sys.m";
include "draw.m";
```
Textually includes the file (may be nested). Conventionally used for `.m` interface files.

---

## Operators and Expressions

### Operator Precedence (tightest to loosest)

```
.   ->   ()  []  ++  --          postfix / member; left-associative
+ - ! ~ ref * ++ -- <- hd tl len tagof    unary prefix; right-to-left
**                               exponentiation; right-associative
* / %
+ -
<< >>
< > <= >=
== !=
&
^
|
::                               list cons; right-associative
&&
||
= += -= *= /= %= &= |= ^= <<= >>= <-=  :=    assignment; right-to-left
```

### Arithmetic Operators
`+`, `-`, `*`, `/`, `%` — operands must be the **same** arithmetic type; result has the same type.
- `%` does not apply to `real`.
- `(a/b)*b + a%b == a`; remainder is non-negative when both operands are non-negative.
- Integer division/overflow: undefined result.
- Real: IEEE 754; divide-by-zero, overflow, underflow are **fatal** (unlike C's undefined behavior).
- `+` also concatenates strings.

### Shift Operators
```
<< >>
```
- Left operand: `int`, `big`, or `byte`; right operand: `int` (must be non-negative and < bit-width).
- `<<`: zero-fill. `>>`: sign-fill for `int` and `big`; zero-fill for `byte`.

### Bitwise Operators
`&`, `^`, `|` — operands must be the same type (`byte`, `int`, or `big`).

### Logical Operators
`&&`, `||` — short-circuit; operands must be the same arithmetic type; result `int` (0 or 1).
`!` — operand must be `int`; result `int`.

### Comparison Operators
- `<`, `>`, `<=`, `>=` — arithmetic types and strings (same type required); result `int` (1=true).
- `==`, `!=` — arithmetic, strings, reference types (same type, or compare to `nil`).
- String comparison is lexicographic Unicode; `nil` string == `""`.
- Reference equality: same object or both `nil`.

### Exponentiation
```limbo
base ** exp      # right-associative: 2**3**2 == 2**(3**2) == 512
```
`base`: `int`, `big`, or `real`; `exp`: `int`.

### List Cons
```limbo
element :: list_expr    # right-associative; prepend element to list
```

### Unary Operators
| Operator | Operand | Result |
|----------|---------|--------|
| `+` | arithmetic | same type (no-op) |
| `-` | arithmetic | negation |
| `~` | `int` or `byte` | bitwise complement |
| `!` | `int` | logical not (0 or 1) |
| `ref` | `adt` value | allocates new heap `adt`; type is `ref adt` |
| `*` | `ref adt` (non-nil) | dereferenced `adt` value |
| `hd` | non-empty list | first element |
| `tl` | non-empty list | rest (nil if single-element) |
| `len` | string, array, or list | element count; type `int` |
| `tagof` | `ref pick-adt` or variant type name | unique `int` per variant |
| `<-` | channel | receive; blocks until ready |

`ref` allocates a **new heap object** initialized with the value. It does NOT take the address of an existing variable (unlike C's `&`).

Special receive form: `<- array_of_chans` — selects fairly among ready channels, returns `(int, T)` tuple (index, value).

### Casts (all explicit; no implicit coercions)
```limbo
byte  expr              # truncate to byte
int   expr              # arithmetic to int, or string → parse decimal
big   expr              # arithmetic to big
real  expr              # arithmetic to real
string expr             # numeric → decimal (or array of byte → UTF-8 string)
array of byte  expr     # string → UTF-8 bytes
AdtName(field_exprs)    # adt cast (by data member order; fn members skipped)
ref AdtName(field_exprs) # heap-allocated adt
```
When converting `real` to integral: rounds to nearest, away from zero on tie.

### Channel Send
```limbo
ch <-= expr;    # blocks if unbuffered (no receiver) or buffer full
```

### Declare-and-Assign (`:=`)
```limbo
x := expr
(a, b) := tuple_expr
(a, nil) := tuple_expr    # nil discards that component
```
Can appear as a statement or as the qualifier of an `alt` arm.

### Load Expression
```limbo
m = load ModName path_string_expr;   # nil on failure
```

### Subscripting
```limbo
a[i]         # 0-based; runtime error if out of bounds
s[i]         # Unicode code point at position i; type int
a[e1:e2]     # slice (e2 exclusive); shared ref (array) or copy (string)
a[e:]        # shorthand for a[e:len a]
a[e:] = b;   # slice as lvalue: copies b into a starting at e
```

### Increment/Decrement
```limbo
x++    # post-increment (value is old); x--  post-decrement
++x    # pre-increment (value is new);  --x  pre-decrement
```
Operand must be arithmetic lvalue.

---

## Statements

### if / if-else
```limbo
if (expr) statement
if (expr) statement else statement
```
`expr` must be `int`; non-zero is true. Dangling `else` attaches to nearest `else`-less `if`.

### Loops
```limbo
label: while (expr) statement
label: while () statement           # infinite (no condition)
label: do statement while (expr);
label: do statement while ();       # infinite
label: for (init; test; step) statement
for (;;) statement                  # infinite
```
`for` is equivalent to: `init; while (test) { statement; step; }`

### case Statement
```limbo
label: case expr {
    val1 or val2 =>
        statements
    lo to hi =>               # inclusive range; int/big only
        statements
    * =>
        default
}
```
- `expr` must be `int`, `big`, or `string`.
- String: exact matches only (no ranges).
- **No fall-through** between arms (unlike C switch). No explicit `break` needed.
- `or` separates multiple values in one arm.
- Each arm is a separate scope.
- Overlapping ranges or duplicate values are compile errors.

### alt Statement (channel select)
```limbo
label: alt {
    x := <-ch1 =>
        # received from ch1; x declared in this arm
    ch2 <-= expr =>
        # sent to ch2
    nil = <-ch3 =>
        # receive and discard
    * =>
        # no channel ready (non-blocking)
}
```
- Waits for one or more channels to be ready; selects randomly but fairly.
- `*` arm makes it non-blocking (if no channel is ready, takes `*` arm).
- **CRITICAL:** Qualifier expressions are evaluated before channel readiness is tested, in undefined order. Never put blocking calls or significant side effects in qualifiers.
- **Only the leftmost** `<-` or `<-=` in a qualifier is tested for readiness.
- Multiple threads may `alt` on the same channel simultaneously; they are queued FIFO.

**Multiple sources merged into one arm:**
```limbo
ctl := <-winctl or
ctl  = <-ctxt.ctl or
ctl  = <-wreq =>
    handle(ctl);
```

### pick Statement
```limbo
label: pick x := expr {
    AdtName.Variant1 =>
        # x is ref AdtName.Variant1
    AdtName.Variant2 or AdtName.Variant3 =>
        # x is typed as Variant2
    * =>
        # default
}
```
`expr` must be `ref PickAdt`. Each arm is a separate scope.

### break and continue
```limbo
break;          # exit innermost while/do/for/case/alt/pick
break label;    # exit labeled construct
continue;       # restart loop condition in innermost while/do/for
continue label; # restart labeled loop
```
`continue` does NOT apply to `case`, `alt`, or `pick`.
For `for`: `continue` executes the step expression then tests condition (does NOT redo init).

### return, spawn, exit
```limbo
return;           # void function
return expr;      # return value
return f(args);   # tail call from void function (compiler may optimize)
spawn func(args); # create new thread; no handle returned
spawn obj.method(args);
spawn mod->func(args);
exit;             # terminate current thread
```

### raise and Exception Handler
```limbo
raise "error string";           # string exception
raise ExcName(p1, p2);          # user-defined exception
raise;                          # re-raise current exception (inside handler only)
raise e;                        # re-raise captured exception value

{
    risky_call();
} exception e {
    "fail:*" =>
        # e is the full string; matches any string starting with "fail:"
    "exact" =>
        # exact string match (more specific wins)
    ExcName =>
        # user-defined; (x, y) = e; to unpack parameters
    "*" =>
        # any string exception
    * =>
        # any exception (string or user-defined)
}
```
- Most specific string match wins: exact > longer prefix > shorter prefix > `"*"`.
- `or` combines multiple patterns per arm, but pattern types must be compatible.
- A typed (user-defined) exception keeps its full payload as it propagates up the
  stack until a **typed** handler (`ExcName =>`) catches it — at any depth, not just
  the immediate caller (R1 change, `emu/port/exception.c`). It only degrades to a
  string (its exception-identifier name) when caught by a **string/`"*"`** arm,
  which is where the handler variable is string-typed. So `(a,b) := e;` inside an
  `ExcName =>` arm now works regardless of how many frames the exception crossed.
  (Pre-R1, anything beyond the immediate caller was eagerly stringified, losing the
  payload — older code worked around this by matching the name with string arms.)
- After the handler runs, control falls through to the statement after the exception construct.

**Common string exception conventions:**
- `raise "fail:reason"` — signals failure (shell sees non-zero exit).
- `raise "dereference of nil"` — what you get on nil dereference (catchable).

---

## Module System

### Implement Statement
```limbo
implement ModName;
# or multiple: implement A, B;
```
First declaration in every `.b` file. When implementing multiple module types, names appearing in more than one must have the same type.

### Interface File (.m) Pattern
```limbo
Mylib: module {
    PATH: con "/dis/lib/mylib.dis";
    CONST: con 42;
    MyAdt: adt { x, y: int; };
    init:    fn();
    frobnitz: fn(x: int): string;
};
```

### Accessing Module Members
```limbo
Mylib->CONST           # constant/type from type name (no handle needed)
m->CONST               # constant/type from handle
m->func(args)          # function call (loaded handle required)
m->adt_obj.field       # adt member access
m->adt_obj.method()    # method call
```

### Type Compatibility for load
The module in the `.dis` file must export all members declared in the interface type with matching types. The stored module may export additional members (superset OK). Constants and type members do not enter comparison.

---

## Scoping Rules

- **Module top level**: visible from declaration point to end of file.
- **Function arguments and locals**: visible from declaration to end of enclosing block.
- **Blocks** (`if`, `for`, `while`, case/alt/pick arms): each creates an inner scope.
- **ADT member names**: separate namespace; no conflict with other identifiers.
- **Module member names**: accessed via `->` (or imported with `import`).
- **Forward references**: local functions may be defined anywhere in the module file without prior declaration.
- Self-referential `ref adt` field: OK in declaration; needs `cyclic` for individual field assignment.

---

## Concurrency

### spawn
```limbo
spawn myfunc(arg1, arg2);
done := chan of int;
spawn worker(done);
<-done;              # wait for completion
```
- Creates a new thread sharing the same module data and any reference values passed.
- No thread ID returned; no language-level join. Use channels for synchronization.

### Channel-Based Synchronization
```limbo
# Semaphore/mutex (buffered channel size 1):
lock := chan[1] of int;
lock <-= 0;          # acquire
# ... critical section ...
<-lock;              # release

# Signaling done:
done := chan of int;
spawn worker(done);
<-done;

worker(done: chan of int) {
    # ... work ...
    done <-= 0;
}
```
- No built-in mutex or condition variable; model everything with channels.
- Threads are preemptively scheduled; changes to shared module globals may occur at any time.

---

## Standard Program Patterns

### Command Module
```limbo
implement Myapp;

include "sys.m";
    sys: Sys;
include "draw.m";
    draw: Draw;

Myapp: module {
    init: fn(ctxt: ref Draw->Context, argv: list of string);
};

init(ctxt: ref Draw->Context, argv: list of string)
{
    sys = load Sys Sys->PATH;
    if(sys == nil)
        raise "fail:sys";

    argv = tl argv;    # skip program name

    # program body
}
```
`ctxt` is the graphics context (nil for non-graphical programs).

### Library Module (.m and .b)
```limbo
# mylib.m
Mylib: module {
    PATH: con "/dis/lib/mylib.dis";
    init:    fn();
    operate: fn(x: int): string;
};

# mylib.b
implement Mylib;
include "sys.m";
    sys: Sys;
include "mylib.m";

init()
{
    sys = load Sys Sys->PATH;
}

operate(x: int): string
{
    return string x;
}
```

### Using a Library
```limbo
include "mylib.m";
    mylib: Mylib;

init(...)
{
    mylib = load Mylib Mylib->PATH;
    if(mylib == nil) {
        sys->fprint(sys->fildes(2), "can't load Mylib: %r\n");
        raise "fail:load";
    }
    mylib->init();
    s := mylib->operate(42);
}
```

### Error-Return Idiom (tuple)
```limbo
myfunc(name: string): (int, string)
{
    if(ok)
        return (1, result);
    return (0, "");
}
(ok, val) := myfunc("foo");
if(!ok)
    raise "fail:myfunc";
```

### Reading a File
```limbo
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

### List Building and Iteration
```limbo
# Build (prepend and then reverse)
items: list of int = nil;
for(i := 0; i < 10; i++)
    items = i :: items;

rev: list of int = nil;
for(l := items; l != nil; l = tl l)
    rev = hd l :: rev;

# Iterate
for(l := rev; l != nil; l = tl l)
    sys->print("%d\n", hd l);
```

---

## Gotchas — Things Different from C

1. **No implicit coercions.** `byte(n)` and `int(b)` are required for arithmetic type conversions.
2. **No ternary operator** (`?:`). Use `if-else` or a function.
3. **No comma operator** (sequential expression evaluation). Use separate statements.
4. **`case` does not fall through.** Each arm is independent; no `break` needed.
5. **List elements are immutable.** Cannot do `hd l = x;` — must rebuild the list.
6. **`ref` is NOT address-of.** `ref e` allocates a **new** heap object. It does not take the address of an existing variable.
7. **No stack pointers.** Cannot take the address of a local variable or function argument.
8. **`nil` string == `""`** for all comparisons.
9. **Array slice is a shared reference** — mutations via the slice affect the original.
10. **String slice is a value copy.**
11. **Uninitialized local arithmetic vars are undefined** (not zero). Module-level vars are zero.
12. **`load` returns `nil` on failure** — always check!
13. **`alt` qualifier expressions evaluated before channel readiness is tested.** No blocking calls or side effects in qualifiers.
14. **Only the leftmost `<-` or `<-=` in an `alt` qualifier is tested for readiness.**
15. **`iota` is not a keyword** outside `con` declarations.
16. **`adt` types compared structurally** — differently-named `adt`s with identical data members are the same type.
17. **Shift count** must be non-negative and < bit-width.
18. **`for` with `continue`**: step executes, then condition is tested. Init is NOT re-executed.
19. **Function arguments evaluated in unspecified order**; all side effects complete before the call.
20. **Real arithmetic errors (divide by zero, overflow) are fatal** — they actually crash or raise an exception.
21. **`spawn` returns no handle.** No language-level way to wait except via channels.
22. **`pick adt` must always be `ref adt`.** No value (non-reference) of a pick adt allowed.
23. **`cyclic` on a field permits individual assignment** and enables circular structures; without it, self-referential field assignment is a compile error.
24. **Module type equality ignores constants and types** — only data and function members compared.
25. **`tl` of a single-element list is `nil`.** Check for `nil` before calling `hd` or `tl`.
26. **Comments use `#`**, not `//` or `/* */`.
27. **No `goto`**. Use labeled `break`/`continue`, or restructure.
28. **`pick` statement uses `AdtName.Variant` names in arms** — the adt name prefix is required.

---

## Standard Modules Quick Reference

| Module | Path | Purpose |
|--------|------|---------|
| `Sys` | `module/sys.m` | System calls — open, read, write, pipe, mount, bind, stat |
| `Draw` | `module/draw.m` | 2D graphics — images, colors, drawing ops |
| `Tk` | `module/tk.m` | Tcl/Tk GUI widgets |
| `Tkclient` | `module/tkclient.m` | Tk window manager client (requires explicit `init()`) |
| `Prefab` | `module/prefab.m` | Higher-level GUI widgets |
| `Dial` | `module/dial.m` | Network connections |
| `Bufio` | `module/bufio.m` | Buffered file I/O |
| `String` | `module/string.m` | String utilities (split, trim, find, etc.) |
| `Regex` | `module/regex.m` | Regular expressions |
| `Math` | `module/math.m` | Math functions |
| `Keyring` | `module/keyring.m` | Key management / low-level crypto |
| `Auth` | `module/auth.m` | Authentication |
| `Styx` | `module/styx.m` | 9P protocol server |
| `Crypt` | `module/crypt.m` | Cryptographic operations |

**Key `sys` calls:**
```limbo
fd := sys->open(path, Sys->OREAD);       # or OWRITE, ORDWR
n  := sys->read(fd, buf, len buf);
n   = sys->write(fd, buf, n);
(ok, dir) := sys->stat(path);
fds := array[2] of ref Sys->FD;
sys->pipe(fds);
sys->bind("/net", "/net", Sys->MREPL);
sys->mount(fd, nil, "/", Sys->MREPL, "");
sys->sleep(ms);
sys->pctl(Sys->NEWPGRP, nil);
sys->print("fmt %s %d\n", s, n);
sys->fprint(sys->fildes(2), "err: %r\n");  # stderr; %r = last error
```

**Format verbs:**
- `%d` — int, `%bd` — big, `%g` — real, `%s` — string, `%r` — last system error.

---

## Compiler Pipeline

**Directory**: `limbo/`

### Phases
```
1. Lex (lex.c): UTF-8 → tokens
2. Parse (limbo.y → y.tab.c): tokens → AST
3. Declaration processing (decls.c): resolve symbols, assign offsets
4. Type checking (typecheck.c, types.c): infer types, check signatures
5. Code generation (com.c, ecom.c, gen.c): typed AST → Dis instructions
6. Optimization (optim.c): dead code, constant folding, copy propagation
7. Output (asm.c, dis.c): binary .dis or text assembly
```

### Compiler Invocation
```sh
limbo [-o out.dis] [-I incdir] file.b
limbo -S file.b              # dump assembly for debugging
limbo -G file.b              # emit debug info
limbo -g file.b              # enable bounds checking
limbo -a module.m            # generate C header for built-in module stubs
```

### dis/ Directory
`dis/` holds pre-compiled `.dis` files. Inferno runs from `dis/`, not from `appl/`.
```sh
# Recompile a single app:
limbo -o dis/cmd/myapp.dis appl/cmd/myapp.b

# Recompile all (via mk):
cd appl && mk install
```

---

## Built-in Modules (C-Implemented)

Some modules have no `.b` implementation — implemented entirely in C and linked into the emulator. Their `.m` files describe the API; C stubs generated by `limbo -a`:
- `Sys` — all system calls
- `Draw` — all drawing operations
- `Math` — math functions (`sin`, `cos`, `sqrt`, etc.)
- `Keyring` — low-level crypto

Pure-Limbo modules (in `appl/lib/`): Auth, Bufio, Regex, String, etc.

---

## Debugging Tips

- `limbo -S file.b` — dump assembly to inspect generated instructions.
- `disdump dis/cmd/myapp.dis` — disassemble a `.dis` file.
- `prof` — Limbo profiler (instruction counts per source line).
- Add `sys->print(...)` liberally — no debugger breakpoints in standard operation.
- `"dereference of nil"` exception → check every `load` return value and every `ref` usage before access.
- `raise "custom:msg"` can be caught by a parent's `exception` block for structured error propagation.
- `%r` in a format string prints the most recent system error string.
