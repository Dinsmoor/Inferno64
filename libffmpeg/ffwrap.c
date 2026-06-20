/*
 * ffwrap.c -- Inferno glue for the vendored FFmpeg decode build
 * (libffmpeg/ffmpeg-<ver>, LGPL v2.1+; unpacked and built by buildffmpeg.sh).
 *
 * This is the ONLY translation unit that pulls in the FFmpeg headers.  Like
 * stbwrap.c / webpwrap.c, it is plain ISO C and must NOT include Inferno's
 * lib9.h -- it sees only libc and the FFmpeg public headers.  The Inferno side
 * (libinterp/ffmpeg.c) declares the handful of ffwrap_* prototypes itself, so
 * the two header worlds never mix.
 *
 * It exposes a tiny video-decode API: open a file (by path) or an in-memory
 * buffer, pull frames one at a time, each scaled (via swscale) to 8-bit RGBA --
 * 4 channels, top-to-bottom, byte order R,G,B,A per pixel.  That is exactly the
 * pixel layout of a Draw ABGR32 image, so a frame can be written straight into
 * one with writepixels and no reordering (the same contract imageio uses).
 *
 * The decoder, the AVFrame scratch, and one RGBA frame buffer all live here in
 * C memory, off the back of a GC handle on the Limbo side -- so an open video
 * costs ONE frame of Dis heap at a time, not the whole stream (the Dis arena is
 * only ~32 MB).
 */

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/log.h>
#include <libswscale/swscale.h>

/*
 * FFmpeg logs to stderr by default, which in emu lands on the Limbo console
 * (e.g. swscale's harmless "no accelerated colorspace conversion" note for our
 * no-SIMD build).  Pin it to fatal-only once, on first open, so a decode is
 * silent unless something is actually wrong.
 */
static void
ffwrap_init(void)
{
	static int done = 0;
	if(!done){
		av_log_set_level(AV_LOG_FATAL);
		done = 1;
	}
}

/*
 * Hard ceilings on decoded geometry.  Video comes from untrusted sources, so
 * cap dimensions before we ever allocate a frame: 8192 per side, 64 Mpx area
 * (= 256 MB RGBA) -- the same spirit as webpwrap's caps.
 */
#define FF_MAX_DIM	8192
#define FF_MAX_AREA	(64L * 1024 * 1024)

typedef struct Ffvideo Ffvideo;
struct Ffvideo {
	AVFormatContext	*fmt;
	AVCodecContext	*dec;
	struct SwsContext *sws;
	AVPacket	*pkt;
	AVFrame		*frame;		/* native-format decoded frame */
	int		vstream;	/* index of the chosen video stream */

	/* in-memory source (NULL for a path open); freed in ffwrap_close */
	AVIOContext	*avio;
	unsigned char	*ioblk;		/* avio's working buffer */
	unsigned char	*memdata;	/* OWNED copy of the caller's bytes */
	long		memlen;
	long		mempos;

	/*
	 * Optional caller-supplied source (e.g. an Inferno-namespace file read via
	 * the kernel ops, kept out of this TU which must not see lib9.h).  When set,
	 * these back the AVIO instead of memdata; the opaque is passed through and a
	 * close hook lets the caller release its handle in ffwrap_close.
	 */
	int		(*cb_read)(void *opaque, unsigned char *buf, int len);
	int64_t		(*cb_seek)(void *opaque, int64_t off, int whence);
	void		(*cb_close)(void *opaque);
	void		*cb_opaque;

	int		maxw, maxh;	/* fit ceiling (0 = none); set before open_common */
	int		w, h;		/* output dimensions (coded, or fitted down) */
	unsigned char	*rgba;		/* w*h*4, reused frame to frame */
	long		rgbasize;

	double		tb;		/* video stream time_base as seconds */
};

/* ---- in-memory AVIO callbacks -------------------------------------------- */

static int
mem_read(void *opaque, unsigned char *buf, int want)
{
	Ffvideo *v = (Ffvideo*)opaque;
	long avail = v->memlen - v->mempos;
	if(avail <= 0)
		return AVERROR_EOF;
	if(want > avail)
		want = (int)avail;
	memcpy(buf, v->memdata + v->mempos, (size_t)want);
	v->mempos += want;
	return want;
}

