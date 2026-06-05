# Network Programming in Inferno OS

All network I/O in Inferno goes through the `/net` filesystem. The `Dial` module is a thin wrapper that opens the right files and writes the right commands so you usually don't have to touch `/net` directly.

## The Dial Module

**Interface**: `module/dial.m`  
**Implementation**: `appl/lib/dial.b`

```limbo
include "dial.m";
dial: Dial;

# Load once at startup
dial = load Dial Dial->PATH;
if(dial == nil)
    raise "fail:cannot load Dial";
```

### Connection and Conninfo ADTs

```limbo
Connection: adt {
    dfd: ref Sys->FD;   # data fd — read/write application data through this
    cfd: ref Sys->FD;   # control fd — ctl file for the conversation
    dir: string;        # conversation directory, e.g. "/net/tcp/3"
};

Conninfo: adt {
    dir:   string;   # connection directory
    root:  string;   # /net root used
    spec:  string;   # device spec
    lsys:  string;   # local IP
    lserv: string;   # local port
    rsys:  string;   # remote IP
    rserv: string;   # remote port
    laddr: string;   # full local address string
    raddr: string;   # full remote address string
};
```

### Function Signatures

```limbo
dial(addr, local: string): ref Connection
    # Connect to addr. local is local address hint (nil = any).
    # Returns nil on failure; check sys->sprint("%r") for reason.

announce(addr: string): ref Connection
    # Open a listening endpoint. addr uses * for host to mean all interfaces.

listen(c: ref Connection): ref Connection
    # Block until an incoming connection arrives on an announced endpoint.
    # Returns a new Connection for the incoming call.

accept(c: ref Connection): ref Sys->FD
    # Accept the incoming call; returns data fd. Call after listen.

reject(c: ref Connection, why: string): int
    # Reject an incoming call with a reason string.

netmkaddr(addr, net, svc: string): string
    # Normalize an address. If addr has no protocol, net is used.
    # Example: netmkaddr("example.com", "tcp", "80") → "tcp!example.com!80"

netinfo(c: ref Connection): ref Conninfo
    # Read local/remote address info from connection directory.
```

## Network Address Format

```
[netdir/]proto!host!service
```

| Format | Example | Meaning |
|--------|---------|---------|
| `tcp!host!port` | `tcp!example.com!80` | TCP to hostname |
| `tcp!ip!port` | `tcp!1.2.3.4!443` | TCP to IP |
| `udp!host!port` | `udp!8.8.8.8!53` | UDP |
| `tcp!*!port` | `tcp!*!8080` | Listen on all interfaces |
| `net!host!svc` | `net!www.example.com!http` | Let cs translate |
| `host!port` | `example.com!8080` | Shorthand for `net!host!port` |
| `/net/tcp!ip!port` | `/net/tcp!10.0.0.1!22` | Explicit netdir |
| `il!host!port` | | IL (reliable datagram) protocol |

The `net` protocol is a meta-protocol: dial looks it up through the connection server (`/net/cs`), which translates service names to real protocol+address+port triples. `netmkaddr` is the standard way to build an address from parts.

## Client Pattern

```limbo
implement HttpGet;

include "sys.m";   sys: Sys;
include "dial.m";  dial: Dial;

HttpGet: module { init: fn(nil: ref Draw->Context, args: list of string); };

init(nil: ref Draw->Context, args: list of string)
{
    sys  = load Sys  Sys->PATH;
    dial = load Dial Dial->PATH;

    addr := dial->netmkaddr("example.com", "tcp", "80");
    conn := dial->dial(addr, nil);
    if(conn == nil)
        raise "fail:dial: " + sys->sprint("%r");

    fd := conn.dfd;

    # write request
    sys->fprint(fd, "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n");

    # read response
    buf := array[8192] of byte;
    for(;;) {
        n := sys->read(fd, buf, len buf);
        if(n <= 0) break;
        sys->write(sys->fildes(1), buf, n);
    }
    # connection closes when fd is GC'd
}
```

Real example: `appl/cmd/whois.b:72–89`, `appl/cmd/webgrab.b:51–86`.

## Server Pattern

The standard server loop: announce → loop(listen → accept → spawn handler).

```limbo
implement EchoSrv;

include "sys.m";   sys: Sys;
include "draw.m";
include "dial.m";  dial: Dial;

EchoSrv: module { init: fn(nil: ref Draw->Context, args: list of string); };

init(nil: ref Draw->Context, nil: list of string)
{
    sys  = load Sys  Sys->PATH;
    dial = load Dial Dial->PATH;

    c := dial->announce("tcp!*!7");
    if(c == nil)
        raise "fail:announce: " + sys->sprint("%r");

    for(;;) {
        nc := dial->listen(c);
        if(nc == nil)
            raise "fail:listen: " + sys->sprint("%r");
        spawn handler(nc);
    }
}

handler(nc: ref Dial->Connection)
{
    dfd := dial->accept(nc);
    if(dfd == nil)
        return;

    # Optional: prevent the TCP stack from timing out an idle connection
    if(nc.cfd != nil)
        sys->fprint(nc.cfd, "keepalive");

    buf := array[4096] of byte;
    for(;;) {
        n := sys->read(dfd, buf, len buf);
        if(n <= 0) break;
        sys->write(dfd, buf, n);
    }
}
```

