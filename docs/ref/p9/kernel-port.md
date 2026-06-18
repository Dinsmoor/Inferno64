# 9front → Inferno64: portable-kernel ideas (9/port)

Mined from `9front:sys/src/9/port` (993 commits) and compared against Inferno's
**two** kernels:
- **`emu/port/*` — the LIVE hosted kernel** (what Inferno64 builds/runs). Shares
  lineage for `chan.c`, `pgrp.c`, `devmnt.c`, `qio.c`, `sysfile.c`, `dev.c`,
  `exportfs.c`, `devsrv.c`, `devcons.c`, `exception.c`. The hosted emu has **no**
  VM/paging/scheduler-of-its-own (no `segment.c`/`page.c`/`fault.c`; Dis procs run
  on host pthreads via `kproc-pthreads.c`; the Dis scheduler lives in libinterp),
  so 9front's `proc.c`/`edf.c`/VM work does **not** apply here.
- **`os/port/*` — the DORMANT native kernel** (full Plan 9 kernel: `proc.c`,
  `edf.c`, `segment.c`, `page.c`, `fault.c`, `taslock.c`, `qlock.c`, `xalloc.c`).
  All of 9front's scheduler/VM/lock work applies here, but only matters if the
  native port is revived.

**This is the highest-value of the three topics for the hosted emu** — several
items below touch the live `emu/port` directly. A key accelerant: 9front shares
many fixes with **drawterm** (the hosted Plan 9 terminal), which is
architecturally the same shape as Inferno's emu — those commits port almost
verbatim.

Status legend: ✅ in emu · ❌ absent · ⚠️ present, audit/refine · 🔧 directly applicable · 🔒 security · ⏸ native-port-only (dormant)

---

## Tier 1 — LIVE (emu/port): high-value, applicable now

### K1. Raise the 9P/Styx iounit from 8 KB → 32 KB 🔧 (perf)
`5bc9f30c0` (2023) "kernel: support 32k iounit"; `3c5a33eaa` (2015) chunk
reads/writes by `c->iounit` not `msize-IOHDRSZ`.

Inferno `emu/port/devmnt.c` hardcodes `#define MAXRPC (IOHDRSZ+8192)` and
`malloc(8192+IOHDRSZ)` — every Styx read/write is capped at 8 KB. Bumping the
negotiated msize to 32 KB (and honoring `c->iounit` for chunking) is a
straightforward, large throughput win for everything that mounts a 9P/Styx
server (file I/O, exportfs, remote namespaces). **Effort: low. Risk: low.**

### K2. Eliminate the O(n²) `pgrpcpy()` + 64-bit mount ids 🔧 (perf + correctness)
`4f6fa04fe` (2025) "get rid of mountid and quadratic algorithms in pgrpcpy() and
devproc/readns1()"; `d73f18e1d` (2022) "use 64 bits for mountids";
`fe42622fa` (2025) embed `Mount.spec` into the `Mount` struct.

Inferno `emu/port/pgrp.c` still does the mountid-order-preserving `pgrpcpy()`
(the comment "pgrpcpy MUST preserve the mountid allocation order" is verbatim
1990s code) and uses a 32-bit `Ref mountid`. Namespace copy on every fork is
quadratic, and a long-lived emu can wrap a 32-bit mountid. 9front's rework makes
`pgrpcpy` linear and widens mountids. **Effort: medium. Risk: medium** (touches
the namespace-copy hot path; well-tested in 9front). High value for fork/rfork-
heavy Limbo workloads.

### K3. Port the "from drawterm" hosted-kernel fixes 🔧🔒
drawterm == hosted Plan 9 kernel in userspace == the same architecture as emu.
These should drop in with minimal translation; diff `emu/port` against them:
- `efaeebeb5` (2018) "port: sync two longjmp fixes from drawterm" — `waserror`/
  `longjmp` correctness. emu uses the identical `waserror()`/`nexterror()`
  mechanism (`emu/port/exception.c`); a botched longjmp is a latent crash.
- `e076133ab` (2017) "avoid waserror() botch in devwalk (from drawterm)" —
  audit `emu/port/{dev.c,chan.c}` `devwalk`.
- `9eab390e5` (2012) "devproc buffer overflow, strncpy" — 🔒 bounds bug.

**Effort: low per item. Risk: low.** These are exactly the class of latent
hosted-kernel bug the LP64/observability work cares about.

### K4. `_Noreturn` on the error/abort primitives 🔧 (helps `make lint`)
`b0ab2a2de` (2024) "Use _Noreturn for gotolabel(), error(), nexterror() and
panic()"; `4537fd480`-era `faulterror()`/`namelenerror()` too.

Annotating `error()`/`nexterror()`/`panic()`/`gotolabel()` as `_Noreturn` lets
the compiler and the existing `clang -Wshorten-64-to-32` / sanitizer sweeps (see
the LP64 observability work) prune false "use after the throw" paths and catch
real fall-through bugs. **Effort: trivial. Risk: none.** Natural fit with the
existing lint baseline.

### K5. `sysfile`/`chan` correctness batch ⚠️
Audit `emu/port/{sysfile,chan,dev}.c` against:
- `ebc8c2920` (2025) fix `waserror()` handling in `bindmount()`/`sysunmount()`
- `18af0b191` (2021) fix `stat` bugs
- `2e600e6b0` (2017) fix directory rewinding with `pread()` offset
- `db3f78629` (2023) make walk/open errors consistent (better diagnostics)
- `1d99ad006` (2021) acquire `Mhead.lock` for **all** `Mhead.mount` access (race)
- `0f0b6def8` (2020) fix `Abind` cyclic reference + mounthead leaks
- `579ce6fc0` (2025) fix `namec()` `Aunmount` semantics for directories
- `00dbc3dd4` (2014) don't pass a user address of the `fd[2]` array to `newfd2()` 🔒