static int64_t
mem_seek(void *opaque, int64_t off, int whence)
{
	Ffvideo *v = (Ffvideo*)opaque;
	long np;
	if(whence == AVSEEK_SIZE)
		return v->memlen;
	whence &= ~AVSEEK_FORCE;
	switch(whence){
	case 0:	np = (long)off; break;			/* SEEK_SET */
	case 1:	np = v->mempos + (long)off; break;	/* SEEK_CUR */
	case 2:	np = v->memlen + (long)off; break;	/* SEEK_END */
	default: return AVERROR(EINVAL);
	}
	if(np < 0 || np > v->memlen)
		return AVERROR(EINVAL);
	v->mempos = np;
	return np;
}

/* ---- caller-supplied (e.g. Inferno-file) AVIO trampolines ---------------- */

static int
cb_read_tramp(void *opaque, unsigned char *buf, int want)
{
	Ffvideo *v = (Ffvideo*)opaque;
	int n = v->cb_read(v->cb_opaque, buf, want);
	if(n <= 0)
		return AVERROR_EOF;		/* 0 or error -> EOF to the demuxer */
	return n;
}

static int64_t
cb_seek_tramp(void *opaque, int64_t off, int whence)
{
	Ffvideo *v = (Ffvideo*)opaque;
	return v->cb_seek(v->cb_opaque, off, whence);
}

/* ---- teardown ------------------------------------------------------------ */

void
ffwrap_close(Ffvideo *v)
{
	if(v == 0)
		return;
	if(v->sws != 0)
		sws_freeContext(v->sws);
	if(v->frame != 0)
		av_frame_free(&v->frame);
	if(v->pkt != 0)
		av_packet_free(&v->pkt);
	if(v->dec != 0)
		avcodec_free_context(&v->dec);
	if(v->fmt != 0)
		avformat_close_input(&v->fmt);
	/*
	 * The buffer we handed to avio_alloc_context is owned by the AVIOContext
	 * thereafter, and FFmpeg may have swapped it for a larger one (e.g.
	 * ffio_rewind_with_probe_data), freeing our original.  So free whatever
	 * the context currently points at -- never our stale v->ioblk pointer.
	 */
	if(v->avio != 0){
		av_freep(&v->avio->buffer);
		avio_context_free(&v->avio);
	}
	if(v->memdata != 0)
		free(v->memdata);
	if(v->cb_close != 0)
		v->cb_close(v->cb_opaque);	/* release the caller's source handle */
	if(v->rgba != 0)
		free(v->rgba);
	free(v);
}

/* ---- open: shared tail after fmt context is created and input opened ----- */