Real examples: `appl/cmd/styxlisten.b:96–138`, `appl/cmd/listen.b:111–188`.

## Connection Info: Local and Remote Addresses

After connecting or accepting, read endpoint info from the conversation directory:

```limbo
ci := dial->netinfo(conn);
if(ci != nil)
    sys->print("connected %s → %s\n", ci.laddr, ci.raddr);

# Or read directly from the directory
localfd  := sys->open(conn.dir + "/local",  Sys->OREAD);
remotefd := sys->open(conn.dir + "/remote", Sys->OREAD);
buf := array[64] of byte;
n := sys->read(remotefd, buf, len buf);
# content is "ip!port\n"
```

## The /net Filesystem Directly

When the Dial module isn't available or you need low-level control:

```limbo
# 1. Open clone file to allocate a new conversation
clonefd := sys->open("/net/tcp/clone", Sys->ORDWR);
if(clonefd == nil) raise "fail:open clone: " + sys->sprint("%r");

# 2. Read the conversation number
buf := array[12] of byte;
n := sys->read(clonefd, buf, len buf);
convnum := string buf[0:n];      # e.g. "3\n" → strip to "3"
convnum = convnum[0:len convnum - 1];  # strip newline

# 3. Write command to ctl (clonefd IS the ctl file)
sys->fprint(clonefd, "connect 1.2.3.4!80");
# For server: sys->fprint(clonefd, "announce *!8080");

# 4. Open data file
datapath := "/net/tcp/" + convnum + "/data";
datafd := sys->open(datapath, Sys->ORDWR);

# 5. Read/write through datafd; ctl file (clonefd) stays open
```

Files per conversation:

| File | Use |
|------|-----|
| `ctl` (= the clone fd) | Write `connect host!port` or `announce addr!port` |
| `data` | Application read/write |
| `listen` | For announced endpoints: open and read to block on incoming call |
| `local` | Read: `ip!port\n` of local end |
| `remote` | Read: `ip!port\n` of remote end |
| `status` | Connection state string |

What you write to `ctl`:
- `connect host!port` — client connect
- `connect host!port localaddr!localport` — with local binding
- `announce addr!port` — server listen (`*` for all interfaces)
- `keepalive` — enable TCP keepalives
- `close` — half-close

## The Connection Server (cs)

`/net/cs` translates logical addresses to physical ones. It is a file server you write a query to and read recipes back from.

```
write: "tcp!www.example.com!http"
read:  "/net/tcp/clone\t1.2.3.4!80\n"  (one or more lines)
```

`dial->dial` does this automatically when the protocol is `net` or when `/net/cs` exists. If cs is not running, dial uses the address verbatim.

Service names → port numbers come from `/lib/ndb/common` and `/lib/ndb/inferno`:

```
tcp=http    port=80
tcp=https   port=443
tcp=styx    port=6666
udp=dns     port=53
```

The connection server source is `appl/cmd/ndb/cs.b`.

## DNS / Name Resolution

Names are resolved by the DNS server `appl/cmd/ndb/dns.b`, which serves
`/net/dns` (a `file2chan`). `cs` forwards name queries to it; you can also query
it directly with `ndb/dnsquery <name>`. Both `cs` and `dns` are normally started
by the wm desktop (`lib/wmsetup`); start them by hand with `ndb/cs &` then
`ndb/dns -r &`.

Resolution order inside `dns.b` (the important part for hosted Inferno):

1. **Host resolver first** — with the default `usehost=1`, `dns` loads `$Srv`
   (`emu/port/srv.c`) and calls `srv->iph2a(name)`, which drops the VM token and
   calls the host's `getaddrinfo` (`ipif6-posix.c`). On hosted emu this means
   **name resolution works out of the box with zero Inferno-side config** — it
   uses the host's `/etc/resolv.conf`. (`ndb/dns -h` disables this.)
2. **Recursive fallback** — if the host map returns nothing, `dns` does real DNS
   queries against the resolvers listed in `lib/ndb/local`:
   ```
   dns=8.8.8.8    # forward-to resolver (Google public DNS)
   dns=1.1.1.1    # backup (Cloudflare)
   ```
   The shipped defaults make recursion work without editing ndb; replace them
   with a site resolver if you prefer.

