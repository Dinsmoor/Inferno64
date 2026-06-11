# Inferno Emulator (emu) Architecture

> *So you want to understand or extend the emulator?* This is the reference.

Hosted Inferno runs inside `emu` — a process on the host OS that provides the Dis VM, a synthetic kernel, and a set of device drivers. Understanding `emu` is prerequisite for adding devices, debugging kernel panics, or touching anything in `emu/`.

## Directory Layout

```
emu/
  port/       — portable kernel (OS-independent)
  Linux/      — Linux-specific: signal handling, terminal, timers, audio
  Nt/         — Windows
  Plan9/      — Plan 9 host
  MacOSX/     — macOS
  FreeBSD/    — FreeBSD
  ...
```

`emu/port/` contains everything that doesn't touch the host OS directly. The OS-specific directories provide implementations of a fixed abstraction layer (OS functions) and any platform-specific devices.

### Key files in emu/port/

| File | Purpose |
|------|---------|
| `main.c` | Entry point; `emuinit()`, namespace bootstrap |
| `dat.h` | All kernel data structures: Chan, Dev, Proc, Pgrp, etc. |
| `fns.h` | Portable function declarations |
| `chan.c` | Channel (file handle) allocation, namespace operations, `chandevinit` |
| `sysfile.c` | Limbo syscall implementations: open, read, write, bind, mount |
| `alloc.c` | Three memory pools (main, heap, image) |
| `lock.c` | Lock, QLock, RWlock implementations |
| `dis.c` | Dis VM: vmachine, acquire/release, spawn, process groups |
| `dev.c` | Generic device helpers: devwalk, devstat, devopen, devgen |
| `devcons.c` | Console device (`#c`) |
| `devenv.c` | Environment device (`#e`) |
| `devpipe.c` | Pipe device (`#|`) |
| `devprog.c` | Process inspector (`#p`) |
| `devdup.c` | File descriptor directory (`#d`) |
| `devdraw.c` | Graphics device (`#i`) |
| `devsnarf.c` | Clipboard/snarf (`#^`) |
| `styx.c` | 9P wire format: convM2S, convS2M |
| `kproc-pthreads.c` | Proc (host thread) management via pthreads |
| `qio.c` | Queue-based I/O (block chains for pipe/network) |

### Key files in emu/Linux/

| File | Purpose |
|------|---------|
| `os.c` | `libinit`, signal handlers (`trapmemref`, EMUCRASH/watchdog), `osmillisec`, `osmillisleep`, `readkbd` |
| `devfs.c` | Host filesystem bridge (the `#U` device) |
| `audio-oss.c` | OSS audio driver |
| `aarch64-tas.S` | Atomic test-and-set (the spinlock primitive) — **this tree's target** |
| `asm-aarch64.S` | `umult` etc. arithmetic helpers (aarch64) |
| `segflush-aarch64.c` | I-cache flush after JIT codegen |
| `asm-386.S` | Atomic test-and-set for x86 (other hosts; not built here) |

> This tree is built and tested only on **Linux/aarch64** (LP64). The portable
> design below applies to every host port, but the other `emu/<OS>/` and
> `emu/Linux/asm-*` variants are not exercised here. Arch-specific Dis/JIT detail is
> in `ON_DIS_ARCH.md`; emu fault-debugging in `ON_EMU_DEBUG.md`.

---

## The Dev Struct: Device Driver Interface

Every device is described by a `Dev` struct (`emu/port/dat.h:142–160`):

```c
struct Dev {
    int      dc;       /* device character: 'c', 'e', '|', 'p', etc. */
    char*    name;     /* human-readable name */

    void     (*init)(void);
    Chan*    (*attach)(char *spec);
    Walkqid* (*walk)(Chan *c, Chan *nc, char **name, int nname);
    int      (*stat)(Chan *c, uchar *db, int n);
    Chan*    (*open)(Chan *c, int mode);
    void     (*create)(Chan *c, char *name, int mode, ulong perm);
    void     (*close)(Chan *c);
    long     (*read)(Chan *c, void *buf, long n, vlong offset);
    Block*   (*bread)(Chan *c, long n, ulong offset);
    long     (*write)(Chan *c, void *buf, long n, vlong offset);
    long     (*bwrite)(Chan *c, Block *b, ulong offset);
    void     (*remove)(Chan *c);
    int      (*wstat)(Chan *c, uchar *db, int n);
};
```

**Field notes:**

