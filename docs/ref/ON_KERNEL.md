# Inferno Kernel Internals — Agent Reference

This document covers the kernel layer of Inferno — both the hosted emulator (emu) kernel and the native bare-metal kernel (os/). It explains process management, the 9P file protocol, device drivers, the namespace, memory allocation, and the scheduler.

---

## Two Kernel Modes

Inferno runs in two configurations that share the same interface but differ in implementation:

| Aspect | Hosted (emu/) | Native (os/) |
|--------|---------------|--------------|
| Runs on | Linux, macOS, Windows, FreeBSD | Bare metal (ARM, x86, PowerPC, MIPS, SPARC) |
| OS threads | POSIX pthreads | Kernel scheduling |
| File I/O | Via host OS syscalls (devfs-posix.c) | Direct device drivers |
| Memory | malloc-based pools | Direct MMU/physical memory |
| Interrupt handling | POSIX signals | Hardware interrupts |
| Key files | `emu/port/`, `emu/Linux/` | `os/port/`, `os/pc/`, `os/arm/` |

From a Limbo application's perspective, both modes are identical — the same .dis bytecode runs on both, accessing the same 9P-based namespace.

---

## Process Abstraction: Proc and Prog

There are two distinct "process" concepts in Inferno. Understanding both is essential.

### Proc — Kernel Thread (C level)

`Proc` is an OS-level thread. In hosted mode, each Proc corresponds to a POSIX pthread. Procs handle blocking I/O and device operations.

**File**: `emu/port/dat.h`

```c
struct Proc {
    int     type;           // Unknown, IdleGC, Interp, BusyGC, Moribund (values below)
    char    text[KNAMELEN]; // name, for debugging
    long    pid;
    Proc*   next, *prev;    // global proc list
    Lock    rlock;          // protects r field
    Rendez* r;              // rendezvous point currently sleeping on
    Rendez  sleep;          // default sleep point
    int     killed;         // set by swiproc to interrupt
    int     swipend;        // software interrupt pending for associated Prog
    int     nerr;           // error stack depth
    osjmpbuf estack[NERR];  // setjmp/longjmp error recovery stack
    void    (*func)(void*); // kproc entry function
    void*   arg;            // kproc argument
    void*   iprog;          // associated Limbo Prog (if type==Interp)
    Osenv*  env;            // OS environment (namespace, fds, ...)
    Osenv   defenv;         // default env (for kprocs without a Prog)
};

// Real values (emu/port/dat.h) — NOT a 0..n sequence:
enum { Unknown=0xdeadbabe, IdleGC=0x16, Interp=0x17, BusyGC=0x18, Moribund };
```

**Key functions**:
- `newproc()` — allocate and initialize a Proc, add to global list.
- `kproc(name, fn, arg, flags)` — create a new kernel thread running `fn(arg)`.
- `Sleep(r, condition, arg)` — block this Proc until `condition(arg)` is true or it is woken by `Wakeup(r)`.
- `Wakeup(r)` — wake a Proc sleeping on rendezvous `r`.
- `swiproc(p, interp)` — deliver a software interrupt to Proc `p`; if `interp=1`, signals the associated Prog.

**Error stack**: Each Proc has a `setjmp` stack of depth `NERR=32` (`emu/port/dat.h`). `error(msg)` calls `longjmp` to the nearest `waserror()` handler. Code that must clean up on error uses:
```c
if(waserror()) {
    // cleanup
    nexterror();  // propagate to next handler
}
// ... risky operations ...
poperror();       // pop handler, normal exit
```

### Prog — Limbo Thread (VM level)

`Prog` is a Limbo-level coroutine managed by the Dis VM scheduler. One Proc (the interpreter Proc) runs many Progs cooperatively.

**File**: `include/interp.h`

```c
struct Prog {
    REG         R;          // register file (PC, FP, MP, SP, IC, ...)
    enum ProgState state;   // Pready, Palt, Psend, Precv, Pdebug, Prelease, Pexiting, Pbroken
    int         pid;        // unique Prog identifier
    int         quanta;     // time slice (instructions remaining)
    Prog*       link;       // run queue link
    Channel*    chan;        // channel blocked on (when in Palt/Psend/Precv)
    void*       ptr;        // data pointer for channel op
    Progs*      group;      // process group
    void*       exval;      // current exception value
    char*       exstr;      // last exception string
    void*       osenv;      // pointer to Osenv (fds, namespace, user, ...)
    void      (*xec)(Prog*); // executor (interpreted or JIT)
    void      (*addrun)(Prog*); // enqueue on run queue
};
```

