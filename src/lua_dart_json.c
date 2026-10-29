// The json library of lua_dart: json.decode and json.encode.
//
// The values are those of dart:convert, as a Dart host gets them when it
// converts between Dart and Lua values with the rules below. The structure of
// the decoder (tokens, escapes, depth limit) is from lua_cjson.c of lua-cjson
// (https://github.com/openresty/lua-cjson; MIT license, Copyright (c)
// 2010-2012 Mark Pulford). Numbers use dtoa.c of David M. Gay.
//
// json.decode(s), strict JSON (RFC 8259), as jsonDecode of dart:convert:
// - Invalid JSON raises an error. Whitespace is space, tab, CR, LF only.
// - null is nil: an object member with a null value is absent, and an array
//   with null has a hole. The table of such an array has its raw length
//   preset to the element count.
// - An integer without a fraction or an exponent that fits 64 bits is a Lua
//   integer, else a float. "-0" is the integer 0.
// - An empty array is a table with a metatable { __json_array = true }.
// - Text is UTF-8. Invalid UTF-8 in a string, and an escaped lone UTF-16
//   surrogate, become U+FFFD.
//
// json.encode(v), as jsonEncode of dart:convert, with no spaces:
// - nil is null. An integer, and a float with an integer value in 64 bits,
//   print as an integer. Other floats print as Dart prints a double (the
//   shortest digits; "100000000000000000000.0", "1e+21", "1e-7"). NaN and
//   infinities raise an error.
// - A table is an array if its keys are exactly 1..#t (raw), or if it is
//   empty and its metatable has a true __json_array. Else it is an object.
//   Object keys: strings as they are, numbers as tostring prints them, other
//   keys as "0". If two keys print the same, the object has the key at its
//   first position, with the last value.
// - Invalid UTF-8 becomes U+FFFD. Escapes: \" \\ \b \t \n \f \r, other
//   control characters as \u00xx. "/" and non-ASCII text are not escaped.
// - A function, userdata or thread is the string of its type name.
// - Tables nest at most 1000 deep; a cycle raises an error.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lua_dart.h"
#include "lua_dart_json.h"
#include "third_party/dtoa.h"

#define JSON_MAX_DEPTH 1000

// --- Buffer ---------------------------------------------------------------
//
// The memory is a userdata at a fixed stack index, so a Lua error (for
// example out of memory) frees it, and the buffer can grow while other values
// are on the stack.

typedef struct {
  lua_State* L;
  int box;
  char* data;
  size_t len;
  size_t cap;
} jbuf;

static void jbuf_init(lua_State* L, jbuf* b, size_t cap) {
  if (cap < 64) cap = 64;
  b->L = L;
  b->data = (char*)lua_newuserdatauv(L, cap, 0);
  b->box = lua_gettop(L);
  b->len = 0;
  b->cap = cap;
}

static void jbuf_reserve(jbuf* b, size_t extra) {
  if (b->cap - b->len >= extra) return;
  size_t cap = b->cap;
  while (cap - b->len < extra) {
    if (cap > SIZE_MAX / 2) luaL_error(b->L, "json: text too large");
    cap *= 2;
  }
  char* data = (char*)lua_newuserdatauv(b->L, cap, 0);
  memcpy(data, b->data, b->len);
  lua_replace(b->L, b->box);
  b->data = data;
  b->cap = cap;
}

static void jbuf_add(jbuf* b, const void* s, size_t n) {
  jbuf_reserve(b, n);
  memcpy(b->data + b->len, s, n);
  b->len += n;
}

static void jbuf_char(jbuf* b, char c) {
  jbuf_reserve(b, 1);
  b->data[b->len++] = c;
}

#define JBUF_LIT(b, s) jbuf_add((b), (s), sizeof(s) - 1)

static const char replacement[] = "\xEF\xBF\xBD";  // U+FFFD

// --- UTF-8 --------------------------------------------------------------------

