#!/usr/bin/env python3
"""
End-to-end tests for native kernels (os/<arch> + os/boards/<board>).

Board-agnostic: HWTARG selects the board (default virt64) and the board's
os/boards/<board>/qemu.json profile says how to boot it under qemu (machine
args, device flavours, settle time).  Each test boots its own guest from
the built image and drives the serial console; TAP output, one line per
test.  See run.sh for the entry point and README.md for what each test
proves.  Tests needing a device the profile doesn't declare (gui, disk)
SKIP rather than fail.

Origin: the ad-hoc /tmp harnesses that verified the Tier-1 services
(networking, DNS, storage, TLS, import/export, the graphical session)
as they were built; consolidated here so regressions stay caught.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
HWTARG = os.environ.get("HWTARG", "virt64")
PROFILE = os.path.join(ROOT, "os/boards", HWTARG, "qemu.json")
with open(PROFILE) as _f:
    PROF = json.load(_f)
KERNEL = os.environ.get("KERNEL", os.path.join(
    ROOT, "os", PROF["arch"], f"i{HWTARG}.elf"))
# the hosted emu used as the import/export peer — always the build host's
HOSTM = {"arm64": "aarch64", "x86_64": "amd64"}.get(os.uname().machine,
                                                    os.uname().machine)
EMU = os.environ.get("EMU", os.path.join(ROOT, f"Linux/{HOSTM}/bin/emu"))

QEMU_BASE = [PROF["qemu"]] + PROF["machine"]

NETCONF = [
    ("bind -a '#l' /net", 2),
    ("bind -a '#I' /net", 2),
    ("echo bind ether /net/ether0 > /net/ipifc/clone", 2),
    ("echo add 10.0.2.15 255.255.255.0 > /net/ipifc/0/ctl", 2),
    ("echo add 0 0 10.0.2.2 > /net/iproute", 2),
]


def freeport():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Guest:
    """One qemu guest driven over the serial console."""

    def __init__(self, extra=None, bootsecs=None):
        if bootsecs is None:
            bootsecs = PROF.get("bootsecs", 25)
        self.port = freeport()
        cmd = QEMU_BASE + (extra or []) + [
            "-kernel", KERNEL, "-display", "none", "-monitor", "none",
            "-serial", f"tcp:127.0.0.1:{self.port},server=on,wait=on",
        ]
        self.qemu = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        time.sleep(2)
        self.s = socket.create_connection(("127.0.0.1", self.port), timeout=10)
        self.s.settimeout(0.5)
        self.buf = b""
        self.wait_ready(bootsecs)

    def drain(self, secs, until=None):
        # Read serial for up to `secs`.  If `until` (a list of marker strings)
        # is given, return as soon as any marker has appeared anywhere in the
        # buffer -- `secs` becomes a cap, not a fixed wait.  Positive-evidence
        # semantics are preserved: a kernel that never prints the marker still
        # waits the full cap and the caller proceeds (and fails as it would have).
        end = time.time() + secs
        umark = [m.encode() for m in until] if until else None
        while time.time() < end:
            try:
                d = self.s.recv(4096)
                if d:
                    self.buf += d
                    if umark and any(m in self.buf for m in umark):
                        return
            except OSError:
                pass

    def wait_ready(self, cap):
        # Sync on the shell instead of sleeping a fixed `bootsecs`: poke the
        # console with `echo <nonce>` and return the moment it comes back, so a
        # boot that settles in ~10s doesn't burn the whole 25-45s window.  Input
        # sent before the shell is reading is queued and echoed once it is, so
        # this is strictly more reliable than a timed sleep.  Falls back to the
        # full cap if the nonce never appears (the test then runs and fails as
        # a fixed-sleep run would have).
        nonce = b"KREADY%d" % self.port
        end = time.time() + cap
        while time.time() < end:
            self.s.sendall(b"echo " + nonce + b"\n")
            self.drain(min(2.0, max(0.2, end - time.time())), until=[nonce.decode()])
            if nonce in self.buf:
                return

    def run(self, cmds):
        # Each item is (cmd, cap) or (cmd, cap, marker).  With a marker, `cap`
        # is a ceiling: the command returns the instant its expected output
        # appears, instead of always sleeping the full time.  Without one it
        # drains the whole `cap` (unchanged).
        #
        # The marker MUST be output the command prints only as it *completes*
        # (a command's result line, an `echo` sentinel) -- not interim output.
        # A command that keeps running after its marker prints (e.g. `ping -n N`
        # emits "rtt" on the first reply but runs N more) would let the next
        # command be sent while it still owns the shell; leave those unmarked.
        for item in cmds:
            cmd, cap = item[0], item[1]
            mark = item[2] if len(item) > 2 else None
            self.s.sendall(cmd.encode() + b"\n")
            self.drain(cap, until=[mark] if mark else None)

    def output(self):
        return self.buf.decode("utf-8", "replace")

    def close(self):
        self.qemu.terminate()
        self.qemu.wait(timeout=10)


def netdev(hostfwd=None, device=None):
    if device is None:
        if not PROF.get("netdev_device"):
            raise SkipTest(f"board {HWTARG} declares no qemu net device")
        device = PROF["netdev_device"]
    n = "user,id=n0" + (f",hostfwd=tcp:127.0.0.1:{hostfwd[0]}-:{hostfwd[1]}"
                        if hostfwd else "")
    return ["-netdev", n, "-device", f"{device},netdev=n0"]


def netdev_opt():
    """netdev args if the board declares a NIC, else nothing — so GUI-only
    boards (no PCI/net, e.g. pc64) still run the display tests."""
    return netdev() if PROF.get("netdev_device") else []


# ---- the tests -----------------------------------------------------

def test_boot():
    """Boots to sh; devices probe; the board's boot markers appear."""
    g = Guest()
    g.run([("echo boot-marker", 3, "boot-marker")])
    out = g.output()
    g.close()
    assert "boot-marker" in out, "no shell prompt traffic"
    # board-specific positive markers (e.g. aarch64 "psci", amd64 "conf pc64")
    for m in PROF.get("boot_markers", []):
        assert m in out, f"missing boot marker {m!r}"
    assert "panic" not in out, "panic during boot"