**Relationship**: A Prog's `osenv` points to the Osenv of the Proc that created it. When a Prog needs to do blocking I/O, it sets its state to `Prelease` and hands control to a slave kproc; the kproc does the blocking call, then re-enqueues the Prog.

---

## OS Environment (Osenv)

Each process group shares a namespace, file-descriptor table, and environment variables. These are managed via reference-counted groups:

```c
struct Osenv {
    char*   syserrstr;    // last OS error string
    char*   errstr;       // current unwinding error string
    char    errbuf0[ERRMAX];
    char    errbuf1[ERRMAX];
    Pgrp*   pgrp;         // process group: namespace, cwd, root
    Fgrp*   fgrp;         // file descriptor group
    Egrp*   egrp;         // environment variable group
    Skeyset* sigs;        // signed module keys
    Queue*  waitq;        // dead-child notifications
    Queue*  childq;       // child notifications for debuggers
    char*   user;         // Inferno user name
    FPU     fpu;          // floating-point state
    int     uid, gid;     // host UID/GID
};
```

**Pgrp** — Process Group (namespace):

```c
struct Pgrp {
    Ref     r;              // reference count
    ulong   pgrpid;
    RWlock  ns;             // namespace lock (one writer, many readers)
    Mhead*  mnthash[MNTHASH]; // hash table of mount points (32 buckets)
    Chan*   dot;            // current directory (".")
    Chan*   slash;          // root ("/")
};
```

**Fgrp** — File Descriptor Group:

```c
struct Fgrp {
    Lock    l;
    Ref     r;
    Chan**  fd;     // fd[i] = Chan* for file descriptor i (nil if closed)
    int     nfd;    // allocated slots
    int     maxfd;  // highest fd in use
    int     minfd;  // lower bound for free slot search
};
```

**Egrp** — Environment Group:

```c
struct Egrp {
    Ref     r;
    QLock   l;
    ulong   path;   // version number (incremented on each write)
    ulong   vers;
    Evalue* entries; // linked list of name=value pairs
};
```

---

## The 9P File Protocol

All kernel I/O is mediated by 9P (also called Styx in older Inferno). 9P is a client-server protocol where:
- The **client** sends T-messages (Tagged requests).
- The **server** replies with R-messages (Responses).
- Every resource is addressed by a **fid** (file identifier) in the client's connection.

**File**: `include/fcall.h`

### Message Types

```c
enum {
    Tversion  = 100,   Rversion,   // negotiate protocol version and max msize
    Tauth     = 102,   Rauth,      // set up authentication
    Tattach   = 104,   Rattach,    // connect to file tree (get root fid)
    Rerror    = 107,               // error response (no Terror)
    Tflush    = 108,   Rflush,     // cancel a pending request
    Twalk     = 110,   Rwalk,      // traverse path elements (stat-less walk)
    Topen     = 112,   Ropen,      // open a fid for I/O
    Tcreate   = 114,   Rcreate,    // create and open a file
    Tread     = 116,   Rread,      // read data
    Twrite    = 118,   Rwrite,     // write data
    Tclunk    = 120,   Rclunk,     // forget a fid
    Tremove   = 122,   Rremove,    // remove a file
    Tstat     = 124,   Rstat,      // get file metadata
    Twstat    = 126,   Rwstat,     // set file metadata
};
```

### Fcall Structure

