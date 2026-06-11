# Using third-party C at runtime — out-of-process native services over Styx

> *So you want to use someone else's C library on a running Inferno system, without rebuilding the world — and without it crashing the world?* This is the reference.

This document is about a specific, narrow building block: take **some C library
someone else wrote** (SQLite, a codec, a numerics kernel), build it on a running
system, and **write Limbo against it** — *without* vendoring it into emu/the
kernel, and in a way where **a segfault in that C takes down only it, never the
system that called it.**

The answer is **not** DLM / runtime native linking (see
[ON_DLM.md](ON_DLM.md)). It is older, simpler, and already the Inferno idiom:
**run the foreign C as a separate process that serves a Styx (9P) file tree, and
mount it.** The process boundary *is* the fault isolation; Styx *is* the API.

**One-line summary:** wrap the C library in a host program that links it and
serves files via `tools/libstyx`; Inferno `mount`s it and drives the library by
reading and writing files. Crash isolation is free, because it's a different
address space.

See also: [ON_DLM.md](ON_DLM.md) (the in-process path, and why it's stubbed +
gives no isolation), [ON_C_IN_INFERNO.md](ON_C_IN_INFERNO.md) /
[ON_STB.md](ON_STB.md) (the *other* way to add C — compile a typed builtin
**into** emu; in-process, no isolation, needs a rebuild),
[ON_NETWORK.md](ON_NETWORK.md), [ON_9P.md](ON_9P.md), [ON_NAMESPACE.md](ON_NAMESPACE.md).

---

## The two ways to add C, and when each applies

| | **Compile a builtin into emu** ([ON_STB.md](ON_STB.md): `$Imageio`) | **Out-of-process Styx service** (this doc: `sqlitefs`) |
|---|---|---|
| Where the C runs | inside emu's address space | a **separate** process |
| Crash blast radius | **the whole emu** | only that process |
| Add/replace it | rebuild emu (~55s here) | build + relaunch one binary, no emu rebuild |
| Call cost | a function call across the Dis↔C boundary | an IPC round-trip (Styx message) |
| Best for | hot, trusted, fine-grained native code (`$Raster3`, decoders) | reusing big/crashy/foreign C at coarse granularity (a database, a parser) |

DLM would have been a *third* way ("load native C into emu at runtime"), but it
is stubbed on hosted emu, has no 64-bit backend, and — critically for the
requirement here — gives **no isolation**: in-process loading means the
library's segfault *is* emu's segfault. The fault-isolation requirement alone
rules out every in-process option and selects the process boundary.

---

## The mechanism

```
   Inferno (emu)                          host OS process
  ┌───────────────┐   Styx/9P over      ┌────────────────────────┐
  │ Limbo program │   tcp! or pipe      │  sqlitefs (host C)      │
  │   mount ──────┼─────────────────────┼─▶ libstyx (Styxserver) │
  │   open/read/  │                     │      │                 │
  │   write files │◀────────────────────┼──────┴─▶ SQLite (libsqlite3)
  └───────────────┘                     └────────────────────────┘
         safe Dis world                    if this faults, only THIS dies
```

Three parts:

1. **A host program that links the library** and exposes it as a Styx file
   tree, using the in-tree host server library `tools/libstyx`
   (`Styxserver`/`Styxops`, see `include/styxserver.h`).
2. **A transport** — TCP (the `tools/odbc` model) or a pipe via the cmd device
   `#C` / the `os` command. Either way it's a separate process.
3. **Inferno mounts it** (`sys->mount` / `mount`) and uses ordinary file I/O.

This is exactly how `tools/odbc/odbc.c` exposes ODBC databases to Inferno today;
`sqlitefs` is the same pattern with a self-contained library and no external
dependency, written to be the easiest case to copy.

### Why this is idiomatic, not a hack
Inferno's whole model is "every resource is a file server speaking Styx." A
crashy C library wrapped as a Styx server is just *another file server*. The
isolation isn't bolted on — it falls out of the architecture.

---

## Worked example: `sqlitefs` (SQLite as a file tree)

Files (all in `tools/sqlitefs/`, client in `appl/cmd/sql.b`):

| file | role |
|---|---|
| `sqlitefs.c` | the host server: links SQLite, serves Styx, `-t` self-test |
| `fetch-sqlite.sh` | fetches the pinned SQLite amalgamation + builds `sqlite3.o` (not vendored) |
| `mkfile`, `mkfile-Linux` | host build (`mk`), mirrors `tools/odbc` |
| `appl/cmd/sql.b` | minimal Limbo client: dial, mount, query, print |

The served tree:

```
/db            directory
/db/new        open() clones a connection -> /db/N/ ( /net-style clone )
/db/N/ctl      write "open <path>" | "close"; read -> connection number
/db/N/cmd      write an SQL statement -> it runs, result is buffered
/db/N/data     read the result ('|'-separated fields, '\n' per row)
/db/N/error    read the last error message
/db/N/status   read connection state
```

### Build it

```sh
# on the host (Linux), from the repo root:
sh tools/sqlitefs/fetch-sqlite.sh                 # fetch + compile sqlite3.o
export ROOT=$PWD PATH=$PWD/Linux/$OBJTYPE/bin:$PATH
(cd tools/libstyx  && mk install)                 # once: host Styx server lib
(cd tools/sqlitefs && mk install)                 # -> Linux/$OBJTYPE/bin/sqlitefs
limbo -I module -o dis/sql.dis appl/cmd/sql.b      # the Limbo client
```

### Prove the C works with no Inferno at all

```
$ sqlitefs -t
--- sqlitefs selftest (sqlite 3.46.1) ---
id|name
1|hello
2|world
--- ok ---
```

`-t` runs `open :memory:` → create → insert → select through the *same* code
path the Styx server uses, so the library binding can be validated as a plain
program before any Inferno is involved. Always provide this mode.

