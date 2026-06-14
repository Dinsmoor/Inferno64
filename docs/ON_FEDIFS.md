# fedifs — the Fediverse as a file tree

`fedifs` (`appl/cmd/fedifs.b`) serves a Pleroma/Mastodon account as a Styx file
tree. It wraps the GUI-free [`Masto`](ON_PLEROMUSSY.md) library in a
`styxservers` file server, so the Fediverse becomes part of the namespace and
the whole system composes against it: the shell can `cat` a timeline, acme can
compose a toot, `grep` can search a feed, the plumber can route a status, and a
thin client can `import` the tree from a beefy host. fedifs is the **sole holder
of the OAuth bearer token at run time** — its clients never see it.

This is the Inferno-native shape of a network client: not an application that
hoards a connection, but a file server that publishes a resource into the
namespace for everything else to share.

## Mounting

`cs` must be up (for `dialtls` name resolution). Under wm both are started for
the whole session by `/lib/wmsetup`:

```
ndb/cs &
mount {fedifs} /mnt/fedi
```

Stand-alone:

```
mount {fedifs} /mnt/fedi
```

Mounting is not logging in: a freshly-mounted fedifs is an idle server that
does nothing until a host is walked. At startup it **enumerates the saved
sessions** (`$home/lib/pleromussy/*.json`, the same store the GUI login writes)
and pre-creates a subtree for each, so the accounts you are already logged into
appear immediately:

```
% ls /mnt/fedi
/mnt/fedi/nicecrew.digital
% cat /mnt/fedi/nicecrew.digital/home
```

Beyond those, **any host also appears the first time it is walked** — there is
no configuration step:

```
cat /mnt/fedi/mastodon.social/public
```

Because each host is its own subtree, multiple accounts/instances need no
multi-account logic: walk a second host and it is simply there. The token for a
host is loaded from its saved session; a host with no saved session is
**anonymous** (public reads where the instance allows; authenticated reads
error) until you `login` through its `ctl` — which mints and persists the token
inside fedifs, so the secret never leaves the server.

## The tree

Per host (`/mnt/fedi/<host>/`):

| file | mode | read | write |
|---|---|---|---|
| `ctl` | rw | one-line status (logged in? last error) | a command per line (below) |
| `home` | r | home timeline, newest first | — |
| `public` | r | public timeline | — |
| `notifications` | r | your notifications | — |
| `me` | r | the authenticated account | — |
| `instance` | r | instance title/version/description | — |
| `compose` | w | — | one write == one new status |
| `stream` | r | **blocks**, yields new home posts as they land | — |
| `authurl` | r | the pending OAuth authorize URL (after `authbegin`), else empty | — |

A read of `home`/`public`/`notifications`/`me`/`instance` fetches fresh on
**open** and caches the rendered text in the fid, so the read sequence is
stable; re-open for fresh data. Content is rendered to plain text (HTML
stripped, the common entities decoded), each post terminated by a `----` rule
and tagged with `[fav N boost N reply N] <id>` so scripts and `ctl` can refer
to it.

### `ctl` verbs

One verb per write:

```
login <user> <pass>        log in (bare-host node) and persist the session
login <pass>               log in (user@host node — user is in the node name)
authbegin                  start OAuth browser login; stages the authurl file
authcode <code>            finish OAuth browser login with the pasted code
logout                     forget and delete the saved session
reload                     re-read the session from disk
post <text...>             create a status
reply <id> <text...>       reply to a status
fav <id> | unfav <id>
boost <id> | unboost <id>
bookmark <id> | unbookmark <id>
react <id> <emoji> | unreact <id> <emoji>
```

The password is taken as the rest of the line, so it may contain spaces. A
failed verb returns a Styx error (so `echo … > ctl` reports failure) and is
also remembered in the `ctl` read as `last error:`.

Examples:

```
echo 'fav 109876543210' > /mnt/fedi/nicecrew.digital/ctl
echo 'hello from inferno' > /mnt/fedi/nicecrew.digital/compose
tail -f /mnt/fedi/nicecrew.digital/stream
```

## Logging in

Login happens **inside fedifs** (the token never leaves the server). The
password should not go on a command line or into shell history, so the simplest
safe path is the **`fedilogin`** helper, which prompts with terminal echo off:

```
fedilogin poa.st              # prompts for user, then password (hidden)
fedilogin alice@poa.st        # prompts only for the password
```

Equivalently, by hand:

```
echo 'login alice hunter2' > /mnt/fedi/poa.st/ctl
```

A successful login persists the session, so the account reappears automatically
on the next mount. To check, `cat /mnt/fedi/poa.st/ctl` → `… : logged in as @alice`.

### Browser login (OAuth authorization-code)

The `login` verb uses the OAuth **resource-owner password grant**, which
Pleroma accepts but modern Mastodon increasingly **rejects**. The fallback is
the **authorization-code ("oob") flow**: the user authenticates on the
instance's own `/oauth/authorize` web page (so the password never enters
Inferno) and pastes back a one-time code. It is driven entirely through the
file tree:

```
echo authbegin > /mnt/fedi/<label>/ctl     # register app, stage the URL
cat /mnt/fedi/<label>/authurl              # open this in a browser, approve
echo 'authcode <code>' > /mnt/fedi/<label>/ctl   # exchange the shown code
```

`fedilogin -o <label>` wraps exactly this: it writes `authbegin`, prints the
`authurl`, prompts for the code, and writes `authcode`. The GUI's **Browser
login** button opens the authorize page in Charon and does the same. The
authorize page is plain server-rendered HTML (no JS) and renders in Charon.

### Multiple accounts on one instance

The node name is the **account label** — a bare host (`poa.st`) *or* a fediverse
handle (`alice@poa.st`). Several accounts on the same instance coexist as
sibling subtrees, each with its own session file (`<label>.json`); the client
always dials the real host (the part after the last `@`):

```
fedilogin alice@poa.st
fedilogin bob@poa.st
cat /mnt/fedi/alice@poa.st/home
cat /mnt/fedi/bob@poa.st/notifications
```

A bare `poa.st` node is the single/default slot; use the `user@host` form when
you want more than one.

### Picking up a GUI login

If the GUI (`wm/pleromussy`) logs a host in while fedifs is already running,
fedifs notices: as long as a host is still anonymous it re-reads its session on
the next access (`refreshauth`), so a GUI login becomes live without a remount.
`reload` forces a re-read explicitly.

## Streaming

`stream` is the canonical Inferno blocking-read event file: a read returns the
next new post or blocks until one arrives (cf. `/dev/cons`). It is currently
fed by a **server-side poll** of the home timeline (`POLLSEC`, default 30 s)
with a per-host seen-id ring for dedup. The poller is **lazy and
reference-counted**: it runs only while a `stream` file for that host is open
(started on the first reader, stopped when the last one clunks), so a host you
have merely logged into is not polled in the background. The file interface is
identical to a true Server-Sent-Events stream, so the transport can later be
swapped to the Mastodon `/api/v1/streaming` endpoint with no change to any
client.

## Design notes

- **One token holder.** Only fedifs carries the bearer token at run time; GUI,
  shell, and plumber are all just clients of the tree. `login` through `ctl`
  keeps the secret inside the server entirely.
- **Lazy subtrees via Walk interception.** Host directories are created on
  first walk: the serve loop materialises the subtree (`nametree` `create`)
  when a walk from the root names an unknown host, then lets `styxservers`
  resolve the walk normally. Qid paths pack `(hostindex<<8)|fileindex`.
- **Synchronous verbs.** Timeline/action requests run inline in the serve loop
  (a single-user client; the GUI keeps its own UI async). A slow fetch
  therefore stalls the server for its duration — acceptable for one user, and
  the obvious thing to make async (worker procs replying through the loop, the
  `stream` pattern generalised) if it ever matters.
- **Stream replies stay on the serve loop.** Pollers run in their own procs but
  hand new posts to the loop over a channel (`feedc`); every `srv.reply` is
  issued from the one loop, so there are no interleaved writes to the Styx fd.

## Why this exists

Before fedifs, the only way into the Fediverse was `wm/pleromussy`, a monolith
that owned transport, parsing, and GUI in one address space. fedifs splits the
resource out of the application: the GUI becomes one client among many, the
token stops living in every client, and the feed gains the composability the
rest of Inferno already has. See [`ON_PLEROMUSSY.md`](ON_PLEROMUSSY.md) for the
client and the `Masto` library it shares.