def test_net():
    """Static slirp config; ping the gateway; conversation dirs appear."""
    g = Guest(extra=netdev())
    g.run(NETCONF + [
        ("ip/ping -n 2 10.0.2.2", 8),   # no marker: ping runs past its first reply
        ("netstat", 4),
        ("echo net-marker", 2, "net-marker"),
    ])
    out = g.output()
    g.close()
    assert "net-marker" in out
    assert ": rtt" in out or "avg rtt" in out, "no ping replies"


def test_igbe():
    """The ported Intel e1000/igbe PCI NIC carries real traffic: attach a
    qemu -device e1000 (82540EM, id 0x100e — igbe's pnp match) as the only
    NIC, configure slirp statically, ping the gateway, and read ifstats.
    The ping replies prove TX/RX end-to-end (the first echo is normally lost
    to ARP, so send several); the igbe-only ifstats fields (Ctrlext/rintr/
    tintr) prove it is the igbe driver — not virtio-net — doing it, with
    interrupts actually firing."""
    if not PROF.get("netdev_device"):
        raise SkipTest(f"board {HWTARG} has no networking — no igbe path")
    g = Guest(extra=netdev(device="e1000"))
    g.run(NETCONF + [
        ("ip/ping -n 4 10.0.2.2", 12),   # no marker: ping runs past its first reply
        ("cat /net/ether0/ifstats", 3),
        ("echo igbe-marker", 2, "igbe-marker"),
    ])
    out = g.output()
    g.close()
    assert "igbe-marker" in out
    assert ": rtt" in out or "avg rtt" in out, "no ping replies over igbe"
    assert "Ctrlext:" in out, "ifstats not from igbe — wrong driver claimed the card"


