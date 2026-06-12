# 9P/Styx Protocol in Inferno OS

The 9P protocol (called Styx in Inferno) is the universal communication layer. Every resource—files, devices, network connections, synthetic filesystems—is served over 9P. Understanding it is prerequisite to any systems-level work.

## Wire Format

All messages use little-endian byte order. Every message begins with:

```
[4] size   — total byte count including this field
[1] type   — message type constant (Tversion=100 … Rwstat=127)
[2] tag    — client-chosen request ID; NOTAG (0xFFFF) for version
```

Message type constants (`include/styx.h:97–124`):

```c
Tversion=100, Rversion,
Tauth=102,    Rauth,
Tattach=104,  Rattach,
Terror=106,   Rerror,
Tflush=108,   Rflush,
Twalk=110,    Rwalk,
Topen=112,    Ropen,
Tcreate=114,  Rcreate,
Tread=116,    Rread,
Twrite=118,   Rwrite,
Tclunk=120,   Rclunk,
Tremove=122,  Rremove,
Tstat=124,    Rstat,
Twstat=126,   Rwstat,
```

Bit-packing macros (`include/styx.h:64–74`):

```c
GBIT8(p), GBIT16(p), GBIT32(p), GBIT64(p)   /* get little-endian */
PBIT8(p,v), PBIT16(p,v), PBIT32(p,v), PBIT64(p,v)  /* put little-endian */
```

Key size constants:

```c
QIDSZ     = 13   /* 1-byte type + 4-byte vers + 8-byte path */
STATFIXLEN= 49   /* fixed part of a Dir entry */
MAXWELEM  = 16   /* max path components in Twalk */
IOHDRSZ   = 24   /* per-message overhead for read/write */
MAXFDATA  = 8192 /* default max data per message */
```

### Per-Message Layouts

**Twalk/Rwalk** — navigate directory tree:
```
T: fid[4] newfid[4] nwname[2] nwname×(wname[s])
R: nwqid[2] nwqid×(wqid[13])
```
Walk clones fid into newfid; use `newfid==fid` to walk in place. Partial walks are valid: if only k of n names succeed, Rwalk returns k qids and the walk is partial.

**Tread/Rread**:
```
T: fid[4] offset[8] count[4]
R: count[4] data[count]
```

**Twrite/Rwrite**:
```
T: fid[4] offset[8] count[4] data[count]
R: count[4]
```

**Topen/Ropen**:
```
T: fid[4] mode[1]
R: qid[13] iounit[4]
```
`iounit` is the maximum bytes the server will return in a single read.

**Tstat/Rstat**:
```
T: fid[4]
R: nstat[2] stat[nstat]   /* packed Dir, includes 2-byte size prefix */
```

### Qid Structure

A Qid uniquely identifies a file across the server's lifetime:

```
qid.type  [1]  — QTDIR(0x80) QTAPPEND(0x40) QTEXCL(0x20) QTAUTH(0x08) QTFILE(0x00)
qid.vers  [4]  — incremented each time file content changes
qid.path  [8]  — unique number, never reused for the server's lifetime
```

### Packed Dir Entry Format

```
[2] size (excludes this 2-byte field itself)
[2] type
[4] dev
[1] qid.type
[4] qid.vers
[8] qid.path
[4] mode
[4] atime
[4] mtime
[8] length
[2+n] name string
[2+n] uid string
[2+n] gid string
[2+n] muid string
```

Total = `STATFIXLEN` (49) + sum of string lengths.

## Limbo ADTs: Tmsg and Rmsg

Defined in `module/styx.m`. The `pick` discriminated union mirrors the wire type byte.

**Tmsg** (requests from client, `module/styx.m:75–123`):

```limbo
Tmsg: adt {
    tag: int;
    pick {
    Readerror =>
        error: string;
    Version =>
        msize: int;
        version: string;
    Auth =>
        afid: int;
        uname, aname: string;
    Attach =>
        fid, afid: int;
        uname, aname: string;
    Flush =>
        oldtag: int;
    Walk =>
        fid, newfid: int;
        names: array of string;
    Open =>
        fid, mode: int;
    Create =>
        fid: int;
        name: string;
        perm, mode: int;
    Read =>
        fid: int;
        offset: big;
        count: int;
    Write =>
        fid: int;
        offset: big;
        data: array of byte;
    Clunk or Stat or Remove =>
        fid: int;
    Wstat =>
        fid: int;
        stat: Sys->Dir;
    }
    read:       fn(fd: ref Sys->FD, msize: int): ref Tmsg;
    unpack:     fn(a: array of byte): (int, ref Tmsg);
    pack:       fn(nil: self ref Tmsg): array of byte;
    packedsize: fn(nil: self ref Tmsg): int;
};
```

