#!/usr/bin/env python3
# mkbibledata.py -- convert the kjv_api SQLite/JSON data into the flat data
# files consumed by appl/cmd/biblefs.b.  This runs ONCE on the host at
# packaging time; SQLite is never used inside Inferno.
#
# Source data comes from the kjv_api project:
#   https://gitea.nicecrew.digital/tyler/kjv_api  (data/kjv.db + the 1828
#   Webster dictionary JSON).
#
# Usage:
#   tools/mkbibledata.py <kjv.db> <1828_Webster_KJV.json> <outdir>
# e.g.
#   tools/mkbibledata.py /tmp/kjv_api/data/kjv.db \
#       /tmp/kjv_api/data/1828_Webster_KJV.json lib/bible
#
# Output files (all text, tab/space separated; offsets are byte offsets):
#   verses        raw verse text, one verse per line, ascending verse id
#   verses.idx    "<id> <off> <len>" per verse (off/len index into `verses`)
#   books         "<b>\t<name>\t<testament>\t<genre>" per book
#   abbrev        "<lc-name-or-abbrev>\t<b>" lookup keys for ref parsing
#   dict          concatenated dictionary definitions
#   dict.idx      "<lc-word>\t<off> <len>" index into `dict`
#   xref          per-verse cross-reference blocks ("<sv> <ev> <r>" lines)
#   xref.idx      "<vid> <off> <len>" index into `xref`

import json
import os
import sqlite3
import sys


def main():
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__)
        sys.exit(2)
    dbpath, jsonpath, outdir = sys.argv[1:4]
    os.makedirs(outdir, exist_ok=True)
    con = sqlite3.connect(dbpath)
    cur = con.cursor()

    write_verses(cur, outdir)
    write_books(cur, outdir)
    write_abbrev(cur, outdir)
    write_xref(cur, outdir)
    write_dict(jsonpath, outdir)
    con.close()


def write_verses(cur, outdir):
    rows = cur.execute(
        "SELECT id, t FROM fts_kjv ORDER BY id ASC;").fetchall()
    off = 0
    with open(os.path.join(outdir, "verses"), "wb") as f, \
         open(os.path.join(outdir, "verses.idx"), "w") as idx:
        for vid, text in rows:
            text = text.replace("\n", " ").replace("\r", " ").rstrip()
            data = text.encode("utf-8")
            f.write(data)
            f.write(b"\n")
            idx.write("%d %d %d\n" % (vid, off, len(data)))
            off += len(data) + 1
    sys.stderr.write("verses: %d\n" % len(rows))


def write_books(cur, outdir):
    genre = dict(cur.execute(
        "SELECT g, n FROM key_genre_english;").fetchall())
    rows = cur.execute(
        "SELECT b, n, t, g FROM key_english ORDER BY b ASC;").fetchall()
    with open(os.path.join(outdir, "books"), "w") as f:
        for b, n, t, g in rows:
            f.write("%d\t%s\t%s\t%s\n" % (b, n, t, genre.get(g, "")))
    sys.stderr.write("books: %d\n" % len(rows))


def write_abbrev(cur, outdir):
    # lookup keys for the reference parser: canonical names, plus the
    # abbreviation table.  Key is lowercased and spaces removed so "1 cor",
    # "1cor", "ICor" all collapse.  Longest unique prefixes win at parse time.
    keys = {}

    def add(k, b):
        k = k.lower().replace(" ", "")
        if k and k not in keys:
            keys[k] = b

    for b, n in cur.execute("SELECT b, n FROM key_english;").fetchall():
        add(n, b)
    for a, b in cur.execute(
            "SELECT a, b FROM key_abbreviations_english;").fetchall():
        add(a, b)
    with open(os.path.join(outdir, "abbrev"), "w") as f:
        for k in sorted(keys):
            f.write("%s\t%d\n" % (k, keys[k]))
    sys.stderr.write("abbrev: %d\n" % len(keys))


def write_xref(cur, outdir):
    rows = cur.execute(
        "SELECT vid, sv, ev, r FROM cross_reference "
        "ORDER BY vid ASC, r DESC;").fetchall()
    off = 0
    cur_vid = None
    block = []
    with open(os.path.join(outdir, "xref"), "wb") as f, \
         open(os.path.join(outdir, "xref.idx"), "w") as idx:
        def flush():
            nonlocal off
            if cur_vid is None:
                return
            data = "".join(block).encode("utf-8")
            f.write(data)
            idx.write("%d %d %d\n" % (cur_vid, off, len(data)))
            off += len(data)
        for vid, sv, ev, r in rows:
            if vid != cur_vid:
                flush()
                cur_vid = vid
                block = []
            block.append("%d %d %d\n" % (sv, ev, r))
        flush()
    sys.stderr.write("xref rows: %d\n" % len(rows))


def write_dict(jsonpath, outdir):
    with open(jsonpath) as f:
        d = json.load(f)
    off = 0
    with open(os.path.join(outdir, "dict"), "wb") as f, \
         open(os.path.join(outdir, "dict.idx"), "w") as idx:
        for word in sorted(d, key=lambda w: w.lower()):
            senses = d[word]
            if isinstance(senses, list):
                text = "\n\n".join(senses)
            else:
                text = str(senses)
            data = text.encode("utf-8")
            f.write(data)
            key = word.lower().strip().replace("\t", " ")
            idx.write("%s\t%d %d\n" % (key, off, len(data)))
            off += len(data)
    sys.stderr.write("dict: %d\n" % len(d))


if __name__ == "__main__":
    main()