def test_dns():
    """ndb/cs + the resolver chain + webgrab's TCP path, proven
    deterministically.  A synthetic host name is mapped to the slirp host
    gateway (10.0.2.2) in the guest's own ndb, and webgrab fetches it by name
    from a local HTTP server on the host.  This exercises cs name resolution
    and the dial/TCP path with no dependency on live external DNS — the old
    live `example.com` lookup made the gate flaky on offline or loaded boxes
    (DNS to the internet times out), which is an environment fault, not a
    kernel one.  ndb/cs and ndb/dns are still started (boot realism); the
    `dns=` forwarders stay configured so a real deployment resolves the
    internet, but the gate no longer rides on it."""
    if not PROF.get("netdev_device"):
        raise SkipTest(f"board {HWTARG} has no networking")

    import http.server
    import threading

    port = freeport()

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"hello-by-name\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *a):
            pass

    httpd = http.server.HTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    g = Guest(extra=netdev())
    # Writable ndb: list the db files, set the DNS forwarders (slirp proxy
    # first, public DNS fallback) for real deployments, and add a deterministic
    # host entry mapping a synthetic name to the slirp host gateway so cs
    # resolves it with no network.  Continuation lines are tab-indented (ndb
    # syntax); the host entry is its own stanza.
    g.run(NETCONF + [
        ("echo 'database=' > /tmp/nl", 1),
        ("echo '\tfile=/lib/ndb/local' >> /tmp/nl", 1),
        ("echo '\tfile=/lib/ndb/dns' >> /tmp/nl", 1),
        ("echo '\tfile=/lib/ndb/inferno' >> /tmp/nl", 1),
        ("echo '\tfile=/lib/ndb/common' >> /tmp/nl", 1),
        ("echo 'infernosite=' >> /tmp/nl", 1),
        ("echo '\tdns=10.0.2.3' >> /tmp/nl", 1),
        ("echo '\tdns=8.8.8.8' >> /tmp/nl", 1),
        ("echo '' >> /tmp/nl", 1),
        ("echo 'sys=ktesthost dom=ktesthost.local ip=10.0.2.2' >> /tmp/nl", 1),
        ("bind /tmp/nl /lib/ndb/local", 1),
        # cs must be up and serving before the resolve below; on a slow
        # TCG+PARANOID boot 4s was not always enough (the dominant dns flake),
        # so give the connection server real headroom to start.  dns/cs daemon
        # startup is a fixed wait (no console marker to drain on).
        ("ndb/cs &", 12),
        ("ndb/dns &", 5),
    ])
    # deterministic: resolve the local name and fetch it over TCP.  webgrab
    # prints "created <file>, <n> bytes" on success.
    g.run([
        # Caps are generous because drain() returns the instant the marker
        # appears, so a fast fetch still exits early; the headroom only matters
        # on a slow TCG+PARANOID boot, where the resolve+connect+fetch can spike
        # well past a tight window.  This is timeout headroom, not a retry.
        (f"webgrab -o /tmp/byname.txt http://ktesthost:{port}/", 40,
         "created /tmp/byname.txt"),
        ("cat /tmp/byname.txt*", 8, "hello-by-name"),
        ("echo dns-marker", 5, "dns-marker"),
    ])
    out = g.output()
    g.close()
    httpd.shutdown()
    assert "dns-marker" in out
    assert "hello-by-name" in out, "name resolution + fetch by hostname failed"