static Ffvideo*
open_common(Ffvideo *v, const char **err)
{
	const AVCodec *codec;
	AVStream *st;
	int i, rc;

	if(avformat_find_stream_info(v->fmt, 0) < 0){
		if(err != 0) *err = "ffmpeg: no stream info";
		ffwrap_close(v);
		return 0;
	}

	v->vstream = -1;
	for(i = 0; i < (int)v->fmt->nb_streams; i++){
		if(v->fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO){
			v->vstream = i;
			break;
		}
	}
	if(v->vstream < 0){
		if(err != 0) *err = "ffmpeg: no video stream";
		ffwrap_close(v);
		return 0;
	}
	st = v->fmt->streams[v->vstream];

	codec = avcodec_find_decoder(st->codecpar->codec_id);
	if(codec == 0){
		if(err != 0) *err = "ffmpeg: no decoder for codec";
		ffwrap_close(v);
		return 0;
	}
	v->dec = avcodec_alloc_context3(codec);
	if(v->dec == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		ffwrap_close(v);
		return 0;
	}
	if(avcodec_parameters_to_context(v->dec, st->codecpar) < 0){
		if(err != 0) *err = "ffmpeg: codec params";
		ffwrap_close(v);
		return 0;
	}
	v->dec->thread_count = 1;	/* keep it single-threaded and portable */
	rc = avcodec_open2(v->dec, codec, 0);
	if(rc < 0){
		if(err != 0) *err = "ffmpeg: cannot open decoder";
		ffwrap_close(v);
		return 0;
	}

	v->w = v->dec->width;
	v->h = v->dec->height;
	if(v->w <= 0 || v->h <= 0 || v->w > FF_MAX_DIM || v->h > FF_MAX_DIM
	|| (long)v->w * v->h > FF_MAX_AREA){
		if(err != 0) *err = "ffmpeg: dimensions out of range";
		ffwrap_close(v);
		return 0;
	}

	/*
	 * Optional fit: if a max box was requested and the coded frame exceeds it,
	 * shrink the OUTPUT dimensions, preserving aspect ratio (never upscale).
	 * scale_out already swscales dec->width/height -> v->w/v->h, so picking a
	 * smaller v->w/v->h here is all it takes -- the native-resolution RGBA is
	 * never materialised, so a 1080p frame costs the Dis side only the fitted
	 * w*h*4 (the same trick imageio's decodefit uses for stills).
	 */
	if(v->maxw > 0 && v->maxh > 0 && (v->w > v->maxw || v->h > v->maxh)){
		double sx = (double)v->maxw / (double)v->w;
		double sy = (double)v->maxh / (double)v->h;
		double s = sx < sy ? sx : sy;
		int nw = (int)(v->w * s + 0.5);
		int nh = (int)(v->h * s + 0.5);
		if(nw < 1) nw = 1;
		if(nh < 1) nh = 1;
		v->w = nw;
		v->h = nh;
	}

	v->pkt = av_packet_alloc();
	v->frame = av_frame_alloc();
	if(v->pkt == 0 || v->frame == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		ffwrap_close(v);
		return 0;
	}

	v->rgbasize = (long)v->w * v->h * 4;
	v->rgba = (unsigned char*)malloc(v->rgbasize);
	if(v->rgba == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		ffwrap_close(v);
		return 0;
	}

	if(st->time_base.den > 0)
		v->tb = (double)st->time_base.num / (double)st->time_base.den;
	else
		v->tb = 0.0;

	if(err != 0)
		*err = 0;
	return v;
}

/*
 * Open a video file by host path.  Returns an opaque handle or NULL with *err
 * set.  (protocol=file is the only protocol the lean build enables.)
 */
Ffvideo*
ffwrap_open_file(const char *path, int maxw, int maxh, const char **err)
{
	Ffvideo *v;

	ffwrap_init();
	if(err != 0) *err = 0;
	if(path == 0 || path[0] == 0){
		if(err != 0) *err = "ffmpeg: empty path";
		return 0;
	}
	v = (Ffvideo*)calloc(1, sizeof(Ffvideo));
	if(v == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		return 0;
	}
	v->maxw = maxw;
	v->maxh = maxh;
	if(avformat_open_input(&v->fmt, path, 0, 0) < 0){
		if(err != 0) *err = "ffmpeg: cannot open file";
		free(v);
		return 0;
	}
	return open_common(v, err);
}

/*
 * Open a video held entirely in memory.  The bytes are COPIED and owned by the
 * handle (freed in ffwrap_close), so the caller's buffer -- e.g. a Dis array
 * the GC may move or collect -- need not outlive this call.
 */
#define FF_IOBLK	(1 << 16)	/* avio working-buffer size */

Ffvideo*
ffwrap_open_mem(const unsigned char *data, long len, int maxw, int maxh, const char **err)
{
	Ffvideo *v;

	ffwrap_init();
	if(err != 0) *err = 0;
	if(data == 0 || len <= 0){
		if(err != 0) *err = "ffmpeg: no data";
		return 0;
	}
	v = (Ffvideo*)calloc(1, sizeof(Ffvideo));
	if(v == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		return 0;
	}
	v->maxw = maxw;
	v->maxh = maxh;
	v->memdata = (unsigned char*)malloc((size_t)len);
	if(v->memdata == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		free(v);
		return 0;
	}
	memcpy(v->memdata, data, (size_t)len);
	v->memlen = len;
	v->mempos = 0;

	v->ioblk = (unsigned char*)av_malloc(FF_IOBLK);
	if(v->ioblk == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		free(v);
		return 0;
	}
	v->avio = avio_alloc_context(v->ioblk, FF_IOBLK, 0, v,
		mem_read, 0, mem_seek);
	if(v->avio == 0){
		av_free(v->ioblk);
		if(err != 0) *err = "ffmpeg: out of memory";
		free(v);
		return 0;
	}
	v->fmt = avformat_alloc_context();
	if(v->fmt == 0){
		avio_context_free(&v->avio);
		av_free(v->ioblk);
		if(err != 0) *err = "ffmpeg: out of memory";
		free(v);
		return 0;
	}
	v->fmt->pb = v->avio;
	v->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;

	if(avformat_open_input(&v->fmt, 0, 0, 0) < 0){
		/* avformat_open_input freed v->fmt on failure */
		v->fmt = 0;
		if(err != 0) *err = "ffmpeg: cannot open stream";
		ffwrap_close(v);
		return 0;
	}
	return open_common(v, err);
}