- `dc` — single character. Access via `#c` from Limbo, or `devattach('c', spec)` from C.
- `init` — called once by `chandevinit()` at boot; set up device globals here.
- `attach` — called when the device is first accessed (`#c` or `bind #c /dev`); returns a Chan for the device root (must be a directory).
- `walk` — navigate the file tree. Most devices use `devwalk()` with a static `Dirtab`.
- `stat` — serialize a Dir struct into 9P format. Use `devstat()` for standard files.
- `open` — called on `sys->open()`; validate permissions, set `c->flag |= COPEN`. Use `devopen()` for standard behavior.
- `read`/`write` — data transfer; `offset` is passed explicitly (not stored in Chan for most devices).
- `bread`/`bwrite` — block-oriented I/O for high-throughput devices; most simple devices set these to `devbread`/`devbwrite` (the generic wrappers).
- `close` — free per-file resources stored in `c->aux`. Called when the last reference closes.
- `create`/`remove`/`wstat` — set to `devnone` if not supported; `devnone` calls `error(Eperm)`.

### Device Table

The device table is generated from `emu/port/master` by `mkdevc` into a C source file that defines:

```c
Dev *devtab[] = {
    &rootdevtab,
    &consdevtab,
    &envdevtab,
    &pipedevtab,
    /* ... */
    nil
};
```

`chandevinit()` (`emu/port/chan.c:141–152`) iterates this table and calls `->init()` on each.

### Built-in Device Characters

| Char | Device | Mounted at |
|------|--------|------------|
| `/` | root | (implicit) |
| `c` | cons | /dev |
| `d` | dup (fd directory) | /fd |
| `e` | env | /env |
| `\|` | pipe | (explicit bind) |
| `m` | pointer/mouse | /dev |
| `p` | prog | /prog |
| `s` | srv | /srv |
| `^` | snarf | /chan, /dev |
| `i` | draw | /dev/draw |
| `U` | host filesystem | / |
| `I` | network (IP) | /net |

---

## Adding a New Device: Step by Step

**1. Choose a unique device character** not in the master file.

**2. Create `emu/port/devxxx.c`**. Use `devenv.c` or `devsnarf.c` as a template.

```c
#include "dat.h"
#include "fns.h"
#include "error.h"

/* Qid path constants */
enum {
    Qdir  = 0,   /* directory */
    Qdata = 1,   /* a single data file */
};

/* Static directory table */
static Dirtab mydir[] = {
    ".",    {Qdir,  0, QTDIR}, 0,    DMDIR|0555,
    "data", {Qdata, 0, QTFILE}, 0,   0666,
};
#define NMYDIR (sizeof(mydir)/sizeof(mydir[0]))

static void
myinit(void)
{
    /* one-time initialization */
}

static Chan*
myattach(char *spec)
{
    return devattach('x', spec);   /* 'x' = your device char */
}

static Walkqid*
mywalk(Chan *c, Chan *nc, char **name, int nname)
{
    return devwalk(c, nc, name, nname, mydir, NMYDIR, devgen);
}

static int
mystat(Chan *c, uchar *db, int n)
{
    return devstat(c, db, n, mydir, NMYDIR, devgen);
}

static Chan*
myopen(Chan *c, int mode)
{
    return devopen(c, mode, mydir, NMYDIR, devgen);
}

static void
myclose(Chan *c)
{
    /* free c->aux resources if any */
}

static long
myread(Chan *c, void *buf, long n, vlong offset)
{
    switch((ulong)c->qid.path) {
    case Qdir:
        return devdirread(c, buf, n, mydir, NMYDIR, devgen);
    case Qdata:
        /* return data */
        return readstr(offset, buf, n, "hello\n");
    }
    error(Egreg);
    return -1;
}

static long
mywrite(Chan *c, void *buf, long n, vlong offset)
{
    switch((ulong)c->qid.path) {
    case Qdata:
        /* process write */
        return n;
    }
    error(Eperm);
    return -1;
}

Dev mydevtab = {
    'x',
    "mydev",

    myinit,
    myattach,
    mywalk,
    mystat,
    myopen,
    devnone,       /* create — not supported */
    myclose,
    myread,
    devbread,      /* bread — generic wrapper around read */
    mywrite,
    devbwrite,     /* bwrite — generic wrapper around write */
    devnone,       /* remove */
    devnone,       /* wstat */
};
```

**3. Add to `emu/port/master`:**

```
x    mydev
```

**4. Rebuild:** `mk` in `emu/port/` regenerates the device table and builds.