def _kfs_persist(disk, unit):
    """Prove durable block I/O on a storage controller: ream kfs on the #S
    `unit` (e.g. sd00), write a file, fully restart qemu, read it back.  The
    write must reach the host-side image for the second boot to find it, so
    this exercises the whole driver path (identify, write, flush, read) — not
    just attach.  `disk` is the qemu device args; the caller owns the backing
    image and keeps it alive across both boots."""
    g = Guest(extra=disk)
    g.run([
        ("bind -a '#S' /dev", 2),
        (f"mount -c {{disk/kfs -r /dev/{unit}/data}} /n/kfs", 8),
        ("echo persistent-data-survives > /n/kfs/persist.txt", 2),
        ("unmount /n/kfs", 3),
        ("echo first-marker", 2, "first-marker"),
    ])
    first = g.output()
    g.close()
    assert "first-marker" in first, "first boot did not complete"

    g = Guest(extra=disk)
    g.run([
        ("bind -a '#S' /dev", 2),
        (f"mount -c {{disk/kfs /dev/{unit}/data}} /n/kfs", 8),
        ("cat /n/kfs/persist.txt", 3, "persistent-data-survives"),
        ("echo second-marker", 2, "second-marker"),
    ])
    out = g.output()
    g.close()
    assert "second-marker" in out
    assert "persistent-data-survives" in out, "file did not survive reboot"


def test_disk():
    """kfs on the board's block device: a file survives a full qemu restart."""
    if not PROF.get("blk_device"):
        raise SkipTest(f"board {HWTARG} declares no qemu block device")
    with tempfile.NamedTemporaryFile(suffix=".img") as img:
        img.truncate(64 * 1024 * 1024)
        disk = ["-drive", f"if=none,file={img.name},format=raw,id=hd0",
                "-device", f"{PROF['blk_device']},drive=hd0"]
        _kfs_persist(disk, "sd00")


def test_nvme():
    """The ported NVMe PCIe controller (sd-nvme) carries durable block I/O.
    qemu -device nvme attaches over the PCIe seam as #S/sdN0; kfs reams it,
    writes a file, and it survives a full machine restart.  On the default
    GIC=v2 image completion is by INTx (the driver falls back from MSI-X when
    there is no GICv3 ITS); a GICv3 build instead exercises the MSI-X path."""
    unit = PROF.get("nvme_unit")
    if not unit:
        raise SkipTest(f"board {HWTARG} declares no nvme unit")
    with tempfile.NamedTemporaryFile(suffix=".img") as img:
        img.truncate(64 * 1024 * 1024)
        disk = ["-drive", f"if=none,file={img.name},format=raw,id=nv0",
                "-device", "nvme,serial=ktest,drive=nv0"]
        _kfs_persist(disk, unit)


def test_ahci():
    """The ported AHCI/SATA controller (sd-ahci) carries durable block I/O.
    qemu -device ich9-ahci + an attached ide-hd attaches over the PCIe seam as
    #S/sdE0 and round-trips kfs across a restart.  Completion is IRQ-driven on
    a plain GIC SPI (sd-ahci arms PxIE and clears the storm-free way)."""
    unit = PROF.get("ahci_unit")
    if not unit:
        raise SkipTest(f"board {HWTARG} declares no ahci unit")
    with tempfile.NamedTemporaryFile(suffix=".img") as img:
        img.truncate(64 * 1024 * 1024)
        disk = ["-device", "ich9-ahci,id=ahci",
                "-drive", f"if=none,file={img.name},format=raw,id=sa0",
                "-device", "ide-hd,drive=sa0,bus=ahci.0"]
        _kfs_persist(disk, unit)


def test_audio():
    """The ported Intel HDA controller (audio-hda) plays real audio.  qemu
    -device intel-hda + hda-duplex bound to a wav audiodev attaches over the
    PCIe seam as #A; the driver enumerates the codec and connects the output
    path, then the guest streams PCM (a dis file) to /dev/audio.  qemu records
    the DAC output to a WAV, and a non-silent capture proves the whole chain —
    BAR map, CORB/RIRB codec commands, stream DMA and the interrupt-driven ring
    drain (the write returns, so the ring is draining) — works end to end."""
    devs = PROF.get("audio_devices")
    if not devs:
        raise SkipTest(f"board {HWTARG} declares no qemu audio device")
    wav = tempfile.mktemp(prefix="kaud-", suffix=".wav")
    extra = ["-audiodev", f"wav,id=snd0,path={wav}"] + devs
    g = Guest(extra=extra)
    g.run([
        ("bind -a '#A' /dev", 2),
        # sh reads `name=val` as assignment, so cat (not dd) feeds the device
        ("cat /dis/sh.dis > /dev/audio", 8),
        ("echo audio-marker", 2, "audio-marker"),
    ])
    out = g.output()
    g.close()
    assert "audio-marker" in out
    assert "codec #0" in out, "HDA codec did not enumerate"
    try:
        data = open(wav, "rb").read()
    finally:
        if os.path.exists(wav):
            os.unlink(wav)
    pcm = data[44:]  # skip the RIFF/WAVE header; PCM is written as it plays
    nonzero = sum(1 for b in pcm if b != 0)
    assert nonzero > 1000, \
        f"silent capture ({len(pcm)} pcm bytes, {nonzero} nonzero) — audio did not play"