/*
 * Open a video from a caller-supplied seekable source: the decoder pulls bytes
 * on demand through read/seek (whose semantics mirror FFmpeg's AVIO -- read
 * returns the byte count or <=0 at EOF; seek honours SEEK_SET/CUR/END and
 * AVSEEK_SIZE).  Nothing is copied into this handle, so the whole encoded
 * stream never has to be resident -- the Inferno side backs these with the
 * kernel file ops (kread/kseek) on a namespace file, which works the same on
 * emu and the native kernel.  On close, cb_close(opaque) is called so the
 * caller can release its handle.  maxw/maxh fit as in the other openers.
 */
Ffvideo*
ffwrap_open_cb(
	int (*read)(void *opaque, unsigned char *buf, int len),
	int64_t (*seek)(void *opaque, int64_t off, int whence),
	void (*close)(void *opaque),
	void *opaque, int maxw, int maxh, const char **err)
{
	Ffvideo *v;

	ffwrap_init();
	if(err != 0) *err = 0;
	if(read == 0 || seek == 0){
		if(err != 0) *err = "ffmpeg: no source callbacks";
		return 0;
	}
	v = (Ffvideo*)calloc(1, sizeof(Ffvideo));
	if(v == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		return 0;
	}
	v->cb_read = read;
	v->cb_seek = seek;
	v->cb_close = close;
	v->cb_opaque = opaque;
	v->maxw = maxw;
	v->maxh = maxh;

	v->ioblk = (unsigned char*)av_malloc(FF_IOBLK);
	if(v->ioblk == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		ffwrap_close(v);
		return 0;
	}
	v->avio = avio_alloc_context(v->ioblk, FF_IOBLK, 0, v,
		cb_read_tramp, 0, cb_seek_tramp);
	if(v->avio == 0){
		av_free(v->ioblk);
		v->ioblk = 0;
		if(err != 0) *err = "ffmpeg: out of memory";
		ffwrap_close(v);
		return 0;
	}
	v->fmt = avformat_alloc_context();
	if(v->fmt == 0){
		if(err != 0) *err = "ffmpeg: out of memory";
		ffwrap_close(v);
		return 0;
	}
	v->fmt->pb = v->avio;
	v->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;

	if(avformat_open_input(&v->fmt, 0, 0, 0) < 0){
		v->fmt = 0;
		if(err != 0) *err = "ffmpeg: cannot open stream";
		ffwrap_close(v);
		return 0;
	}
	return open_common(v, err);
}

/* ---- geometry / metadata accessors --------------------------------------- */

int ffwrap_width(Ffvideo *v)  { return v ? v->w : 0; }
int ffwrap_height(Ffvideo *v) { return v ? v->h : 0; }

/* Stream duration in ms (0 if unknown). */
long
ffwrap_duration_ms(Ffvideo *v)
{
	if(v == 0 || v->fmt == 0 || v->fmt->duration == AV_NOPTS_VALUE)
		return 0;
	return (long)(v->fmt->duration / (AV_TIME_BASE / 1000));
}

/* Average frame rate * 1000 (so 29.97 fps -> 29970), 0 if unknown. */
long
ffwrap_fps_milli(Ffvideo *v)
{
	AVRational r;
	if(v == 0 || v->fmt == 0 || v->vstream < 0)
		return 0;
	r = v->fmt->streams[v->vstream]->avg_frame_rate;
	if(r.den == 0)
		return 0;
	return (long)((double)r.num * 1000.0 / (double)r.den);
}

/* ---- frame pull ---------------------------------------------------------- */

