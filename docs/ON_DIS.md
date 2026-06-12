# The Dis virtual machine

The Dis VM is the execution engine for all Inferno programs. It is a register-based virtual machine with a flat address space per module instance, concurrent threads, and a garbage-collected heap. This document covers the **portable** VM: the instruction set, object file format, interpreter loop, garbage collector, channel operations, exceptions, and the scheduler.

> **Architecture/ABI-specific material lives in `ON_DIS_ARCH.md`** — pointer
> widths (dual-ABI), the per-ABI `.dis` magic, compiled/JIT execution and its
> register map, and the emu memory pools. The JIT codegen reference is
> `ON_JIT.md`. Keep this doc host-independent.

---

## Overview

- **Architecture**: Register-based (not stack-based). A Dis `WORD` is 32-bit on every ABI; `LONG`/`REAL` are 64-bit. **Pointer width is arch-dependent** (8 bytes on the LP64 aarch64 build) — see `ON_DIS_ARCH.md`.
- **Module granularity**: Each `.dis` file is one module. Modules share bytecode but have separate data segments per instance.
- **Thread model**: M:N — many Limbo threads (Prog) mapped onto fewer OS threads (Proc) via a cooperative/time-sliced scheduler
- **GC**: hybrid — **reference-counting** (instant-free for acyclic objects, via `Heap.ref`) plus a **tri-color incremental mark-sweep** tracing pass to collect cycles
- **Key files**:
  - `include/isa.h` — opcode and addressing mode constants
  - `include/interp.h` — runtime data structures
  - `libinterp/xec.c` — opcode implementations and interpreter loop
  - `libinterp/load.c` — `.dis` file parser and module loader
  - `libinterp/gc.c` — garbage collector
  - `libinterp/alt.c` — channel and alt statement
  - `libinterp/comp-aarch64.c` (and other archs) — JIT compiler

---

## Instruction Set

All opcodes are defined as enum values in `include/isa.h` starting from `INOP = 0`.

### Instruction Format

```c
struct Inst {
    uchar  op;    // opcode (8 bits, index into optab[256])
    uchar  add;   // addressing mode byte
    ushort reg;   // immediate or register value
    Adr    s;     // source operand
    Adr    d;     // destination operand
};
```

The middle operand (when present) is encoded in bits 6–7 of `add` (`ARM` field):
- `AXNON` — no middle operand
- `AXIMM` — immediate middle
- `AXINF` — indirect via frame pointer
- `AXINM` — indirect via module pointer

Source and destination addressing modes (bits 0–2 for src, bits 3–5 for dst):
- `AFP` — frame-pointer relative (local variable)
- `AMP` — module-pointer relative (global variable)
- `AIMM` — immediate / small integer
- `AIND` — indirect (pointer dereference)
- `AXXX` — not used

### Opcode Categories

#### Control Flow

| Opcode     | Description |
|------------|-------------|
| `IGOTO`    | Unconditional branch to PC offset |
| `ICALL`    | Call a function (push frame, jump) |
| `IRET`     | Return from function (pop frame) |
| `IJMP`     | Indirect jump through a function reference |
| `IFRAME`   | Allocate a new activation frame |
| `ISPAWN`   | Spawn a new Limbo thread (Prog) |
| `IALT`     | Alt statement: block until a channel is ready, then communicate |
| `INBALT`   | Non-blocking alt (returns immediately if no channel ready) |
| `IRAISE`   | Raise an exception |
| `ILOAD`    | Load a module dynamically |
| `IMCALL`   | Call a method through a module interface |
| `IMSPAWN`  | Spawn with a module call |
| `IMFRAME`  | Allocate frame for a module method call |
| `ICASE`    | Jump table for integer case/switch |
| `IEXIT`    | Exit the current thread |
| `IRUNT`    | Thread yield / reschedule point |

#### Memory and Object Operations