**Rmsg** (replies from server, `module/styx.m:125–163`) — parallel structure with reply-specific fields.

Protocol constants (`module/styx.m:6–21`):

```limbo
VERSION:    con "9P2000";
MAXWELEM:   con 16;
NOTAG:      con 16rFFFF;
NOFID:      con int ~0;
STATFIXLEN: con BIT16SZ+QIDSZ+5*BIT16SZ+4*BIT32SZ+BIT64SZ;  # 49
IOHDRSZ:    con 24;
MAXFDATA:   con 8192;
MAXRPC:     con IOHDRSZ+MAXFDATA;
```

Open mode flags:

```limbo
OREAD=0, OWRITE=1, ORDWR=2, OEXEC=3
OTRUNC=16, ORCLOSE=64
```

Directory mode bits:

```limbo
DMDIR=int 1<<31, DMAPPEND=int 1<<30, DMEXCL=int 1<<29, DMAUTH=int 1<<27
```

## Writing a File Server in Limbo

### The Two APIs

**`Styxlib`** (`module/styxlib.m`) — simpler, deprecated. Messages arrive on a channel; you reply manually. Used in older code like `appl/cmd/memfs.b`.

**`Styxservers`** (`module/styxservers.m`) — the current API. Manages Fid state automatically, plugs in a Navigator for directory tree queries. Used in `appl/cmd/dbfs.b`, `appl/cmd/vacfs.b`, etc.

### Styxservers Framework

**Fid** (`module/styxservers.m:5–19`) — tracks per-handle state:

```limbo
Fid: adt {
    fid:   int;           # client's numeric fid
    path:  big;           # 64-bit file identity (matches Qid.path)
    qtype: int;           # QTDIR or QTFILE
    isopen: int;
    mode:  int;
    doffset: (int, int);  # (internal) cached directory read offset
    uname: string;
    param: string;        # aname from Attach
    data:  array of byte; # application-defined storage
    clone: fn(f: self ref Fid, nf: ref Fid): ref Fid;
    open:  fn(f: self ref Fid, mode: int, qid: Sys->Qid);
    walk:  fn(f: self ref Fid, qid: Sys->Qid);
};
```

**Navigator** (`module/styxservers.m:31–42`) — answers directory queries via a channel:

```limbo
Navop: adt {
    reply: chan of (ref Sys->Dir, string);
    path:  big;
    pick {
    Stat =>
    Walk =>    name: string;
    Readdir => offset: int; count: int;
    }
};
```

Your navigator goroutine receives `Navop` values and sends `(ref Sys->Dir, string)` replies (nil Dir on error, nil string on success).

**Nametree** (`appl/lib/styxservers-nametree.b`) — pre-built in-memory Navigator. Call `nametree->start()` to get a `(Tree, chan of ref Navop)` pair; use `Tree.create/remove/wstat` to manipulate the tree.

### Minimal Server Template

```limbo
implement Minfs;

include "sys.m";   sys: Sys;
include "draw.m";
include "styx.m";  styx: Styx;
include "styxservers.m";
    styxservers: Styxservers;
    Styxserver, Navigator, Navop: import styxservers;

Minfs: module { init: fn(nil: ref Draw->Context, nil: list of string); };

Qroot, Qfile: con iota;  # unique path numbers

init(nil: ref Draw->Context, args: list of string) {
    sys = load Sys Sys->PATH;
    styx = load Styx Styx->PATH; styx->init();
    styxservers = load Styxservers Styxservers->PATH;
    styxservers->init(styx);

    navops := chan of ref Navop;
    spawn navigator(navops);

    fds := array[2] of ref Sys->FD;
    sys->pipe(fds);

    (tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
    spawn serveloop(tchan, srv);

    if(sys->mount(fds[1], nil, "/mnt/minfs", Sys->MREPL, nil) < 0)
        raise "mount failed";
}

navigator(c: chan of ref Navop) {
    for(;;) {
        op := <-c;
        pick o := op {
        Stat =>
            case int o.path {
            Qroot => o.reply <-= (dir(".", 8r555|Sys->DMDIR, big Qroot), nil);
            Qfile => o.reply <-= (dir("data", 8r444, big Qfile), nil);
            *     => o.reply <-= (nil, "not found");
            }
        Walk =>
            if(int o.path == Qroot && o.name == "data")
                o.reply <-= (dir("data", 8r444, big Qfile), nil);
            else
                o.reply <-= (nil, "not found");
        Readdir =>
            if(int o.path == Qroot && o.offset == 0)
                o.reply <-= (dir("data", 8r444, big Qfile), nil);
            else
                o.reply <-= (nil, nil);   # end of directory
        }
    }
}

serveloop(tchan: chan of ref Styx->Tmsg, srv: ref Styxserver) {
    while((tm := <-tchan) != nil) {
        pick t := tm {
        Attach  => srv.attach(t);
        Walk    => srv.walk(t);
        Open    => srv.open(t);
        Stat    => srv.stat(t);
        Clunk   => srv.clunk(t);
        Read    =>
            fid := srv.getfid(t.fid);
            srv.reply(ref Styx->Rmsg.Read(t.tag, array of byte "hello\n"));
        *       => srv.default(t);
        }
    }
}

dir(name: string, perm: int, path: big): ref Sys->Dir {
    d := ref sys->zerodir;
    d.name = name;
    d.uid = d.gid = d.muid = "none";
    d.qid.path = path;
    if(perm & Sys->DMDIR) d.qid.qtype = Sys->QTDIR;
    d.mode = perm;
    return d;
}
```

