/*
 * sqlitefs - expose an SQLite database to Inferno as a Styx file tree.
 *
 * This is a worked example of the "third-party C at runtime" pattern
 * described in docs/ON_C_AT_RUNTIME.md.  It is an ordinary *host* program
 * (built with the host cc, not compiled into emu) that links a third-party
 * C library (the SQLite amalgamation) and serves a Styx/9P file tree using
 * tools/libstyx.  Inferno mounts it and drives SQLite by reading and writing
 * files - so a crash in SQLite or in this server takes down only this
 * process, never the emu/kernel that mounted it.
 *
 * It is modelled directly on tools/odbc/odbc.c (the established Inferno idiom
 * for talking to a host database), trimmed to a single implicit protocol.
 *
 * File tree served:
 *   /db            directory
 *   /db/new        open() clones a fresh connection -> /db/N/
 *   /db/N/ctl      write "open <path>" | "close"
 *   /db/N/cmd      write an SQL statement; it runs and the result is buffered
 *   /db/N/data     read the result of the last cmd ('|'-separated, '\n' rows)
 *   /db/N/error    read the last error message
 *   /db/N/status   read connection state
 *
 * Transport is TCP (default port 6701), exactly like tools/odbc; Inferno
 * mounts it with e.g.  mount -A tcp!127.0.0.1!6701 /n/sqlite
 *
 * Run  sqlitefs -t  to self-test the SQLite path without Styx/Inferno at all.
 */
#include <lib9.h>
#include <styx.h>
#include "styxserver.h"
#include "sqlite3.h"

enum
{
	NCONV	= 64,		/* max simultaneous connections */
};

/* qid path layout: low nibble = file type, next 12 bits = connection index */
enum
{
	Qdbdir	= 1,		/* /db */
	Qclone,			/* /db/new */
	Qconvdir,		/* /db/N */
	Qctl,
	Qcmd,
	Qdata,
	Qerror,
	Qstatus,
};
#define TYPE(q)		((q).path & 0xf)
#define CONV(q)		(((q).path >> 4) & 0xfff)
#define QID(c, y)	(((uvlong)(c) << 4) | (y))

typedef struct Conv Conv;
struct Conv
{
	int		x;		/* index in conv[] */
	int		ref;
	int		inuse;
	char		*owner;
	char		*state;
	sqlite3	*db;		/* the open database, or nil */
	char		*result;	/* buffered result of last cmd */
	ulong		resultlen;
	char		err[ERRMAX];
};

static char	*netport = "6701";
static char	*owner = "sqlite";
static int	debug;

static Conv	conv[NCONV];
Styxserver	*iserver;

static long
readbytes(ulong off, char *buf, ulong n, char *src, ulong srclen)
{
	if(off >= srclen)
		return 0;
	if(off + n > srclen)
		n = srclen - off;
	memmove(buf, src + off, n);
	return n;
}

static long
readstr(ulong off, char *buf, ulong n, char *s)
{
	return readbytes(off, buf, n, s, strlen(s));
}

/*
 * Run one SQL statement against c->db and buffer the result into c->result.
 * Returns nil on success or an error string (also left in c->err).
 */
static char*
runquery(Conv *c, char *sql)
{
	sqlite3_stmt *st;
	sqlite3_str *out;
	int rc, ncols, i;
	const char *txt;

	sqlite3_free(c->result);	/* result comes from sqlite3_str_finish */
	c->result = nil;
	c->resultlen = 0;
	c->err[0] = 0;

	if(c->db == nil){
		strecpy(c->err, c->err+sizeof(c->err), "no database open");
		return c->err;
	}

	rc = sqlite3_prepare_v2(c->db, sql, -1, &st, nil);
	if(rc != SQLITE_OK){
		snprint(c->err, sizeof(c->err), "%s", sqlite3_errmsg(c->db));
		return c->err;
	}

	out = sqlite3_str_new(c->db);
	ncols = sqlite3_column_count(st);

	/* header row of column names */
	for(i = 0; i < ncols; i++)
		sqlite3_str_appendf(out, "%s%c", sqlite3_column_name(st, i),
			i == ncols-1 ? '\n' : '|');

	while((rc = sqlite3_step(st)) == SQLITE_ROW){
		for(i = 0; i < ncols; i++){
			txt = (const char*)sqlite3_column_text(st, i);
			sqlite3_str_appendf(out, "%s%c", txt ? txt : "",
				i == ncols-1 ? '\n' : '|');
		}
	}
	sqlite3_finalize(st);

	if(rc != SQLITE_DONE){
		snprint(c->err, sizeof(c->err), "%s", sqlite3_errmsg(c->db));
		sqlite3_free(sqlite3_str_finish(out));
		return c->err;
	}

	/* non-SELECT (CREATE/INSERT/...) reports rows changed */
	if(ncols == 0)
		sqlite3_str_appendf(out, "%d rows changed\n", sqlite3_changes(c->db));

	c->resultlen = sqlite3_str_length(out);
	c->result = sqlite3_str_finish(out);	/* malloc'd; freed via sqlite3_free */
	return nil;
}