// The length of the UTF-8 sequence at p; *valid is 0 if it is invalid. An
// invalid sequence is its maximal subpart, or one byte (WHATWG), which is
// what dart:convert and TextDecoder replace with one U+FFFD.
static size_t utf8_next(const unsigned char* p, const unsigned char* end,
                        int* valid) {
  unsigned char c = p[0];
  size_t need;
  unsigned char lo = 0x80, hi = 0xBF;
  if (c < 0x80) {
    *valid = 1;
    return 1;
  } else if (c >= 0xC2 && c <= 0xDF) {
    need = 1;
  } else if (c >= 0xE0 && c <= 0xEF) {
    need = 2;
    if (c == 0xE0) lo = 0xA0;
    if (c == 0xED) hi = 0x9F;
  } else if (c >= 0xF0 && c <= 0xF4) {
    need = 3;
    if (c == 0xF0) lo = 0x90;
    if (c == 0xF4) hi = 0x8F;
  } else {
    *valid = 0;
    return 1;
  }
  size_t i = 1;
  for (; i <= need; i++) {
    if (p + i >= end || p[i] < lo || p[i] > hi) {
      *valid = 0;
      return i;
    }
    lo = 0x80;
    hi = 0xBF;
  }
  *valid = 1;
  return i;
}

static int utf8_valid(const unsigned char* p, size_t n) {
  const unsigned char* end = p + n;
  while (p < end) {
    if (*p < 0x80) {
      p++;
      continue;
    }
    int valid;
    p += utf8_next(p, end, &valid);
    if (!valid) return 0;
  }
  return 1;
}