### Running the Server as a Service via /srv

To export the server so other namespaces can mount it:

```limbo
# Create a file in /srv — its fd is the server end of the connection
srvfd := sys->create("/srv/myfs", Sys->ORDWR, 8r600);
# Write the server-side fd number into the file so others can open it
# Then serve 9P on srvfd
```

Or use `sys->export(srvfd, root, Sys->EXPWAIT)` to re-export an existing directory tree as 9P. See `appl/cmd/9srvfs.b` for the complete pattern.

## Mount and Bind

**`sys->mount(fd, afd, mnt, flags, aname)`** — attach the 9P server behind `fd` at path `mnt`:

```limbo
sys->mount(fds[1], nil, "/mnt/myfs", Sys->MREPL, nil)
```

**`sys->bind(src, dst, flags)`** — alias one existing path to another:

```limbo
sys->bind("/usr/foo", "/bin", Sys->MBEFORE)
```

**Flags** (from `Sys` module):

| Flag | Meaning |
|------|---------|
| `Sys->MREPL`   | Replace dst with src |
| `Sys->MBEFORE` | Add src before existing entries at dst |
| `Sys->MAFTER`  | Add src after existing entries at dst |
| `Sys->MCREATE` | Allow creates to fall through to underlying directory |
| `Sys->MCACHE`  | Cache remote data locally |

(There is no `Sys->MORDER`: `MORDER` is an internal C bitmask in `include/kern.h`
— `0x0003`, the field selecting MREPL/MBEFORE/MAFTER — not a Limbo-visible flag.)

Union mounts: multiple `mount`/`bind` calls to the same `dst` stack entries. Lookups search each layer in order. Creates go to the first layer with `MCREATE`.

The `pipe(fds)` + `mount(fds[1], …)` + serve-on-`fds[0]` pattern is universal. The kernel reads 9P messages from `fds[1]` and forwards them; your process receives decoded `Tmsg` values via the Styxserver channel.

## Kernel-Level Conversion

`emu/port/styx.c` contains the authoritative wire↔struct converters:

- `convM2S(buf, nbuf, f)` — parse bytes into `Fcall` struct (lines 50–315)
- `convS2M(f, buf, nbuf)` — pack `Fcall` struct into bytes (lines 509–701)
- `sizeS2M(f)` — compute packed size without writing (lines 364–506)

`lib9/convD2M.c` and `lib9/convM2D.c` handle `Dir` entry packing/unpacking.

## Key Files at a Glance

| File | Purpose |
|------|---------|
| `include/styx.h` | Wire format constants, bit macros, Fcall struct |
| `include/styxserver.h` | C server framework types |
| `module/styx.m` | Limbo Tmsg/Rmsg ADTs |
| `module/styxservers.m` | Styxserver/Fid/Navigator ADTs |
| `module/styxlib.m` | Deprecated simpler server interface |
| `emu/port/styx.c` | Kernel wire↔struct conversion |
| `lib9/convD2M.c` | Dir entry packing |
| `appl/lib/styx.b` | Limbo pack/unpack implementation |
| `appl/lib/styxservers.b` | Styxserver framework implementation |
| `appl/cmd/memfs.b` | Simple in-memory filesystem (648 lines) |
| `appl/cmd/dbfs.b` | Database-backed filesystem |
| `appl/cmd/9srvfs.b` | /srv export tool |
| `man/5/0intro` | Protocol specification |
| `man/2/styx` | Limbo styx module reference |
| `man/2/styxservers` | Styxservers framework reference |
| `ref/sources/styx.ms` | Original Styx paper |
