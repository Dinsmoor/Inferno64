# 9front → Inferno64: IP-stack ideas (9/ip + libip)

Mined from `9front:sys/src/9/ip` (217 commits) + `sys/src/libip` (17) and compared
against `inferno-os:os/ip/*` and `emu/port/{devip,ipaux}.c`.

## ⚠️ Read this first — applicability is narrower than it looks

Inferno has **two** networking paths, and they have very different relationships
to 9front's IP work:

1. **Hosted `emu` (what Inferno64 builds and runs today).** `emu/port/devip.c`
   is *socket glue* — it calls `so_socket`/`so_connect`/`so_accept`/`so_recv`
   on the **host OS kernel**, which provides TCP/IP/IPv6, congestion control,
   reassembly, etc. **None of 9front's stack-internals work applies here** — the
   host kernel already does it (and does it more modernly than any Plan 9 stack).
2. **Native `os/` port (`os/ip/*`).** This *is* the Plan 9 IP stack
   (`tcp.c`, `udp.c`, `ipv6.c`, `icmp6.c`, `ipifc.c`, `iproute.c`, `il.c`,
   `rudp.c`, …) and shares direct lineage with 9front's `9/ip`. But the native
   port is **currently dormant** (the project targets hosted emu).

**Therefore this file is primarily a *native-port revival* consideration list.**
If Inferno64 never revives `os/`, almost everything below is moot. Given the
current hosted focus, this topic is **lower immediate priority than `draw.md`
and `kernel-port.md`.** A short hosted-relevant slice is at the end (§H).

Inferno's `os/ip/tcp.c` already has window scaling (`ws`/`snd.scale`), a
congestion window (`cwind`), and Tahoe/Reno — i.e. the same base 9front started
from. 9front's value is ~15 years of *refinements, leak fixes, and security
hardening* on top.

Status legend: ✅ in Inferno os/ip · ❌ absent · ⚠️ present, refine · 🔒 security

---

## Tier 1 (native port) — Security & robustness hardening 🔒

This is the strongest cluster: a network-facing native kernel wants these. Most
are in the **fragment / ICMP / ARP** paths, which are attacker-reachable.

| Idea | 9front | Inferno os/ip status |
|---|---|---|
| IP fragment-handling rewrite | `7d472df1f` `b9f98a451` `3991f08f9` `2770a46f9` `4d8b994cf` (2019) | ⚠️ audit reassembly in `ip.c`/`ipv6.c`; the 9front series simplified `Ipfrag`, fixed header-option fragmentation, zeroed stale offsets, fixed fragment *forwarding* |
| Restrict ICMP forwarding | `961c35a39` (2022) only forward Echo/Timestamp/Info/AddrMask requests | ⚠️ check `icmp.c` doesn't blindly forward |
| ARP reply padding leak | `4fd1e64e2` (2022) don't leak kernel data in arp-reply padding | 🔒 audit `arp.c` (info-leak) |
| Reject bad numeric ports | `ac442621f` (2019) (e.g. `9fs`→`9`) | ⚠️ audit dial/port parsing |
| Ignore evil-bit / reserved frag bits | `27455c306` `4d8b994cf` (2019) | ⚠️ minor robustness |
| Overflow on lifetime checks | `4537fd480` (2018) ipv6 addr lifetime | ⚠️ audit `ipv6.c` |
| Multicast/interface addr pairing | `0a5b89643` (2018) reject incompatible pairs | ⚠️ |
| `assert` panic on fragmented ICMP echo | `929c19612` (2012) | ⚠️ check Inferno has erik's icmp-frag fix |
| Don't panic on port exhaustion | `414284021` (2011) | ⚠️ |

**Effort: per-item low–medium. Risk: low** (these are defensive). Do this as a
batch diff of `os/ip/{ip,ipv6,icmp,icmp6,arp}.c` against the 9front versions.

## Tier 2 (native port) — Memory-leak fixes

9front fixed a *lot* of leaks the original stack shipped with. Direct candidates
for the same files in `os/ip`:
- `1c786deef` "tcp: fix limbo entry leaks from hell" (2024)
- `1a48ac738` ipmux tree free leak (2026); `1246287cd` devip temp-buffer leaks on error (2023)
- `b865a9dd3` arp "flush"/"del" ctl leaks; `582e3b588` `ipicadd6()` leak; `03bb0782a` queue leaks + malloc-error handling
- `f86917b75` "devip: don't leak blocks" (2026)