| Opcode           | Description |
|------------------|-------------|
| `INEW`           | Allocate heap object of given type |
| `INEWZ`          | Allocate and zero heap object |
| `INEWA`          | Allocate array |
| `INEWCB`         | Create byte channel |
| `INEWCW`         | Create word (int) channel |
| `INEWCF`         | Create float channel |
| `INEWCP`         | Create pointer channel |
| `INEWCM`         | Create aggregate (struct) channel |
| `INEWCMP`        | Create module-pick channel |
| `ISEND`          | Send value on channel |
| `IRECV`          | Receive value from channel |
| `IMOVB/W/F/L`    | Move byte/word/float/long |
| `IMOVP`          | Move pointer |
| `IMOVM`          | Move memory block (aggregate copy) |
| `IMOVMP`         | Move module-pick aggregate |
| `ILEA`           | Load effective address |
| `IINDX`          | Array index (compute element address) |
| `ICONSB/W/F/P/M` | Build a list cons cell |
| `IHEADB/W/F/P/M` | Extract list head |
| `ITAIL`          | Extract list tail |
| `ISLICEA`        | Slice an array |
| `ISLICELA`       | Slice a list into array |
| `ISLICEC`        | Slice a string |
| `IINSC`          | Insert character into string |
| `IINDC`          | Index character in string |
| `IADDC`          | Concatenate strings |

#### Arithmetic

Suffixes: `B` = byte, `W` = word (32-bit int), `F` = float (64-bit), `L` = long (64-bit int).

| Opcode group       | Operations |
|--------------------|------------|
| `IADD{B,W,F,L}`    | Addition |
| `ISUB{B,W,F,L}`    | Subtraction |
| `IMUL{B,W,F,L}`    | Multiplication |
| `IDIV{B,W,F,L}`    | Division |
| `IMOD{B,W,L}`      | Modulo |
| `IEXPW/EXPL/EXPF`  | Exponentiation |
| `IMULX/DIVX`       | 64-bit multiply/divide extensions |

#### Bitwise

| Opcode group         | Operations |
|----------------------|------------|
| `IAND{B,W,L}`        | Bitwise AND |
| `IOR{B,W,L}`         | Bitwise OR |
| `IXOR{B,W,L}`        | Bitwise XOR |
| `ISHL{B,W,L}`        | Left shift |
| `ISHR{B,W,L}`        | Arithmetic right shift |
| `ILSR{W,L}`          | Logical (unsigned) right shift |

#### Comparison and Conditional Branch

Pattern: `IB{EQ,NE,LT,LE,GT,GE}{B,W,F,C,L}` — branch if condition holds.

Examples: `IBEQW` (branch if equal, word), `IBLTF` (branch if less-than, float), `IBGEC` (branch if greater-equal, char/string).

#### Type Conversion

Pattern: `ICVT{src}{dst}` where src/dst are: `B`=byte, `W`=word, `F`=float, `C`=string/char, `A`=array, `L`=long, `R`=real, `S`=string, `X`=fixed-point.

Examples: `ICVTWF` (word→float), `ICVTCA` (char→array-of-byte), `ICVTFC` (float→string).

#### String Operations

| Opcode    | Description |
|-----------|-------------|
| `ILENC`   | Length of string (in characters) |
| `ILENA`   | Length of array |
| `ILENL`   | Length of list |
| `ISLICEA` | Array slice |
| `ISLICEC` | String slice |
| `IINDC`   | Character at index |
| `IADDC`   | String concatenation |

---

## Interpreter Loop

**File**: `libinterp/xec.c`

The interpreter is a function-pointer dispatch loop:

```c
void xec(Prog *p) {
    R = p->R;            // load register state
    if(R.M->compiled)
        comvec();        // run JIT'd native code
    else do {
        dec[R.PC->add]();      // decode addressing modes into R.s, R.d, R.m
        op = R.PC->op;
        R.PC++;
        optab[op]();           // execute instruction
    } while(--R.IC != 0);     // time slice: PQUANTA = 2048 instructions
    p->R = R;            // save registers back
}
```

`optab` is a 256-element array of `void (*)(void)` function pointers. Each entry is an inline C function of the form:

```c
OP(iaddw) {
    *(WORD*)R.d = *(WORD*)R.s + *(WORD*)R.m;
}
```

`dec[]` is indexed by the `add` byte of the instruction and sets `R.s`, `R.d`, `R.m` to point at the actual operand memory before the opcode handler runs.

**Time-slicing**: Each Prog gets `quanta = PQUANTA` (2048) instructions. When `R.IC` reaches zero, the VM saves registers and calls the scheduler to pick the next Prog.

**Reschedule**: The `IRUNT` opcode forces an early yield.

---

## .dis Object File Format

**File**: `libinterp/load.c`, `module/dis.m`

A `.dis` file has this structure (all integers encoded as variable-length):