```c
typedef struct Fcall {
    uchar   type;       // message type
    u32int  fid;        // file identifier (NOFID = ~0 = none)
    ushort  tag;        // request tag for multiplexing (NOTAG = ~0 = untagged)
    u32int  msize;      // Tversion/Rversion: max message size
    char*   version;    // Tversion/Rversion: protocol version string
    ushort  oldtag;     // Tflush: tag to cancel
    char*   ename;      // Rerror: error string
    Qid     qid;        // Rattach, Ropen, Rcreate: resulting qid
    u32int  iounit;     // Ropen, Rcreate: recommended I/O unit
    char*   uname;      // Tattach: user name
    char*   aname;      // Tattach: attach path
    u32int  newfid;     // Twalk: new fid to assign to walked path
    ushort  nwname;     // Twalk: number of path elements to walk
    char*   wname[MAXWELEM]; // Twalk: path elements
    ushort  nwqid;      // Rwalk: number of qids returned
    Qid     wqid[MAXWELEM];  // Rwalk: qids for each walked element
    vlong   offset;     // Tread, Twrite: file offset
    u32int  count;      // Tread, Twrite, Rread: byte count
    char*   data;       // Twrite, Rread: payload
    uchar*  stat;       // Tstat, Twstat, Rstat: stat buffer
    ushort  nstat;      // stat buffer length
} Fcall;
```

### Qid — Unique File Identifier

```c
typedef struct Qid {
    uvlong  path;   // unique 64-bit path number (assigned by device)
    ulong   vers;   // version (incremented on each modification)
    uchar   type;   // QTDIR, QTAPPEND, QTEXCL, QTAUTH, QTFILE
} Qid;
```

`QTDIR` (0x80) marks a directory. Each device is responsible for assigning unique `path` values within its own namespace.

### Wire Encoding

9P messages are little-endian binary. Convenience macros in `include/fcall.h`:

```c
GBIT8(p)     // read 1 byte from p
GBIT16(p)    // read 2 bytes LE
GBIT32(p)    // read 4 bytes LE
GBIT64(p)    // read 8 bytes LE
PBIT8(p, v)  // write 1 byte
PBIT16(p, v) // write 2 bytes LE
PBIT32(p, v) // write 4 bytes LE
PBIT64(p, v) // write 8 bytes LE
```

Each message begins with a 4-byte little-endian length, 1-byte type, and 2-byte tag. The `IOHDRSZ = 24` constant allows for maximum header size of any message.

---

## Device Driver Interface

**Files**: `emu/port/dev.c`, `emu/port/dat.h`

Every kernel resource is a device. Devices register themselves in `devtab[]`, which
is generated from the active config file's `dev` section (`emu/Linux/emu` for the
`make` build; `emu/port/master` + `mkdevlist` for the legacy `mk` build).

### Dev Vtable

```c
struct Dev {
    int   dc;           // device character (e.g., 'c' for #c = cons)
    char* name;         // device name (e.g., "cons")
    void  (*init)(void);           // called at system startup
    Chan* (*attach)(char* spec);   // open the device root
    Walkqid* (*walk)(Chan* c, Chan* nc, char** names, int nnames);
    int   (*stat)(Chan* c, uchar* buf, int n);
    Chan* (*open)(Chan* c, int mode);
    void  (*create)(Chan* c, char* name, int mode, ulong perm);
    void  (*close)(Chan* c);
    long  (*read)(Chan* c, void* buf, long n, vlong offset);
    Block* (*bread)(Chan* c, long n, ulong offset);  // block read
    long  (*write)(Chan* c, void* buf, long n, vlong offset);
    long  (*bwrite)(Chan* c, Block* b, ulong offset); // block write
    void  (*remove)(Chan* c);
    int   (*wstat)(Chan* c, uchar* buf, int n);
};
```

Devices are accessed via a path like `#c/cons` (device char `c`, file `cons`). The `dc` field is the single character after `#`.

### Dirtab — Static Directory Entries

Most devices define their file tree as a static `Dirtab` array:

```c
typedef struct Dirtab {
    char    name[KNAMELEN];  // file name
    Qid     qid;             // unique id
    long    length;          // file length (0 = dynamic)
    long    perm;            // permissions (e.g., 0644, DMDIR|0555)
} Dirtab;
```

The `devgen()` function turns a `Dirtab` array into `walk`/`stat` responses automatically. Most devices use it for the directory listing and add custom logic only for read/write.

### devdir() — Fill a Dir

```c
void devdir(Chan* c, Qid qid, char* name, long length, char* user,
            long perm, Dir* dp);
```

Fills a `Dir` structure for stat/walk responses. The `eve` global holds the system owner username.

### Writing a Device Driver

