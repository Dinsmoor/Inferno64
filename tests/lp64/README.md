# LP64 headless test suite

A repeatable, headless regression suite for the **LP64 Dis VM + Limbo** port
(`IBY2PTR=8`). It exercises the Dis virtual machine and the Limbo language
end-to-end through `emu-g` (the graphics-less emulator), with no display
required. Every test is a self-contained Limbo program that emits
[TAP](https://testanything.org/)-style `ok` / `not ok` lines via a shared
`Testing` helper; the host harness compiles each program with the C `limbo`,
runs it under `emu-g`, and aggregates the results.

## Running

```sh
make all                 # build Linux/<arch>/bin/{emu-g,limbo} first
tests/lp64/run.sh        # run every suite
tests/lp64/run.sh crypto # run only suites whose name contains "crypto"
TIMEOUT=120 tests/lp64/run.sh   # override the per-suite timeout (default 60s)
```

The runner exits non-zero if any assertion fails (`FAIL`) or any suite crashes
or times out (`err`). It tolerates exit code 137 (SIGKILL): `emu-g` is killed
on teardown by a pre-existing benign shutdown path — reproducible with a bare
`echo hi` — and all program output completes first.

## Layout

| Path | Purpose |
|------|---------|
| `run.sh` | host harness: compile → run → aggregate TAP |
| `lib/testing.{m,b}` | TAP assertion helper loaded by every suite |
| `lib/gen.m` | module interface the self-host suite compiles against |
| `suites/*.b` | one Limbo program per test group |
| `_build/` | generated `.dis` (git-ignored; wiped each run) |

## Suites

- **`00_vm`** — foundation: big/64-bit constants & arithmetic, real
  constants + math, strings (UTF-8), lists, tuples, arrays incl. replicate
  fill, pick-ADTs, data-carrying exceptions, and the modern language features
  (`**` exponentiation, `fixed()` point, function references). Covers the data
  paths most sensitive to the pointer-width port.
- **`10_concur`** — concurrency + GC stress: spawn fan-in, buffered/unbuffered
  channels, the buffered-channel mutex idiom, `alt`, a sentinel-terminated
  concurrent prime sieve, request/reply over a channel of references, and a
  retained linked structure that must survive ~1M churned allocations intact.
- **`20_crypto`** — crypto + big-number: Keyring digests (md5/sha1/sha256,
  one-shot and incremental) against published vectors, AES/DES-CBC
  encrypt→decrypt round-trips, and IPint infinite-precision arithmetic
  including modular exponentiation (the `libmp` C-port path on LP64).
- **`30_styxnet`** — networking + 9P/Styx: a real TCP loopback round-trip
  through `devip` via the `Dial` module, plus Styx (9P2000) `Tmsg`/`Rmsg`
  pack→unpack round-trips (arrays of names/qids, 64-bit offsets) and
  `packdir`/`unpackdir` with a >4 GiB `Dir` length.
- **`40_selfhost`** — self-hosted build: drives the *in-emu* compiler
  (`/dis/limbo.dis`) to compile a freshly-generated module from source, then
  loads and runs the product. A successful load also proves the emitted
  `XMAGIC8` pointer-width magic.
- **`50_loader`** — debug/reflect via `$Loader`: `ifetch`/`tdesc`/`link` a
  loaded module, rebuild it with `newmod`/`tnew`/`dnew`/`ext`, require a
  byte-for-byte instruction round-trip, then drop it and force GC. Directly
  validates the three `libinterp/loader.c` LP64 fixes (branch-target width,
  zeroed Module, nil-ext teardown).

## Adding a test

Drop a new `NN_name.b` into `suites/`. Load the helper and emit results:

```limbo
implement MyTest;
include "sys.m";
include "draw.m";
include "testing.m";
sys: Sys;
t: Testing;
MyTest: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();
	t->eqi(big (2+2), big 4, "arithmetic");
	t->summary();
}
```

`testing.m` is on the include path automatically. Any spawned helper procs
must terminate (e.g. via a sentinel) or the suite will hang until the timeout.