```
magic               XMAGIC (unsigned) or SMAGIC (signed/crypto)
                    NB: the value encodes the pointer ABI — 32-bit XMAGIC/SMAGIC vs
                    64-bit XMAGIC8/SMAGIC8. This LP64 tree uses XMAGIC8. See
                    ON_DIS_ARCH.md.

header:
    RT              runtime flags (MUSTCOMPILE, DONTCOMPILE, SHAREMP, HASLDT, HASEXCEPT)
    SS              stack size in bytes
    ISIZE           number of instructions
    DSIZE           size of module data segment in bytes
    HSIZE           number of type descriptors
    LSIZE           number of link table entries
    ENTRY           entry-point instruction index
    ENTRYT          type descriptor index for entry frame

code section:       ISIZE instructions, each:
    1 byte: opcode
    1 byte: addressing mode
    variable: source operand (depends on addressing mode bits)
    variable: middle operand (if ARM field != AXNON)
    variable: destination operand

type descriptors:   HSIZE entries, each:
    operand: descriptor index
    operand: size in bytes
    operand: number of pointer slots (np)
    np bits: GC pointer map (1 bit per slot, 1 = pointer)

data section:       DSIZE bytes, encoded as typed initializers:
    1 byte: DTYPE|DLEN  (type in high bits, count in low)
    operand: value (format depends on DTYPE)
    DTYPE values: DEFZ(zero), DEFB(byte), DEFW(word), DEFS(string),
                  DEFF(float), DEFA(array), DIND(indirect), DEFL(long)

link table:         LSIZE entries, each:
    operand: PC offset of ILOAD or IMCALL instruction
    operand: type descriptor index
    operand: signature hash
    string: symbol name

import table:       module dependency entries, each:
    operand: signature hash
    string: module name
```

**Variable-length integer encoding**:
```
0x00–0x7F → 1 byte, value = byte
0x80–0xBF → 2 bytes, value = ((b0 & 0x3F) << 8) | b1
0xC0–0xFF → 4 bytes, value in next 3 bytes
```

---

## Module Loading

**File**: `libinterp/load.c`

`parsemod(path)` loads a `.dis` file:

1. Open the file from the Inferno namespace (not host filesystem).
2. Read and verify magic number.
3. Parse header fields.
4. Read type descriptors — set up `Type*` structures with pointer maps.
5. Read code section — populate `Inst[]` array.
6. Read data section — initialize the module data template (`origmp`).
7. Read link table — record what external symbols this module needs.
8. On first instantiation, call `newmod()` to create `Modlink`, copy `origmp` into `MP`.
9. Walk the link table; for each symbol, find the definition in the target module and patch the instruction's operand.

**Type checking during linking**: the `signature` field in each link-table entry is a hash of the function's type. If it doesn't match the definition, loading fails with `"module not loaded"`.

**Module data sharing**: if `SHAREMP` flag is set, all instances share one MP (read-only data). Otherwise each `spawn` or `load` gets a fresh copy of `origmp`.

---

## Garbage Collector

**File**: `libinterp/gc.c`

### Algorithm: Tri-Color Incremental Mark-Sweep

Colors are assigned to every heap object:

| Color       | Meaning |
|-------------|---------|
| `mutator`   | White — not yet seen by current GC cycle |
| `propagator`| Gray — seen but children not yet scanned |
| `marker`    | Black — fully scanned |
| `sweeper`   | Dead — to be freed on sweep pass |

The GC runs incrementally during idle time (between interpreter quanta) so it never stops the world for long.

### Heap Object Header

Every GC-managed allocation has a `Heap` header immediately before the object data:

```c
struct Heap {           // include/interp.h
    int    color;   // current GC color
    ulong  ref;     // reference count (instant-free + pinning)
    Type  *t;       // type descriptor (holds pointer map)
    ulong  hprof;   // heap-profiling hook
};

// Convert between data pointer and Heap header (note: byte arithmetic, the header
// sits immediately before the object — see the real macros in interp.h):
#define D2H(x)  ((Heap*)(((uchar*)(x))-sizeof(Heap)))
#define H2D(t,x) ((t)(((uchar*)(x))+sizeof(Heap)))
```

(`ref` is pointer-width — 8 bytes on LP64. The collector is **reference-counted**
for the common acyclic case, with the tri-color tracing pass below for cycles.)

### Mark Phase

`markheap(h)` — marks one object and schedules its children:

1. Consult `h->t->map` — the pointer bitmap. Each set bit means that slot holds a pointer.
2. For each pointer found, call `Setmark()` on the pointed-to object (turns it gray).
3. For arrays: `markarray()` marks elements in chunks (incremental).
4. For lists: `marklist()` marks list cells in chunks.

Root set (`rootset()`):
- All live Prog stack frames (walk FP chain up to stack base)
- All module data segments (MP of each active Modlink)
- Global string table