1. Define an enum of Qid path constants.
2. Define a `Dirtab[]` with names, qids, lengths, permissions.
3. Implement the `Dev` vtable functions.
4. Implement `init()` to initialize global state.
5. Use `devgen(c, name, tab, ntab, i, dp)` in `walk` for directory listing.
6. `attach()` returns a Chan for the device root (call `devattach(dc, spec)`).
7. `open()` validates mode and returns the Chan unchanged (or cloned).
8. `read()`/`write()` implement the actual data transfer.
9. Add to the `dev` section of `emu/Linux/emu` (and `emu-g`) — or `emu/port/master`
   for the `mk` build — then rebuild (`make all`).

---

## Chan — File Channel

**File**: `emu/port/chan.c`

`Chan` is the per-connection file handle, analogous to a file descriptor but richer. Every open file, mounted directory, and network connection is a `Chan`.

```c
struct Chan {
    Lock    l;
    Ref     r;              // reference count (closedchan when 0)
    Chan*   next;           // free list link
    vlong   offset;         // current file position (for read/write)
    ushort  type;           // index into devtab[]
    ulong   dev;            // device instance number
    ushort  mode;           // OREAD, OWRITE, ORDWR, OEXEC, OTRUNC
    ushort  flag;           // COPEN, CMSG, CCEXEC, CFREE, CRCLOSE
    Qid     qid;            // unique file identifier
    int     fid;            // 9P fid (for devmnt channels)
    ulong   iounit;         // preferred I/O transfer size
    Mhead*  umh;            // union mount head (for union reads)
    Chan*   umc;            // current channel in union read
    QLock   umqlock;
    int     uri;            // union read index
    Chan*   mchan;          // channel to server (for mounted paths)
    Qid     mqid;           // server-side qid
    Cname*  name;           // path name (ref counted)
    void*   aux;            // device-specific state
};
```

**Reference counting**: Use `cclone(c)` to get a new reference (increments ref), `cclose(c)` to release one (frees when ref hits zero).

**Walking**: `walk(c, nc, names, n)` traverses path elements. `nc` is a freshly allocated clone to update (caller must supply it or pass nil for a fresh one).

---

## Namespace and Mount Points

**Files**: `emu/port/chan.c`, `emu/port/devmnt.c`

The namespace is a graph of mount points managed by the Pgrp. When a path is resolved:

1. Start from `pgrp->slash` (for absolute paths) or `pgrp->dot` (for relative).
2. For each path element, call `walk()` on the current Chan.
3. At each Chan, check `pgrp->mnthash` for a mount point covering this Qid.
4. If mounted, redirect the walk through the mount's `to` channel.
5. Union mounts: multiple mounts layered via Mhead→Mount chain.

### bind and mount

```limbo
# Limbo side (module/sys.m)
bind(name: string, old: string, flag: int): int;
mount(fd: ref FD, afd: ref FD, old: string, flag: int, aname: string): int;
```

`bind("/net/tcp", "/tcp", Sys->MBEFORE)` — makes `/tcp` appear in the namespace before any existing content.

`mount(fd, afd, "/", Sys->MREPL, "")` — connects to a 9P server over `fd` (with optional auth on `afd`) and mounts it at `/`.

### Mount Flags

| Flag      | Value | Meaning |
|-----------|-------|---------|
| `MREPL`   | 0     | Replace existing content |
| `MBEFORE` | 1     | Insert before (union: check this first) |
| `MAFTER`  | 2     | Insert after (union: check this last) |
| `MCREATE` | 4     | Allow create in the union |

### devmnt — 9P Client

**File**: `emu/port/devmnt.c`

`devmnt` implements the client side of 9P. When you mount a file server, `devmnt` creates an Mnt structure that multiplexes requests over the transport channel.

```c
struct Mnt {
    Lock    l;
    Chan*   c;          // channel to the file server
    Mntrpc* queue;      // pending RPCs (by tag)
    ulong   id;
    int     msize;      // max message size (negotiated)
    Queue*  q;          // input queue
};

struct Mntrpc {
    Fcall   request;    // outgoing message
    Fcall   reply;      // incoming reply
    Rendez  r;          // sleep here waiting for reply
    uchar*  rpc;        // wire-format buffer
    char    done;       // reply received flag
};
```

