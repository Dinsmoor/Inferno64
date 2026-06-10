# Namespace in Inferno OS

> *So you want to compose services with bind, mount, and unmount?* This is the reference.

Every process in Inferno has its own private namespace — a mapping from path names to file servers. Bind, mount, and unmount reshape this mapping without touching any global state. This is how Inferno composes services: you attach a file server to a path and everything that can manipulate files can then use it.

## Core Concepts

A **mount point** is a directory in the current namespace. A **channel** (`Chan` in the kernel) is an open reference to a file or directory on some device. When you mount or bind, you add a new `Mount` record to the mount table for that path. Lookups walk the mount table and search each layer in order.

**Union mounts** let multiple file servers appear merged at the same directory. A directory lookup that doesn't find a name in the first layer continues into subsequent layers. Creates go to the first layer that has `MCREATE` set.

## bind and mount

**`sys->bind(src, dst, flags)`** — alias an existing path:

```limbo
sys->bind("/usr/foo", "/bin", Sys->MBEFORE);
sys->bind("#c", "/dev", Sys->MBEFORE);  # attach console device to /dev
```

**`sys->mount(fd, afd, dst, flags, spec)`** — connect a 9P server over `fd`:

```limbo
fds := array[2] of ref Sys->FD;
sys->pipe(fds);
# serve 9P on fds[0]; mount fds[1]
sys->mount(fds[1], nil, "/mnt/myfs", Sys->MREPL, nil);
```

`afd` is for authenticated mounts (pass nil for unauthenticated). `spec` is the `aname` passed in the 9P Attach message; servers may use it to select which tree to export.

**`sys->unmount(src, dst)`** — remove a specific mount:

```limbo
sys->unmount(nil, "/mnt/myfs");   # remove all mounts at dst
sys->unmount("/usr/foo", "/bin"); # remove only this specific binding
```

### Mount Flags

Defined in `module/sys.m` and `include/kern.h`:

| Limbo constant | C constant | Value | Meaning |
|---------------|-----------|-------|---------|
| `Sys->MREPL`   | `MREPL`   | 0 | Replace all existing mounts at dst |
| `Sys->MBEFORE` | `MBEFORE` | 1 | Insert before existing mounts (searched first) |
| `Sys->MAFTER`  | `MAFTER`  | 2 | Insert after existing mounts (searched last) |
| `Sys->MCREATE` | `MCREATE` | 4 | Allow creates in this layer of a union |
| `Sys->MCACHE`  | `MCACHE`  | 16 | Cache remote data locally |

You can OR `MCREATE` with any of the ordering flags:

```limbo
sys->bind("/tmp", "/work", Sys->MBEFORE | Sys->MCREATE);
```

### Kernel Implementation

`emu/port/sysfile.c:413–485` implements `kbind` and `kmount`. Both delegate to `bindmount()` which calls `cmount()` in `emu/port/chan.c:386`. `cmount` validates that both channels are directories, then manipulates the `Mhead` linked list for that mount point. Mount operations are serialized via a reader-writer lock on the process group's namespace (`pg->ns`).

## pctl: Namespace Inheritance

By default, `spawn` shares the parent's namespace. To get an isolated copy:

```limbo
sys->pctl(Sys->FORKNS, nil);   # fork a copy before modifying
sys->pctl(Sys->NEWNS, nil);    # brand new empty namespace
sys->pctl(Sys->NEWENV, nil);   # new environment
sys->pctl(Sys->FORKENV, nil);  # fork a copy of environment
sys->pctl(Sys->NEWPGRP, nil);  # new process group
sys->pctl(Sys->NODEVS, nil);   # disallow attaching new devices
sys->pctl(Sys->NEWFD, nil);    # new (empty) file descriptor table
sys->pctl(Sys->FORKFD, nil);   # fork a copy of fd table
```

Flags can be OR'd. The typical pattern for an isolated subprocess:

```limbo
sys->pctl(Sys->FORKNS | Sys->FORKENV | Sys->NEWPGRP, nil);
# now reshape namespace freely without affecting parent
```

## The Default Namespace at Startup

`emu/port/main.c:300–328` sets up the initial namespace by calling `kbind` directly before any Limbo code runs:

```
#U  → /          (MAFTER|MCREATE)  Unix host filesystem as the base
#^  → /dev       (MBEFORE)         Snarf/clipboard device
#^  → /chan       (MBEFORE)         Same snarf device at /chan
#m  → /dev       (MBEFORE)         Mouse/pointer device
#c  → /dev       (MBEFORE)         Console device
#p  → /prog      (MREPL)           Process/thread inspector
#d  → /fd        (MREPL)           File descriptor filesystem
#I  → /net       (MAFTER)          Network device
#U/dev   → /dev  (MAFTER)          Host /dev overlaid
#U/net   → /net  (MAFTER)          Host /net overlaid
#U/net.alt→/net.alt (MAFTER)       Alternate network stack
```

Device names follow the convention `#C` where C is a single character identifying the driver.

## Built-in Devices and Their Paths

| Device | Path | Purpose |
|--------|------|---------|
| `#U`  | /    | Host OS filesystem (Unix, Windows) |
| `#p`  | /prog | Process table — one directory per thread |
| `#d`  | /fd   | File descriptor filesystem |
| `#e`  | /env  | Environment variables as files |
| `#c`  | /dev  | Console (`/dev/cons`, `/dev/consctl`) |
| `#m`  | /dev  | Mouse/pointer (`/dev/mouse`, `/dev/cursor`) |
| `^`  | /chan, /dev | Snarf/clipboard buffer |
| `#I`  | /net  | Network stack (TCP, UDP, IP, ARP…) |
| `#s`  | /srv | Server registry — post an fd here (`/srv/name`) for other procs to mount (`emu/port/devsrv.c`) |