static char*
ctlopen(Conv *c, char *path)
{
	if(c->db != nil){
		sqlite3_close(c->db);
		c->db = nil;
	}
	if(sqlite3_open(path, &c->db) != SQLITE_OK){
		snprint(c->err, sizeof(c->err), "%s", sqlite3_errmsg(c->db));
		sqlite3_close(c->db);
		c->db = nil;
		return c->err;
	}
	c->state = "Open";
	return nil;
}

static void
convfree(Conv *c)
{
	if(c->db != nil){
		sqlite3_close(c->db);
		c->db = nil;
	}
	sqlite3_free(c->result);
	c->result = nil;
	c->resultlen = 0;
	free(c->owner);
	c->owner = nil;
	c->inuse = 0;
	c->ref = 0;
	c->state = "Closed";
}

static Conv*
convclone(char *user)
{
	Conv *c;
	int i;
	char buf[16];
	uvlong nr;

	for(i = 0; i < NCONV; i++)
		if(!conv[i].inuse)
			break;
	if(i == NCONV)
		return nil;

	c = &conv[i];
	memset(c, 0, sizeof(*c));
	c->x = i;
	c->inuse = 1;
	c->ref = 1;
	c->owner = strdup(user);
	c->state = "Open";

	nr = QID(c->x, Qconvdir);
	snprint(buf, sizeof(buf), "%d", c->x);
	styxadddir(iserver, Qdbdir, nr, buf, 0555, c->owner);
	styxaddfile(iserver, nr, QID(c->x, Qctl), "ctl", 0660, c->owner);
	styxaddfile(iserver, nr, QID(c->x, Qcmd), "cmd", 0660, c->owner);
	styxaddfile(iserver, nr, QID(c->x, Qdata), "data", 0660, c->owner);
	styxaddfile(iserver, nr, QID(c->x, Qerror), "error", 0440, c->owner);
	styxaddfile(iserver, nr, QID(c->x, Qstatus), "status", 0440, c->owner);
	return c;
}

static char*
dbopen(Qid *qid, int omode)
{
	Conv *c;
	Client *cl;

	switch(TYPE(*qid)){
	case Qclone:
		cl = styxclient(iserver);
		c = convclone(cl->uname);
		if(c == nil)
			return Enodev;
		qid->path = QID(c->x, Qctl);
		qid->type = 0;
		qid->vers = 0;
		break;
	case Qctl:
	case Qcmd:
	case Qdata:
		c = &conv[CONV(*qid)];
		if(!c->inuse)
			return Enonexist;
		c->ref++;
		break;
	}
	USED(omode);
	return nil;
}

static char*
dbclose(Qid qid, int mode)
{
	Conv *c;

	USED(mode);
	switch(TYPE(qid)){
	case Qctl:
	case Qcmd:
	case Qdata:
		c = &conv[CONV(qid)];
		if(!c->inuse)
			break;
		if(--c->ref > 0)
			break;
		styxrmfile(iserver, QID(c->x, Qconvdir));
		convfree(c);
		break;
	}
	return nil;
}

