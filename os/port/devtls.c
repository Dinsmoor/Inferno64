/*
 * devtls - modern TLS (1.2/1.3) layered onto a connection, backed by
 * mbedTLS.  Native-kernel adaptation of emu/port/devtls.c; same #T
 * interface (see that file, or appl/lib/dial.b pushtls):
 *	clone := open("#T/clone", ORDWR)	# read conv number
 *	write(ctl, "fd <n>")			# attach an already-dialed connection
 *	write(ctl, "servername example.com")	# SNI + cert hostname check
 *	[write(ctl, "verify off") | "cafile <p>" | "alpn h2 http/1.1"]
 *	data := open("#T/<conv>/data", ORDWR)	# first read/write drives the handshake
 *
 * Differences from the emu version: kernel include set; the CA bundle
 * is read through the kernel's own file I/O (kopen/kread) and parsed
 * from memory, since the freestanding mbedTLS build has no FS_IO; the
 * default bundle is the one baked into the root image.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#include	"mbedtls/ssl.h"
#include	"mbedtls/net_sockets.h"	/* MBEDTLS_ERR_NET_{SEND,RECV}_FAILED */
#include	"mbedtls/entropy.h"
#include	"mbedtls/ctr_drbg.h"
#include	"mbedtls/x509_crt.h"
#include	"mbedtls/error.h"

enum
{
	/* connection state */
	Tincomplete=	0,
	Testablished=	1,
	Tbroken=	2,

	Tlsbufsz=	1<<14,	/* TLS record max */
	Maxtstate=	1<<10,
	Maxalpn=	8,
	Maxcafile=	1<<21,	/* sanity cap when slurping a CA bundle */

	DEFVERIFY=	MBEDTLS_SSL_VERIFY_REQUIRED,
};

static char Defcafile[] = "/lib/tls/ca-certificates.crt";

typedef struct Tstate Tstate;
struct Tstate
{
	Chan*	c;		/* underlying (already-dialed) connection */
	int	state;
	int	ref;		/* serialized by tlslock */
	char*	user;
	int	perm;

	/* mbedTLS engine (initialised lazily at handshake) */
	int	inited;
	int	handshaken;
	mbedtls_ssl_context	ssl;
	mbedtls_ssl_config	conf;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_entropy_context	entropy;
	mbedtls_x509_crt	cacert;

	/* configuration set via ctl before the handshake */
	char	servername[256];
	char*	cafile;
	int	verify;
	char*	alpn[Maxalpn+1];	/* NULL-terminated for mbedtls */

	/* leftover input from the underlying Chan, for the recv BIO */
	Block*	rb;

	uint32_t verifyflags;
	char	err[ERRMAX];
};

static Lock	tlslock;
static int	thiwat;
static int	maxtstate = 20;
static Tstate**	tstate;

enum{
	Qtopdir= 1,
	Qclonus,
	Qconvdir,
	Qdata,
	Qctl,
	Qstatus,
};

#define TYPE(x)		((ulong)(x).path & 0xf)
#define CONV(x)		(((ulong)(x).path >> 4)&(Maxtstate-1))
#define QID(c, y)	(((c)<<4) | (y))

static Chan*	buftochan(char*);
static void	tlshangup(Tstate*);
static void	tsclone(Chan*);
static void	tsnew(Chan*, Tstate**);
static void	dohandshake(Tstate*);

/* ---- mbedTLS BIO bridged to the underlying Inferno Chan ---- */

static int
bio_send(void *ctx, const unsigned char *buf, size_t len)
{
	Tstate *s = ctx;
	Block *b;

	if(s->c == nil)
		return MBEDTLS_ERR_NET_SEND_FAILED;
	if(waserror())
		return MBEDTLS_ERR_NET_SEND_FAILED;
	b = allocb(len);
	memmove(b->wp, buf, len);
	b->wp += len;
	/* bwrite consumes/frees b */
	devtab[s->c->type]->bwrite(s->c, b, 0);
	poperror();
	return (int)len;
}

