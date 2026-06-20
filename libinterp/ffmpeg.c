#include <lib9.h>
#include <kernel.h>
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "ffmpegmod.h"

/*
 * Limbo face of the native video decoder.  The codec work lives in libffmpeg
 * (ffwrap.c wrapping the vendored FFmpeg libav / libsw archives); this file only
 * marshals Limbo arguments and has no Draw/Memimage dependency at all -- it
 * hands back raw RGBA bytes a frame at a time and lets Limbo build the image
 * (exactly like imageio.c does for still images).
 *
 * The ffwrap_* prototypes are declared here (not via a header) so the FFmpeg
 * world and the Inferno (lib9.h) world never share a translation unit -- ffwrap.c
 * sees only libc + the FFmpeg headers, this file sees only lib9.h + Inferno.
 */
typedef struct Ffvideo Ffvideo;	/* opaque on this side */

extern Ffvideo*	ffwrap_open_file(const char *path, int maxw, int maxh, const char **err);
extern Ffvideo*	ffwrap_open_mem(const uchar *data, long len, int maxw, int maxh, const char **err);
extern Ffvideo*	ffwrap_open_cb(
			int (*read)(void *opaque, uchar *buf, int len),
			vlong (*seek)(void *opaque, vlong off, int whence),
			void (*close)(void *opaque),
			void *opaque, int maxw, int maxh, const char **err);
extern void	ffwrap_close(Ffvideo *v);
extern int	ffwrap_width(Ffvideo *v);
extern int	ffwrap_height(Ffvideo *v);
extern long	ffwrap_duration_ms(Ffvideo *v);
extern long	ffwrap_fps_milli(Ffvideo *v);
extern int	ffwrap_next_frame(Ffvideo *v, long *pts_ms, uchar **rgba, long *len, const char **err);
extern int	ffwrap_seek_ms(Ffvideo *v, long t_ms, const char **err);

/*
 * An open video.  The Limbo-visible part (Ffmpeg_Vid: w,h,durationms,fpsmilli --
 * all ints, so the GC map is empty) sits at the front; the FFmpeg decoder hangs
 * off the back in C memory, kept out of the small Dis heap.  frame() decodes one
 * frame and copies it into the Dis heap on demand; freevid (the dtype finalizer)
 * and close() release the decoder.
 */
typedef struct Vid Vid;
struct Vid {
	Ffmpeg_Vid	x;	/* limbo-visible part */
	Ffvideo		*ff;	/* the FFmpeg decoder (C memory) */
};

Type*	TVid;
static uchar	Vidmap[] = Ffmpeg_Vid_map;

static void	freevid(Heap*, int);
static Vid*	ckvid(Ffmpeg_Vid*);

static void
vidfree(Vid *v)
{
	if(v->ff != nil){
		ffwrap_close(v->ff);
		v->ff = nil;
	}
}

/*
 * dtype finalizer.  The Limbo part holds no Dis references, so there is nothing
 * to freeptrs; the C decoder, however, must be released whether the heap is
 * being swept or refcount-collected, since it lives outside the Dis heap.
 */
static void
freevid(Heap *h, int swept)
{
	Vid *v = H2D(Vid*, h);

	USED(swept);
	vidfree(v);
}

static Vid*
ckvid(Ffmpeg_Vid *lv)
{
	if(lv == nil || lv == H)
		error("nil Vid");
	if(D2H(lv)->t != TVid)
		error(exType);
	return (Vid*)lv;
}

void
ffmpegmodinit(void)
{
	builtinmod("$Ffmpeg", Ffmpegmodtab, Ffmpegmodlen);
	TVid = dtype(freevid, sizeof(Vid), Vidmap, sizeof(Vidmap));
}

/*
 * Build a (ref Vid, string) result from an opened Ffvideo (or an error).  The
 * two return slots are passed individually because Ffmpeg_open and
 * Ffmpeg_openbytes have distinct (anonymous) ret-tuple types in runt.h.
 */