Each Twrite/Tread becomes an Mntrpc: serialized into `rpc`, sent over `c`, and then the calling Proc sleeps on `r` until the reply arrives and is deserialized.

---

## I/O Queues

**File**: `emu/port/qio.c`

Queues are kernel-internal Block chains for buffered I/O between producers and consumers (e.g., keyboard input, network data).

```c
struct Queue {
    Lock    l;
    Block*  bfirst, *blast;   // block chain
    int     len;              // total bytes allocated to queue
    int     dlen;             // data bytes available
    int     limit;            // max bytes (flow control)
    int     state;            // Qstarve, Qmsg, Qclosed, Qflow, Qcoalesce
    void  (*kick)(void*);     // output trigger callback
    void  (*bypass)(void*, Block*); // bypass callback (zero-copy path)
    QLock   rlock, wlock;     // reader/writer mutexes
    Rendez  rr, wr;           // reader/writer rendezvous
};
```

Key operations:
- `qopen(limit, type, kick, arg)` — allocate a queue.
- `qwrite(q, buf, n)` — write data (blocks if queue full).
- `qread(q, buf, n)` — read data (blocks if queue empty).
- `qclose(q)` — close queue, wakes all blocked readers/writers.
- `qpass(q, block)` — enqueue a Block directly (avoids copy).

`Qmsg` flag preserves message boundaries — a single `qwrite` is returned as a single `qread`.

---

## Block — Data Buffer

**File**: `emu/port/dat.h`

All I/O data in the kernel moves in `Block` structures:

```c
struct Block {
    Block*  next;           // next in chain
    Block*  list;           // list linkage
    uchar*  rp;             // read pointer (first unconsumed byte)
    uchar*  wp;             // write pointer (first free byte)
    uchar*  lim;            // end of allocated buffer
    uchar*  base;           // start of allocated buffer
    void  (*free)(Block*);  // custom free (for non-malloc'd bufs)
    ulong   flag;
};

#define BLEN(b)    ((b)->wp - (b)->rp)    // data available
#define BALLOC(b)  ((b)->lim - (b)->base) // total capacity
```

Key functions:
- `allocb(size)` — allocate a Block with `size` bytes of capacity.
- `freeb(b)` — free one Block.
- `concatblock(b)` — flatten a Block chain into one Block.
- `copyblock(b, n)` — copy `n` bytes from a Block chain.

---

## Memory Allocation

**File**: `emu/port/alloc.c`

Three pools:

| Variable   | Name    | Default | Usage |
|------------|---------|---------|-------|
| `mainmem`  | `main`  | 32 MB   | C kernel data structures |
| `heapmem`  | `heap`  | 32 MB   | Limbo GC-managed objects |
| `imagmem`  | `image` | 64 MB   | Graphics images |

The pool allocator uses a binary search tree of free `Bhdr` nodes for O(log n) first-fit allocation. Blocks are coalesced on free.

Use `malloc(n)` / `free(p)` for `mainmem`. Limbo heap uses `halloc(n, type)`.

High-water marks and current usage can be read from `/dev/memory` (via devcons).

---

## OS Integration Layer

**File**: `emu/Linux/os.c`

The OS integration layer adapts POSIX to the emu's internal interfaces.

### Signal Handling

```c
// SIGSEGV / SIGBUS → nil dereference or bad address
static void trapmemref(int sig, siginfo_t *si, void *a) {
    if(isnilref(si))
        disfault(nil, exNilref);   // raises Limbo "dereference of nil"
    else
        sysfault("bad address", si->si_addr);
}

// SIGILL → illegal instruction
static void trapILL(int sig, siginfo_t *si, void *a) {
    sysfault("illegal instruction pc=", si->si_addr);
}

// SIGFPE → floating-point exception  
static void trapFPE(int sig, siginfo_t *si, void *a) {
    disfault(nil, "sys: fp: exception ...");
}

// SIGUSR1 → software interrupt for blocking I/O interrupt
static void trapUSR1(int sig) {
    if(up->intwait == 0)
        disfault(nil, Eintr);
}
```

### Synchronization (pthreads)

