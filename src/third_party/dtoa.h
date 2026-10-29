// The functions of dtoa.c that lua_dart uses (see dtoa_config.h).
#ifndef LUADART_DTOA_H
#define LUADART_DTOA_H

double luadart_strtod(const char* s, char** end);
// mode 0: the shortest digits that read back as d. *decpt: the position of
// the decimal point; 9999 for Infinity or NaN. Free with luadart_freedtoa.
char* luadart_dtoa(double d, int mode, int ndigits, int* decpt, int* sign,
                   char** end);
void luadart_freedtoa(char* s);

#endif