**5. Bind from Limbo:**

```limbo
sys->bind("#x", "/mnt/mydev", Sys->MREPL);
fd := sys->open("/mnt/mydev/data", Sys->OREAD);
```

---

## Qid Path Encoding

The 64-bit `qid.path` is opaque to the kernel — only your device interprets it. The standard patterns:

**Static table**: paths are just row indices.
```c
enum { Qdir=0, Qfile1=1, Qfile2=2 };
```

**Instance + type**: split bits between instance ID and file type within the instance.
```c
#define NETTYPE(x)   ((ulong)(x) & 0x1f)        /* low 5 bits: file type */
#define NETID(x)     (((ulong)(x)) >> 5)         /* upper bits: instance */
#define NETQID(i, t) (((i) << 5) | (t))
```

**Sequential**: assign a unique incrementing number to each new entity.
```c
c->qid.path = ++eg->path;
```

The path must uniquely identify the file for the server's lifetime. Never reuse a path for a different file.

---

## The Chan Struct

`Chan` is the kernel's open file handle (`emu/port/dat.h:106–132`):

```c
struct Chan {
    Ref     r;          /* reference count */
    vlong   offset;     /* current file position */
    ushort  type;       /* index into devtab[] */
    ulong   dev;        /* device-specific value (usually 0) */
    ushort  mode;       /* OREAD, OWRITE, ORDWR */
    ushort  flag;       /* COPEN: file is open; CRCLOSE: remove on close */
    Qid     qid;        /* file identity */
    void*   aux;        /* per-device private data */
    /* ... mount-point fields, name, etc. */
};
```

Key fields for device code:
- `c->qid.path` — your file identity; switch on this in read/write
- `c->aux` — store a pointer to your per-open-file state here; free it in `close`
- `c->flag & COPEN` — set by `devopen()` when successfully opened
- `c->offset` — maintained by syscall layer for sequential reads; passed explicitly to `read`/`write`

---

## Error Handling in C

The kernel uses setjmp-based error recovery. The pattern (`emu/port/dat.h:404–421`):

```c
if(waserror()) {
    /* error cleanup — runs when error() is called from deeper code */
    qunlock(&mylock);
    nexterror();    /* propagate to next outer waserror */
}

/* protected code */
qlock(&mylock);
if(condition_bad)
    error(Enonexist);   /* jumps to the waserror() above */
result = compute();
qunlock(&mylock);

poperror();    /* must call on all normal paths out */
return result;
```

Rules:
- `waserror()` returns 0 on first call, nonzero after an `error()` call
- Every `waserror()` must be matched by exactly one `poperror()` on the normal path
- Call `nexterror()` in the error branch to re-propagate
- `error(char*)` sets `up->env->errstr` and longjmps to the innermost `waserror`

Common error strings (`include/kern.h` and `emu/port/error.h`):

```c
Eperm    = "permission denied"
Enonexist = "file does not exist"
Ebadarg  = "invalid argument"
Einuse   = "file in use"
Eio      = "i/o error"
Egreg    = "programming error"
Enodev   = "no such device"
Enomem   = "out of memory"
```

---

## Locking

**`Lock`** (spinlock) — for very short critical sections, interrupt-safe:

```c
Lock l;
lock(&l);
/* critical section — must be brief, no blocking */
unlock(&l);
```

**`QLock`** (queue lock) — for longer critical sections where blocking is acceptable:

```c
QLock ql;
qlock(&ql);
/* critical section — can call error(), osblock(), etc. */
qunlock(&ql);
```

When `qlock` finds the lock held, it queues the current Proc and calls `osblock()`. `qunlock` calls `osready()` on the next queued Proc. This is how most device state is protected.

**`RWlock`** — multiple concurrent readers, exclusive writers:

```c
RWlock rw;
rlock(&rw);   /* acquire read lock */
/* read-only access */
runlock(&rw);

wlock(&rw);   /* acquire write lock */
/* exclusive access */
wunlock(&rw);
```

Used for namespace mount tables (`Pgrp.ns`).

---

## OS Abstraction Layer

These functions are declared in `emu/port/fns.h` and implemented per-OS:

| Function | Purpose |
|----------|---------|
| `osblock()` | Sleep current Proc until `osready()` |
| `osready(Proc *p)` | Wake Proc `p` |
| `osmillisec()` | Milliseconds since an arbitrary epoch |
| `osmillisleep(ulong ms)` | Sleep for ms milliseconds |
| `osyield()` | Hint to host scheduler to yield |
| `oslongjmp(buf, n)` | Signal-safe longjmp (for fault recovery) |
| `readkbd()` | Block and return one keyboard character |

