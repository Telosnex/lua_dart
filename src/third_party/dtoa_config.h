// Configuration of dtoa.c for lua_dart. Adapted from dtoa_config.h of
// lua-cjson (MIT, Copyright (c) 2010-2012 Mark Pulford).
#ifndef LUADART_DTOA_CONFIG_H
#define LUADART_DTOA_CONFIG_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

// The functions of dtoa.c, renamed: dtoa.c must not replace strtod of libc.
#define fpconv_strtod luadart_strtod
#define dtoa luadart_dtoa
#define dtoa_r luadart_dtoa_r
#define freedtoa luadart_freedtoa
#define gethex luadart_gethex

// No locale, no errno.
#undef USE_LOCALE
#define NO_ERRNO
// No static memory pool shared by threads (see the TI0 change).
#define Omit_Private_Memory

#define Long int32_t
#define ULong uint32_t
#define Llong int64_t
#define ULLong uint64_t

// Every lua_dart target is little-endian IEEE 754.
#define IEEE_8087

#endif
