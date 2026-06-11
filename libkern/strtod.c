#include <lib9.h>

static int
strtodf(void *vp)
{
	return *(*((char**)vp))++;
}

double
strtod(const char *cs, char **end)
{
	double d;
	char *s, *ss;
	int c;

	s = (char*)cs;
	ss = s;
	d = charstod(strtodf, &s);
	/*
	 * Fix cases like 2.3e+ , which charstod will consume
	 */
	if(end){
		*end = --s;
		while(s > ss){
			c = *--s;
			if(c!='-' && c!='+' && c!='e' && c!='E')
				break;
			(*end)--;
		}
	}
	return d;
}
