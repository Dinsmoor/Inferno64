# Limbo error handling — the two-layer model and why it's awkward

> *So you want to handle (or fix) errors and exceptions in Limbo?* This is the reference.

## The two-layer error model (what exists today)

  Inferno has two error systems bridged awkwardly:

  Layer 1 — C/kernel: error() / waserror() — Plan 9 setjmp/longjmp. A builtin calls error("msg"), which longjmps to the nearest waserror() on the proc's
  up->estack[]. This is invisible to Limbo programmers and is exactly what bit me above: bracketing compile() in release()/acquire() is unsafe only because
  a longjmp would skip the acquire(). The fix is discipline (a waserror wrapper that re-acquires) — not a Limbo change. But it's a perfect illustration of
  the root rot: error propagation is manual-invariant longjmp, so any new control flow has to hand-maintain balance.

  Layer 2 — Limbo language: raise / exception — raise "fail:reason" or raise Exc(args); caught by { … } exception e { "pat*" => … }.

  What actually "sucks," concretely

  1. Stringly-typed. A user-defined exception(int, string) degrades to a bare string (its identifier) the moment it crosses the immediate caller
  (ON_LIMBO.md:668). So you cannot carry a typed payload — error code, offending value, wrapped cause — up the stack. Everyone sprints into a string and
  re-parses with glob patterns ("fail:*"). The error text becomes the API contract (e.g. sh.b literally pattern-matches %r text to detect a wrong-width
  .dis).
  2. Two competing idioms. The dominant library style is tuple returns (T, string) (ON_LIMBO.md:829), threaded by hand at every call site — no
  propagation operator. Exceptions are the other style. Mixing them is constant friction and dropped errors.
  3. %r is a clobberable thread-global. Last-system-error, errno-style: any intervening syscall overwrites it before you read it.
  4. No backtrace / cause chain — even though the VM knows module+PC and has the .sbl line mapping. Userspace can't get a stack trace at raise time. That's
  a glaring miss for a VM.
  5. Spawned-proc errors vanish. spawn returns no handle (ON_LIMBO.md:897); a proc's terminal exception is unobservable unless you pre-wire a channel.
  For a concurrency-first language this is the biggest gap.
  6. No finally/scoped cleanup, no resumption, flat namespace. Cleanup must be duplicated in normal + handler paths; matching is glob-on-string.

  Recommendation (ranked by value ÷ effort)

  The lineage matters here: Limbo → Go (Pike/Winterbottom). Go solved this exact problem with typed error values, defer, panic/recover, and later error
  wrapping (%w, errors.Is/As). That's the proven direction, and it's native to these designers.

  Tier 1 — high value, runtime-only (no syntax change):
  - Make typed exceptions survive propagation. Stop the degrade-to-string; carry the exception ADT payload intact through the Dis exception mechanism. This
  single change kills most of the stringly-typed pain.
  - sys->stacktrace() builtin returning the current Dis call stack as (module, fn, line) using the info the VM already has. Massive debugging win, near-zero
  risk (read-only).
  - Snapshot %r into the raised exception so the cause isn't clobbered.

  Tier 2 — language sugar (compiler work, backward-compatible):
  - A defer-style cleanup (or {…} finally {…}) so fds/locks/external state release once, on both paths.
  - A propagation operator for the tuple idiom — collapse (x,err):=f(); if(err!=nil) raise err;.
  - Error wrapping / cause chains (raise wrap(e, "context"), match by cause).

  Tier 3 — the structural one:
  - Observable spawned-proc errors — spawn with a handle, or a "nursery"/wait primitive that delivers a child's terminal exception to the parent. This is
  the most Limbo-native extension (errors-as-channels) and aligns with your concurrency interests.

  My one-line take: the cheapest enormous win is Tier 1 (typed-payload propagation + a stacktrace builtin) — pure runtime, no syntax, and it directly
  attacks the "stringly-typed, no-trace" misery. If you want a language-level flagship for Goal 5, structured spawned-proc error propagation (Tier 3) is the
  one that's both novel and true to Limbo.
