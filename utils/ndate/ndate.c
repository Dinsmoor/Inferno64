#include	<lib9.h>
#include	<time.h>	/* time(2); modern gcc errors on its implicit declaration */

void
main(void)
{
	ulong t;

	t = time(0);
	print("%lud\n", t);
	exits(0);
}