**Effort: low–medium (a review pass). Risk: low.** Several are real races/leaks.

### K6. qio flow-control & leak fixes ⚠️
`emu/port/qio.c` has the same `Qflow`/`limit` flow control as 9front. Candidates:
- `863431cff` (2024) fix qio flow control; `96b131e39` fix queue-bloat blocking
  in `qwrite()` (writer wakeup threshold)
- `830337793` (2024) fix deadlock in `qdiscard()`
- `4714ed413` (2023) memory leak in `qproduce()`
- `70c97c334` (2026) `trimblock()` free blocks for negative offset/len
- `a4ac136dc` (2011) `eqlock()` — an *interruptible* `qlock` (so a blocked
  reader/writer can take a note/interrupt); check whether emu has an equivalent.

**Effort: low each. Risk: low.** qio underlies pipes, devices, and network I/O.

---

## Tier 2 — LIVE (emu/port): perf, more involved

### K7. 9P read pipelining (multiple outstanding RPCs)
`e7fe1e3dc`/`177c5e761` (2015) pipelined read-ahead; `b6dc3746a` `devstream`
9p-pipelining experiment; `69481a8a5` (2025) devmnt `bread/bwrite` handlers.

emu's `cache.c` is intentionally a no-op ("no cache in hosted mode"), so the
*mount-cache* read-ahead doesn't apply directly — but the underlying idea
(**keep several read RPCs in flight** instead of strict request/reply) is
independent of caching and would cut latency for Styx mounts over a network.
Worth considering if remote-namespace latency ever matters. **Effort: medium-
high. Risk: medium.**

### K8. Async clunk for closed channels
`b4b2bbc0b` (2012) "async clunk for cached mounts, fix closeproc explosion."
The general idea — don't block a closing proc on the Tclunk round-trip — reduces
teardown latency. Audit emu's close path. **Effort: medium.**

---

## Tier 3 — DORMANT (os/port): native-port revival list ⏸

Only relevant if Inferno64 revives the native `os/` kernel. Listed so the next
person has the map. Inferno's `os/port` already has `edf.c`, `proc.c`,
`segment.c`, `page.c`, `fault.c`, `taslock.c`, `qlock.c`.

### Scheduler / EDF
- `5deae3fbb` (2025) **"Edf times are in µs(), not nanoseconds"** — a real
  unit bug in taslock/EDF; check Inferno's `edf.c` for the same.
- `63beb8c35` (2024) EDF double-`ready()` detection + robustness; `afdf90a3e`
  never `sched()` in `unlock()` when not Running; `62c66b9e4`/`99e8716ee` add
  "New"/"Queueing" state assertions to catch invalid transitions.
- `7d2d050f9` (2024) `sched()` should not imply `spllo()`.
- **`2019-05-01` insert memory barrier before `up->mach = nil` in the
  scheduler** — *directly echoes the aarch64 unlock release-barrier root cause
  already fixed in emu* (see memory `aarch64-unlock-release-barrier`). The native
  `os/port` scheduler likely needs the same barrier discipline on weakly-ordered
  arches. Cross-reference when porting to native ARM64.
- `0bf...`/`2020-01-11` remove dead CPU "load balancing" relics; `2024-07-xx`
  processor-affinity / load-sharing rework (SMP).
- `4...semacquire stack corruption on interrupt` (2024); `addbroken()` race.

### VM / pager (segment/page/fault)
- Page-reclaim strategy + locking rework (`2020-04-26`, `2025-07-13` cap
  reclaim work, avoid reclaim on active images, `palloc.headroom`).
- `2025-08-23` make `pio()` interruptible, avoid copy on single-page I/O.
- `2019-08-27` catch exec read-fault on `SG_NOEXEC` segments 🔒 (W^X).
- `2020-05-10` fix `checkpages()`/`segflush()` on `SG_PHYSICAL`; `2017-05-21`
  avoid panic with `segio` + `SG_FAULT`.
- `2014-06-22` new pagecache: remove `Lock` from `Page`, use `cmpswap` for `Ref`
  (lock-free refcounting — relevant to the concurrency hardening theme).

### Locks / clocks
- `ec4daa138` add `pc` field in `QLock` for debugging; `ad0726a14` warn when
  rlock/wlock held while holding spinlocks — cheap deadlock-detection aids worth
  having in any kernel.

---

## Cross-cutting (could touch emu too)

### K9. Monotonic time in `/dev/time` and `/dev/bintime`
`06009390d` (2025, from rsc) "add monotonic time to /dev/time, /dev/bintime."
A monotonic clock that doesn't jump on wall-clock adjustment is useful to *any*
program doing timing/timeouts. emu exposes time via `devcons`/host clock; adding
a monotonic source (host `CLOCK_MONOTONIC`) to the relevant emu device is a small
quality-of-life win. **Effort: low.**

---

## Suggested order of attack (hosted emu)

1. **K1 (32k iounit)** — biggest perf/effort ratio; one file.
2. **K3 (drawterm fixes) + K4 (_Noreturn)** — cheap correctness/lint wins that
   align with the existing observability work.
3. **K5 + K6** — a correctness/leak review pass over `sysfile`/`chan`/`qio`.
4. **K2 (pgrpcpy/mountids)** — higher value but bigger blast radius; do once K1/K3
   build confidence.
5. K7/K8 (pipelining/async clunk) only if Styx latency becomes a measured problem.
6. Tier 3 is parked until/unless the native `os/` port is revived — at which point
   the EDF µs bug (`5deae3fbb`) and the scheduler memory barrier are the first
   things to check (the barrier ties into the known aarch64 ordering bug class).