**Effort: low each. Risk: low.** Worth it if the native port is ever long-running.

## Tier 3 (native port) — TCP refinements

- **`"close"` ctl — graceful half-close ❌** (`9ea7dd530`, 2017). Adds a `close`
  ctl message that does an orderly FIN shutdown instead of a RST; **"used by Go"**
  and other runtimes that expect half-close semantics. Inferno's `tcpctl` has
  `hangup` (→RST) but **not** `close`. Tiny patch (`tcpclose(c)`), real
  interop value. *Also see §H — the concept maps to hosted emu too.*
- **MSS clamping correctness** — clamp to `min(src,dst iface MTU)`
  (`tcpmssclamp`, 2022); never raise MSS above link MTU for v6 < 1280
  (`2016-11-16`); only read TCP header from the *first* v4 fragment
  (`5e68ad195`). Matters when the native port forwards/routes.
- **Auto-disable window scaling** when the peer omits the WS option
  (`a52eef884`, 2019) — avoids a class of stuck connections.
- **Backoff counter overflow** + `Tcpctl` field reorder (`e045eefc7`, 2025).
- **Loopback slowness / server-socket MSS** fixes (`582e3b588`-era, 2015).

## Tier 4 (native port) — IPv6 neighbor-discovery modernization

Inferno already has ND (`icmp6.c`: RouterAdvert, neighbor solicitation). 9front
brought it closer to RFC 4861:
- Source-address selection for neighbor solicitations per RFC 4861 §7.2.2 (`f9bad976f`, 2018)
- Set router R-flag for neighbor advertisement when `sendra` active (`0b546cc0f`, 2018)
- Handle "packet too big" for icmp6 / remove fragment header (`5a6ecc985`, 2019)
- "reflect" ctl message + icmpv6 leak fixes + correct source for ttl-exceeded (`a249149cf`, 2018)

## Tier 5 (native port) — `ipifc` interface management (largest cluster, 56 commits)

Mostly operational polish; port opportunistically if reviving native:
- NAT routes (`961c35a39`-adjacent, 2022 "implement network address translation routes")
- Routing-table-based local source-address selection (2019)
- Recursive rlock deadlock fix (2020); packet loss when iface wlocked (2020)
- Auto-unbind interface on read errors (2023); `del` aliases for route/iface ops (2023)
- ARP entry caching in `Routehint` (2021); generalized proxy-ARP (2023)

## libip (portable parsing) — small, partly hosted-relevant

Inferno's parse helpers live in `os/ip/ipaux.c` (`eipfmt`, `parseip`,
`parseipmask`, `v4tov6`, `v6tov4`, `v4parseip`, `defmask`) — the same set as
9front's `libip`. Worth folding in:
- `6fa52678b` `parseipandmask()` replacing `v4parsecidr()`; `4027b1974`/`81cfd4544`
  v4/v6 mask-form handling (2019) — cleaner CIDR parsing.
- `f7ae0abf2` prefer v4 over v6 in `myipaddr()`; `b7da68668`/`6c9f4ad6e` skip v6
  link-local/loopback (2018–2019) — better default source-address choice.
- `f2ab3b12e` `iplocalonifc()`/`ipremoteonifc()` helpers (2023).

---

## §H — The hosted-emu slice (applies *now*)

The only IP ideas that touch the path Inferno64 actually runs:

1. **Mirror `"close"` (orderly shutdown) in `emu/port/devip.c`.** A `close` ctl
   (or honoring it on the write side) can map to the host `shutdown(fd, SHUT_WR)`
   so emu apps can half-close a TCP stream the way Go/modern peers expect.
   Today devip only has full close. **Low effort, real interop value.**
2. **Adopt the `libip` parse refinements** (`parseipandmask`, v4/v6 mask forms,
   myipaddr v4-preference) in `emu/port/ipaux.c` *if* emu does its own address
   parsing for `/net`/cs. Verify the call sites first.
3. **OCEXEC on temporary fds** (`6b4c24958`, `1246287cd`) — close-on-exec hygiene
   for any host fds devip opens. Trivial.
4. **devip block/buffer-leak discipline** (`f86917b75`, `1246287cd`) — the *idea*
   (free on every error path) is worth auditing in `emu/port/devip.c` even though
   the host owns the stack.

**Bottom line:** unless/until the native `os/` port is revived, treat this whole
topic as deferred except §H. When the native port *is* revived, Tier 1
(security) and Tier 2 (leaks) are the highest-value batches.
