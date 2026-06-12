/*
 * minimal screen.h for devdraw/devpointer: ramfb has no hardware
 * cursor or colormap, so this is just the types the port code names.
 */
typedef struct Cursor Cursor;

struct Cursor {
	Point	offset;
	uchar	clr[2*16];
	uchar	set[2*16];
};

extern Memimage *gscreen;

uchar*	attachscreen(Rectangle*, ulong*, int*, int*, int*);
void	detachscreen(void);
void	flushmemscreen(Rectangle);
void	blankscreen(int);