### Sweep Phase

`rungc(head)` iterates through the linked list of all heap objects. Any object still in `mutator` color (white) was not reached and is freed. Then colors are rotated: `sweeper→mutator`, `marker→sweeper`, `mutator→marker` (conceptually — implementation uses integer arithmetic).

### GC Locking

```c
#define gclock()    gchalt++    // suspend GC (during critical ops)
#define gcunlock()  gchalt--
#define gcruns()    (gchalt == 0)
#define Setmark(h)  if((h)->color != mutator) { (h)->color = propagator; nprop = 1; }
```

### GC Timing

`execatidle()` in `emu/port/dis.c` is called between interpreter quanta when the run queue is empty. It runs GC passes until either a Prog becomes ready or a fixed number of passes complete.

---

## Channel Operations and Alt Statement

**File**: `libinterp/alt.c`

### Channel Structure

```c
struct Channel {        // include/interp.h
    Array*  buf;        // circular buffer (nil = unbuffered); MUST be first
    Progq*  send;       // linked list of Progs waiting to send
    Progq*  recv;       // linked list of Progs waiting to receive
    void*   aux;        // rock for devsrv (file-backed channels)
    void  (*mover)(void); // copies one element of the channel's type
    union { WORD w; Type* t; } mid;  // element-type info for the mover
    int     front;      // head index in buf
    int     size;       // items currently in buf
};
```

**Type-specific movers** (set at channel creation by `INEWCX` opcodes):

| Mover   | Data type |
|---------|-----------|
| `movb`  | byte (8-bit) |
| `movw`  | word (32-bit int) |
| `movf`  | float (64-bit) |
| `movp`  | pointer/ref |
| `movm`  | aggregate (struct, by type descriptor size) |

### Send and Receive

**Unbuffered send** (`ISEND`):
1. If a receiver is waiting: copy data via `mover`, wake the receiver, continue.
2. If no receiver: enqueue self in `chan->send`, set state `Psend`, yield to scheduler.

**Buffered send**: if `buf->size < buf->len`, enqueue in buffer, continue. Otherwise block as above.

**Receive** (`IRECV`): symmetric.

### Alt Statement (`IALT`)

Alt implements Go-style `select`. The instruction provides an `Alt` structure listing channels and directions.

**Three-pass protocol**:

1. **Pass 1 — survey** (`altrdy`): For each branch, enqueue `Prog` in the relevant `chan->send` or `chan->recv` list. Count how many channels are immediately ready.

2. **Pass 2 — communicate** (`altcomm`): If ≥1 channel is ready, pick one at random (`xrand >> 8 % nrdy`). Perform the data transfer via `mover`. Wake any waiting counterpart.

3. **Pass 3 — cleanup** (`altdone`): Remove `Prog` from all channel queues it was registered in. Set the return value (index of selected branch).

If no channel is ready in pass 1: set state `Palt` and yield. The scheduler will re-run passes 2 and 3 when a counterpart arrives.

**Non-blocking alt** (`INBALT`): same but if no channel ready, takes the default branch immediately (no blocking).

---

## Exception Handling

**File**: `libinterp/raise.c`, `libinterp/xec.c`

### Exception Strings

Predefined runtime exceptions raised by the VM:

```
"alt send/recv on same chan"    — channel used for both send and recv in same alt
"module not loaded"             — load/link failure
"zero divide"                   — integer division by zero
"dereference of nil"            — nil pointer dereference
"array bounds error"            — index out of range
"out of memory: heap"           — GC heap exhausted
"out of memory: main"           — C malloc failed
"stack overflow"                — Limbo stack too deep
"sys: fp: ..."                  — floating-point trap
```

### Exception Handler Table

Each Module has a `htab` array of `Handler` structs:

```c
struct Handler {
    ulong pc1, pc2;   // PC range this handler covers [pc1, pc2)
    ulong eoff;       // offset into exception descriptor array
    ulong ne;         // number of exception entries
    Type* t;          // type of handler's stack frame (for GC)
    Except* etab;     // array of {string, pc} pairs
};

struct Except {
    char* s;    // exception string (nil = catch-all)
    ulong pc;   // jump target when this exception matches
};
```

### Exception Dispatch (`iraise`)

```c
OP(iraise) {
    void* v = T(s);            // exception value: a string, or an exception adt
    if(v == H) error(exNilref);
    p->exval = v;              // full value retained (typed payload survives, see below)
    // match name = the string itself, or the adt's first field (its name):
    error(D2H(v)->t == &Tstring ? string2c(v) : string2c(*(String**)v));
}
```