```c
// Blocking a Proc: uses a pthread mutex + condvar
void osblock(void) {
    // pthread_cond_wait on up->sleep
}

// Waking a Proc: signals its condvar
void osready(Proc* p) {
    // pthread_cond_signal on p->sleep
}

// kproc: create a new pthread
void kproc(char* name, void (*fn)(void*), void* arg, int flags) {
    // pthread_create(fn, arg)
}
```

### Time

```c
long osmillisec(void);      // milliseconds since first call
vlong osnsec(void);         // nanoseconds since epoch
vlong osusectime(void);     // microseconds since epoch
int osmillisleep(ulong ms); // sleep for ms milliseconds (nanosleep)
```

---

## Device Inventory

Which devices are compiled in is chosen by a configuration file listing the
`dev`/`lib`/`mod` sections. The legacy `mk` build uses `emu/port/master` +
`mkdevlist`; the current `make all` build uses **`emu/Linux/emu`** (and
`emu/Linux/emu-g` for the headless variant) — that is the file to edit to add a
device today. Standard devices:

| `#` char | Name       | File | Description |
|----------|------------|------|-------------|
| `c`      | cons       | `devcons.c` | Console, keyboard, random, time, null |
| `d`      | dup        | `devdup.c` | File descriptor duplication |
| `e`      | env        | `devenv.c` | Environment variables |
| `i`      | draw       | `devdraw.c` | Graphics display |
| `I`      | ip         | `devip.c` | TCP/IP networking |
| `m`      | pointer    | `devpointer.c` | Mouse/pointer input |
| `M`      | mnt        | `devmnt.c` | 9P client (mount) |
| `p`      | prog       | `devprog.c` | Process control (/prog namespace) |
| `P`      | prof       | `devprof.c` | Profiling |
| `s`      | srv        | `devsrv.c` | Service registry (`/srv`) |
| `U`      | fs         | `devfs-posix.c` | Host filesystem (`#U`, name "fs") |
| `\|`     | pipe       | `devpipe.c` | Pipes |
| `τ`      | tk         | `devtk.c` | Tk GUI events (dc is the wide char `L'τ'`) |

(There is no `#f` device in this tree, and no `emu/port/devfs.c`: the single host
filesystem device is `#U` = `devfs-posix.c`.)

### devcons Qids

`#c` provides:
```
cons        read/write  console (keyboard in, text out)
consctl     write-only  control (e.g. "rawon", "rawoff")
drivers     read-only   list of loaded device drivers
null        read/write  null device (/dev/null equivalent)
random      read-only   cryptographic random bytes
time        read/write  current time (nanoseconds since epoch)
user        read/write  current user name
sysname     read/write  system name
memory      read-only   memory pool statistics
msec        read-only   milliseconds since boot
kprint      read-only   kernel print buffer
```

---

## Console Device Internals

**File**: `emu/port/devcons.c`

The console maintains three I/O queues:

```c
Queue* kbdq;    // raw keyboard input (from OS keyboard event)
Queue* lineq;   // cooked keyboard input (line-edited, after newline)
Queue* gkbdq;   // graphical keyboard input (separate from text console)
```

Reading `#c/cons`:
- If `raw` mode: read directly from `kbdq` (one key at a time).
- If cooked mode: read from `lineq` (whole lines, backspace processed).

Writing `#c/cons`: writes to the draw subsystem (text terminal rendered in the window) or to the host's stdout.

Keyboard state machine (`kbd` struct) handles:
- Raw vs cooked mode toggling via `consctl`.
- Erase character (backspace), kill-line, etc.
- Rune decoding (UTF-8 → Unicode).

---

## File System Device (devfs)

**File**: `emu/port/devfs-posix.c`

Maps Inferno's 9P namespace operations onto POSIX filesystem calls.

```c
typedef struct Fsinfo {
    int     uid, gid;       // POSIX owner
    int     mode;           // POSIX mode
    DIR*    dir;            // open directory stream (for readdir)
    int     fd;             // POSIX file descriptor (for regular files)
    vlong   offset;         // directory read offset
    Cname*  name;           // Inferno path name
    Qid     rootqid;        // Inferno root qid for this attachment
} Fsinfo;
```