On Linux: `osblock`/`osready` use POSIX `sem_wait`/`sem_post` (`emu/port/kproc-pthreads.c`, one semaphore per Proc); `osmillisleep` uses `nanosleep` (`emu/Linux/os.c`); faults (SIGSEGV, SIGBUS) call `oslongjmp` to unwind to the last `waserror` (unless EMUCRASH is set — see `ON_EMU_DEBUG.md`).

---

## Memory Pools

Three separate pools (`emu/port/alloc.c`):

| Pool | Default Size | Used For |
|------|-------------|---------|
| `mainmem` | 32 MB | Kernel structs (Chan, Proc, Pgrp, etc.) |
| `heapmem` | 32 MB | Dis VM heap (garbage collected) |
| `imagmem` | 64 MB | Draw image pixel data |

Allocation functions:

```c
void* malloc(ulong n);          /* may return nil */
void* mallocz(ulong n, int clr); /* zero if clr != 0; may return nil */
void* smalloc(ulong n);          /* calls exhausted() on failure */
void  free(void *p);
```

Use `mallocz(n, 1)` to get zeroed memory. Use `smalloc` only when failure is truly unrecoverable.

---

## Initialization Sequence

(`emu/port/main.c`, `emu/Linux/os.c`)

1. `main()` — parse flags (`-g`, `-c`, `-r`, `-p`), call `libinit(firstmod)`
2. `libinit()` (Linux/os.c) — install signal handlers (SIGILL→Dis illegal instruction, SIGSEGV→fault recovery), configure terminal, get username, call `emuinit(firstmod)`
3. `emuinit()` (port/main.c) — allocate per-process state, call `links()` (module init hooks), call `chandevinit()` (device init), open stdin/stdout/stderr from `#c/cons`, bind default namespace, `kproc("main", disinit, firstmod)` to spawn the first Limbo thread, enter `ospause()`
4. `disinit()` — load and run `firstmod` (default `/dis/emuinit.dis`)
5. `emuinit.dis` — the Limbo-level bootstrap: loads the shell or specified program

The main OS thread enters `ospause()` and parks. All work happens in kproc pthreads after that.

---

## Best Devices to Read as Templates

Ordered by complexity:

1. **`devsnarf.c`** (~162 lines) — Two files (dir + snarf). Static Dirtab. Simple string buffer in global state. Clipboard read/write. Good starting point.

2. **`devenv.c`** (~253 lines) — Dynamic file creation (`create`). Linked list of named entries. Sequential Qid.path numbering. QLock pattern. Good for understanding dynamic directories.

3. **`devdup.c`** (~150 lines) — Content derived from Fgrp (current fd table). Uses a generator function instead of static Dirtab. Path encoding: `2*fd + (is_ctl_file)`. Good for devices whose directory listing varies per-process.

4. **`devpipe.c`** (~461 lines) — Bidirectional queues with `qread`/`qwrite`. Reference-counted pipe struct. NETQID path encoding. Block-oriented I/O. Exception handling for broken pipe. Good for understanding queue-based devices and `c->aux` lifecycle.

---

## Key Files at a Glance

| File | Purpose |
|------|---------|
| `emu/port/dat.h` | Chan, Dev, Proc, Pgrp, Mount, and all other kernel structs |
| `emu/port/fns.h` | Portable function declarations |
| `emu/port/error.h` | Standard error strings (Eperm, Eio, etc.) |
| `include/kern.h` | C standard signatures, Qid, Dir, more error strings |
| `emu/port/dev.c` | devwalk, devstat, devopen, devgen, devdirread helpers |
| `emu/port/chan.c` | Chan alloc/free, chandevinit, namespace ops |
| `emu/port/lock.c` | Lock, QLock, RWlock implementations |
| `emu/port/alloc.c` | Memory pools |
| `emu/port/main.c` | emuinit, namespace bootstrap, ospause |
| `emu/Linux/os.c` | Linux: signals, terminal, timers, osblock/osready |
| `emu/port/kproc-pthreads.c` | Proc/pthread management, semaphore block/ready |
| `man/10/intro` | Kernel internals overview |
| `man/10/dev` | Dev struct and device interface reference |
| `man/10/lock` | Kernel locking reference |
| `man/10/malloc` | Memory allocation reference |
