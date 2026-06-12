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
        self.drain(bootsecs)

    def drain(self, secs):
        end = time.time() + secs
        while time.time() < end:
            try:
                d = self.s.recv(4096)
                if d:
                    self.buf += d
            except OSError:
                pass

    def run(self, cmds):
        for c, t in cmds:
            self.s.sendall(c.encode() + b"\n")
            self.drain(t)

    def output(self):
        return self.buf.decode("utf-8", "replace")

    def close(self):
        self.qemu.terminate()
        self.qemu.wait(timeout=10)


def netdev(hostfwd=None):
    if not PROF.get("netdev_device"):
        raise SkipTest(f"board {HWTARG} declares no qemu net device")
    n = "user,id=n0" + (f",hostfwd=tcp:127.0.0.1:{hostfwd[0]}-:{hostfwd[1]}"
                        if hostfwd else "")
    return ["-netdev", n, "-device", f"{PROF['netdev_device']},netdev=n0"]


# ---- the tests -----------------------------------------------------

def test_boot():
    """Boots to sh; devices probe; psci answers."""
    g = Guest()
    g.run([("echo boot-marker", 3)])
    out = g.output()
    g.close()
    assert "boot-marker" in out, "no shell prompt traffic"
    assert "psci" in out, "no psci banner"
    assert "panic" not in out, "panic during boot"


def test_net():
    """Static slirp config; ping the gateway; conversation dirs appear."""
    g = Guest(extra=netdev())
    g.run(NETCONF + [
        ("ip/ping -n 2 10.0.2.2", 8),
        ("netstat", 4),
        ("echo net-marker", 2),
    ])
    out = g.output()
    g.close()
    assert "net-marker" in out
    assert ": rtt" in out or "avg rtt" in out, "no ping replies"


def test_dns():
    """ndb/cs + ndb/dns out of the box: resolve + fetch by hostname.
    Needs host internet (slirp NATs UDP to the public resolvers in ndb)."""
    g = Guest(extra=netdev())
    g.run(NETCONF + [
        ("ndb/cs &", 4),
        ("ndb/dns &", 4),
        ("ndb/dnsquery example.com", 10),
        ("webgrab -o /tmp/web.txt http://example.com/", 15),
        ("echo dns-marker", 2),
    ])
    out = g.output()
    g.close()
    assert "dns-marker" in out
    assert "example.com ip" in out, "dnsquery returned nothing"
    assert "created /tmp/web.txt" in out, "webgrab by hostname failed"


def test_disk():
    """kfs on the board's block device: a file survives a full qemu restart."""
    if not PROF.get("blk_device"):
        raise SkipTest(f"board {HWTARG} declares no qemu block device")
    with tempfile.NamedTemporaryFile(suffix=".img") as img:
        img.truncate(64 * 1024 * 1024)
        disk = ["-drive", f"if=none,file={img.name},format=raw,id=hd0",
                "-device", f"{PROF['blk_device']},drive=hd0"]
        g = Guest(extra=disk)
        g.run([
            ("bind -a '#S' /dev", 2),
            ("mount -c {disk/kfs -r /dev/sd00/data} /n/kfs", 8),
            ("echo persistent-data-survives > /n/kfs/persist.txt", 2),
            ("unmount /n/kfs", 3),
            ("echo first-marker", 2),
        ])
        first = g.output()
        g.close()
        assert "first-marker" in first, "first boot did not complete"

        g = Guest(extra=disk)
        g.run([
            ("bind -a '#S' /dev", 2),
            ("mount -c {disk/kfs /dev/sd00/data} /n/kfs", 8),
            ("cat /n/kfs/persist.txt", 3),
            ("echo second-marker", 2),
        ])
        out = g.output()
        g.close()
        assert "second-marker" in out
        assert "persistent-data-survives" in out, "file did not survive reboot"


def test_tls():
    """devtls + mbedTLS: unknown CA refused, then TLS 1.3 fetch with the
    test CA bound over the bundle (real verification, IP-SAN check)."""
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
        (f"webgrab -o /tmp/tls.txt 'https://10.0.2.2:{httpsport}/'", 15),
        ("cat /tmp/tls.txt*", 3),
        ("echo tls-marker", 2),
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
    guest's export (via hostfwd); the guest mounts the hosted emu's."""
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
    time.sleep(4)
    g.run([
        (f"mount -A 'tcp!10.0.2.2!{hsrv}' /n/remote", 5),
        ("cat /n/remote/tmp/hostmarker", 3),
        ("echo impexp-marker", 2),
    ])
    out = g.output()
    g.close()
    srv.terminate()
    srv.wait(timeout=10)
    assert "impexp-marker" in out
    assert "hello-from-hosted-emu" in out, "guest could not read the host export"


def test_gui():
    """The wm desktop comes up on the board's display: QMP screendump must
    show a real image (many distinct colours), not a flat/black framebuffer."""
    if not PROF.get("gui_devices"):
        raise SkipTest(f"board {HWTARG} declares no qemu display devices")
    qmp = tempfile.mktemp(prefix="ktest-qmp-")
    gui = PROF["gui_devices"] + ["-qmp", f"unix:{qmp},server=on,wait=off"]
    # wm + warmup settle
    g = Guest(extra=gui + netdev(), bootsecs=PROF.get("bootsecs", 25) + 20)
    s = socket.socket(socket.AF_UNIX)
    s.connect(qmp)
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
    ppm = tempfile.mktemp(prefix="ktest-", suffix=".ppm")
    cmd("screendump", filename=ppm)
    time.sleep(1)
    g.close()
    with open(ppm, "rb") as fh:
        data = fh.read()
    os.unlink(ppm)
    pix = data.split(b"\n", 3)[3]
    colours = set(pix[i:i+3] for i in range(0, min(len(pix), 3*1024*768), 3))
    assert len(colours) > 16, f"flat framebuffer ({len(colours)} colours) — no desktop"


# ---- runner --------------------------------------------------------

class SkipTest(Exception):
    pass


ALL = [test_boot, test_net, test_dns, test_disk, test_tls, test_impexp, test_gui]


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