static int
bio_recv(void *ctx, unsigned char *buf, size_t len)
{
	Tstate *s = ctx;
	Block *b;
	int n;

	if(s->c == nil)
		return MBEDTLS_ERR_NET_RECV_FAILED;
	/* refill from the underlying connection if our buffer is empty */
	while(s->rb != nil && BLEN(s->rb) == 0){
		b = s->rb;
		s->rb = b->next;
		b->next = nil;
		freeb(b);
	}
	if(s->rb == nil){
		if(waserror())
			return MBEDTLS_ERR_NET_RECV_FAILED;
		s->rb = devtab[s->c->type]->bread(s->c, Tlsbufsz, 0);
		poperror();
		while(s->rb != nil && BLEN(s->rb) == 0){
			b = s->rb;
			s->rb = b->next;
			b->next = nil;
			freeb(b);
		}
		if(s->rb == nil)
			return 0;	/* clean EOF */
	}
	n = BLEN(s->rb);
	if(n > (int)len)
		n = len;
	memmove(buf, s->rb->rp, n);
	s->rb->rp += n;
	return n;
}

/*
 * Slurp a CA bundle and hand it to mbedtls_x509_crt_parse: the
 * freestanding mbedTLS has no FS_IO, and the kernel reads its own
 * files anyway.  PEM parsing wants the terminating NUL counted.
 */
static int
loadcafile(Tstate *s, char *path)
{
	char *buf;
	long n, sofar;
	int fd, ret;

	fd = kopen(path, OREAD);
	if(fd < 0)
		return -1;
	if(waserror()){
		kclose(fd);
		nexterror();
	}
	buf = malloc(Maxcafile+1);
	if(buf == nil)
		error(Enomem);
	sofar = 0;
	while(sofar < Maxcafile){
		n = kread(fd, buf+sofar, Maxcafile-sofar);
		if(n <= 0)
			break;
		sofar += n;
	}
	buf[sofar] = 0;
	ret = mbedtls_x509_crt_parse(&s->cacert, (uchar*)buf, sofar+1);
	free(buf);
	poperror();
	kclose(fd);
	return ret < 0 ? -1 : 0;
}

/* ---- handshake / engine setup (lazy, on first data I/O) ---- */