## /env: Environment Variables as Files

Each environment variable is a file in `/env`. Reading the file gives the value; writing sets it; creating a new file adds a variable.

```limbo
# Set
fd := sys->create("/env/PATH", Sys->OWRITE, 8r666);
sys->fprint(fd, "/bin:/usr/bin");

# Read
fd = sys->open("/env/HOME", Sys->OREAD);
buf := array[256] of byte;
n := sys->read(fd, buf, len buf);
home := string buf[0:n];
```

The Limbo `os` module provides a higher-level `env->get/set` interface built on top of `/env`.

## /prog: Processes as Files

`/prog/PID/` contains a directory for each live Prog. Key files:

| File | Purpose |
|------|---------|
| `status` | pid, pgid, user, cpu, state, mem, module name |
| `ctl` | write `kill`, `killgrp`, `exceptions propagate` |
| `ns` | current namespace as bind/mount commands |
| `nsgrp` | namespace group ID |
| `pgrp` | process group ID |
| `stack` | call stack frames |
| `exception` | last **caught** exception as `pc module string`; **empty for a proc broken by an _unhandled_ exception** (`p->exstr` is only set on a catch — see ON_DEBUGGING.md) |
| `fd` | open file descriptors |
| `heap` | memory inspector |
| `dbgctl` | debugger control |
| `wait` | child exit events |

The `ns` file is especially useful: it outputs the sequence of bind/mount commands that would reproduce the current namespace from scratch.

```sh
cat /prog/1/ns
# bind -b '#c' /dev
# bind -b '#m' /dev
# bind    '#p' /prog
# mount   /fd/1 /net
# ...
```

## /net: Network Stack as Files

The `/net` directory exposes the full network stack. The standard pattern for making a TCP connection:

```limbo
# High-level: use the dial module
c := dial->dial("tcp!hostname!80", nil);

# Low-level: walk the /net filesystem directly
fd := sys->open("/net/tcp/clone", Sys->ORDWR);
# Read to get conversation number
buf := array[12] of byte;
sys->read(fd, buf, len buf);
n := int string buf;
ctlpath := "/net/tcp/" + string n + "/ctl";
datapath := "/net/tcp/" + string n + "/data";
# Connect
ctlfd := sys->open(ctlpath, Sys->OWRITE);
sys->fprint(ctlfd, "connect hostname!80");
# Read/write data
datafd := sys->open(datapath, Sys->ORDWR);
```

Network directory structure:

```
/net/
  tcp/
    clone   — open to create new conversation; read for conversation number
    stats   — protocol statistics
    0/      — conversation 0
      ctl   — connect, announce, bind
      data  — send/receive bytes
      listen — accept incoming connections
      local — local address string
      remote — remote address string
      status — connection state
  udp/      — same structure
  dns/      — DNS resolver
  arp/      — ARP table
  ndb/      — network database
```

## Reshaping the Namespace

Common patterns:

### Import a remote service

```limbo
# Mount a remote Plan 9 / Inferno file server
sys->mount(conn_fd, nil, "/mnt/remote", Sys->MREPL, "");
```

### Shadow a directory with a synthetic one

```limbo
# Overlay /bin with a custom set of commands
fds := array[2] of ref Sys->FD;
sys->pipe(fds);
spawn myserver(fds[0]);   # serve 9P on fds[0]
sys->mount(fds[1], nil, "/bin", Sys->MBEFORE, nil);
```

### Export part of your namespace

```limbo
# Publish a directory via /srv so others can mount it
srvfd := sys->create("/srv/myfs", Sys->ORDWR, 8r600);
if(sys->export(srvfd, "/my/dir", Sys->EXPWAIT) < 0)
    raise "fail:export";
```

### Namespace file: automate namespace setup

Namespace files are scripts in the format described in `man/6/namespace`. Location: `usr/inferno/namespace` is the default user namespace.

```
# namespace file syntax
bind -b '#c' /dev            # bind device to /dev, before existing
bind -a '#U/bin' /bin        # append host /bin after existing /bin
mount tcp!fileserver!9999 /n/server
cd /usr/username
```

Commands: `bind [-abci]`, `mount [-abci]`, `unmount`, `import`, `cd`, `fork`, `new`, `nodev`, `. filename` (include).

The `newns` Limbo module (`appl/lib/newns.b`) parses and executes namespace files. Call `newns->newns(user, nsfile)` to apply one.

## Viewing the Current Namespace

```sh
ns           # prints the current namespace as bind/mount commands
ns -r PID    # prints another process's namespace
cat /prog/SELF_PID/ns   # same, via /prog directly
```

## Key Files

| File | Purpose |
|------|---------|
| `emu/port/sysfile.c:413–485` | kbind/kmount syscall implementation |
| `emu/port/chan.c:386` | cmount: actual mount table manipulation |
| `emu/port/main.c:300–328` | Default namespace bootstrap |
| `emu/port/devenv.c` | /env device implementation |
| `emu/port/devprog.c` | /prog device implementation |
| `emu/port/devip.c` | /net network stack |
| `emu/port/devsnarf.c` | /chan and snarf device |
| `module/sys.m:97–110` | bind/mount/pctl Limbo interface and flag constants |
| `include/kern.h:402–406` | Mount flag constants (C) |
| `appl/lib/newns.b` | Namespace file parser/executor |
| `appl/cmd/ns.b` | `ns` tool: print current namespace |
| `man/6/namespace` | Namespace file format specification |
| `man/2/sys-bind` | bind/mount/unmount reference |
| `man/2/sys-pctl` | pctl flags reference |
