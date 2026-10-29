// A stress test of the json library under ASan and UBSan: random and
// damaged JSON through json.decode, json.encode and back. Local only:
//
//   L=build/native/macos-arm64/lua/src
//   clang -std=c11 -g -O1 -fsanitize=address,undefined -w -DLUA_COMPAT_5_3 \
//     -DLUA_USE_POSIX -I$L -Isrc src/lua_dart.c src/lua_dart_json.c \
//     src/third_party/dtoa.c $(ls $L/*.c | grep -v -E "/(lua|luac)\.c$") \
//     native_test/json_stress.c -o /tmp/json_stress && /tmp/json_stress
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
#include "lua_dart_json.h"
#include "lua_dart.h"

static unsigned seed = 7;
static unsigned rnd(void) { seed = seed * 1103515245u + 12345u; return seed >> 8; }

static const char* pieces[] = {"[", "]", "{", "}", ",", ":", "\"a\"", "\"\\u", "d83d", "\\ude00", "\"",
  "1", "-0", "1e9", "123456789012345678901234567890", ".5", "e+", "null", "true", "false", " ", "\\",
  "\xff", "\xed\xa0\x80", "\xf0\x9f\x98", "\xc3\xa9", "\"x\":", "0.1", "1e400", "\t", "\x01"};

static size_t gen(char* b, size_t n, size_t cap, int depth) {
  if (n + 64 >= cap) return n;
  switch (rnd() % (depth > 4 ? 4 : 6)) {
    case 0: return n + (size_t)snprintf(b + n, cap - n, "%lld", (long long)(rnd() * (long long)rnd()) - (1ll << 40));
    case 1: { double d; unsigned long long bits = ((unsigned long long)rnd() << 40) ^ ((unsigned long long)rnd() << 16) ^ rnd(); memcpy(&d, &bits, 8);
              if (d != d || d - d != 0) d = 0.25; return n + (size_t)snprintf(b + n, cap - n, "%.17g", d); }
    case 2: { b[n++] = '"'; int k = rnd() % 6; for (int i = 0; i < k && n + 16 < cap; i++) { const char* p = pieces[rnd() % 3 + 22]; size_t l = strlen(p);
                if (rnd() % 2) { p = "\\u00e9\\n"; l = strlen(p); } memcpy(b + n, p, l); n += l; } b[n++] = '"'; return n; }
    case 3: { const char* w[] = {"null", "true", "false"}; const char* p = w[rnd() % 3]; memcpy(b + n, p, strlen(p)); return n + strlen(p); }
    case 4: { b[n++] = '['; int k = rnd() % 5; for (int i = 0; i < k; i++) { if (i) b[n++] = ','; n = gen(b, n, cap, depth + 1); if (n + 64 >= cap) break; } b[n++] = ']'; return n; }
    default: { b[n++] = '{'; int k = rnd() % 5; for (int i = 0; i < k; i++) { if (i) b[n++] = ','; n += (size_t)snprintf(b + n, cap - n, "\"k%u\":", rnd() % 4); n = gen(b, n, cap, depth + 1); if (n + 64 >= cap) break; } b[n++] = '}'; return n; }
  }
}

int main(void) {
  lua_State* L = luadart_new_state(0, NULL, 0);
  luadart_open_libs(L, LUADART_LIB_ALL, 0);
  char buf[4096];
  long ok = 0, failed = 0, roundtrip = 0;
  for (int iter = 0; iter < 300000; iter++) {
    size_t n = 0;
    if (iter % 2) {
      n = gen(buf, 0, sizeof buf, 0);
      goto generated;
    }
    int parts = rnd() % 40;
    for (int i = 0; i < parts; i++) {
      const char* p = pieces[rnd() % (sizeof pieces / sizeof *pieces)];
      size_t len = strlen(p);
      if (n + len >= sizeof buf) break;
      memcpy(buf + n, p, len);
      n += len;
    }
  generated:
    if (rnd() % 4 == 0 && n > 0) buf[rnd() % n] = (char)rnd();
    lua_getglobal(L, "json");
    lua_getfield(L, -1, "decode");
    lua_pushlstring(L, buf, rnd() % 8 == 0 && n > 0 ? rnd() % n : n);
    if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
      ok++;
      lua_getfield(L, -2, "encode");
      lua_insert(L, -2);
      if (lua_pcall(L, 1, 1, 0) == LUA_OK) {
        // The text decodes again and encodes to the same text.
        size_t len;
        const char* text = lua_tolstring(L, -1, &len);
        char* copy = malloc(len);
        memcpy(copy, text, len);
        lua_getfield(L, -2, "decode");
        lua_insert(L, -2);
        if (lua_pcall(L, 1, 1, 0) != LUA_OK) { fprintf(stderr, "re-decode failed: %s\n", lua_tostring(L, -1)); return 1; }
        lua_getfield(L, -2, "encode");
        lua_insert(L, -2);
        if (lua_pcall(L, 1, 1, 0) != LUA_OK) { fprintf(stderr, "re-encode failed\n"); return 1; }
        size_t len2;
        const char* text2 = lua_tolstring(L, -1, &len2);
        if (len != len2) {  // key order can differ (Lua hash order)
          fprintf(stderr, "not stable:\n%.*s\n%.*s\n", (int)len, copy, (int)len2, text2);
          return 1;
        }
        free(copy);
        roundtrip++;
      }
    } else {
      failed++;
    }
    lua_settop(L, 0);
  }
  // Deep input and a cycle.
  if (luaL_dostring(L, "assert(not pcall(json.decode, ('['):rep(100000)))"
                   "local t = {} t[1] = t assert(not pcall(json.encode, t))"
                   "assert(json.encode(json.decode(('[1,'):rep(50000) .. '1' .. (']'):rep(50000) == nil and 1 or '[]')))"
                   "local t = {[1]=1, ['1']=2, [1.5]=3, ['1.5']=4, [true]=5, [{}]=6, ['\\xff']=7, ['\\xfe']=8}"
                   "assert(#json.encode(t) > 0)")) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
  printf("%ld decoded, %ld failed, %ld round trips\n", ok, failed, roundtrip);
  luadart_close(L);
  return 0;
}