Mapping:
- `attach(spec)` — opens the host path given by `spec` (or `/` if none).
- `walk(names)` — calls `stat()` on each path element.
- `open(mode)` — calls POSIX `open(name, mode)`.
- `read(buf, n, offset)` — calls POSIX `pread(fd, buf, n, offset)`.
- `write(buf, n, offset)` — calls POSIX `pwrite(fd, buf, n, offset)`.
- `stat` — maps `struct stat` to Inferno `Dir` (mode, uid, gid, size, mtime, atime).

User/group ID mapping: The device maintains a cache of POSIX uid/gid→name mappings so Inferno can display human-readable owner names without repeated `getpwuid` calls.

---

## Scheduler (Limbo threads)

**File**: `emu/port/dis.c`

The Dis VM scheduler is a cooperative, run-to-completion scheduler within the interpreter Proc. It is single-threaded with respect to the VM — only one Prog runs at a time on the interpreter.

### Run Queue

```c
static struct {
    Prog* runhd;      // next prog to run
    Prog* runtl;      // tail (for O(1) enqueue)
    Prog* head;       // all progs (alive, regardless of state)
} isched;
```

`addrun(p)` appends `p` to the tail. `delrun()` removes from the head. This is a FIFO queue — fair scheduling by round-robin.

### Scheduler Loop (conceptual)

```
loop:
    p = dequeue from isched.runhd
    if p is nil:
        execatidle()     # run GC, then sleep waiting for I/O
        goto loop
    xec(p)               # run p for up to PQUANTA=2048 instructions
    if p.state == Pready:
        addrun(p)        # re-enqueue for next time slice
    goto loop
```

### Blocking a Prog

When a Prog does a channel operation that can't complete immediately:
1. Set `p->state = Psend` (or `Precv` or `Palt`).
2. Enqueue `p` in the channel's send/recv queue.
3. Return from `xec()` — the Prog is not re-enqueued.
4. Later, when a counterpart arrives, `addrun(p)` is called, and the Prog runs again.

### Blocking I/O (Prelease)

When a Prog needs to do a blocking host syscall (e.g., a network read):
1. Set `p->state = Prelease`.
2. Create a slave kproc (pthread) to do the actual I/O.
3. The Prog is removed from the run queue while the kproc runs.
4. When the kproc finishes, it calls `addrun(p)` to reschedule the Prog.

---

## Native Kernel (os/) Notes

**Directory**: `os/`

The native kernel has the same conceptual structure but is implemented differently:

- **Proc** has a `Label sched` field (setjmp-style context for cooperative scheduling).
- **Scheduler** is preemptive with priorities, including an EDF (Earliest Deadline First) real-time scheduler.
- **Memory** is managed via direct physical memory allocation (no malloc).
- **Interrupts** are hardware exceptions mapped to Proc wakeups.
- **Devices** have direct register-level implementations (UART, SPI, I2C, Ethernet, etc.).

The `os/port/` directory contains architecture-independent kernel code (proc management, channel routing, memory allocation) that mirrors `emu/port/` semantically but is implemented for bare-metal.

For aarch64/ARM64 native kernel work, look in `os/arm/` and `os/omap/` (TI OMAP) as reference points — there is no dedicated os/aarch64 port yet.

---

## Synchronization Primitives

**File**: `emu/port/dat.h` (declarations), `emu/port/lock.c` (implementations)

| Primitive | Type     | Use |
|-----------|----------|-----|
| `Lock`    | Spinlock | Short critical sections (never sleep while holding) |
| `QLock`   | Sleep lock | Long critical sections (OK to sleep while holding) |
| `RWlock`  | Read-write lock | Many readers, one writer |
| `Rendez`  | Condition variable | Sleep until woken by specific event |

```c
// Spinlock
lock(&l);
// ... critical section ...
unlock(&l);

// QLock (processes can sleep while holding)
qlock(&ql);
// ... critical section (may call sleep) ...
qunlock(&ql);

// RWlock
rlock(&rwl);   // acquire read lock
// ... read-only ...
runlock(&rwl);

wlock(&rwl);   // acquire write lock
// ... write ...
wunlock(&rwl);

// Rendezvous (condition variable)
// Sleeping side:
Sleep(&r, condition_fn, arg);

// Waking side:
Wakeup(&r);
```

**Important**: Never call `sleep()` or block while holding a `Lock` (spinlock) — this will deadlock. Only `QLock` and `RWlock` are safe across sleeping points.