static void
dohandshake(Tstate *s)
{
	int ret;
	char *cafile;

	if(s->handshaken)
		return;
	if(s->c == nil)
		error("tls: no underlying fd (write 'fd <n>' to ctl first)");

	if(!s->inited){
		mbedtls_ssl_init(&s->ssl);
		mbedtls_ssl_config_init(&s->conf);
		mbedtls_ctr_drbg_init(&s->drbg);
		mbedtls_entropy_init(&s->entropy);
		mbedtls_x509_crt_init(&s->cacert);
		s->inited = 1;
	}

	if((ret = mbedtls_ctr_drbg_seed(&s->drbg, mbedtls_entropy_func,
			&s->entropy, (const unsigned char*)"devtls", 6)) != 0)
		error("tls: rng seed failed");

	if(s->verify != MBEDTLS_SSL_VERIFY_NONE){
		cafile = s->cafile ? s->cafile : Defcafile;
		if(loadcafile(s, cafile) < 0)
			error("tls: cannot load CA bundle");
	}

	if(mbedtls_ssl_config_defaults(&s->conf, MBEDTLS_SSL_IS_CLIENT,
			MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0)
		error("tls: config failed");
	mbedtls_ssl_conf_authmode(&s->conf, s->verify);
	if(s->verify != MBEDTLS_SSL_VERIFY_NONE)
		mbedtls_ssl_conf_ca_chain(&s->conf, &s->cacert, nil);
	mbedtls_ssl_conf_rng(&s->conf, mbedtls_ctr_drbg_random, &s->drbg);

	if(mbedtls_ssl_setup(&s->ssl, &s->conf) != 0)
		error("tls: ssl setup failed");
	if(s->servername[0]){
		if(mbedtls_ssl_set_hostname(&s->ssl, s->servername) != 0)
			error("tls: set hostname failed");
	}
	if(s->alpn[0] != nil)
		mbedtls_ssl_conf_alpn_protocols(&s->conf, (const char**)s->alpn);

	mbedtls_ssl_set_bio(&s->ssl, s, bio_send, bio_recv, nil);

	for(;;){
		ret = mbedtls_ssl_handshake(&s->ssl);
		if(ret == 0)
			break;
		if(ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
			continue;
		s->state = Tbroken;
		mbedtls_strerror(ret, s->err, sizeof(s->err));
		error(s->err);
	}
	s->verifyflags = mbedtls_ssl_get_verify_result(&s->ssl);
	s->handshaken = 1;
	s->state = Testablished;
}

/* ---- device plumbing (modeled on devssl) ---- */

static int
tlsgen(Chan *c, char *dname, Dirtab *d, int nd, int s, Dir *dp)
{
	Qid q;
	Tstate *ts;
	char *p, *nm;

	USED(dname); USED(nd); USED(d);
	q.type = QTFILE;
	q.vers = 0;
	if(s == DEVDOTDOT){
		q.path = QID(0, Qtopdir);
		q.type = QTDIR;
		devdir(c, q, "#T", 0, eve, 0555, dp);
		return 1;
	}
	switch(TYPE(c->qid)){
	case Qtopdir:
		if(s < thiwat){
			q.path = QID(s, Qconvdir);
			q.type = QTDIR;
			ts = tstate[s];
			nm = ts != 0 ? ts->user : eve;
			snprint(up->genbuf, sizeof(up->genbuf), "%d", s);
			devdir(c, q, up->genbuf, 0, nm, DMDIR|0555, dp);
			return 1;
		}
		if(s > thiwat)
			return -1;
		/* fall through */
	case Qclonus:
		q.path = QID(0, Qclonus);
		devdir(c, q, "clone", 0, eve, 0666, dp);
		return 1;
	case Qconvdir:
		ts = tstate[CONV(c->qid)];
		nm = ts != 0 ? ts->user : eve;
		switch(s){
		default:
			return -1;
		case 0:
			q.path = QID(CONV(c->qid), Qctl);
			p = "ctl";
			break;
		case 1:
			q.path = QID(CONV(c->qid), Qdata);
			p = "data";
			break;
		case 2:
			q.path = QID(CONV(c->qid), Qstatus);
			p = "status";
			break;
		}
		devdir(c, q, p, 0, nm, 0660, dp);
		return 1;
	}
	return -1;
}

static void
tlsinit(void)
{
	if((tstate = malloc(sizeof(Tstate*) * maxtstate)) == 0)
		panic("tlsinit");
}

static Chan*
tlsattach(char *spec)
{
	Chan *c;

	c = devattach('T', spec);
	c->qid.path = QID(0, Qtopdir);
	c->qid.vers = 0;
	c->qid.type = QTDIR;
	return c;
}

static Walkqid*
tlswalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, 0, 0, tlsgen);
}

static int
tlsstat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, 0, 0, tlsgen);
}

static Chan*
tlsopen(Chan *c, int omode)
{
	Tstate *s, **pp;
	int perm;

	perm = 0;
	omode &= 3;
	switch(omode){
	case OREAD:	perm = 4; break;
	case OWRITE:	perm = 2; break;
	case ORDWR:	perm = 6; break;
	}

	switch(TYPE(c->qid)){
	default:
		panic("tlsopen");
	case Qtopdir:
	case Qconvdir:
		if(omode != OREAD)
			error(Eperm);
		break;
	case Qclonus:
		tsclone(c);
		break;
	case Qctl:
	case Qdata:
	case Qstatus:
		if(waserror()){
			unlock(&tlslock);
			nexterror();
		}
		lock(&tlslock);
		pp = &tstate[CONV(c->qid)];
		s = *pp;
		if(s == 0)
			tsnew(c, pp);
		else{
			if((perm & (s->perm>>6)) != perm
			   && (strcmp(up->env->user, s->user) != 0
			     || (perm & s->perm) != perm))
				error(Eperm);
			s->ref++;
		}
		unlock(&tlslock);
		poperror();
		break;
	}
	c->mode = openmode(omode);
	c->flag |= COPEN;
	c->offset = 0;
	return c;
}

