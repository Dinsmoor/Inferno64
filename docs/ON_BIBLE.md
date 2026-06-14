# biblefs — the King James Bible as a file tree

`biblefs` (`appl/cmd/biblefs.b`) serves the King James Bible as a Styx file
tree. A scripture reference is a path; you read it. There is no query language
for the common case and no database engine at run time — the Bible simply
becomes part of the namespace, so the whole system composes against it: the
shell can `cat` a verse, `grep` can search the text, the plumber can route a
reference, and a thin client (or a GUI such as a future `wm/bible`) can `import`
the tree from a beefy host.

This is the Inferno-native shape of what was a web application. The upstream
[`kjv_api`](https://gitea.nicecrew.digital/tyler/kjv_api) is a Flask service
backed by SQLite; biblefs keeps the data and discards both the web server and
the database. Presentation lives in clients, not in the server.

## Mounting

```
mount {biblefs} /mnt/bible
```

biblefs serves Styx on file descriptor 0 (the `fedifs`/`mount {}` model), so the
mount lands in the caller's namespace. It does not self-mount and does not fork
the namespace. `-d datadir` overrides the data directory (default `/lib/bible`);
`-D` turns on Styx tracing.

## The tree

```
/mnt/bible/
    books/                  the canonical text as a walkable tree
        Genesis/
            info            name, testament, genre, chapter and verse counts
            1/              chapter directory
                1           a verse record
                2 ...
        John/3/16           reference == path
    define/                 walk define/<word> for an 1828 Webster definition
    lookup                  write a reference, read the verses back
    search                  write keywords, read matching verses
    xref                    write a reference, read its cross-referenced verses
    votd                    read: the verse of the day (deterministic by date)
    random                  read: a random verse per open
    ctl                     read: server status
    notes/                  empty stub: a mount point for a per-user notefs
```

`books/` and `define/` are walked by path. `define/` is walk-only: it resolves
`define/<word>` but its `readdir` is empty (the dictionary has thousands of
entries and is not meant to be listed). `notes/` is an empty stub directory so a
per-user [notefs](#notefs--per-user-notes) can be mounted there, putting your
notes in the same namespace as scripture.

## Record format

Verse records are one verse per line, tab-separated, so a GUI client parses them
with a single `sys->tokenize(line, "\t")`:

```
<book>\t<chapter>\t<verse>\t<text>\n
```

`lookup`, `search`, and `xref` return zero or more such lines. `define/<word>`
returns the raw dictionary prose (paragraph-separated senses). `info` returns
`name\ttestament\tgenre\t<n> chapters\t<n> verses`. `ctl` returns `key\tvalue`
status lines.

## The query files

`lookup`, `search`, and `xref` use the request/response file idiom of `/net/dns`
and `/net/cs`: open the file `ORDWR`, write the query, read the answer from the
same fid. The answer streams out on reads and the byte offset is ignored, so the
offset left behind by the write does not matter — a client never has to seek.
One write is one query; writing again replaces the answer.

- `lookup` parses references: `john3:16`, `1cor13` (whole chapter), `1cor13:4-7`
  (range), `ps23`, and comma-separated lists (`gen1:1,john1:1`). Leading book
  numbers (`1cor`, `2john`) and abbreviations resolve through the abbreviation
  table; a bare book name returns its whole chapter 1 through the book.
- `search` matches the AND of whitespace-separated terms, case-folded, against
  the verse text. Results are capped (see the `MAX*` constants).
- `xref` returns the verses cross-referenced from a reference (Treasury of
  Scripture Knowledge data).

## Data

The data is a set of flat files under `/lib/bible`, built once on the host by
`tools/mkbibledata.py` from the `kjv_api` SQLite database and the 1828 Webster
dictionary JSON. SQLite is a build-time host dependency only; it is never used
inside Inferno.

```
tools/mkbibledata.py <kjv.db> <1828_Webster_KJV.json> lib/bible
```

The files are: `verses` (verse text) and `verses.idx` (per-verse byte offsets);
`books` and `abbrev` (book metadata and reference-parsing keys); `dict` and
`dict.idx` (the dictionary blob and its headword index); `xref` and `xref.idx`
(cross-reference blocks and their per-verse index).

At startup biblefs reads the indices and the verse text into memory and serves
verse and search results by slicing the in-memory verse blob; the dictionary and
cross-reference blobs stay on disk and are read on demand with `sys->pread`
(lock-free, so concurrent reads need no serialisation). The whole working set is
on the order of the verse text plus the indices.

## wm/bible — the reader

`wm/bible` (`appl/wm/bible.b`) is a Tk reader over this namespace. It holds no
data model of its own: every action is a file operation against `/mnt/bible`.
Navigation reads the `books` tree, a chapter is one read of `lookup`,
search and cross-references are the `search`/`xref` query files, and a
right-clicked word is read from `define/<word>`. Launch it from the wm menu
(**Bible**), or:

	mount {biblefs} /mnt/bible
	wm/bible

Layout: a left nav of two resizable lists (books over that book's chapters), a
centre reading pane (serif body, superscript verse numbers), a right context
pane with **Cross-refs** and **Dictionary** tabs, and a bottom note editor. It
opens on the verse of the day. The toolbar has **Prev/Next** (browser-style
back/forward over the verses you have focused), a `Go:` reference box
(`john3:16`, `1cor13:4-7`, `ps23`, …), and a `Search:` box.

Interactions: click a verse to select it and load its cross-references; click a
cross-reference or a search result to jump there; right-click a word for its
1828 Webster definition (opens the Dictionary tab); keys `j`/`k` move the
selected verse, `n`/`p` page chapters, `/` focuses search. The note editor saves
to `/mnt/bible/notes`; the colour buttons highlight the selected verse and a
note's highlight tints that verse in the reading pane.

The reader is built on the [`Tkwidgets`](ON_TK_WIDGETS.md) megawidgets — the
two-pane nav is a `Paned` of two `Scrolledlist`s, the context tabs and reading
and note panes are `Notebook`/`Scrolledtext`, and the bottom bar a `Statusbar` —
which replaced the hand-rolled scaffolding the earlier Tk packer limitations had
forced.

## notefs — per-user notes

`notefs` (`appl/cmd/notefs.b`) is a small writable file server, mounted onto the
`notes/` stub at `/mnt/bible/notes`, that puts your annotations in the same
namespace as scripture:

```
/mnt/bible/books/John/3/16      the verse        (biblefs, read-only, shareable)
/mnt/bible/notes/John/3/16      your note on it  (notefs, per-user, writable)
```

Notes persist as plain files under `$home/lib/bible/notes/<Book>/<chap>/<verse>`
(so acme/grep/the plumber compose with them and they survive a restart). Any
`<Book>/<chap>/<verse>` path is walkable whether or not a note exists yet, so a
client just opens the path and writes — no `mkdir` dance; writing an empty note
removes it. `readdir` lists only the books/chapters/verses that *have* notes,
which is how the reader marks annotated verses. `recent` reads back the noted
references, newest first.

notefs holds the file contents opaque; `wm/bible` owns the little frontmatter (a
`highlight:`/`tags:` header, a blank line, then the body). Keeping notes in a
separate per-user server leaves biblefs pure and shareable (it can be imported
from a beefy host) while your private notes stay local.

## Qid encoding

The 64-bit Qid path packs a kind in the high byte and a payload in the low bits:
a book number, `book*1000 + chapter`, a verse id (`book*1000000 +
chapter*1000 + verse`), or a dictionary headword index. The navigator answers
`Stat`/`Walk`/`Readdir` by decoding the path, so the ~31 k-leaf tree is fully
synthetic — nothing is materialised until it is walked.