def test_tls():
    """devtls + mbedTLS: unknown CA refused, then TLS 1.3 fetch with the
    test CA bound over the bundle (real verification, IP-SAN check).  A failure
    here is a real fault — do not paper over it with a retry; if it misses,
    investigate (see docs/DEV_LP64_JIT_JOBS.md, Job 1)."""
    import http.server
    import ssl
    import threading

    d = tempfile.mkdtemp(prefix="ktls-")
    def osl(*a):
        subprocess.run(["openssl"] + list(a), check=True, cwd=d,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    osl("ecparam", "-genkey", "-name", "prime256v1", "-out", "ca.key")
    osl("req", "-x509", "-new", "-key", "ca.key", "-subj", "/CN=ktest CA",
        "-days", "2", "-out", "ca.crt")
    osl("ecparam", "-genkey", "-name", "prime256v1", "-out", "srv.key")
    osl("req", "-new", "-key", "srv.key", "-subj", "/CN=10.0.2.2",
        "-out", "srv.csr")
    with open(os.path.join(d, "ext"), "w") as f:
        f.write("subjectAltName=IP:10.0.2.2\n")
    osl("x509", "-req", "-in", "srv.csr", "-CA", "ca.crt", "-CAkey", "ca.key",
        "-CAcreateserial", "-days", "2", "-extfile", "ext", "-out", "srv.crt")

    httpsport = freeport()

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"hello-over-TLS\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *a):
            pass

    httpd = http.server.HTTPServer(("127.0.0.1", httpsport), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(d, "srv.crt"), os.path.join(d, "srv.key"))
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    g = Guest(extra=netdev())
    g.run(NETCONF + [
        # negative: the baked Mozilla bundle does not contain the test CA
        (f"webgrab -o /tmp/neg.txt 'https://10.0.2.2:{httpsport}/'", 12),
        ("rm -f /tmp/ca.pem", 1),
    ])
    neg = g.output()
    for line in open(os.path.join(d, "ca.crt")):
        g.run([(f"echo '{line.rstrip()}' >> /tmp/ca.pem", 0.4)])
    g.run([
        ("bind /tmp/ca.pem /lib/tls/ca-certificates.crt", 2),
        # Generous caps (drain() exits on the marker, so fast runs pay nothing):
        # the ECDHE handshake + cert verify is crypto-heavy and spikes past a
        # tight window on a slow TCG+PARANOID boot.  Headroom, not a retry.
        (f"webgrab -o /tmp/tls.txt 'https://10.0.2.2:{httpsport}/'", 40, "created /tmp/tls.txt"),
        ("cat /tmp/tls.txt*", 8, "hello-over-TLS"),
        ("echo tls-marker", 5, "tls-marker"),
    ])
    out = g.output()
    g.close()
    httpd.shutdown()
    assert "tls-marker" in out
    assert "created /tmp/neg.txt" not in neg, \
        "unknown CA was ACCEPTED — verification is broken"
    assert "hello-over-TLS" in out, "verified TLS fetch failed"


def test_impexp():
    """Namespace both ways over the kernel IP stack: hosted emu mounts the
    guest's export (via hostfwd); the guest mounts the hosted emu's.  Network
    + styx over slirp, plus a host-side emu that must come up first (readiness
    is polled below, not slept on)."""
    if not os.path.exists(EMU):
        raise SkipTest(f"hosted emu not built ({EMU})")
    fwd = freeport()
    hsrv = freeport()
    g = Guest(extra=netdev(hostfwd=(fwd, 6666)))
    g.run(NETCONF + [
        ("echo hello-from-bare-metal > /tmp/marker", 2),
        ("styxlisten -A 'tcp!*!6666' export / &", 4),
    ])
    r = subprocess.run(
        [EMU, f"-r{ROOT}", "/dis/sh.dis", "-c",
         f"mount -A 'tcp!127.0.0.1!{fwd}' /n/remote; cat /n/remote/tmp/marker"],
        capture_output=True, text=True, timeout=60)
    assert "hello-from-bare-metal" in r.stdout, \
        f"host emu could not read the guest's export: {r.stdout!r} {r.stderr[-200:]!r}"

    srv = subprocess.Popen(
        [EMU, f"-r{ROOT}", "/dis/sh.dis", "-c",
         f"echo hello-from-hosted-emu > /tmp/hostmarker; "
         f"styxlisten -A 'tcp!*!{hsrv}' export /; sleep 1000000"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Wait for the hosted emu's styx listener to actually accept (it uses the
    # host TCP stack), instead of a fixed sleep — the host emu can be slow to
    # come up under load, which was the dominant impexp race.
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            socket.create_connection(("127.0.0.1", hsrv), timeout=0.5).close()
            break
        except OSError:
            time.sleep(0.3)
    g.run([
        (f"mount -A 'tcp!10.0.2.2!{hsrv}' /n/remote", 5),
        ("cat /n/remote/tmp/hostmarker", 3, "hello-from-hosted-emu"),
        ("echo impexp-marker", 2, "impexp-marker"),
    ])
    out = g.output()
    g.close()
    srv.terminate()
    srv.wait(timeout=10)
    assert "impexp-marker" in out
    assert "hello-from-hosted-emu" in out, "guest could not read the host export"


def qmp_open(path):
    """Connect to a guest's QMP socket; return (socket, cmd) with caps
    negotiated.  cmd(name, **args) issues one command and returns its reply."""
    s = socket.socket(socket.AF_UNIX)
    s.connect(path)
    f = s.makefile("rw")

    def cmd(c, **args):
        f.write(json.dumps({"execute": c, "arguments": args}) + "\n")
        f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r:
                return r

    f.readline()  # greeting
    cmd("qmp_capabilities")
    return s, cmd


def _screendump_pixels(cmd):
    """Take a QMP screendump and return its raw PPM pixel bytes."""
    ppm = tempfile.mktemp(prefix="ktest-", suffix=".ppm")
    cmd("screendump", filename=ppm)
    time.sleep(1)
    with open(ppm, "rb") as fh:
        data = fh.read()
    os.unlink(ppm)
    return data.split(b"\n", 3)[3]


def test_usb():
    """The C xHCI host controller + the usbd HID enumerator: attach a USB
    keyboard and require usbd to enumerate it over the kernel's #u.  Like the
    audio/storage cells, this is here to gate the *C driver* (xHCI BAR map,
    transfer rings, the #u device) end to end -- usbd reports enumeration to
    the console, so a live HID keyboard shows up in the boot output."""
    devs = PROF.get("usb_devices")
    if not devs:
        raise SkipTest(f"board {HWTARG} declares no qemu usb device")
    g = Guest(extra=devs)
    # usbd enumerates the HID device asynchronously, after the shell is already
    # up -- so wait for that evidence directly rather than for a fixed settle.
    g.drain(30, until=["HID keyboard live", "class 3"])
    g.run([("echo usb-marker", 2, "usb-marker")])
    out = g.output()
    g.close()
    assert "usb-marker" in out
    assert "HID keyboard live" in out or "class 3" in out, \
        "usbd did not enumerate the USB HID keyboard — xHCI driver path broken"


def test_gui():
    """The wm desktop comes up on the board's display: QMP screendump must
    show a real image (many distinct colours), not a flat/black framebuffer."""
    if not PROF.get("gui_devices"):
        raise SkipTest(f"board {HWTARG} declares no qemu display devices")
    qmp = tempfile.mktemp(prefix="ktest-qmp-")
    gui = PROF["gui_devices"] + ["-qmp", f"unix:{qmp},server=on,wait=off"]
    # wm + warmup settle
    g = Guest(extra=gui + netdev_opt())
    s, cmd = qmp_open(qmp)
    # wm + the warmup splash render asynchronously after the shell is up; retry
    # the screendump until the framebuffer is non-blank rather than depend on a
    # fixed boot settle.
    colours = set()
    for _ in range(8):
        pix = _screendump_pixels(cmd)
        colours = set(pix[i:i+3] for i in range(0, min(len(pix), 3*1024*768), 3))
        if len(colours) > 16:
            break
        time.sleep(2)
    s.close()
    g.close()
    assert len(colours) > 16, f"flat framebuffer ({len(colours)} colours) — no desktop"


def test_cursor():
    """The software mouse cursor draws and tracks a relative pointer.  On a
    board with a relative pointer (PS/2, virtio-mouse) the kernel composites
    a software cursor onto the scanout (an absolute pointer instead lets qemu
    draw the host cursor — `sw_cursor` flags which boards have the software
    one).  Inject relative motion over QMP and require the framebuffer to
    change: a cursor that is missing, frozen, or has wandered off-screen
    (the bugs the backing-buffer cursor + screen clamp fixed) would leave the
    scanout identical."""
    if not PROF.get("gui_devices"):
        raise SkipTest(f"board {HWTARG} declares no qemu display devices")
    if not PROF.get("sw_cursor"):
        raise SkipTest(f"board {HWTARG} has no software cursor (absolute pointer)")
    qmp = tempfile.mktemp(prefix="ktest-qmp-")
    gui = PROF["gui_devices"] + ["-qmp", f"unix:{qmp},server=on,wait=off"]
    g = Guest(extra=gui + netdev_opt(), bootsecs=PROF.get("bootsecs", 25) + 20)
    s, cmd = qmp_open(qmp)
    # The cursor boots centred over the desktop; nudge it down-right (away from
    # any edge, so it stays on-screen) and watch the scanout move.  A loaded TCG
    # cross-boot processes the PS/2 reports + redraw slowly, so inject a burst,
    # let it settle, and retry until the framebuffer changes (or we give up).
    before = _screendump_pixels(cmd)
    diff = 0
    for _ in range(6):
        for _ in range(4):
            cmd("human-monitor-command", **{"command-line": "mouse_move 40 40"})
            time.sleep(0.3)
        time.sleep(1.5)
        after = _screendump_pixels(cmd)
        diff = sum(1 for a, b in zip(before, after) if a != b)
        if diff > 30:
            break
    s.close()
    g.close()
    assert diff > 30, \
        f"cursor did not move the framebuffer ({diff} bytes changed) — " \
        "missing, frozen, or off-screen"


# ---- runner --------------------------------------------------------

class SkipTest(Exception):
    pass


ALL = [test_boot, test_net, test_igbe, test_dns, test_disk, test_nvme,
       test_ahci, test_audio, test_usb, test_tls, test_impexp,
       test_gui, test_cursor]


def main():
    want = sys.argv[1:]
    tests = [t for t in ALL
             if not want or any(w in t.__name__ for w in want)]
    if not os.path.exists(KERNEL):
        print(f"Bail out! kernel image missing: {KERNEL} "
              f"(cd os/{PROF['arch']} && make HWTARG={HWTARG})")
        return 1
    print(f"1..{len(tests)}")
    failed = 0
    for i, t in enumerate(tests, 1):
        name = t.__name__[5:]
        try:
            t()
            print(f"ok {i} - {name}")
        except SkipTest as e:
            print(f"ok {i} - {name} # SKIP {e}")
        except Exception as e:
            failed += 1
            print(f"not ok {i} - {name}: {e}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