static void
tlshangup(Tstate *s)
{
	if(s->inited){
		if(s->handshaken)
			mbedtls_ssl_close_notify(&s->ssl);
		mbedtls_ssl_free(&s->ssl);
		mbedtls_ssl_config_free(&s->conf);
		mbedtls_ctr_drbg_free(&s->drbg);
		mbedtls_entropy_free(&s->entropy);
		mbedtls_x509_crt_free(&s->cacert);
		s->inited = 0;
	}
	if(s->rb != nil){
		freeblist(s->rb);
		s->rb = nil;
	}
}

static void
tlsclose(Chan *c)
{
	Tstate *s;
	int i;

	switch(TYPE(c->qid)){
	case Qctl:
	case Qdata:
	case Qstatus:
		if((c->flag & COPEN) == 0)
			break;
		s = tstate[CONV(c->qid)];
		if(s == 0)
			break;
		lock(&tlslock);
		if(--s->ref > 0){
			unlock(&tlslock);
			break;
		}
		tstate[CONV(c->qid)] = 0;
		unlock(&tlslock);

		tlshangup(s);
		if(s->c)
			cclose(s->c);
		free(s->user);
		free(s->cafile);
		for(i = 0; s->alpn[i] != nil; i++)
			free(s->alpn[i]);
		free(s);
	}
}

