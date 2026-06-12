# tests/kernel — end-to-end suite for the native aarch64 kernel

Boots `os/aarch64/ivirt64.elf` under `qemu-system-aarch64 -M virt` (one
fresh guest per test), drives the serial console, and emits TAP.

    tests/kernel/run.sh             # all (~4 min; rebuilds the image if stale)
    tests/kernel/run.sh dns tls     # substring-select

| test | proves |
|---|---|
| boot | boots to sh, devices probe, PSCI answers, no panic |
| net | virtio-net + os/ip: static slirp config, ping the gateway |
| dns | ndb/cs + ndb/dns out of the box: dnsquery + webgrab by hostname (needs host internet) |
| disk | devsd + virtio-blk + kfs: a file survives a full qemu restart |
| tls | devtls/mbedTLS: unknown CA **refused** against the baked bundle, then a verified TLS 1.3 fetch (fresh throwaway CA + IP-SAN cert, python ssl server on the host) |
| impexp | the namespace travels: hosted emu mounts the guest's `styxlisten` export through a slirp hostfwd, and the guest mounts the hosted emu's (skipped if the hosted emu isn't built) |
| gui | wm desktop renders on ramfb: QMP `screendump`, fail on a flat framebuffer |

Knobs: `KERNEL=` (another board's image), `EMU=` (hosted emu for impexp).

Notes for writing more of these: serial gives no echo and qemu boots
faster than a client can connect — the harness uses
`-serial tcp:...,server=on,wait=on` and marker-based scoring
(positive evidence only; never score on "no error output").  Inferno
sh has no `&&`.  Each guest gets its own qemu; kill by handle
(`terminate()`), never by name — a developer's live qemu desktop may
be running.
