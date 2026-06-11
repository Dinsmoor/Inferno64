#!/bin/sh
# Compile the vendored SQLite amalgamation into sqlite3.o for sqlitefs.
#
# sqlite3.c / sqlite3.h are vendored in this directory (see NOTICE); this script
# compiles them into sqlite3.o with the plain host cc (NOT the Inferno
# toolchain).  Run it once before `mk install` here.  If the vendored source is
# ever missing it is re-downloaded from the pinned release.
# See docs/ON_C_AT_RUNTIME.md.

set -e
ver=3460100			# SQLite 3.46.1 (stable, 2024)
url="https://sqlite.org/2024/sqlite-amalgamation-$ver.zip"
cc=${CC:-cc}

cd "$(dirname "$0")"

if [ ! -f sqlite3.h ] || [ ! -f sqlite3.c ]; then
	echo "fetching $url"
	curl -sSL -o sqlite-amalg.zip "$url"
	unzip -o -q sqlite-amalg.zip
	cp "sqlite-amalgamation-$ver/sqlite3.h" .
	cp "sqlite-amalgamation-$ver/sqlite3.c" .
	rm -rf sqlite-amalg.zip "sqlite-amalgamation-$ver"
fi

echo "compiling sqlite3.o with $cc"
$cc -O2 -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 \
	-c sqlite3.c -o sqlite3.o
echo "sqlite3.o built (SQLite $ver)"