static long
tlsread(Chan *c, void *a, long n, vlong off)
{
	Tstate *s;
	char buf[256];
	int ret;

	USED(off);
	if(c->qid.type & QTDIR)
		return devdirread(c, a, n, 0, 0, tlsgen);

	s = tstate[CONV(c->qid)];
	if(s == 0)
		error(Ebadusefd);

	switch(TYPE(c->qid)){
	case Qstatus:
		if(s->handshaken)
			snprint(buf, sizeof(buf), "%s %s verify=0x%lux\n",
				mbedtls_ssl_get_version(&s->ssl),
				mbedtls_ssl_get_ciphersuite(&s->ssl),
				(ulong)s->verifyflags);
		else
			snprint(buf, sizeof(buf), "incomplete\n");
		return readstr(off, a, n, buf);
	case Qctl:
		/* reading the ctl/clone fd yields the conversation number */
		snprint(buf, sizeof(buf), "%ld", (long)CONV(c->qid));
		return readstr(off, a, n, buf);
	case Qdata:
		dohandshake(s);
		for(;;){
			ret = mbedtls_ssl_read(&s->ssl, a, n);
			if(ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
				continue;
			if(ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
				return 0;
			if(ret < 0){
				mbedtls_strerror(ret, s->err, sizeof(s->err));
				error(s->err);
			}
			return ret;
		}
	}
	error(Ebadusefd);
	return -1;
}

static long
tlswrite(Chan *c, void *a, long n, vlong off)
{
	Tstate *s;
	char buf[300], *p, *fld;
	int ret, sofar, i;

	USED(off);
	s = tstate[CONV(c->qid)];
	if(s == 0)
		error(Ebadusefd);

	switch(TYPE(c->qid)){
	case Qdata:
		dohandshake(s);
		sofar = 0;
		while(sofar < n){
			ret = mbedtls_ssl_write(&s->ssl, (uchar*)a + sofar, n - sofar);
			if(ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
				continue;
			if(ret < 0){
				mbedtls_strerror(ret, s->err, sizeof(s->err));
				error(s->err);
			}
			sofar += ret;
		}
		return n;
	case Qctl:
		break;
	default:
		error(Ebadusefd);
	}

	/* ctl command parsing */
	if(n >= sizeof(buf))
		error(Ebadarg);
	strncpy(buf, a, n);
	buf[n] = 0;
	p = strchr(buf, '\n');
	if(p)
		*p = 0;
	p = strchr(buf, ' ');
	if(p)
		*p++ = 0;

	if(strcmp(buf, "fd") == 0){
		s->c = buftochan(p);
	}else if(strcmp(buf, "servername") == 0 && p != 0){
		strncpy(s->servername, p, sizeof(s->servername)-1);
		s->servername[sizeof(s->servername)-1] = 0;
	}else if(strcmp(buf, "cafile") == 0 && p != 0){
		kstrdup(&s->cafile, p);
	}else if(strcmp(buf, "verify") == 0 && p != 0){
		if(strcmp(p, "off") == 0)
			s->verify = MBEDTLS_SSL_VERIFY_NONE;
		else if(strcmp(p, "optional") == 0)
			s->verify = MBEDTLS_SSL_VERIFY_OPTIONAL;
		else
			s->verify = MBEDTLS_SSL_VERIFY_REQUIRED;
	}else if(strcmp(buf, "alpn") == 0 && p != 0){
		for(i = 0; s->alpn[i] != nil; i++){
			free(s->alpn[i]);
			s->alpn[i] = nil;
		}
		i = 0;
		while(p != nil && i < Maxalpn){
			fld = p;
			p = strchr(p, ' ');
			if(p)
				*p++ = 0;
			if(*fld){
				s->alpn[i] = nil;
				kstrdup(&s->alpn[i], fld);
				i++;
			}
		}
		s->alpn[i] = nil;
	}else if(strcmp(buf, "handshake") == 0){
		dohandshake(s);
	}else
		error(Ebadarg);

	return n;
}

static Chan*
buftochan(char *p)
{
	Chan *c;
	int fd;

	if(p == 0)
		error(Ebadarg);
	fd = strtoul(p, 0, 0);
	if(fd < 0)
		error(Ebadarg);
	c = fdtochan(up->env->fgrp, fd, -1, 0, 1);	/* error check + incref */
	return c;
}

static void
tsnew(Chan *ch, Tstate **pp)
{
	Tstate *s;
	int t;

	*pp = s = mallocz(sizeof(*s), 1);
	if(s == nil)
		error(Enomem);
	if(pp - tstate >= thiwat)
		thiwat++;
	s->state = Tincomplete;
	s->ref = 1;
	s->verify = DEFVERIFY;
	kstrdup(&s->user, up->env->user);
	s->perm = 0660;
	t = TYPE(ch->qid);
	if(t == Qclonus)
		t = Qctl;
	ch->qid.path = QID(pp - tstate, t);
	ch->qid.vers = 0;
	ch->qid.type = QTFILE;
}

static void
tsclone(Chan *ch)
{
	Tstate **pp, **ep, **np;
	int newmax;

	lock(&tlslock);
	if(waserror()){
		unlock(&tlslock);
		nexterror();
	}
	ep = &tstate[maxtstate];
	for(pp = tstate; pp < ep; pp++)
		if(*pp == 0){
			tsnew(ch, pp);
			break;
		}
	if(pp >= ep){
		if(maxtstate >= Maxtstate)
			error(Enodev);
		newmax = 2 * maxtstate;
		if(newmax > Maxtstate)
			newmax = Maxtstate;
		np = realloc(tstate, sizeof(Tstate*) * newmax);
		if(np == 0)
			error(Enomem);
		tstate = np;
		pp = &tstate[maxtstate];
		memset(pp, 0, sizeof(Tstate*)*(newmax - maxtstate));
		maxtstate = newmax;
		tsnew(ch, pp);
	}
	poperror();
	unlock(&tlslock);
}

static int
tlswstat(Chan *c, uchar *db, int n)
{
	Dir *dir;
	Tstate *s;
	int m;

	s = tstate[CONV(c->qid)];
	if(s == 0)
		error(Ebadusefd);
	if(strcmp(s->user, up->env->user) != 0)
		error(Eperm);
	dir = smalloc(sizeof(Dir)+n);
	m = convM2D(db, n, &dir[0], (char*)&dir[1]);
	if(m == 0){
		free(dir);
		error(Eshortstat);
	}
	if(!emptystr(dir->uid))
		kstrdup(&s->user, dir->uid);
	if(dir->mode != ~0UL)
		s->perm = dir->mode;
	free(dir);
	return m;
}

Dev tlsdevtab = {
	'T',
	"tls",

	tlsinit,
	devinit,
	devshutdown,
	tlsattach,
	tlswalk,
	tlsstat,
	tlsopen,
	devcreate,
	tlsclose,
	tlsread,
	devbread,
	tlswrite,
	devbwrite,
	devremove,
	tlswstat
};