The C `error()` longjmps into the handler search (`handler()`, `emu/port/exception.c`),
which walks the handler table from the current PC for a `Handler` whose `[pc1, pc2)`
range contains the PC and whose `etab` has a matching pattern. A **typed** exception
now keeps its full payload until a typed (`ExcName =>`) arm catches it, degrading to
its name string only for a string/`"*"` arm — see `ON_LIMBO.md` (exception
semantics) and `ON_DEBUGGING.md` (the R1 change). If no handler matches, the
exception propagates to the parent Prog (via the `Progs` group).

---

## Type Descriptors at Runtime

Defined in `include/interp.h`. Every heap-allocated Dis object has an associated `Type*`.

```c
struct Type {            // include/interp.h — field order matters for the GC
    int    ref;
    void (*free)(Heap*, int);      // called by GC to free object
    void (*mark)(Type*, void*);    // called by GC to mark children
    int    size;         // size in bytes of the object
    int    np;           // number of pointer-sized slots covered by map
    void  *destroy;      // destructor (for ADTs with destructors)
    void  *initialize;   // initializer
    uchar  map[STRUCTALIGN];       // GC pointer bit map (1 bit per pointer slot), last
};
```

**Pointer map**: `np` gives the number of pointer-aligned slots in the object. `map[]` has `np` bits; if bit `i` is set, slot `i` (at byte offset `i * sizeof(void*)`) holds a GC-traced pointer. The GC uses this to know which fields to follow during marking without needing to know the object's semantic type.

**Predefined types** (global variables in libinterp):

```c
extern Type Tarray;     // Limbo array
extern Type Tstring;    // Limbo string
extern Type Tchannel;   // Limbo channel
extern Type Tlist;      // Limbo list cell
extern Type Tmodlink;   // Module instance
extern Type Tptr;       // Generic pointer
extern Type Tbyte;      // Scalar byte
extern Type Tword;      // Scalar int
extern Type Tlong;      // Scalar big (64-bit)
extern Type Treal;      // Scalar real (64-bit float)
```

---

## Thread Scheduler

**File**: `emu/port/dis.c`

### Run Queue

```c
struct {
    Prog* runhd;    // head of ready-to-run queue
    Prog* runtl;    // tail
    Prog* head;     // head of all Progs (alive or blocked)
    Prog* tail;
    Rendez irend;   // idle rendezvous
} isched;
```

### Scheduling Loop

The interpreter runs one Prog at a time (single-threaded within the Dis VM). After each time slice:

1. If `isched.runhd` is non-nil, take its head and execute it.
2. If run queue is empty, call `execatidle()` to run GC.
3. When a channel operation wakes a blocked Prog, `addrun(p)` enqueues it.

### Prog States

| State      | Meaning |
|------------|---------|
| `Pready`   | On run queue, eligible to run |
| `Palt`     | Blocked in alt statement |
| `Psend`    | Blocked waiting to send on a channel |
| `Precv`    | Blocked waiting to receive |
| `Pdebug`   | Halted under debugger |
| `Prelease` | Released from VM (doing blocking I/O in a kproc) |
| `Pexiting` | Killed or errored, will be freed soon |
| `Pbroken`  | Crashed, kept alive for debugging |

### Prog Groups (`Progs`)

Progs are organized into groups (analogous to process groups). When an uncaught exception occurs in a Prog, it propagates up to the group leader. If the group has `Ppropagate` flag, the exception kills all members of the group.

---

## Compiled (JIT) Execution

A module can be compiled to native code (`cflag>0`, or the `MUSTCOMPILE` flag, or an
explicit `Loader->compile`). Compilation is **whole-module, at load time** — there is
no tiered or hot-count heuristic. The interpreter and compiled code interoperate
freely; the dispatch loop picks the path per module, and cross-mode calls resync at
the call boundary.

The architecture-specific realization — the per-arch backends
(`libinterp/comp-aarch64.c` is the only one built/tested here), the register map,
`pctab`, the native-code arena, `segflush`, and the `jitlock` compile invariant — is
in **`ON_DIS_ARCH.md`**, with the full codegen reference in
**`ON_JIT.md`**.

---

## Memory Pools

emu carves host memory into three pools (`main` / `heap` / `image`) via
`emu/port/alloc.c`. Details (sizes, `-p` overrides, the `Bhdr` allocator) are
host/arch realization — see **`ON_DIS_ARCH.md`**.
