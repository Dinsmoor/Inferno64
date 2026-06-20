typedef struct{char *name; long sig; void (*fn)(void*); int size; int np; uchar map[16];} Runtab;
Runtab Ffmpegmodtab[]={
	"Vid.close",0xffffffffec2399df,Vid_close,72,2,{0x0,0x80,},
	"Vid.frame",0x24f3b563,Vid_frame,72,2,{0x0,0x80,},
	"open",0xffffffff91a0cc26,Ffmpeg_open,72,2,{0x0,0x80,},
	"openbytes",0xffffffffce21a40a,Ffmpeg_openbytes,72,2,{0x0,0x80,},
	"openbytesfit",0xffffffff8e948afd,Ffmpeg_openbytesfit,80,2,{0x0,0x80,},
	"openfit",0xffffffff8c0802a9,Ffmpeg_openfit,80,2,{0x0,0x80,},
	"openstream",0xffffffff8c0802a9,Ffmpeg_openstream,80,2,{0x0,0x80,},
	"Vid.seek",0x4206d406,Vid_seek,80,2,{0x0,0x80,},
	0
};
#define Ffmpegmodlen	8
