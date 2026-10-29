// ABI smoke test of the lua_dart library. Uses only src/lua_dart.h, so it
// also checks that the public surface is enough without lua.h.

#define _POSIX_C_SOURCE 200809L  // nanosleep

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lua_dart.h"

static int failures = 0;

#define CHECK(cond)                                               \
  do {                                                            \
    if (!(cond)) {                                                \
      fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond); \
      failures++;                                                 \
    }                                                             \
  } while (0)

static const uint8_t* S(const char* s) { return (const uint8_t*)s; }

static int run(lua_State* L, const char* code) {
  int32_t status = luadart_load(L, S(code), strlen(code), "=smoke");
  if (status != LUADART_OK) return status;
  return luadart_pcall(L, 0, 0, 0, 0);
}

static int top_is(lua_State* L, const char* expected) {
  uint64_t len = 0;
  const uint8_t* s = luadart_tolstring(L, -1, &len);
  return s != NULL && len == strlen(expected) &&
         memcmp(s, expected, len) == 0;
}

// Interrupts the state from another OS thread after 50 ms.
static void* interrupt_later(void* state) {
  struct timespec delay = {0, 50 * 1000 * 1000};
  nanosleep(&delay, NULL);
  luadart_interrupt((lua_State*)state);
  return NULL;
}

// Runs `code` while another thread interrupts it; returns its status.
static int run_interrupted(lua_State* L, const char* code) {
  pthread_t thread;
  pthread_create(&thread, NULL, interrupt_later, L);
  int status = run(L, code);
  pthread_join(thread, NULL);
  luadart_settop(L, 0);
  luadart_clear_interrupt(L);
  return status;
}

static int released = 0;

// Function 1 adds two integers. Function 2 fails with its argument.
static int32_t host(int64_t token, lua_State* L, int64_t id, int32_t op) {
  if (token != 42) abort();
  if (op == LUADART_HOST_RELEASE) {
    released++;
    return 0;
  }
  if (id == 1) {
    int32_t ok1 = 0, ok2 = 0;
    int64_t a = luadart_tointegerx(L, 1, &ok1);
    int64_t b = luadart_tointegerx(L, 2, &ok2);
    if (!ok1 || !ok2) {
      luadart_pushlstring(L, S("add: integers"), 13);
      return LUADART_HOST_ERROR;
    }
    luadart_pushinteger(L, a + b);
    return 1;
  }
  if (id == 2) {
    luadart_pushvalue(L, 1);
    return LUADART_HOST_ERROR;
  }
  return LUADART_HOST_ERROR_NO_OBJECT;
}