static void utf8_put(jbuf* b, uint32_t cp) {
  char u[4];
  size_t n;
  if (cp < 0x80) {
    u[0] = (char)cp;
    n = 1;
  } else if (cp < 0x800) {
    u[0] = (char)(0xC0 | (cp >> 6));
    u[1] = (char)(0x80 | (cp & 0x3F));
    n = 2;
  } else if (cp < 0x10000) {
    u[0] = (char)(0xE0 | (cp >> 12));
    u[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    u[2] = (char)(0x80 | (cp & 0x3F));
    n = 3;
  } else {
    u[0] = (char)(0xF0 | (cp >> 18));
    u[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    u[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    u[3] = (char)(0x80 | (cp & 0x3F));
    n = 4;
  }
  jbuf_add(b, u, n);
}

// --- Decode ------------------------------------------------------------------

typedef struct {
  lua_State* L;
  const unsigned char* start;
  const unsigned char* p;
  const unsigned char* end;
  jbuf tmp;
  int depth;
} jdec;

_Noreturn static void dec_error(jdec* d, const char* what) {
  luaL_error(d->L, "json.decode: %s at byte %d", what,
             (int)(d->p - d->start) + 1);
  // luaL_error does not return.
  abort();
}

_Noreturn static void dec_unexpected(jdec* d) {
  dec_error(d, d->p >= d->end ? "unexpected end of input"
                              : "unexpected character");
}

static void skip_ws(jdec* d) {
  while (d->p < d->end &&
         (*d->p == ' ' || *d->p == '\t' || *d->p == '\n' || *d->p == '\r')) {
    d->p++;
  }
}

static int hex4(const unsigned char* p) {
  int v = 0;
  for (int i = 0; i < 4; i++) {
    unsigned char c = p[i];
    int digit;
    if (c >= '0' && c <= '9') {
      digit = c - '0';
    } else if ((c | 0x20) >= 'a' && (c | 0x20) <= 'f') {
      digit = (c | 0x20) - 'a' + 10;
    } else {
      return -1;
    }
    v = v * 16 + digit;
  }
  return v;
}

// The string at d->p ('"') in d->tmp, without its quotes.
static void dec_string(jdec* d) {
  jbuf* t = &d->tmp;
  t->len = 0;
  d->p++;
  for (;;) {
    const unsigned char* run = d->p;
    while (d->p < d->end && *d->p >= 0x20 && *d->p < 0x80 && *d->p != '"' &&
           *d->p != '\\') {
      d->p++;
    }
    if (d->p > run) jbuf_add(t, run, (size_t)(d->p - run));
    if (d->p >= d->end) dec_error(d, "unterminated string");
    unsigned char c = *d->p;
    if (c == '"') {
      d->p++;
      return;
    }
    if (c < 0x20) dec_error(d, "control character in string");
    if (c >= 0x80) {
      int valid;
      size_t n = utf8_next(d->p, d->end, &valid);
      if (valid) {
        jbuf_add(t, d->p, n);
      } else {
        JBUF_LIT(t, replacement);
      }
      d->p += n;
      continue;
    }
    // A backslash.
    if (d->p + 1 >= d->end) {
      d->p++;
      dec_error(d, "unterminated string");
    }
    unsigned char e = d->p[1];
    char out;
    switch (e) {
      case '"': out = '"'; break;
      case '\\': out = '\\'; break;
      case '/': out = '/'; break;
      case 'b': out = '\b'; break;
      case 'f': out = '\f'; break;
      case 'n': out = '\n'; break;
      case 'r': out = '\r'; break;
      case 't': out = '\t'; break;
      case 'u': {
        int cu = d->end - d->p >= 6 ? hex4(d->p + 2) : -1;
        if (cu < 0) {
          d->p++;
          dec_error(d, "invalid \\u escape");
        }
        d->p += 6;
        if (cu >= 0xD800 && cu <= 0xDBFF) {
          int low = d->end - d->p >= 6 && d->p[0] == '\\' && d->p[1] == 'u'
                        ? hex4(d->p + 2)
                        : -1;
          if (low >= 0xDC00 && low <= 0xDFFF) {
            d->p += 6;
            utf8_put(t, 0x10000 + (((uint32_t)cu - 0xD800) << 10) +
                            ((uint32_t)low - 0xDC00));
          } else {
            JBUF_LIT(t, replacement);  // a lone high surrogate
          }
        } else if (cu >= 0xDC00 && cu <= 0xDFFF) {
          JBUF_LIT(t, replacement);  // a lone low surrogate
        } else {
          utf8_put(t, (uint32_t)cu);
        }
        continue;
      }
      default:
        d->p++;
        dec_error(d, "invalid escape");
    }
    jbuf_char(t, out);
    d->p += 2;
  }
}

static int is_digit(jdec* d) {
  return d->p < d->end && *d->p >= '0' && *d->p <= '9';
}

static void dec_number(jdec* d) {
  const unsigned char* s = d->p;
  int negative = 0;
  if (*d->p == '-') {
    negative = 1;
    d->p++;
  }
  if (!is_digit(d)) dec_unexpected(d);
  if (*d->p == '0') {
    d->p++;
  } else {
    while (is_digit(d)) d->p++;
  }
  int integer = 1;
  if (d->p < d->end && *d->p == '.') {
    d->p++;
    if (!is_digit(d)) dec_unexpected(d);
    while (is_digit(d)) d->p++;
    integer = 0;
  }
  if (d->p < d->end && (*d->p == 'e' || *d->p == 'E')) {
    d->p++;
    if (d->p < d->end && (*d->p == '+' || *d->p == '-')) d->p++;
    if (!is_digit(d)) dec_unexpected(d);
    while (is_digit(d)) d->p++;
    integer = 0;
  }
  if (integer) {
    // Fits int64? The magnitude may be 2^63 when negative.
    uint64_t limit = negative ? (uint64_t)INT64_MAX + 1 : (uint64_t)INT64_MAX;
    uint64_t v = 0;
    int fits = 1;
    for (const unsigned char* q = s + negative; q < d->p; q++) {
      unsigned digit = (unsigned)(*q - '0');
      if (v > (limit - digit) / 10) {
        fits = 0;
        break;
      }
      v = v * 10 + digit;
    }
    if (fits) {
      lua_pushinteger(d->L, negative ? (lua_Integer)(0 - v) : (lua_Integer)v);
      return;
    }
  }
  // dtoa reads from a NUL-terminated copy: the text after the number must
  // not continue it (for example "0x1").
  jbuf* t = &d->tmp;
  t->len = 0;
  jbuf_add(t, s, (size_t)(d->p - s));
  jbuf_char(t, '\0');
  lua_pushnumber(d->L, luadart_strtod(t->data, NULL));
}

static void dec_literal(jdec* d, const char* word, size_t n) {
  if ((size_t)(d->end - d->p) < n || memcmp(d->p, word, n) != 0) {
    // Point at the first byte that differs.
    size_t i = 0;
    while (d->p + i < d->end && i < n && d->p[i] == (unsigned char)word[i]) {
      i++;
    }
    d->p += i;
    dec_unexpected(d);
  }
  d->p += n;
}

static void dec_value(jdec* d);

static void dec_enter(jdec* d) {
  if (++d->depth > JSON_MAX_DEPTH) dec_error(d, "too deeply nested");
  luaL_checkstack(d->L, 4, "json.decode: too deeply nested");
}

static void dec_array(jdec* d) {
  lua_State* L = d->L;
  dec_enter(d);
  d->p++;
  lua_newtable(L);
  skip_ws(d);
  if (d->p < d->end && *d->p == ']') {
    d->p++;
    lua_createtable(L, 0, 1);
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, LUADART_JSON_ARRAY_MARKER);
    lua_setmetatable(L, -2);
    d->depth--;
    return;
  }
  lua_Integer n = 0;
  int holes = 0;
  for (;;) {
    dec_value(d);
    if (lua_isnil(L, -1)) holes = 1;
    lua_rawseti(L, -2, ++n);
    skip_ws(d);
    if (d->p < d->end && *d->p == ',') {
      d->p++;
      skip_ws(d);
      continue;
    }
    if (d->p < d->end && *d->p == ']') {
      d->p++;
      break;
    }
    dec_unexpected(d);
  }
  if (holes) {
    // A table with an array part of n slots, so #t is n, as when a host
    // creates the table with its length and sets each element.
    if (n > INT32_MAX) dec_error(d, "array too long");
    lua_createtable(L, (int)n, 0);
    for (lua_Integer i = 1; i <= n; i++) {
      lua_rawgeti(L, -2, i);
      lua_rawseti(L, -2, i);
    }
    lua_remove(L, -2);
  }
  d->depth--;
}

static void dec_object(jdec* d) {
  lua_State* L = d->L;
  dec_enter(d);
  d->p++;
  lua_newtable(L);
  skip_ws(d);
  if (d->p < d->end && *d->p == '}') {
    d->p++;
    d->depth--;
    return;
  }
  for (;;) {
    if (d->p >= d->end || *d->p != '"') dec_unexpected(d);
    dec_string(d);
    lua_pushlstring(L, d->tmp.data, d->tmp.len);
    skip_ws(d);
    if (d->p >= d->end || *d->p != ':') dec_unexpected(d);
    d->p++;
    skip_ws(d);
    dec_value(d);
    lua_rawset(L, -3);  // a nil value removes the key, or adds nothing
    skip_ws(d);
    if (d->p < d->end && *d->p == ',') {
      d->p++;
      skip_ws(d);
      continue;
    }
    if (d->p < d->end && *d->p == '}') {
      d->p++;
      break;
    }
    dec_unexpected(d);
  }
  d->depth--;
}

static void dec_value(jdec* d) {
  if (d->p >= d->end) dec_unexpected(d);
  switch (*d->p) {
    case '{':
      dec_object(d);
      return;
    case '[':
      dec_array(d);
      return;
    case '"':
      dec_string(d);
      lua_pushlstring(d->L, d->tmp.data, d->tmp.len);
      return;
    case 't':
      dec_literal(d, "true", 4);
      lua_pushboolean(d->L, 1);
      return;
    case 'f':
      dec_literal(d, "false", 5);
      lua_pushboolean(d->L, 0);
      return;
    case 'n':
      dec_literal(d, "null", 4);
      lua_pushnil(d->L);
      return;
    default:
      if (*d->p == '-' || (*d->p >= '0' && *d->p <= '9')) {
        dec_number(d);
        return;
      }
      dec_unexpected(d);
  }
}

static int json_decode(lua_State* L) {
  size_t len;
  const char* s = luaL_checklstring(L, 1, &len);
  lua_settop(L, 1);
  jdec d;
  d.L = L;
  d.start = d.p = (const unsigned char*)s;
  d.end = d.start + len;
  d.depth = 0;
  jbuf_init(L, &d.tmp, 64);
  skip_ws(&d);
  dec_value(&d);
  skip_ws(&d);
  if (d.p != d.end) dec_unexpected(&d);
  return 1;
}

// --- Encode ------------------------------------------------------------------

typedef struct {
  lua_State* L;
  jbuf out;
  int depth;
} jenc;

static void enc_string(jbuf* b, const unsigned char* s, size_t n) {
  static const char hex[] = "0123456789abcdef";
  const unsigned char* end = s + n;
  jbuf_reserve(b, n + 2);
  jbuf_char(b, '"');
  while (s < end) {
    const unsigned char* run = s;
    while (s < end && *s >= 0x20 && *s < 0x80 && *s != '"' && *s != '\\') {
      s++;
    }
    if (s > run) jbuf_add(b, run, (size_t)(s - run));
    if (s >= end) break;
    unsigned char c = *s;
    if (c >= 0x80) {
      int valid;
      size_t len = utf8_next(s, end, &valid);
      if (valid) {
        jbuf_add(b, s, len);
      } else {
        JBUF_LIT(b, replacement);
      }
      s += len;
      continue;
    }
    switch (c) {
      case '"': JBUF_LIT(b, "\\\""); break;
      case '\\': JBUF_LIT(b, "\\\\"); break;
      case '\b': JBUF_LIT(b, "\\b"); break;
      case '\t': JBUF_LIT(b, "\\t"); break;
      case '\n': JBUF_LIT(b, "\\n"); break;
      case '\f': JBUF_LIT(b, "\\f"); break;
      case '\r': JBUF_LIT(b, "\\r"); break;
      default: {
        char u[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
        jbuf_add(b, u, 6);
      }
    }
    s++;
  }
  jbuf_char(b, '"');
}

static void enc_integer(jbuf* b, lua_Integer v) {
  char digits[24];
  int n = 0;
  uint64_t u = v < 0 ? 0 - (uint64_t)v : (uint64_t)v;
  do {
    digits[n++] = (char)('0' + u % 10);
    u /= 10;
  } while (u != 0);
  jbuf_reserve(b, (size_t)n + 1);
  if (v < 0) b->data[b->len++] = '-';
  while (n > 0) b->data[b->len++] = digits[--n];
}

// A double as Dart's double.toString prints it.
static void enc_double(jenc* e, double v) {
  jbuf* b = &e->out;
  int decpt, sign;
  char* end;
  char* digits = luadart_dtoa(v, 0, 0, &decpt, &sign, &end);
  if (digits == NULL) luaL_error(e->L, "json.encode: not enough memory");
  int k = (int)(end - digits);
  int n = decpt;
  char text[64];
  int len = 0;
  if (sign) text[len++] = '-';
  if (k <= n && n <= 21) {
    memcpy(text + len, digits, (size_t)k);
    len += k;
    for (int i = k; i < n; i++) text[len++] = '0';
    text[len++] = '.';
    text[len++] = '0';
  } else if (0 < n && n <= 21) {
    memcpy(text + len, digits, (size_t)n);
    len += n;
    text[len++] = '.';
    memcpy(text + len, digits + n, (size_t)(k - n));
    len += k - n;
  } else if (-6 < n && n <= 0) {
    text[len++] = '0';
    text[len++] = '.';
    for (int i = n; i < 0; i++) text[len++] = '0';
    memcpy(text + len, digits, (size_t)k);
    len += k;
  } else {
    text[len++] = digits[0];
    if (k > 1) {
      text[len++] = '.';
      memcpy(text + len, digits + 1, (size_t)(k - 1));
      len += k - 1;
    }
    len += snprintf(text + len, sizeof(text) - (size_t)len, "e%c%d",
                    n - 1 >= 0 ? '+' : '-', n - 1 >= 0 ? n - 1 : 1 - n);
  }
  luadart_freedtoa(digits);
  jbuf_add(b, text, (size_t)len);
}

static void enc_value(jenc* e, int idx);

// The object key at idx as text, as a host gets it with luadart_tolstring:
// numbers as tostring prints them, other non-strings as "0".
static const char* key_text(lua_State* L, int idx, size_t* len) {
  if (lua_type(L, idx) == LUA_TSTRING || lua_type(L, idx) == LUA_TNUMBER) {
    uint64_t n = 0;
    const char* s = (const char*)luadart_tolstring(L, idx, &n);
    *len = (size_t)n;
    return s;
  }
  *len = 1;
  return "0";
}

// An object whose keys can print the same: collect them in first-position
// order with their last values, then write them.
static void enc_object_merged(jenc* e, int idx) {
  lua_State* L = e->L;
  jbuf* b = &e->out;
  lua_newtable(L);  // key text -> position
  int pos = lua_gettop(L);
  lua_newtable(L);  // position -> key text
  int keys = lua_gettop(L);
  lua_newtable(L);  // position -> value
  int values = lua_gettop(L);
  lua_Integer count = 0;
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    size_t len;
    const char* text = key_text(L, -2, &len);
    if (!utf8_valid((const unsigned char*)text, len)) {
      // The key as the host sees it: invalid UTF-8 as U+FFFD.
      jbuf t;
      jbuf_init(L, &t, len * 3);
      const unsigned char* s = (const unsigned char*)text;
      const unsigned char* end = s + len;
      while (s < end) {
        int valid;
        size_t n = utf8_next(s, end, &valid);
        if (valid) {
          jbuf_add(&t, s, n);
        } else {
          JBUF_LIT(&t, replacement);
        }
        s += n;
      }
      lua_pushlstring(L, t.data, t.len);
      lua_remove(L, t.box);
    } else {
      lua_pushlstring(L, text, len);
    }
    // stack: key, value, text
    lua_pushvalue(L, -1);
    lua_rawget(L, pos);
    lua_Integer at;
    if (lua_isnil(L, -1)) {
      at = ++count;
      lua_pushvalue(L, -2);
      lua_pushinteger(L, at);
      lua_rawset(L, pos);
      lua_pushvalue(L, -2);
      lua_rawseti(L, keys, at);
    } else {
      at = lua_tointeger(L, -1);
    }
    lua_pop(L, 2);  // position, text
    lua_rawseti(L, values, at);  // pops the value
  }
  jbuf_char(b, '{');
  for (lua_Integer i = 1; i <= count; i++) {
    if (i > 1) jbuf_char(b, ',');
    size_t len;
    lua_rawgeti(L, keys, i);
    const char* text = lua_tolstring(L, -1, &len);
    enc_string(b, (const unsigned char*)text, len);
    lua_pop(L, 1);
    jbuf_char(b, ':');
    lua_rawgeti(L, values, i);
    enc_value(e, lua_gettop(L));
    lua_pop(L, 1);
  }
  jbuf_char(b, '}');
  lua_pop(L, 3);
}

static void enc_table(jenc* e, int idx) {
  lua_State* L = e->L;
  jbuf* b = &e->out;
  if (++e->depth > JSON_MAX_DEPTH) {
    luaL_error(L, "json.encode: tables nest too deep, or have a cycle");
  }
  luaL_checkstack(L, 8, "json.encode: tables nest too deep");
  lua_Unsigned len = lua_rawlen(L, idx);
  if (len == 0 && lua_getmetatable(L, idx)) {
    lua_getfield(L, -1, LUADART_JSON_ARRAY_MARKER);
    int array = lua_toboolean(L, -1);
    lua_pop(L, 2);
    if (array) {
      JBUF_LIT(b, "[]");
      e->depth--;
      return;
    }
  }
  if (len > 0) {
    // An array iff the keys are exactly 1..len.
    int array = 1;
    lua_Unsigned count = 0;
    lua_pushnil(L);
    while (lua_next(L, idx)) {
      int ok;
      lua_Integer key = lua_tointegerx(L, -2, &ok);
      if (!ok || key < 1 || (lua_Unsigned)key > len) {
        array = 0;
        lua_pop(L, 2);
        break;
      }
      count++;
      lua_pop(L, 1);
    }
    if (array && count == len) {
      jbuf_char(b, '[');
      for (lua_Unsigned i = 1; i <= len; i++) {
        if (i > 1) jbuf_char(b, ',');
        lua_rawgeti(L, idx, (lua_Integer)i);
        enc_value(e, lua_gettop(L));
        lua_pop(L, 1);
      }
      jbuf_char(b, ']');
      e->depth--;
      return;
    }
  }
  // An object. Keys that are not valid UTF-8 strings can print the same as
  // another key: then restart with enc_object_merged.
  size_t mark = b->len;
  jbuf_char(b, '{');
  int first = 1;
  lua_pushnil(L);
  while (lua_next(L, idx)) {
    size_t klen;
    const char* key = lua_type(L, -2) == LUA_TSTRING
                          ? lua_tolstring(L, -2, &klen)
                          : NULL;
    if (key == NULL || !utf8_valid((const unsigned char*)key, klen)) {
      lua_pop(L, 2);
      b->len = mark;
      enc_object_merged(e, idx);
      e->depth--;
      return;
    }
    if (!first) jbuf_char(b, ',');
    first = 0;
    enc_string(b, (const unsigned char*)key, klen);
    jbuf_char(b, ':');
    enc_value(e, lua_gettop(L));
    lua_pop(L, 1);
  }
  jbuf_char(b, '}');
  e->depth--;
}

static void enc_value(jenc* e, int idx) {
  lua_State* L = e->L;
  jbuf* b = &e->out;
  switch (lua_type(L, idx)) {
    case LUA_TNIL:
    case LUA_TNONE:
      JBUF_LIT(b, "null");
      return;
    case LUA_TBOOLEAN:
      if (lua_toboolean(L, idx)) {
        JBUF_LIT(b, "true");
      } else {
        JBUF_LIT(b, "false");
      }
      return;
    case LUA_TNUMBER: {
      int ok;
      lua_Integer i = lua_tointegerx(L, idx, &ok);
      if (ok) {
        enc_integer(b, i);
        return;
      }
      double v = (double)lua_tonumber(L, idx);
      if (isnan(v) || isinf(v)) {
        luaL_error(L, "json.encode: cannot encode %s",
                   isnan(v) ? "NaN" : "Infinity");
      }
      enc_double(e, v);
      return;
    }
    case LUA_TSTRING: {
      size_t len;
      const char* s = lua_tolstring(L, idx, &len);
      enc_string(b, (const unsigned char*)s, len);
      return;
    }
    case LUA_TTABLE:
      enc_table(e, idx);
      return;
    default: {
      const char* name = lua_typename(L, lua_type(L, idx));
      enc_string(b, (const unsigned char*)name, strlen(name));
      return;
    }
  }
}

static int json_encode(lua_State* L) {
  luaL_checkany(L, 1);
  lua_settop(L, 1);
  jenc e;
  e.L = L;
  e.depth = 0;
  jbuf_init(L, &e.out, 256);
  enc_value(&e, 1);
  lua_pushlstring(L, e.out.data, e.out.len);
  return 1;
}

int luadart_open_json(lua_State* L) {
  static const luaL_Reg functions[] = {
      {"decode", json_decode},
      {"encode", json_encode},
      {NULL, NULL},
  };
  luaL_newlib(L, functions);
  return 1;
}