static void
retvid(Ffmpeg_Vid **t0, String **t1, Ffvideo *ff, const char *err)
{
	Heap *h;
	Vid *v;

	*t0 = H;
	*t1 = H;

	if(ff == nil){
		if(err == nil)
			err = "ffmpeg: open failed";
		*t1 = c2string((char*)err, strlen((char*)err));
		return;
	}

	h = heapz(TVid);
	if(h == H){
		ffwrap_close(ff);
		*t1 = c2string(exNomem, strlen(exNomem));
		return;
	}
	v = H2D(Vid*, h);
	v->ff = ff;
	v->x.w = ffwrap_width(ff);
	v->x.h = ffwrap_height(ff);
	v->x.durationms = (WORD)ffwrap_duration_ms(ff);
	v->x.fpsmilli = (WORD)ffwrap_fps_milli(ff);

	*t0 = (Ffmpeg_Vid*)v;
}

/*
 * Shared body for open / openfit: open a host path, optionally fitting the
 * decoded frame into maxw x maxh (0,0 = native resolution).
 */
static void
openpath(String *spath, int maxw, int maxh, Ffmpeg_Vid **t0, String **t1)
{
	Ffvideo *ff;
	const char *err;
	char *path;

	if(spath == H){
		*t0 = H;
		*t1 = c2string("empty path", 10);
		return;
	}
	path = strdup(string2c(spath));		/* string2c() can call error() */
	if(path == nil)
		error(exNomem);

	err = nil;
	ff = ffwrap_open_file(path, maxw, maxh, &err);
	free(path);
	retvid(t0, t1, ff, err);
}

static void
openmem(Array *data, int maxw, int maxh, Ffmpeg_Vid **t0, String **t1)
{
	Ffvideo *ff;
	const char *err;

	if(data == H){
		*t0 = H;
		*t1 = c2string("no data", 7);
		return;
	}
	err = nil;
	ff = ffwrap_open_mem(data->data, data->len, maxw, maxh, &err);
	retvid(t0, t1, ff, err);
}

/*
 * Streaming source backed by an Inferno-namespace file.  The decoder pulls
 * bytes on demand through the kernel file ops (kread/kseek/kclose), so the whole
 * encoded video is never resident -- only one fitted frame ever reaches the Dis
 * heap.  Using the kernel ops (not host libc) keeps this working unchanged on
 * the native kernel, and reads through the Inferno namespace just like the rest
 * of the system.  The source is a file in Inferno's own filesystem (e.g. a ram
 * fs under /tmp), NOT the host filesystem.
 *
 * These callbacks run from inside FFmpeg, with the VM lock released (see
 * openstream / Vid_frame), so kread/kseek may block without stalling the GC.
 * The opaque is a bare malloc (libc), nothing on the Dis heap.
 */
#define FF_AVSEEK_SIZE	0x10000		/* matches libavformat/avio.h */
#define FF_AVSEEK_FORCE	0x20000

typedef struct Kfile Kfile;
struct Kfile {
	int	fd;	/* kernel fd, owned here; closed by kfile_close */
};

static int
kfile_read(void *opaque, uchar *buf, int len)
{
	Kfile *k = opaque;
	return (int)kread(k->fd, buf, len);
}

static vlong
kfile_seek(void *opaque, vlong off, int whence)
{
	Kfile *k = opaque;

	whence &= ~FF_AVSEEK_FORCE;
	if(whence == FF_AVSEEK_SIZE){
		Dir *d = kdirfstat(k->fd);
		vlong sz;
		if(d == nil)
			return -1;
		sz = d->length;
		free(d);
		return sz;
	}
	/* whence is SEEK_SET/CUR/END (0/1/2), which kseek takes directly */
	return kseek(k->fd, off, whence);
}

static void
kfile_close(void *opaque)
{
	Kfile *k = opaque;
	if(k->fd >= 0)
		kclose(k->fd);
	free(k);
}

/*
 * Open a video from a path in the Inferno namespace, streaming it through the
 * kernel file ops.  maxw/maxh fit as in the other openers (0,0 = native).
 */