int main(void) {
  CHECK(luadart_abi_version() == LUADART_ABI_VERSION);
  CHECK(strstr(luadart_build_info(), "lua_dart ABI 1; Lua 5.4.9") != NULL);

  lua_State* L = luadart_new_state(0, host, 42);
  CHECK(L != NULL);
  CHECK(luadart_open_libs(L, LUADART_LIB_ALL, LUADART_OPEN_SANDBOX) ==
        LUADART_ERRARG);
  CHECK(luadart_open_libs(L,
                          LUADART_LIB_BASE | LUADART_LIB_COROUTINE |
                              LUADART_LIB_TABLE | LUADART_LIB_OS |
                              LUADART_LIB_STRING | LUADART_LIB_MATH |
                              LUADART_LIB_UTF8,
                          LUADART_OPEN_SANDBOX) == LUADART_OK);
  CHECK(luadart_gettop(L) == 0);

  // Arithmetic and number formats.
  CHECK(run(L, "x = 1 + 2; y = 10 / 4; z = 2^53; w = 3.0") == LUADART_OK);
  int32_t type = -9;
  CHECK(luadart_getglobal(L, S("x"), 1, &type) == LUADART_OK);
  CHECK(type == LUADART_TNUMBER && luadart_isinteger(L, -1));
  CHECK(top_is(L, "3"));
  luadart_getglobal(L, S("y"), 1, NULL);
  CHECK(top_is(L, "2.5"));
  luadart_getglobal(L, S("z"), 1, NULL);
  CHECK(top_is(L, "9.007199254741e+15"));
  luadart_getglobal(L, S("w"), 1, NULL);
  CHECK(top_is(L, "3.0"));
  CHECK(luadart_type(L, -1) == LUADART_TNUMBER);  // still a number
  luadart_settop(L, 0);

  // Sandbox.
  CHECK(run(L, "assert(io == nil and package == nil and debug == nil)\n"
               "assert(os.execute == nil and os.exit == nil)\n"
               "assert(dofile == nil and loadfile == nil)\n"
               "local f, e = load(string.dump(function() end))\n"
               "assert(f == nil and e:find('binary'), e)\n"
               "assert(load('return 1')() == 1)\n"
               "assert(load('return x', 'n', 'b', {x = 5})() == 5)") ==
        LUADART_OK);
  const char binary[] = "\x1bLua";
  CHECK(luadart_load(L, S(binary), 4, "=bin") == LUADART_ERRSYNTAX);
  luadart_settop(L, 0);

  // Syntax and runtime errors leave one error object.
  CHECK(run(L, "x = = 1") == LUADART_ERRSYNTAX);
  CHECK(luadart_gettop(L) == 1);
  luadart_settop(L, 0);
  CHECK(run(L, "error('boom')") == LUADART_ERRRUN);
  CHECK(top_is(L, "smoke:1: boom"));
  luadart_settop(L, 0);

  // Host functions, their errors, and a pcall of them in Lua.
  CHECK(luadart_push_host_function(L, 1) == LUADART_OK);
  CHECK(luadart_is_host_function(L, -1));
  CHECK(luadart_setglobal(L, S("add"), 3) == LUADART_OK);
  CHECK(luadart_push_host_function(L, 2) == LUADART_OK);
  CHECK(luadart_setglobal(L, S("fail"), 4) == LUADART_OK);
  CHECK(luadart_push_host_function(L, 3) == LUADART_OK);
  CHECK(luadart_setglobal(L, S("broken"), 6) == LUADART_OK);
  CHECK(run(L, "assert(add(2, 3) == 5)\n"
               "local ok, e = pcall(add, 'a')\n"
               "assert(not ok and e == 'add: integers', e)\n"
               "local t = {}\n"
               "ok, e = pcall(fail, t)\n"
               "assert(not ok and e == t)\n"
               "ok, e = pcall(broken)\n"
               "assert(not ok and e == 'host function failed')") ==
        LUADART_OK);
  CHECK(luadart_gettop(L) == 0);

  // Metamethod errors in protected getters and setters.
  CHECK(run(L, "bad = setmetatable({}, {__index = function() error('idx') end,"
               " __newindex = function() error('nidx') end})") == LUADART_OK);
  luadart_getglobal(L, S("bad"), 3, NULL);
  CHECK(luadart_getfield(L, 1, S("k"), 1, &type) == LUADART_ERRRUN);
  CHECK(luadart_gettop(L) == 2 && type == LUADART_TNONE);
  luadart_settop(L, 1);
  luadart_pushinteger(L, 1);
  CHECK(luadart_setfield(L, 1, S("k"), 1) == LUADART_ERRRUN);
  CHECK(luadart_gettop(L) == 2);
  luadart_settop(L, 0);

  // Index checks.
  CHECK(luadart_type(L, 1) == LUADART_TNONE);
  CHECK(luadart_type(L, -1) == LUADART_TNONE);
  CHECK(luadart_pushvalue(L, -1) == LUADART_ERRARG);
  CHECK(luadart_settable(L, 1) == LUADART_ERRARG);
  CHECK(luadart_settop(L, -2) == LUADART_ERRARG);
  luadart_pushinteger(L, 1);
  CHECK(luadart_next(L, 1, NULL) == LUADART_ERRARG);  // not a table
  CHECK(luadart_rawseti(L, 1, 1) == LUADART_ERRARG);
  CHECK(luadart_gettop(L) == 1);
  luadart_settop(L, 0);

  // next over a table with a number key leaves the key a number.
  CHECK(run(L, "t = {[1.5] = 'a'}") == LUADART_OK);
  luadart_getglobal(L, S("t"), 1, NULL);
  luadart_pushnil(L);
  int32_t has_next = 0;
  CHECK(luadart_next(L, 1, &has_next) == LUADART_OK && has_next);
  CHECK(top_is(L, "a"));
  luadart_settop(L, -2);
  uint64_t len = 0;
  CHECK(luadart_tolstring(L, -1, &len) != NULL && len == 3);
  CHECK(luadart_next(L, 1, &has_next) == LUADART_OK && !has_next);
  CHECK(luadart_gettop(L) == 1);
  luadart_settop(L, 0);

  // Interrupt from this thread: it stays set, and pcall cannot catch it.
  luadart_interrupt(L);
  CHECK(run(L, "while true do end") == LUADART_ERRINTERRUPT);
  CHECK(top_is(L, "interrupted"));
  luadart_settop(L, 0);
  CHECK(run(L, "local x = 1") == LUADART_ERRINTERRUPT);
  luadart_settop(L, 0);
  luadart_clear_interrupt(L);
  CHECK(run(L, "local x = 0 for i = 1, 100000 do x = x + i end") ==
        LUADART_OK);

  // Interrupt from another thread, wherever the loop runs.
  const char* const loops[] = {
      "while true do end",
      "while true do pcall(function() while true do end end) end",
      "while true do xpcall(function() while true do end end,"
      " function() while true do end end) end",
      "coroutine.resume(coroutine.create(function() while true do end end))",
      "coroutine.wrap(function() while true do end end)()",
      "coroutine.wrap(function()"
      "  coroutine.resume(coroutine.create(function() while true do end end))"
      "  while true do end end)()",
      // The loop yields and resumes, so the running thread changes.
      "local co = coroutine.wrap(function() while true do"
      " coroutine.yield() end end) while true do co() end",
      "while true do local co = coroutine.create(function()"
      " while true do end end) coroutine.resume(co) end",
  };
  for (size_t k = 0; k < sizeof(loops) / sizeof(loops[0]); k++) {
    int status = run_interrupted(L, loops[k]);
    if (status != LUADART_ERRINTERRUPT) {
      fprintf(stderr, "loop %zu: status %d\n", k, status);
    }
    CHECK(status == LUADART_ERRINTERRUPT);
  }
  // A thread that Dart resumes directly.
  {
    lua_State* co = NULL;
    luadart_newthread(L, &co);
    const char* spin = "while true do end";
    luadart_load(co, S(spin), strlen(spin), "=spin");
    pthread_t thread;
    pthread_create(&thread, NULL, interrupt_later, L);
    int32_t nres = 0;
    CHECK(luadart_resume(co, L, 0, &nres) == LUADART_ERRINTERRUPT);
    pthread_join(thread, NULL);
    luadart_settop(L, 0);
    luadart_clear_interrupt(L);
  }
  // The state works after a cleared interrupt, also in coroutines.
  CHECK(run(L, "assert(coroutine.wrap(function() return 7 end)() == 7)") ==
        LUADART_OK);

  // Memory limit.
  luadart_set_memory_limit(L, luadart_memory_used(L) + 256 * 1024);
  CHECK(run(L, "local t = {} for i = 1, 1e7 do t[i] = {} end") ==
        LUADART_ERRMEM);
  luadart_settop(L, 0);
  luadart_set_memory_limit(L, 0);
  int32_t kb = 0;
  CHECK(luadart_gc(L, 2, 0, &kb) == LUADART_OK);  // LUA_GCCOLLECT
  CHECK(run(L, "local s = string.rep('x', 1000000)") == LUADART_OK);

  // Coroutines from the host.
  CHECK(run(L, "function gen(a) local b = coroutine.yield(a + 1)"
               " return b * 2 end") == LUADART_OK);
  lua_State* co = NULL;
  CHECK(luadart_newthread(L, &co) == LUADART_OK && co != NULL);
  CHECK(luadart_getglobal(co, S("gen"), 3, NULL) == LUADART_OK);
  luadart_pushinteger(co, 10);
  int32_t nres = 0;
  CHECK(luadart_resume(co, L, 1, &nres) == LUADART_YIELD && nres == 1);
  CHECK(top_is(co, "11"));
  luadart_settop(co, 0);
  CHECK(luadart_status(co) == LUADART_YIELD);
  // A protected push on a suspended thread runs on the main thread.
  CHECK(luadart_pushlstring(co, S("21"), 2) == LUADART_OK);
  CHECK(luadart_resume(co, L, 1, &nres) == LUADART_OK && nres == 1);
  CHECK(top_is(co, "42"));
  luadart_settop(co, 0);
  CHECK(luadart_resume(co, L, 0, &nres) == LUADART_ERRARG);  // dead
  CHECK(luadart_closethread(co, L) == LUADART_OK);
  luadart_settop(L, 0);

  // Host closures are released by the collector.
  int before = released;
  CHECK(run(L, "add = nil fail = nil broken = nil") == LUADART_OK);
  luadart_gc(L, 2, 0, NULL);
  CHECK(released == before + 3);

  // Traceback.
  const char* deep = "local function f() error('deep') end f()";
  CHECK(luadart_load(L, S(deep), strlen(deep), "=tb") == LUADART_OK);
  CHECK(luadart_pcall(L, 0, 0, 0, LUADART_PCALL_TRACEBACK) == LUADART_ERRRUN);
  {
    uint64_t n = 0;
    const uint8_t* s = luadart_tolstring(L, -1, &n);
    CHECK(s != NULL && strstr((const char*)s, "stack traceback") != NULL);
  }
  luadart_settop(L, 0);

  luadart_close(L);
  luadart_close(NULL);

  // A limit below the size of a new state.
  CHECK(luadart_new_state(64, NULL, 0) == NULL);

  if (failures != 0) {
    fprintf(stderr, "%d failures\n", failures);
    return 1;
  }
  printf("lua_dart smoke test passed\n");
  return 0;
}
