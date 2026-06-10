# Limbo Concurrency Model in Inferno OS

## Progs and Procs: Two Levels of Concurrency

Inferno has two separate concurrency layers that interact in non-obvious ways.

**Procs** are host OS threads. In hosted Inferno (`emu`), these are pthreads or equivalent. One or more Procs run `vmachine()`, the Dis VM execution loop. You rarely create Procs directly; the system manages them.

**Progs** are Limbo-level threads — lightweight green threads scheduled by the Dis VM. When you write `spawn f()`, you create a Prog. Thousands of Progs can exist while only a handful of Procs run them.

The key invariant: **only one Proc runs the Dis VM at a time**. The VM is protected by a global lock. A Proc acquires the VM, runs Progs in a round-robin loop, then releases the VM when a Prog blocks on I/O. While the VM is released, another Proc waiting on the VM queue can pick it up.

Prog states (`include/interp.h`):

```
Pready    — runnable, in the VM's run queue
Palt      — blocked in an alt statement waiting for a channel
Psend     — blocked trying to send on a channel
Precv     — blocked trying to receive from a channel
Prelease  — the VM has been released for blocking I/O on this Prog
Pdebug    — stopped by debugger
Pexiting  — in the process of terminating
Pbroken   — terminated with unhandled exception (inspectable via /prog)
```

## Channels

The `chan` type is the only synchronization primitive in Limbo. There are no mutexes or shared-memory primitives at the language level.

```limbo
# Unbuffered: send blocks until receiver is ready (and vice versa)
c := chan of string;

# Buffered: sender doesn't block until buffer is full
c := chan[16] of string;
c := chan[1] of int;    # common mutex pattern
```

Channel structure (`include/interp.h:117–130`):

```c
struct Channel {
    Array*  buf;    /* nil for unbuffered; circular queue if buffered. MUST be first */
    Progq*  send;   /* queue of Progs blocked trying to send */
    Progq*  recv;   /* queue of Progs blocked trying to receive */
    void*   aux;    /* "rock" for devsrv (a channel can back a /srv file) */
    void  (*mover)(void); /* data mover selected by element type */
    union { WORD w; Type* t; } mid; /* move descriptor: word, or pointer Type* */
    int     front;  /* head of circular buffer queue */
    int     size;   /* number of items currently in buffer */
};
```

(`aux`/`mover`/`mid` are runtime plumbing — the move function and its type
descriptor, plus the devsrv back-pointer — not part of the Limbo-visible model.)

For buffered channels, `CANPUT` is true when `size < len(buf)` and `CANGET` is true when `size > 0`. The buffer is a circular array; `front` advances on read, `(front+size) % len` is the write position.

### Channel Direction

Channels are first-class values and can be sent over other channels. You can restrict a channel to one direction at a call site:

```limbo
send(c: chan of <- string) { c <- = "hello"; }
recv(c: chan of -> string) { s := <-c; }
```

## The alt Statement

`alt` waits on multiple channels simultaneously, selecting whichever is ready first. If multiple are ready, one is chosen uniformly at random (not first-listed).

```limbo
alt {
(n, err) := <-results =>
    if(err != nil) ...;
<-quit =>
    return;
}
```

The optional `*` arm makes alt non-blocking — if no channel is ready it runs the `*` arm instead of blocking:

```limbo
alt {
x := <-c =>
    process(x);
* =>
    # nothing ready
}
```

This is equivalent to `nbalt` in Dis terms. Without `*`, the Prog enters `Palt` state and blocks.

**Implementation (three passes, `libinterp/alt.c`):**

1. **altrdy** — scan all arms, count how many channels are ready (sender waiting, or buffer non-empty for recv; receiver waiting, or buffer has space for send)
2. **altcomm** — pick one ready arm at random (`xrand = xrand*1103515245 + 12345; sel = (xrand>>8) % nrdy`), perform the transfer
3. **altdone** — remove the Prog from all channel queues it was enqueued in, write the selected arm index to the destination register

If `nrdy == 0` and no `*` arm: the Prog is enqueued on all channels' send/recv queues and its state is set to `Palt`. When any of those channels becomes ready, the Prog is woken via `addrun()`.

### The alt Send/Recv Constraint

A channel may not appear in both a send arm and a receive arm of the same `alt`. The VM will raise `"alt send/recv on same chan"` immediately. This is checked at runtime.

## Process Groups

Spawn creates a child Prog in the same process group as the parent:

```limbo
spawn f(arg);
```

Process groups (`emu/port/dis.c`) are used for:
- Coordinated kill: `echo "killgrp" > /prog/PID/ctl` kills every Prog in the group
- Exception propagation (see below)
- `/prog` filesystem: `pgrp` file shows group ID

`sys->pctl(Sys->NEWPGRP, nil)` creates a new process group for the calling Prog. Use this when you want a subprocess that is isolated from its parent's group.

### Exception Propagation

By default, an unhandled exception leaves only the faulting Prog in `Pbroken` state; other group members are unaffected.

Change the mode by writing to `/prog/PID/ctl`:

```sh
echo "exceptions propagate" > /prog/42/ctl
# Unhandled exception kills all Progs in the group
```

```sh
echo "exceptions notifyleader" > /prog/42/ctl
# Unhandled exception kills siblings, raises exception in group leader
```

In Limbo:

```limbo
sys->pctl(0, nil);  # no effect on pgrp
# To set propagation: write to /prog/self/ctl
ctlfd := sys->open("/prog/" + string sys->pctl(0,nil) + "/ctl", Sys->OWRITE);
sys->fprint(ctlfd, "exceptions propagate");
```