### Use it from Inferno

```sh
# host: start the server (separate process, listens on tcp 6701)
Linux/$OBJTYPE/bin/sqlitefs &

# inside emu:
sql /tmp/demo.db 'create table t(id integer, name text)'
sql /tmp/demo.db "insert into t values(1,'hello'),(2,'world')"
sql /tmp/demo.db 'select * from t order by id'
        # id|name
        # 1|hello
        # 2|world
```

Or skip the client entirely and drive the files from `sh` — it is, after all,
just a mounted file tree:

```sh
mount -A tcp!127.0.0.1!6701 /n/sqlite
# (the clone/ctl handshake is why a small client is handier than raw sh here)
```

### See the isolation

Kill the server (or feed SQLite something that makes *it* crash) while a query
is in flight: the Limbo side gets an I/O error on the next `read`, and **emu
keeps running**. Restart the server and remount. That is the entire point —
contrast a compiled-in builtin, where the same fault is an emu core.

---

## Transport: TCP vs the cmd device

- **TCP** (shown above, and what `tools/odbc` uses): simplest, and the server
  can even live on another machine. Mount with `tcp!host!port`.
- **Pipe via `#C` / `os`**: launch the helper as a child of the Inferno process
  with the `os` command (the `#C` cmd device, `emu/port/devcmd.c`) and speak
  Styx (or a trivial line protocol) over its `data` pipe. No network, lifetime
  tied to the launcher. Use this when you want the service private to one
  session.

Both give the same isolation (separate process); pick by lifetime and scope.

---

## Tradeoffs (so this isn't oversold)

- **The cost is the boundary crossing.** Each call is a Styx round-trip, so keep
  the interface **coarse**: "run this query, return rows," not a per-row
  callback. The heavy work stays at native speed *inside* the server; only the
  crossings cost. For a database, a codec, a parser — exactly the libraries you
  want to reuse — this is the right granularity anyway.
- **Cheap on hosted emu, a real feature on native.** On hosted emu the host OS
  hands you both the compiler and process isolation, so this works *today*. On
  the native `os/` kernel, "a separate protected process" requires the kernel to
  give native C its own MMU-backed address space — which native Inferno does not
  currently do (it isolates *Dis* apps via the VM, not native C via the MMU). So
  on bare metal this building block depends on `os/` growing real protected
  processes. (Note the inversion vs. DLM, which is the opposite: plausible on
  native, pointless on hosted.)

### The one in-process-*and*-isolated alternative: WebAssembly
If you ever need isolation *without* an IPC boundary, compile the C library to
WebAssembly and run a wasm runtime inside emu: a fault becomes a contained wasm
trap (linear-memory sandbox), memory-safe by construction — at the cost of a
wasm runtime dependency and recompiling the library to wasm. Every other option
trades isolation for in-process speed or vice-versa.

---

## Replicating this for another library — the recipe

To expose library `libfoo` the same way:

1. **Get the source.** Prefer a self-contained amalgamation; fetch it in a
   `fetch-*.sh` rather than committing a big blob (see `fetch-sqlite.sh`).
2. **Copy `tools/sqlitefs/` to `tools/foofs/`.** Replace the SQLite calls in the
   `Styxops` handlers (`open`/`read`/`write`/`close`) with `libfoo` calls.
   Design a **coarse** file interface (a `cmd` you write, a `data` you read).
3. **Keep a `-t` self-test** that exercises the library with no Styx, so you can
   debug the binding as a plain host program.
4. **Build:** `mkfile` + `mkfile-$SYSTARG` putting the library in `SYSLIBS`
   (compile foreign C with the *plain* host `cc`, not the Inferno toolchain, to
   avoid `lib9.h` clashes — `sqlite3.o` is built this way).
5. **Write/borrow a Limbo client** (`appl/cmd/sql.b` is ~80 lines: dial, mount,
   clone, write `cmd`, read `data`).
6. **Mount and use.** A crash is now contained to `foofs`.

Prior art to read: `tools/odbc/odbc.c` (databases), `tools/libstyx/` (the
`Styxserver` engine), `appl/demo/odbc/odbcmnt.b` (a richer Limbo client).

### Four rules that are easy to get wrong

These are not optional; a server that skips them fails in confusing ways.

1. **Match the library's allocator.** Free memory the library handed you with
   *its* deallocator (`sqlite3_free` for `sqlite3_str_finish`/`sqlite3_malloc`),
   never libc `free`. Mismatched allocators corrupt the heap.
2. **Make the clone/`ctl` file readable.** The `/net`-style handshake reads the
   connection number back from the freshly cloned `ctl`; if that file is not
   readable the client gets "permission denied" before it ever runs a query.
3. **Isolate the client's namespace.** The Limbo client must `pctl(FORKNS)` and
   `unmount` any stale mount before mounting, so repeated invocations don't
   leave dead mounts behind (which surface as "clone failed" on the next mount).
   See `appl/cmd/sql.b`.
4. **Keep the interface coarse and the buffers bounded.** One write = one
   statement; size every `read`/`write` against `MSGMAX`; report errors as Styx
   error strings, not by crashing.

---

## Status of the example

`sqlitefs` + `sql` are verified end-to-end on the aarch64 build: the host
self-test passes, and from a `wm/sh` shell in emu `sql` creates/inserts/selects
against the mounted server (real SQLite, out of process). Killing the server
mid-session (`kill -SEGV`) fails the next query with "connection refused" while
**emu keeps running**; restarting it returns the data intact — the fault
isolation the pattern exists to provide.

The SQLite amalgamation is intentionally **not** vendored (`.gitignore`d);
`fetch-sqlite.sh` pulls the pinned 3.46.1 release on demand.