static void
openstream(String *spath, int maxw, int maxh, Ffmpeg_Vid **t0, String **t1)
{
	Ffvideo *ff;
	const char *err;
	char *path;
	Kfile *k;
	int fd;

	if(spath == H){
		*t0 = H;
		*t1 = c2string("empty path", 10);
		return;
	}
	path = strdup(string2c(spath));		/* string2c() can call error() */
	if(path == nil)
		error(exNomem);

	release();
	fd = kopen(path, OREAD);
	acquire();
	free(path);
	if(fd < 0){
		*t0 = H;
		*t1 = c2string("cannot open file", 16);
		return;
	}
	k = malloc(sizeof(Kfile));
	if(k == nil){
		release(); kclose(fd); acquire();
		error(exNomem);
	}
	k->fd = fd;

	err = nil;
	release();
	ff = ffwrap_open_cb(kfile_read, kfile_seek, kfile_close, k, maxw, maxh, &err);
	acquire();
	/* on failure ffwrap_open_cb already called kfile_close (frees k + fd) */
	retvid(t0, t1, ff, err);
}

void
Ffmpeg_open(void *fp)
{
	F_Ffmpeg_open *f = fp;
	openpath(f->path, 0, 0, &f->ret->t0, &f->ret->t1);
}

void
Ffmpeg_openstream(void *fp)
{
	F_Ffmpeg_openstream *f = fp;
	openstream(f->path, f->maxw, f->maxh, &f->ret->t0, &f->ret->t1);
}

void
Ffmpeg_openfit(void *fp)
{
	F_Ffmpeg_openfit *f = fp;
	openpath(f->path, f->maxw, f->maxh, &f->ret->t0, &f->ret->t1);
}

void
Ffmpeg_openbytes(void *fp)
{
	F_Ffmpeg_openbytes *f = fp;
	openmem(f->data, 0, 0, &f->ret->t0, &f->ret->t1);
}

void
Ffmpeg_openbytesfit(void *fp)
{
	F_Ffmpeg_openbytesfit *f = fp;
	openmem(f->data, f->maxw, f->maxh, &f->ret->t0, &f->ret->t1);
}

void
Vid_frame(void *fp)
{
	F_Vid_frame *f = fp;
	Vid *v;
	uchar *rgba;
	long pts, len;
	const char *err;
	int rc;
	Heap *hp;
	Array *a;

	/* default return: (-1, nil, nil) == end of stream */
	f->ret->t0 = -1;
	f->ret->t1 = H;
	f->ret->t2 = H;

	v = ckvid(f->v);
	if(v->ff == nil){
		f->ret->t2 = c2string("video closed", 12);
		return;
	}

	err = nil;
	/*
	 * Decoding a streaming (Inferno-file) source can block in kread, so drop
	 * the VM lock across the decode -- it touches only C memory (the FFmpeg
	 * handle and the malloc'd RGBA buffer), never the Dis heap.  The Dis array
	 * is built afterwards, back under the lock.
	 */
	release();
	rc = ffwrap_next_frame(v->ff, &pts, &rgba, &len, &err);
	acquire();
	if(rc == 0)			/* clean end of stream */
		return;
	if(rc < 0){
		if(err == nil)
			err = "ffmpeg: decode error";
		f->ret->t2 = c2string((char*)err, strlen((char*)err));
		return;
	}

	hp = heaparray(&Tbyte, len);
	if(hp == H){
		f->ret->t2 = c2string(exNomem, strlen(exNomem));
		return;
	}
	a = H2D(Array*, hp);
	memmove(a->data, rgba, len);

	f->ret->t0 = (WORD)pts;
	f->ret->t1 = a;
}

void
Vid_seek(void *fp)
{
	F_Vid_seek *f = fp;
	Vid *v;
	const char *err;
	int rc;

	*f->ret = H;	/* default: nil (success) */

	v = ckvid(f->v);
	if(v->ff == nil){
		*f->ret = c2string("video closed", 12);
		return;
	}
	err = nil;
	release();			/* may block in kseek/kread on a streaming source */
	rc = ffwrap_seek_ms(v->ff, f->tms, &err);
	acquire();
	if(rc < 0){
		if(err == nil)
			err = "ffmpeg: seek failed";
		*f->ret = c2string((char*)err, strlen((char*)err));
	}
}

void
Vid_close(void *fp)
{
	F_Vid_close *f = fp;
	Vid *v;

	v = ckvid(f->v);
	vidfree(v);
	v->x.w = 0;
	v->x.h = 0;
}