## The Prelease/kproc Pattern

Blocking host-level I/O (reading from a network socket, waiting for a file) cannot be done while holding the VM — it would stall all other Progs. The pattern:

1. **`release()`** — release the VM. The current Proc becomes free to execute any waiting Procs, or sleeps on the VM queue. The current Prog is marked `Prelease`.

2. **Do the blocking host call** (read, write, sleep, etc.)

3. **`acquire()`** — re-acquire the VM. The Proc queues itself on the VM acquisition queue (`isched.vmq`) and sleeps until the VM is free, then restores the Prog's register state and adds it back to the run queue.

If the blocking I/O needs a separate host thread (e.g., for truly parallel blocking), `kproc("name", func, arg, flags)` spawns a new Proc that runs `func`. This Proc is entirely in host-thread space and never runs Dis directly; it calls `acquire()` when it needs to wake a Prog.

The channel block/wake cycle (`emu/port/dis.c`):

```
Prog wants to receive from empty channel
    → cblock() called
    → release() — VM given to next waiting Proc
    → OS thread sleeps on condition variable
    → (later) sender sends data, calls addrun(receiver_prog)
    → addrun() wakes the blocked OS thread
    → acquire() — OS thread queues for VM
    → Prog resumes with data in register
```

## Common Deadlock Patterns

### 1. Two Progs blocked on each other

```limbo
# Prog A                     # Prog B
<-b;                         <-a;
a <- = "done";               b <- = "done";
```

Neither can proceed. Fix: use a third Prog as intermediary, or use buffered channels if ordering allows it.

### 2. Lock inversion with chan[1]

```limbo
lock1 := chan[1] of int;
lock2 := chan[1] of int;
lock1 <- = 1;   lock2 <- = 1;  # initialize

# Prog A: acquire lock1 then lock2
<-lock1; <-lock2; work(); lock2 <- = 1; lock1 <- = 1;

# Prog B: acquire lock2 then lock1 — DEADLOCK
<-lock2; <-lock1; work(); lock1 <- = 1; lock2 <- = 1;
```

Fix: always acquire locks in the same order across all Progs.

### 3. The "no receiver in group" problem

```limbo
# Bounce pattern: always need a dummy receiver
# If all Progs in a pipeline exit, senders deadlock
# Solution from appl/wm/bounce.b:
# Keep a dummy process that's always available to receive
```

### 4. Spawn + sync without confirmation

```limbo
spawn child();
doWork();   # child may not have started yet
```

If `doWork()` depends on child having initialized something, this is a race. Fix:

```limbo
sync := chan of int;
spawn child(sync);
<-sync;     # child sends on sync when ready
doWork();
```

### 5. Non-blocking write to avoid deadlock

When a goroutine writes status/notification to a channel that may already be full:

```limbo
alt {
status <- = result =>
    ;  # sent
* =>
    ;  # receiver wasn't ready, drop notification
}
```

See `appl/cmd/auth/factotum/factotum.b:208` for a real example with comment.

## Using chan[1] as a Mutex

The standard Limbo idiom for mutual exclusion:

```limbo
lock := chan[1] of int;
lock <- = 1;   # initialize: buffer occupied = unlocked

# To acquire:
<-lock;

# Critical section

# To release:
lock <- = 1;
```

Buffer size 1 means at most one goroutine holds the "token" at a time. See `appl/acme/dat.b:42–66` for the pattern in production code.

## Pipeline Pattern

```limbo
c := chan[BUFSZ] of int;
spawn producer(c);
spawn filter(c, out);
consumer(out);
```

The buffered channel decouples producer from consumer. `BUFSZ > 0` prevents the producer from blocking on every item. See `appl/math/genprimes.b` for a prime sieve implemented this way.

## Scheduler Details

`vmachine()` (`emu/port/dis.c:1126–1195`) runs in a loop:

1. If no Progs are ready, run GC tasks and idle
2. After 2+ scheduling cycles, call `iyield()` so other host threads waiting for the VM can acquire it (prevents starvation of OS-level work)
3. Dequeue the head of the run queue (`runhd`)
4. Execute via `r->xec(r)` until the Prog blocks or exhausts its quantum
5. If more Progs are waiting, move this Prog to the run queue tail (round-robin)
6. Periodically trigger GC

Time quantum: `PQUANTA = 2048` instructions per scheduling slice (`include/interp.h:28`). Each Prog has a `quanta` counter; when it hits zero the Prog is preempted.

## Key Files

| File | Purpose |
|------|---------|
| `include/interp.h` | Prog/Channel/Proc structs, state enum |
| `emu/port/dis.c` | vmachine, acquire/release, spawn, killgrp |
| `libinterp/alt.c` | alt statement: altrdy/altcomm/altdone |
| `libinterp/xec.c` | Channel ops: isend/irecv, chan allocation |
| `emu/port/main.c` | kproc, OS thread creation |
| `man/2/sys-pctl` | pctl flags: NEWPGRP, NEWNS, FORKFD, etc. |
| `man/1/limbo` | spawn, alt syntax |
| `appl/wm/bounce.b` | Token-passing with deadlock avoidance |
| `appl/acme/dat.b` | chan[1] mutex pattern |
| `appl/math/genprimes.b` | Pipeline / prime sieve pattern |
| `appl/cmd/styxlisten.b` | Concurrent connection handler |