> **LP64 note:** the `$Srv` builtin path was historically broken on 64-bit by a
> stale, 32-bit-ABI `emu/Linux/srv.h`/`srvm.h` (wrong frame offsets → a truncated
> `String*` argument → wild-address fault in `Srv_iph2a`, observed as a "DNS
> hang"). Fixed by regenerating those headers per-ABI; see AGENTS_INPRO.md.

`webgrab` (an HTTP `curl` substitute, below) and `dial` of any `net!host!svc`
both depend on this path via `cs`.

## Hosting a 9P Service over the Network: styxlisten Pattern

`appl/cmd/styxlisten.b` is the canonical pattern for serving a 9P file tree to network clients. Read it. The core idea:

```limbo
c := dial->announce(addr);

for(;;) {
    nc := dial->listen(c);
    dfd := dial->accept(nc);
    if(nc.cfd != nil)
        sys->fprint(nc.cfd, "keepalive");

    spawn exportproc(nc, dfd);
}

exportproc(nc: ref Dial->Connection, dfd: ref Sys->FD)
{
    # Give the connection its own namespace and fd table
    sys->pctl(Sys->NEWFD | Sys->NEWNS, 2 :: dfd.fd :: nil);

    # Export the local namespace to the remote client
    sys->export(dfd, "/", Sys->EXPWAIT);
}
```

`sys->export(fd, root, flag)` serves the subtree at `root` as a 9P server over `fd`. `EXPWAIT` blocks until the remote side disconnects; `EXPASYNC` returns immediately.

## Authentication

Authentication is separate from the transport. The standard protocol is `p9any`, negotiated by factotum.

**Client side** (from `appl/cmd/import.b:81–89`):

```limbo
facfd := sys->open("/mnt/factotum/rpc", Sys->ORDWR);

conn := dial->dial(addr, nil);
if(conn == nil) raise "fail:dial: " + sys->sprint("%r");

# Authenticate; ai.secret is the shared session key
ai := factotum->proxy(conn.dfd, facfd, "proto=p9any role=client");
if(ai == nil)
    raise "fail:auth: " + sys->sprint("%r");

# Now mount the authenticated connection
sys->mount(conn.dfd, nil, "/n/remote", Sys->MREPL, "");
```

**Server side** (from `appl/cmd/9export.b:70–80`):

```limbo
facfd := sys->open("/mnt/factotum/rpc", Sys->ORDWR);
ai := factotum->proxy(fd, facfd, "proto=p9any role=server");
if(ai == nil)
    raise "fail:auth: " + sys->sprint("%r");
# ai.cuid is the authenticated remote user name
```

To skip authentication entirely: pass `nil` for auth fd and connect as user "none", or use the `-A` flag in styxlisten/listen.

## SSL/TLS

Push SSL on top of an existing fd using `appl/lib/auth.b`'s `pushssl` helper (or use the `SSL` module directly via `module/ssl3.m`):

```limbo
# After authentication establishes a shared secret:
(sslfd, err) := auth->pushssl(conn.dfd, ai.secret, ai.secret, "rc4_256 sha1");
if(sslfd == nil)
    raise "fail:ssl: " + err;
# sslfd replaces conn.dfd for all further I/O
```

The algorithm string (`"rc4_256 sha1"`, `"des_56_cbc sha1"`, etc.) is negotiated between client and server before pushing SSL.

## Error Handling

`dial->dial` returns `nil` on failure. Get the reason with `sys->sprint("%r")`. The dial library automatically tries `/net` and then `/net.alt` before giving up, and picks the more informative error string.

Common error strings:
- `"connection refused"` — remote port not listening
- `"cs: no translation"` — service name unknown to connection server
- `"does not exist"` — network path not found
- `"i/o error"` — network-level error

Set your own error string with `sys->werrstr(s)` so callers see it via `%r`.

## HTTP (No Dedicated Library)

Inferno has no HTTP library beyond the URL parser (`module/url.m` / `appl/lib/url.b`). HTTP is done with dial + manual framing + bufio for line reading:

```limbo
include "bufio.m"; bufio: Bufio; Iobuf: import Bufio;
bufio = load Bufio Bufio->PATH;

conn := dial->dial("tcp!example.com!80", nil);
sys->fprint(conn.dfd, "GET /path HTTP/1.0\r\nHost: example.com\r\n\r\n");

iob := bufio->fopen(conn.dfd, Bufio->OREAD);
status := iob->gets('\n');   # "HTTP/1.0 200 OK\r\n"
for(;;) {
    hdr := iob->gets('\n');
    if(hdr == "\r\n" || hdr == "\n" || hdr == nil) break;
}
# now read body via iob->read or iob->gets
```

See `appl/cmd/webgrab.b` for a complete working example.

## Key Files

| File | Purpose |
|------|---------|
| `module/dial.m` | Dial module interface, Connection/Conninfo ADTs |
| `appl/lib/dial.b` | Dial implementation (cs integration, address parsing) |
| `appl/cmd/styxlisten.b` | 9P-over-network server template |
| `appl/cmd/listen.b` | General TCP service listener |
| `appl/cmd/ndb/cs.b` | Connection server |
| `appl/lib/auth.b` | pushssl, client/server auth helpers |
| `module/factotum.m` | Factotum authentication agent interface |
| `module/ssl3.m` | SSL module interface |
| `appl/cmd/whois.b` | Minimal dial client example |
| `appl/cmd/webgrab.b` | HTTP client example |
| `appl/cmd/import.b` | Authenticated remote mount example |
| `appl/cmd/9export.b` | Authenticated namespace export example |
| `lib/ndb/common` | TCP/UDP port number database |
| `lib/ndb/local` | Local host configuration |
| `os/port/dial.c` | Kernel-level dial implementation (C) |
| `man/2/dial` | Dial module reference |
| `man/2/sys-bind` | mount/export reference |