static int
scale_out(Ffvideo *v)
{
	const uint8_t *src[4];
	int srcstride[4];
	uint8_t *dst[1];
	int dststride[1];
	int i;

	v->sws = sws_getCachedContext(v->sws,
		v->dec->width, v->dec->height, v->dec->pix_fmt,
		v->w, v->h, AV_PIX_FMT_RGBA,
		SWS_BILINEAR, 0, 0, 0);
	if(v->sws == 0)
		return -1;

	for(i = 0; i < 4; i++){
		src[i] = v->frame->data[i];
		srcstride[i] = v->frame->linesize[i];
	}
	dst[0] = v->rgba;
	dststride[0] = v->w * 4;
	sws_scale(v->sws, src, srcstride, 0, v->dec->height, dst, dststride);
	return 0;
}

/*
 * Decode and return the next video frame as 8-bit RGBA in v->rgba (top-to-
 * bottom, R,G,B,A).  Returns:
 *    1  a frame was produced; *pts_ms = its presentation time in ms (>= 0),
 *       *rgba = the (reused) frame buffer, *len = w*h*4.
 *    0  clean end of stream (no more frames).
 *   -1  decode error; *err set.
 * The returned buffer is owned by the handle and overwritten on the next call.
 */
int
ffwrap_next_frame(Ffvideo *v, long *pts_ms, unsigned char **rgba, long *len,
	const char **err)
{
	int rc;
	int64_t pts;

	if(err != 0) *err = 0;
	if(rgba != 0) *rgba = 0;
	if(len != 0) *len = 0;
	if(pts_ms != 0) *pts_ms = 0;
	if(v == 0){
		if(err != 0) *err = "ffmpeg: nil handle";
		return -1;
	}

	for(;;){
		rc = avcodec_receive_frame(v->dec, v->frame);
		if(rc == 0){
			if(scale_out(v) < 0){
				if(err != 0) *err = "ffmpeg: scale failed";
				return -1;
			}
			pts = v->frame->best_effort_timestamp;
			if(pts == AV_NOPTS_VALUE)
				pts = v->frame->pts;
			if(pts_ms != 0){
				if(pts == AV_NOPTS_VALUE || v->tb == 0.0)
					*pts_ms = 0;
				else
					*pts_ms = (long)(pts * v->tb * 1000.0);
			}
			if(rgba != 0) *rgba = v->rgba;
			if(len != 0) *len = v->rgbasize;
			av_frame_unref(v->frame);
			return 1;
		}
		if(rc == AVERROR_EOF)
			return 0;
		if(rc != AVERROR(EAGAIN)){
			if(err != 0) *err = "ffmpeg: decode error";
			return -1;
		}

		/* need to feed more packets from the chosen video stream */
		for(;;){
			rc = av_read_frame(v->fmt, v->pkt);
			if(rc < 0){
				/* flush the decoder at end of input */
				avcodec_send_packet(v->dec, 0);
				break;
			}
			if(v->pkt->stream_index != v->vstream){
				av_packet_unref(v->pkt);
				continue;
			}
			rc = avcodec_send_packet(v->dec, v->pkt);
			av_packet_unref(v->pkt);
			if(rc < 0 && rc != AVERROR(EAGAIN)){
				if(err != 0) *err = "ffmpeg: send packet failed";
				return -1;
			}
			break;
		}
	}
}

/*
 * Seek to the keyframe at or before t_ms and flush the decoder, so the next
 * ffwrap_next_frame starts decoding from there.  Returns 0 on success, -1 with
 * *err set.  (Best-effort: the first frame after a seek may precede t_ms.)
 */
int
ffwrap_seek_ms(Ffvideo *v, long t_ms, const char **err)
{
	int64_t ts;

	if(err != 0) *err = 0;
	if(v == 0 || v->fmt == 0){
		if(err != 0) *err = "ffmpeg: nil handle";
		return -1;
	}
	if(t_ms < 0)
		t_ms = 0;
	ts = (int64_t)t_ms * (AV_TIME_BASE / 1000);
	if(avformat_seek_file(v->fmt, -1, INT64_MIN, ts, ts, AVSEEK_FLAG_BACKWARD) < 0){
		if(err != 0) *err = "ffmpeg: seek failed";
		return -1;
	}
	avcodec_flush_buffers(v->dec);
	return 0;
}