static char*
dbread(Qid qid, char *buf, ulong *n, vlong offset)
{
	Conv *c;

	c = &conv[CONV(qid)];
	switch(TYPE(qid)){
	case Qctl:		/* read the connection number, /net-style */
		{
			char num[16];
			snprint(num, sizeof(num), "%d", (int)CONV(qid));
			*n = readstr(offset, buf, *n, num);
		}
		return nil;
	case Qdata:
		*n = readbytes(offset, buf, *n, c->result ? c->result : "", c->resultlen);
		return nil;
	case Qerror:
		*n = readstr(offset, buf, *n, c->err);
		return nil;
	case Qstatus:
		*n = readstr(offset, buf, *n, c->state ? c->state : "Closed");
		return nil;
	}
	return Eperm;
}

static char*
dbwrite(Qid qid, char *buf, ulong *n, vlong offset)
{
	Conv *c;
	char cmd[8192], *p, *e;

	USED(offset);
	c = &conv[CONV(qid)];
	if(!c->inuse)
		return Enonexist;

	switch(TYPE(qid)){
	case Qctl:
		if(*n >= sizeof(cmd))
			return Ebadarg;
		memmove(cmd, buf, *n);
		cmd[*n] = 0;
		while(*n > 0 && (cmd[*n-1] == '\n' || cmd[*n-1] == ' '))
			cmd[--(*n)] = 0;
		if(strncmp(cmd, "open ", 5) == 0){
			for(p = cmd+5; *p == ' '; p++)
				;
			if((e = ctlopen(c, p)) != nil)
				return e;
		}else if(strcmp(cmd, "close") == 0){
			if(c->db != nil){
				sqlite3_close(c->db);
				c->db = nil;
			}
			c->state = "Closed";
		}else
			return Ebadcmd;
		return nil;
	case Qcmd:
		if(*n >= sizeof(cmd))
			return Ebadarg;
		memmove(cmd, buf, *n);
		cmd[*n] = 0;
		if((e = runquery(c, cmd)) != nil)
			return e;
		return nil;
	}
	return Eperm;
}

Styxops ops =
{
	nil,		/* newclient */
	nil,		/* freeclient */
	nil,		/* attach */
	nil,		/* walk */
	dbopen,		/* open */
	nil,		/* create */
	dbread,		/* read */
	dbwrite,	/* write */
	dbclose,	/* close */
	nil,		/* remove */
	nil,		/* stat */
	nil,		/* wstat */
};

/* exercise the SQLite path with no Styx/Inferno involved */
static int
selftest(void)
{
	Conv c;
	char *e;

	memset(&c, 0, sizeof(c));
	c.state = "Closed";

	if((e = ctlopen(&c, ":memory:")) != nil){
		fprint(2, "selftest: open: %s\n", e);
		return 1;
	}
	if((e = runquery(&c, "create table t(id integer, name text)")) != nil){
		fprint(2, "selftest: create: %s\n", e);
		return 1;
	}
	if((e = runquery(&c, "insert into t values(1,'hello'),(2,'world')")) != nil){
		fprint(2, "selftest: insert: %s\n", e);
		return 1;
	}
	if((e = runquery(&c, "select id, name from t order by id")) != nil){
		fprint(2, "selftest: select: %s\n", e);
		return 1;
	}
	print("--- sqlitefs selftest (sqlite %s) ---\n", sqlite3_libversion());
	write(1, c.result, c.resultlen);
	print("--- ok ---\n");
	convfree(&c);
	return 0;
}

static void
usage(void)
{
	fprint(2, "usage: sqlitefs [-d] [-t] [-p port]\n");
	exits("usage");
}

void
main(int argc, char *argv[])
{
	Styxserver s;

	ARGBEGIN{
	case 'd':
		debug = 1;
		styxdebug();
		break;
	case 't':
		exits(selftest() ? "fail" : nil);
	case 'p':
		netport = EARGF(usage());
		break;
	default:
		usage();
	}ARGEND
	USED(argc); USED(argv); USED(debug);

	iserver = &s;
	styxinit(&s, &ops, netport, -1, 1);
	styxadddir(&s, Qroot, Qdbdir, "db", 0555, owner);
	styxaddfile(&s, Qdbdir, Qclone, "new", 0666, owner);
	fprint(2, "sqlitefs: serving on tcp port %s\n", netport);
	for(;;){
		styxwait(&s);
		styxprocess(&s);
	}
}
