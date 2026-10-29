// lua_dart: the stable C ABI of src/lua_dart.h over Lua 5.4.
//
// The one rule that this file exists for: a Lua error never longjmps over a
// Dart frame. Dart calls the functions below; the functions that can raise
// run their Lua API call inside lua_pcall (run_protected), so each longjmp
// ends in a C frame of this file. Host functions are called by
// host_trampoline, which raises the host's error only after Dart returns.

#include "lua_dart.h"

#include <locale.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

#if LUA_VERSION_NUM != 504
#error "lua_dart needs Lua 5.4"
#endif

#define LUADART_STR2(x) #x
#define LUADART_STR(x) LUADART_STR2(x)
#define LUADART_BUILD_INFO \
  "lua_dart ABI " LUADART_STR(LUADART_ABI_VERSION) "; " LUA_RELEASE

struct luadart_interrupt_handle {
  atomic_flag lock;  // guards pending and state
  atomic_int refs;
  int pending;       // luadart_interrupt_handle_trigger was called
  lua_State* state;  // the attached state, or NULL
};

typedef struct luadart_vm {
  lua_State* main;
  luadart_interrupt_handle* handle;  // attached, or NULL
  luadart_host_fn host;
  int64_t host_token;
  uint64_t mem_used;
  uint64_t mem_limit;  // 0: no limit
  // The interrupt of skynet's service_snlua.c (see "Interrupt" below).
  // The running thread.
  _Atomic(lua_State*) active;
  // 0: none; 1: luadart_interrupt is setting the hook; -1: interrupted.
  atomic_int trap;
  char numbuf[64];
} luadart_vm;

// Registry keys: addresses of these variables.
static const char host_metatable_key = 0;
static const char host_failed_key = 0;

static luadart_vm* vm_of(lua_State* L) {
  void* ud = NULL;
  lua_getallocf(L, &ud);
  return (luadart_vm*)ud;
}

// --- Allocation and limits --------------------------------------------------

static void* l_alloc(void* ud, void* ptr, size_t osize, size_t nsize) {
  luadart_vm* vm = (luadart_vm*)ud;
  if (ptr == NULL) osize = 0;  // osize is then the type of the new object.
  if (nsize == 0) {
    free(ptr);
    vm->mem_used -= osize;
    return NULL;
  }
  if (nsize > osize && vm->mem_limit != 0 &&
      vm->mem_used + (nsize - osize) > vm->mem_limit) {
    return NULL;
  }
  void* block = realloc(ptr, nsize);
  if (block == NULL) return NULL;
  vm->mem_used = vm->mem_used + nsize - osize;
  return block;
}

static int panic(lua_State* L) {
  // Unreachable while every raising call is protected. An unprotected error
  // has no safe continuation.
  const char* msg = lua_tostring(L, -1);
  fprintf(stderr, "lua_dart: unprotected Lua error: %s\n",
          msg ? msg : "(not a string)");
  fflush(stderr);
  abort();
  return 0;
}

// --- Interrupt -------------------------------------------------------------
//
// The interrupt of skynet (https://github.com/cloudwu/skynet,
// service-src/service_snlua.c: signal_hook, switchL, lua_resumeX and
// snlua_signal; MIT license, Copyright (c) 2012-2025 codingnow.com). No hook
// is set while Lua runs normally, so the VM runs at full speed. Another
// thread interrupts by setting a count hook of 1 on the running thread;
// lua_sethook is safe for that (see its comment in ldebug.c). Every
// lua_resume goes through resume_tracked, so the running thread is known,
// and a thread that starts running while the interrupt is set gets the hook.
//
// One change from skynet: there, the hook removes itself after one error,
// so a `pcall` in the script can catch it and continue. Here the interrupt
// stays set until luadart_clear_interrupt, and the hook fails every
// instruction, so a script cannot continue.

static int interrupted(luadart_vm* vm) {
  return atomic_load(&vm->trap) != 0;
}

static void signal_hook(lua_State* L, lua_Debug* ar) {
  (void)ar;
  if (!interrupted(vm_of(L))) {
    lua_sethook(L, NULL, 0, 0);  // cleared
    return;
  }
  lua_pushliteral(L, "interrupted");
  lua_error(L);
}

static void switch_thread(lua_State* L, luadart_vm* vm) {
  atomic_store(&vm->active, L);
  if (interrupted(vm)) {
    lua_sethook(L, signal_hook, LUA_MASKCOUNT, 1);
  } else if (lua_gethook(L) != NULL) {
    lua_sethook(L, NULL, 0, 0);  // left from a cleared interrupt
  }
}

static int resume_tracked(lua_State* co, lua_State* from, int nargs,
                          int* nresults) {
  luadart_vm* vm = vm_of(co);
  switch_thread(co, vm);
  int status = lua_resume(co, from, nargs, nresults);
  // Wait while luadart_interrupt sets the hook (trap 1), so it does not set
  // the hook on `co` after `from` runs again.
  while (atomic_load(&vm->trap) == 1) {
  }
  switch_thread(from, vm);
  return status;
}

// lua_pcall on L, which then is the running thread. Dart can call into any
// thread, so its calls are tracked as resumes are.
static int pcall_tracked(lua_State* L, int nargs, int nresults, int msgh) {
  luadart_vm* vm = vm_of(L);
  lua_State* previous = atomic_load(&vm->active);
  if (previous == L) return lua_pcall(L, nargs, nresults, msgh);
  switch_thread(L, vm);
  int status = lua_pcall(L, nargs, nresults, msgh);
  while (atomic_load(&vm->trap) == 1) {
  }
  switch_thread(previous, vm);
  return status;
}

static int32_t map_status(lua_State* L, int status) {
  if (status == LUA_OK || status == LUA_YIELD) return status;
  return interrupted(vm_of(L)) ? LUADART_ERRINTERRUPT : status;
}

// --- Index checks ------------------------------------------------------------

static int stack_index_ok(lua_State* L, int idx) {
  int top = lua_gettop(L);
  return (idx > 0 && idx <= top) || (idx < 0 && -idx <= top);
}

// A stack index or the registry. Upvalue pseudo-indices are not accepted:
// host functions keep their state in Dart.
static int index_ok(lua_State* L, int idx) {
  return idx == LUA_REGISTRYINDEX || stack_index_ok(L, idx);
}

static int table_at(lua_State* L, int idx) {
  return index_ok(L, idx) && lua_type(L, idx) == LUA_TTABLE;
}

// --- Protected calls ----------------------------------------------------------

typedef struct op_args {
  const uint8_t* s;
  size_t len;
  lua_Integer i;
  int n;
  int m;
  int out;
  lua_State* co;
  lua_State* from;
  int status;
  int nres;
} op_args;

// Calls f(a, [t], v1 .. vn) in protected mode on L, which has status LUA_OK.
// t is the value at `t_idx` (an absolute index, or 0 for none). v1 .. vn are
// the top `n` values, which the call consumes. On success, the `nresults`
// results of f replace them; on error, the error object replaces them.
static int32_t run_protected_here(lua_State* L, lua_CFunction f, op_args* a,
                                  int t_idx, int n, int nresults) {
  int base = lua_gettop(L);
  if (n > base) return LUADART_ERRARG;
  int room = 3 + n + (nresults > 0 ? nresults : 2);
  if (!lua_checkstack(L, room)) return LUADART_ERRSTACK;
  lua_pushcfunction(L, f);
  lua_pushlightuserdata(L, a);
  int nargs = 1;
  if (t_idx != 0) {
    lua_pushvalue(L, t_idx);
    nargs++;
  }
  for (int k = 0; k < n; k++) lua_pushvalue(L, base - n + 1 + k);
  nargs += n;
  int status = pcall_tracked(L, nargs, nresults, 0);
  if (n > 0) {
    lua_rotate(L, base - n + 1, -n);
    lua_pop(L, n);
  }
  return map_status(L, status);
}

// run_protected_here, also for a suspended or dead thread L. Lua cannot call
// functions on such a thread, so the call runs on the main thread, and the
// values move between the two stacks.
static int32_t run_protected(lua_State* L, lua_CFunction f, op_args* a,
                             int t_idx, int n, int nresults) {
  if (lua_status(L) == LUA_OK) {
    return run_protected_here(L, f, a, t_idx, n, nresults);
  }
  lua_State* M = vm_of(L)->main;
  int top = lua_gettop(L);
  if (n > top) return LUADART_ERRARG;
  int results = nresults > 0 ? nresults : 2;
  if (!lua_checkstack(L, 1 + results) ||
      !lua_checkstack(M, 4 + n + results)) {
    return LUADART_ERRSTACK;
  }
  int moved = n;
  if (t_idx != 0) {
    lua_pushvalue(L, t_idx);
    lua_rotate(L, -(n + 1), 1);  // t below v1 .. vn
    moved++;
  }
  int mbase = lua_gettop(M);
  lua_xmove(L, M, moved);
  int32_t status = run_protected_here(M, f, a, t_idx != 0 ? mbase + 1 : 0,
                                      n, nresults);
  if (t_idx != 0) lua_remove(M, mbase + 1);
  lua_xmove(M, L, lua_gettop(M) - mbase);
  return status;
}

static op_args* args_of(lua_State* L) {
  return (op_args*)lua_touserdata(L, 1);
}

static int p_gettable(lua_State* L) {
  args_of(L)->out = lua_gettable(L, 2);
  return 1;
}

static int p_getfield(lua_State* L) {
  op_args* a = args_of(L);
  lua_pushlstring(L, (const char*)a->s, a->len);
  a->out = lua_gettable(L, 2);
  return 1;
}

static int p_geti(lua_State* L) {
  op_args* a = args_of(L);
  a->out = lua_geti(L, 2, a->i);
  return 1;
}

static int p_getglobal(lua_State* L) {
  op_args* a = args_of(L);
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  lua_pushlstring(L, (const char*)a->s, a->len);
  a->out = lua_gettable(L, -2);
  return 1;
}

static int p_settable(lua_State* L) {
  lua_settable(L, 2);
  return 0;
}

static int p_setfield(lua_State* L) {
  op_args* a = args_of(L);
  lua_pushlstring(L, (const char*)a->s, a->len);
  lua_insert(L, 3);
  lua_settable(L, 2);
  return 0;
}

static int p_seti(lua_State* L) {
  lua_seti(L, 2, args_of(L)->i);
  return 0;
}

static int p_setglobal(lua_State* L) {
  op_args* a = args_of(L);
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  lua_insert(L, 2);
  lua_pushlstring(L, (const char*)a->s, a->len);
  lua_insert(L, 3);
  lua_settable(L, 2);
  return 0;
}

static int p_rawset(lua_State* L) {
  lua_rawset(L, 2);
  return 0;
}

static int p_rawseti(lua_State* L) {
  lua_rawseti(L, 2, args_of(L)->i);
  return 0;
}

static int p_createtable(lua_State* L) {
  op_args* a = args_of(L);
  lua_createtable(L, a->n, a->m);
  return 1;
}

static int p_pushlstring(lua_State* L) {
  op_args* a = args_of(L);
  lua_pushlstring(L, (const char*)a->s, a->len);
  return 1;
}

static int host_trampoline(lua_State* L);

static int p_push_host_function(lua_State* L) {
  op_args* a = args_of(L);
  int64_t* id = (int64_t*)lua_newuserdatauv(L, sizeof(int64_t), 0);
  *id = a->i;
  lua_rawgetp(L, LUA_REGISTRYINDEX, &host_metatable_key);
  lua_setmetatable(L, -2);
  lua_pushcclosure(L, host_trampoline, 1);
  return 1;
}

static int p_newthread(lua_State* L) {
  args_of(L)->co = lua_newthread(L);
  return 1;
}

static int p_next(lua_State* L) {
  op_args* a = args_of(L);
  a->out = lua_next(L, 2);
  return a->out ? 2 : 0;
}

static int p_len(lua_State* L) {
  lua_len(L, 2);
  return 1;
}

static int p_compare(lua_State* L) {
  op_args* a = args_of(L);
  a->out = lua_compare(L, 2, 3, a->n);
  return 0;
}

static int p_arith(lua_State* L) {
  lua_arith(L, args_of(L)->n);
  return 1;
}

static int p_concat(lua_State* L) {
  lua_concat(L, args_of(L)->n);
  return 1;
}

static int p_tostring_meta(lua_State* L) {
  luaL_tolstring(L, 2, NULL);
  return 1;
}

static int p_where(lua_State* L) {
  // Level 0 is this function and level 1 is the caller of lua_pcall, the
  // running host function.
  luaL_where(L, args_of(L)->n + 1);
  return 1;
}

// The message of luaL_argerror, one level further up: level 0 is this
// function and level 1 is the running host function.
static int p_argerror(lua_State* L) {
  op_args* a = args_of(L);
  int arg = a->n;
  lua_Debug ar;
  luaL_where(L, 2);
  if (!lua_getstack(L, 1, &ar)) {
    lua_pushfstring(L, "bad argument #%d (", arg);
  } else {
    lua_getinfo(L, "n", &ar);
    const char* name = ar.name != NULL ? ar.name : "?";
    if (ar.namewhat != NULL && strcmp(ar.namewhat, "method") == 0 &&
        --arg == 0) {
      lua_pushfstring(L, "calling '%s' on bad self (", name);
    } else {
      lua_pushfstring(L, "bad argument #%d to '%s' (", arg, name);
    }
  }
  lua_pushlstring(L, (const char*)a->s, a->len);
  lua_pushliteral(L, ")");
  lua_concat(L, 4);
  return 1;
}

static int p_ref(lua_State* L) {
  args_of(L)->out = luaL_ref(L, 2);
  return 0;
}

static int p_unref(lua_State* L) {
  luaL_unref(L, 2, args_of(L)->n);
  return 0;
}

static int p_gc(lua_State* L) {
  op_args* a = args_of(L);
  a->out = lua_gc(L, a->n, a->m);
  return 0;
}

static int p_resume(lua_State* L) {
  op_args* a = args_of(L);
  a->status = resume_tracked(a->co, a->from, a->n, &a->nres);
  return 0;
}

// --- Host functions -----------------------------------------------------------

static int host_trampoline(lua_State* L) {
  luadart_vm* vm = vm_of(L);
  const int64_t* id = (const int64_t*)lua_touserdata(L, lua_upvalueindex(1));
  if (vm->host == NULL || id == NULL) {
    return luaL_error(L, "host function is not available");
  }
  if (!lua_checkstack(L, LUA_MINSTACK)) return luaL_error(L, "stack overflow");
  int32_t n = vm->host(vm->host_token, L, *id, LUADART_HOST_CALL);
  int top = lua_gettop(L);
  if (n >= 0) {
    if (n <= top) return n;
    return luaL_error(L, "host function returned %d results, has %d", n, top);
  }
  if (n == LUADART_HOST_ERROR && top >= 1) return lua_error(L);
  if (!lua_checkstack(L, 1)) lua_settop(L, top > 0 ? top - 1 : 0);
  lua_rawgetp(L, LUA_REGISTRYINDEX, &host_failed_key);
  return lua_error(L);
}

static int host_gc(lua_State* L) {
  const int64_t* id = (const int64_t*)lua_touserdata(L, 1);
  luadart_vm* vm = vm_of(L);
  if (id != NULL && vm->host != NULL) {
    vm->host(vm->host_token, L, *id, LUADART_HOST_RELEASE);
  }
  return 0;
}

static int p_init(lua_State* L) {
  lua_createtable(L, 0, 2);
  lua_pushcfunction(L, host_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable");
  lua_rawsetp(L, LUA_REGISTRYINDEX, &host_metatable_key);
  lua_pushliteral(L, "host function failed");
  lua_rawsetp(L, LUA_REGISTRYINDEX, &host_failed_key);
  return 0;
}

// --- Libraries ------------------------------------------------------------------

typedef struct lib_entry {
  uint32_t bit;
  const char* name;
  lua_CFunction open;
} lib_entry;

static const lib_entry libs[] = {
    {LUADART_LIB_BASE, LUA_GNAME, luaopen_base},
    {LUADART_LIB_PACKAGE, LUA_LOADLIBNAME, luaopen_package},
    {LUADART_LIB_COROUTINE, LUA_COLIBNAME, luaopen_coroutine},
    {LUADART_LIB_TABLE, LUA_TABLIBNAME, luaopen_table},
    {LUADART_LIB_IO, LUA_IOLIBNAME, luaopen_io},
    {LUADART_LIB_OS, LUA_OSLIBNAME, luaopen_os},
    {LUADART_LIB_STRING, LUA_STRLIBNAME, luaopen_string},
    {LUADART_LIB_MATH, LUA_MATHLIBNAME, luaopen_math},
    {LUADART_LIB_UTF8, LUA_UTF8LIBNAME, luaopen_utf8},
    {LUADART_LIB_DEBUG, LUA_DBLIBNAME, luaopen_debug},
};

// `load` of the sandbox: the original `load` (upvalue 1) with mode "t".
static int text_load(lua_State* L) {
  int n = lua_gettop(L);
  if (n < 3) {
    lua_settop(L, 3);
    n = 3;
  }
  lua_pushliteral(L, "t");
  lua_replace(L, 3);
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_insert(L, 1);
  lua_call(L, n, LUA_MULTRET);
  return lua_gettop(L);
}

static void remove_fields(lua_State* L, int table, const char* const* names) {
  for (; *names != NULL; names++) {
    lua_pushnil(L);
    lua_setfield(L, table, *names);
  }
}

// coroutine.resume and coroutine.wrap: auxresume, luaB_coresume,
// luaB_auxwrap, luaB_cocreate and luaB_cowrap of lcorolib.c of Lua 5.4.9
// (MIT license, Copyright (C) 1994-2025 Lua.org, PUC-Rio), with lua_resume
// replaced by resume_tracked, as skynet does.

static int co_auxresume(lua_State* L, lua_State* co, int narg) {
  int status, nres;
  if ((!lua_checkstack(co, narg))) {
    lua_pushliteral(L, "too many arguments to resume");
    return -1; /* error flag */
  }
  lua_xmove(L, co, narg);
  status = resume_tracked(co, L, narg, &nres);
  if ((status == LUA_OK || status == LUA_YIELD)) {
    if ((!lua_checkstack(L, nres + 1))) {
      lua_pop(co, nres); /* remove results anyway */
      lua_pushliteral(L, "too many results to resume");
      return -1; /* error flag */
    }
    lua_xmove(co, L, nres); /* move yielded values */
    return nres;
  } else {
    lua_xmove(co, L, 1); /* move error message */
    return -1;           /* error flag */
  }
}

static int co_resume(lua_State* L) {
  lua_State* co = lua_tothread(L, 1);
  luaL_argexpected(L, co, 1, "coroutine");
  int r = co_auxresume(L, co, lua_gettop(L) - 1);
  if ((r < 0)) {
    lua_pushboolean(L, 0);
    lua_insert(L, -2);
    return 2; /* return false + error message */
  } else {
    lua_pushboolean(L, 1);
    lua_insert(L, -(r + 1));
    return r + 1; /* return true + 'resume' returns */
  }
}

static int co_auxwrap(lua_State* L) {
  lua_State* co = lua_tothread(L, lua_upvalueindex(1));
  int r = co_auxresume(L, co, lua_gettop(L));
  if ((r < 0)) { /* error? */
    int stat = lua_status(co);
    if (stat != LUA_OK && stat != LUA_YIELD) { /* error in the coroutine? */
      stat = lua_closethread(co, L);           /* close its tbc variables */
      lua_xmove(co, L, 1); /* move error message to the caller */
    }
    if (stat != LUA_ERRMEM &&            /* not a memory error and ... */
        lua_type(L, -1) == LUA_TSTRING) { /* ... error object is a string? */
      luaL_where(L, 1); /* add extra info, if available */
      lua_insert(L, -2);
      lua_concat(L, 2);
    }
    return lua_error(L); /* propagate error */
  }
  return r;
}

static int co_wrap(lua_State* L) {
  lua_State* NL;
  luaL_checktype(L, 1, LUA_TFUNCTION);
  NL = lua_newthread(L);
  lua_pushvalue(L, 1); /* move function to top */
  lua_xmove(L, NL, 1); /* move function from L to NL */
  lua_pushcclosure(L, co_auxwrap, 1);
  return 1;
}

// xpcall with a guarded message handler. Lua calls the handler of an error
// that a hook raises inside the hook, where hooks are off, so a handler
// that loops could not be interrupted. While the state is interrupted, the
// guard returns the error without calling the handler.
static int xpcall_guard_call(lua_State* L) {
  if (interrupted(vm_of(L))) {
    lua_settop(L, 1);
    return 1;
  }
  lua_pushvalue(L, lua_upvalueindex(1));
  lua_insert(L, 1);
  lua_call(L, lua_gettop(L) - 1, LUA_MULTRET);
  return lua_gettop(L);
}

static int xpcall_guard(lua_State* L) {
  if (lua_type(L, 1) != LUA_TFUNCTION) return 1;  // xpcall reports it
  lua_settop(L, 1);
  lua_pushcclosure(L, xpcall_guard_call, 1);
  return 1;
}

static int p_open_libs(lua_State* L) {
  op_args* a = args_of(L);
  uint32_t mask = (uint32_t)a->n;
  int sandbox = (a->m & LUADART_OPEN_SANDBOX) != 0;
  for (size_t k = 0; k < sizeof(libs) / sizeof(libs[0]); k++) {
    if (mask & libs[k].bit) {
      luaL_requiref(L, libs[k].name, libs[k].open, 1);
      lua_pop(L, 1);
    }
  }
  if (mask & LUADART_LIB_BASE) {
    // A Lua function, so xpcall stays a tail call and can yield.
    static const char wrap_xpcall[] =
        "local xpcall, guard = ...\n"
        "return function(f, h, ...) return xpcall(f, guard(h), ...) end";
    if (luaL_loadbufferx(L, wrap_xpcall, sizeof(wrap_xpcall) - 1,
                         "=xpcall", "t") != LUA_OK) {
      return lua_error(L);
    }
    lua_getglobal(L, "xpcall");
    lua_pushcfunction(L, xpcall_guard);
    lua_call(L, 2, 1);
    lua_setglobal(L, "xpcall");
  }
  if (mask & LUADART_LIB_COROUTINE) {
    // The table is also package.loaded.coroutine.
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_getfield(L, -1, LUA_COLIBNAME);
    lua_pushcfunction(L, co_resume);
    lua_setfield(L, -2, "resume");
    lua_pushcfunction(L, co_wrap);
    lua_setfield(L, -2, "wrap");
    lua_pop(L, 2);
  }
  if (!sandbox) return 0;
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  int globals = lua_gettop(L);
  if (mask & LUADART_LIB_BASE) {
    lua_getfield(L, globals, "load");
    lua_pushcclosure(L, text_load, 1);
    lua_setfield(L, globals, "load");
    static const char* const base_removed[] = {"dofile", "loadfile", NULL};
    remove_fields(L, globals, base_removed);
  }
  if (mask & LUADART_LIB_OS) {
    lua_getfield(L, globals, LUA_OSLIBNAME);
    if (lua_istable(L, -1)) {
      static const char* const os_removed[] = {
          "execute", "exit",     "getenv",  "remove",
          "rename",  "setlocale", "tmpname", NULL};
      remove_fields(L, lua_gettop(L), os_removed);
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 1);
  return 0;
}

// --- Library ------------------------------------------------------------------

int32_t luadart_abi_version(void) { return LUADART_ABI_VERSION; }

const char* luadart_build_info(void) { return LUADART_BUILD_INFO; }

int32_t luadart_registry_index(void) { return LUA_REGISTRYINDEX; }

// --- State ----------------------------------------------------------------------

lua_State* luadart_new_state(uint64_t memory_limit, luadart_host_fn host,
                             int64_t host_token) {
  luadart_vm* vm = (luadart_vm*)calloc(1, sizeof(luadart_vm));
  if (vm == NULL) return NULL;
  vm->mem_limit = memory_limit;
  vm->host = host;
  vm->host_token = host_token;
  atomic_init(&vm->trap, 0);
  lua_State* L = lua_newstate(l_alloc, vm);
  if (L == NULL) {
    free(vm);
    return NULL;
  }
  vm->main = L;
  atomic_init(&vm->active, L);
  lua_atpanic(L, panic);
  op_args a = {0};
  if (run_protected(L, p_init, &a, 0, 0, 0) != LUADART_OK) {
    lua_close(L);
    free(vm);
    return NULL;
  }
  return L;
}

void luadart_close(lua_State* L) {
  if (L == NULL) return;
  luadart_vm* vm = vm_of(L);
  lua_State* main = vm->main;
  // After this, a trigger of the handle does not touch the state.
  luadart_detach_interrupt_handle(main);
  vm->host = NULL;
  // Lua code of finalizers fails at its first instruction.
  atomic_store(&vm->trap, -1);
  lua_sethook(main, signal_hook, LUA_MASKCOUNT, 1);
  lua_close(main);
  free(vm);
}

int32_t luadart_open_libs(lua_State* L, uint32_t libs_mask, uint32_t flags) {
  if ((libs_mask & ~LUADART_LIB_ALL) != 0 ||
      (flags & ~LUADART_OPEN_SANDBOX) != 0) {
    return LUADART_ERRARG;
  }
  if ((flags & LUADART_OPEN_SANDBOX) &&
      (libs_mask &
       (LUADART_LIB_PACKAGE | LUADART_LIB_IO | LUADART_LIB_DEBUG))) {
    return LUADART_ERRARG;
  }
  op_args a = {0};
  a.n = (int)libs_mask;
  a.m = (int)flags;
  return run_protected(L, p_open_libs, &a, 0, 0, 0);
}

// --- Limits ----------------------------------------------------------------------

void luadart_set_memory_limit(lua_State* L, uint64_t bytes) {
  vm_of(L)->mem_limit = bytes;
}

uint64_t luadart_memory_used(lua_State* L) { return vm_of(L)->mem_used; }

void luadart_interrupt(lua_State* L) {
  luadart_vm* vm = vm_of(L);
  // Only one thread sets the hook (trap 0 -> 1), as in skynet.
  int expected = 0;
  if (!atomic_compare_exchange_strong(&vm->trap, &expected, 1)) return;
  lua_sethook(atomic_load(&vm->active), signal_hook, LUA_MASKCOUNT, 1);
  atomic_store(&vm->trap, -1);
}

// --- Interrupt handles --------------------------------------------------------
//
// A handle outlives the states it is attached to, so another thread can
// trigger it at any time. The lock makes a trigger and a detach exclusive: a
// trigger never sees a state that is closing.

static void handle_lock(luadart_interrupt_handle* h) {
  while (atomic_flag_test_and_set_explicit(&h->lock, memory_order_acquire)) {
  }
}

static void handle_unlock(luadart_interrupt_handle* h) {
  atomic_flag_clear_explicit(&h->lock, memory_order_release);
}

luadart_interrupt_handle* luadart_interrupt_handle_new(void) {
  luadart_interrupt_handle* h = malloc(sizeof *h);
  if (h == NULL) return NULL;
  atomic_flag_clear(&h->lock);
  atomic_init(&h->refs, 1);
  h->pending = 0;
  h->state = NULL;
  return h;
}

void luadart_interrupt_handle_retain(luadart_interrupt_handle* h) {
  atomic_fetch_add(&h->refs, 1);
}

void luadart_interrupt_handle_release(luadart_interrupt_handle* h) {
  if (h != NULL && atomic_fetch_sub(&h->refs, 1) == 1) free(h);
}

void luadart_interrupt_handle_trigger(luadart_interrupt_handle* h) {
  handle_lock(h);
  h->pending = 1;
  if (h->state != NULL) luadart_interrupt(h->state);
  handle_unlock(h);
}

int32_t luadart_interrupt_handle_triggered(luadart_interrupt_handle* h) {
  handle_lock(h);
  int pending = h->pending;
  handle_unlock(h);
  return pending;
}

int32_t luadart_attach_interrupt_handle(lua_State* L,
                                        luadart_interrupt_handle* h) {
  luadart_vm* vm = vm_of(L);
  if (vm->handle != NULL) {
    luadart_interrupt_handle_release(h);
    return LUADART_ERRARG;
  }
  handle_lock(h);
  if (h->state != NULL) {
    handle_unlock(h);
    luadart_interrupt_handle_release(h);
    return LUADART_ERRARG;
  }
  h->state = vm->main;
  if (h->pending) luadart_interrupt(vm->main);
  handle_unlock(h);
  vm->handle = h;
  return LUADART_OK;
}

void luadart_detach_interrupt_handle(lua_State* L) {
  luadart_vm* vm = vm_of(L);
  luadart_interrupt_handle* h = vm->handle;
  if (h == NULL) return;
  handle_lock(h);
  h->state = NULL;
  handle_unlock(h);
  vm->handle = NULL;
  luadart_interrupt_handle_release(h);
}

void luadart_clear_interrupt(lua_State* L) {
  luadart_vm* vm = vm_of(L);
  // Wait for a luadart_interrupt that is setting the hook.
  int expected = -1;
  while (!atomic_compare_exchange_weak(&vm->trap, &expected, 0)) {
    if (expected == 0) break;
    expected = -1;
  }
  // The running thread clears its hook now; the hook of another thread
  // clears itself (signal_hook) or is cleared when it runs (switch_thread).
  switch_thread(atomic_load(&vm->active), vm);
}

int32_t luadart_gc(lua_State* L, int32_t what, int32_t arg, int32_t* out) {
  switch (what) {
    case LUA_GCSTOP:
    case LUA_GCRESTART:
    case LUA_GCCOLLECT:
    case LUA_GCCOUNT:
    case LUA_GCCOUNTB:
    case LUA_GCSTEP:
    case LUA_GCISRUNNING:
      break;
    default:
      return LUADART_ERRARG;
  }
  op_args a = {0};
  a.n = what;
  a.m = arg;
  int32_t status = run_protected(L, p_gc, &a, 0, 0, 0);
  if (status == LUADART_OK && out != NULL) *out = a.out;
  return status;
}

// --- Stack -------------------------------------------------------------------------

int32_t luadart_gettop(lua_State* L) { return lua_gettop(L); }

int32_t luadart_settop(lua_State* L, int32_t idx) {
  int top = lua_gettop(L);
  if (idx >= 0) {
    if (idx > top && !lua_checkstack(L, idx - top)) return LUADART_ERRSTACK;
  } else if (-idx > top + 1) {
    return LUADART_ERRARG;
  }
  lua_settop(L, idx);
  return LUADART_OK;
}

int32_t luadart_absindex(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx)) return 0;
  return lua_absindex(L, idx);
}

int32_t luadart_checkstack(lua_State* L, int32_t n) {
  if (n < 0) return 0;
  return lua_checkstack(L, n);
}

int32_t luadart_pushvalue(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx)) return LUADART_ERRARG;
  if (!lua_checkstack(L, 1)) return LUADART_ERRSTACK;
  lua_pushvalue(L, idx);
  return LUADART_OK;
}

int32_t luadart_rotate(lua_State* L, int32_t idx, int32_t n) {
  if (!stack_index_ok(L, idx)) return LUADART_ERRARG;
  int count = lua_gettop(L) - lua_absindex(L, idx) + 1;
  if (n > count || -n > count) return LUADART_ERRARG;
  lua_rotate(L, idx, n);
  return LUADART_OK;
}

int32_t luadart_copy(lua_State* L, int32_t from_idx, int32_t to_idx) {
  if (!index_ok(L, from_idx) || !stack_index_ok(L, to_idx)) {
    return LUADART_ERRARG;
  }
  lua_copy(L, from_idx, to_idx);
  return LUADART_OK;
}

int32_t luadart_xmove(lua_State* from, lua_State* to, int32_t n) {
  if (from == to || vm_of(from) != vm_of(to) || n < 0 ||
      n > lua_gettop(from)) {
    return LUADART_ERRARG;
  }
  if (!lua_checkstack(to, n)) return LUADART_ERRSTACK;
  lua_xmove(from, to, n);
  return LUADART_OK;
}

// --- Access ------------------------------------------------------------------------

int32_t luadart_type(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx)) return LUA_TNONE;
  return lua_type(L, idx);
}

int32_t luadart_isinteger(lua_State* L, int32_t idx) {
  return index_ok(L, idx) && lua_isinteger(L, idx);
}

int32_t luadart_isnumber(lua_State* L, int32_t idx) {
  return index_ok(L, idx) && lua_isnumber(L, idx);
}

int32_t luadart_isstring(lua_State* L, int32_t idx) {
  return index_ok(L, idx) && lua_isstring(L, idx);
}

int32_t luadart_is_host_function(lua_State* L, int32_t idx) {
  return index_ok(L, idx) && lua_tocfunction(L, idx) == host_trampoline;
}

int32_t luadart_toboolean(lua_State* L, int32_t idx) {
  return index_ok(L, idx) && lua_toboolean(L, idx);
}

int64_t luadart_tointegerx(lua_State* L, int32_t idx, int32_t* isnum) {
  int ok = 0;
  lua_Integer n = index_ok(L, idx) ? lua_tointegerx(L, idx, &ok) : 0;
  if (isnum != NULL) *isnum = ok;
  return n;
}

double luadart_tonumberx(lua_State* L, int32_t idx, int32_t* isnum) {
  int ok = 0;
  lua_Number n = index_ok(L, idx) ? lua_tonumberx(L, idx, &ok) : 0;
  if (isnum != NULL) *isnum = ok;
  return n;
}

const uint8_t* luadart_tolstring(lua_State* L, int32_t idx, uint64_t* len) {
  if (len != NULL) *len = 0;
  if (!index_ok(L, idx)) return NULL;
  int type = lua_type(L, idx);
  if (type == LUA_TSTRING) {
    size_t n = 0;
    const char* s = lua_tolstring(L, idx, &n);
    if (len != NULL) *len = n;
    return (const uint8_t*)s;
  }
  if (type != LUA_TNUMBER) return NULL;
  // The format of tostringbuff in lobject.c.
  luadart_vm* vm = vm_of(L);
  char* buf = vm->numbuf;
  int n;
  if (lua_isinteger(L, idx)) {
    n = lua_integer2str(buf, sizeof(vm->numbuf), lua_tointeger(L, idx));
  } else {
    n = lua_number2str(buf, sizeof(vm->numbuf), lua_tonumber(L, idx));
    if (buf[strspn(buf, "-0123456789")] == '\0') {
      buf[n++] = lua_getlocaledecpoint();
      buf[n++] = '0';
    }
  }
  if (len != NULL) *len = (uint64_t)n;
  return (const uint8_t*)buf;
}

uint64_t luadart_rawlen(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx)) return 0;
  return lua_rawlen(L, idx);
}

int32_t luadart_rawequal(lua_State* L, int32_t idx1, int32_t idx2) {
  return index_ok(L, idx1) && index_ok(L, idx2) && lua_rawequal(L, idx1, idx2);
}

lua_State* luadart_tothread(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx)) return NULL;
  return lua_tothread(L, idx);
}

int32_t luadart_status(lua_State* L) { return lua_status(L); }

// --- Push --------------------------------------------------------------------------

int32_t luadart_pushnil(lua_State* L) {
  if (!lua_checkstack(L, 1)) return LUADART_ERRSTACK;
  lua_pushnil(L);
  return LUADART_OK;
}

int32_t luadart_pushboolean(lua_State* L, int32_t b) {
  if (!lua_checkstack(L, 1)) return LUADART_ERRSTACK;
  lua_pushboolean(L, b);
  return LUADART_OK;
}

int32_t luadart_pushinteger(lua_State* L, int64_t n) {
  if (!lua_checkstack(L, 1)) return LUADART_ERRSTACK;
  lua_pushinteger(L, (lua_Integer)n);
  return LUADART_OK;
}

int32_t luadart_pushnumber(lua_State* L, double n) {
  if (!lua_checkstack(L, 1)) return LUADART_ERRSTACK;
  lua_pushnumber(L, (lua_Number)n);
  return LUADART_OK;
}

int32_t luadart_pushlstring(lua_State* L, const uint8_t* s, uint64_t len) {
  if (s == NULL && len != 0) return LUADART_ERRARG;
  if (len > (uint64_t)(SIZE_MAX / 2)) return LUADART_ERRARG;
  op_args a = {0};
  a.s = s == NULL ? (const uint8_t*)"" : s;
  a.len = (size_t)len;
  return run_protected(L, p_pushlstring, &a, 0, 0, 1);
}

int32_t luadart_pushglobaltable(lua_State* L) {
  if (!lua_checkstack(L, 1)) return LUADART_ERRSTACK;
  lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
  return LUADART_OK;
}

int32_t luadart_push_host_function(lua_State* L, int64_t function_id) {
  op_args a = {0};
  a.i = function_id;
  return run_protected(L, p_push_host_function, &a, 0, 0, 1);
}

int32_t luadart_newthread(lua_State* L, lua_State** out) {
  op_args a = {0};
  int32_t status = run_protected(L, p_newthread, &a, 0, 0, 1);
  if (out != NULL) *out = status == LUADART_OK ? a.co : NULL;
  return status;
}

// --- Tables ------------------------------------------------------------------------

static int32_t finish_get(int32_t status, const op_args* a, int32_t* type) {
  if (type != NULL) *type = status == LUADART_OK ? a->out : LUA_TNONE;
  return status;
}

int32_t luadart_createtable(lua_State* L, int32_t narr, int32_t nrec) {
  if (narr < 0 || nrec < 0) return LUADART_ERRARG;
  op_args a = {0};
  a.n = narr;
  a.m = nrec;
  return run_protected(L, p_createtable, &a, 0, 0, 1);
}

int32_t luadart_gettable(lua_State* L, int32_t idx, int32_t* type) {
  if (!index_ok(L, idx) || lua_gettop(L) < 1) return finish_get(LUADART_ERRARG, NULL, type);
  op_args a = {0};
  return finish_get(
      run_protected(L, p_gettable, &a, lua_absindex(L, idx), 1, 1), &a, type);
}

int32_t luadart_getfield(lua_State* L, int32_t idx, const uint8_t* k,
                         uint64_t klen, int32_t* type) {
  if (!index_ok(L, idx) || (k == NULL && klen != 0)) {
    return finish_get(LUADART_ERRARG, NULL, type);
  }
  op_args a = {0};
  a.s = k == NULL ? (const uint8_t*)"" : k;
  a.len = (size_t)klen;
  return finish_get(
      run_protected(L, p_getfield, &a, lua_absindex(L, idx), 0, 1), &a, type);
}

int32_t luadart_geti(lua_State* L, int32_t idx, int64_t i, int32_t* type) {
  if (!index_ok(L, idx)) return finish_get(LUADART_ERRARG, NULL, type);
  op_args a = {0};
  a.i = i;
  return finish_get(run_protected(L, p_geti, &a, lua_absindex(L, idx), 0, 1),
                    &a, type);
}

int32_t luadart_getglobal(lua_State* L, const uint8_t* name, uint64_t len,
                          int32_t* type) {
  if (name == NULL && len != 0) return finish_get(LUADART_ERRARG, NULL, type);
  op_args a = {0};
  a.s = name == NULL ? (const uint8_t*)"" : name;
  a.len = (size_t)len;
  return finish_get(run_protected(L, p_getglobal, &a, 0, 0, 1), &a, type);
}

int32_t luadart_rawget(lua_State* L, int32_t idx, int32_t* type) {
  if (!table_at(L, idx) || lua_gettop(L) < 1) {
    if (type != NULL) *type = LUA_TNONE;
    return LUADART_ERRARG;
  }
  int t = lua_rawget(L, idx);
  if (type != NULL) *type = t;
  return LUADART_OK;
}

int32_t luadart_rawgeti(lua_State* L, int32_t idx, int64_t i, int32_t* type) {
  if (type != NULL) *type = LUA_TNONE;
  if (!table_at(L, idx)) return LUADART_ERRARG;
  if (!lua_checkstack(L, 1)) return LUADART_ERRSTACK;
  int t = lua_rawgeti(L, idx, (lua_Integer)i);
  if (type != NULL) *type = t;
  return LUADART_OK;
}

int32_t luadart_getmetatable(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx) || !lua_checkstack(L, 1)) return 0;
  return lua_getmetatable(L, idx);
}

int32_t luadart_settable(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx) || lua_gettop(L) < 2) return LUADART_ERRARG;
  op_args a = {0};
  return run_protected(L, p_settable, &a, lua_absindex(L, idx), 2, 0);
}

int32_t luadart_setfield(lua_State* L, int32_t idx, const uint8_t* k,
                         uint64_t klen) {
  if (!index_ok(L, idx) || lua_gettop(L) < 1 || (k == NULL && klen != 0)) {
    return LUADART_ERRARG;
  }
  op_args a = {0};
  a.s = k == NULL ? (const uint8_t*)"" : k;
  a.len = (size_t)klen;
  return run_protected(L, p_setfield, &a, lua_absindex(L, idx), 1, 0);
}

int32_t luadart_seti(lua_State* L, int32_t idx, int64_t i) {
  if (!index_ok(L, idx) || lua_gettop(L) < 1) return LUADART_ERRARG;
  op_args a = {0};
  a.i = i;
  return run_protected(L, p_seti, &a, lua_absindex(L, idx), 1, 0);
}

int32_t luadart_setglobal(lua_State* L, const uint8_t* name, uint64_t len) {
  if (lua_gettop(L) < 1 || (name == NULL && len != 0)) return LUADART_ERRARG;
  op_args a = {0};
  a.s = name == NULL ? (const uint8_t*)"" : name;
  a.len = (size_t)len;
  return run_protected(L, p_setglobal, &a, 0, 1, 0);
}

int32_t luadart_rawset(lua_State* L, int32_t idx) {
  if (!table_at(L, idx) || lua_gettop(L) < 2) return LUADART_ERRARG;
  op_args a = {0};
  return run_protected(L, p_rawset, &a, lua_absindex(L, idx), 2, 0);
}

int32_t luadart_rawseti(lua_State* L, int32_t idx, int64_t i) {
  if (!table_at(L, idx) || lua_gettop(L) < 1) return LUADART_ERRARG;
  op_args a = {0};
  a.i = i;
  return run_protected(L, p_rawseti, &a, lua_absindex(L, idx), 1, 0);
}

int32_t luadart_setmetatable(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx) || lua_gettop(L) < 1) return LUADART_ERRARG;
  int mt = lua_type(L, -1);
  if (mt != LUA_TTABLE && mt != LUA_TNIL) return LUADART_ERRARG;
  lua_setmetatable(L, idx);
  return LUADART_OK;
}

int32_t luadart_next(lua_State* L, int32_t idx, int32_t* has_next) {
  if (has_next != NULL) *has_next = 0;
  if (!table_at(L, idx) || lua_gettop(L) < 1) return LUADART_ERRARG;
  op_args a = {0};
  int32_t status =
      run_protected(L, p_next, &a, lua_absindex(L, idx), 1, LUA_MULTRET);
  if (status == LUADART_OK && has_next != NULL) *has_next = a.out;
  return status;
}

// --- Operations ------------------------------------------------------------------

int32_t luadart_len(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx)) return LUADART_ERRARG;
  op_args a = {0};
  return run_protected(L, p_len, &a, lua_absindex(L, idx), 0, 1);
}

int32_t luadart_compare(lua_State* L, int32_t idx1, int32_t idx2, int32_t op,
                        int32_t* result) {
  if (result != NULL) *result = 0;
  if (!index_ok(L, idx1) || !index_ok(L, idx2) || op < LUA_OPEQ ||
      op > LUA_OPLE) {
    return LUADART_ERRARG;
  }
  if (!lua_checkstack(L, 2)) return LUADART_ERRSTACK;
  int a1 = lua_absindex(L, idx1);
  int a2 = lua_absindex(L, idx2);
  lua_pushvalue(L, a1);
  lua_pushvalue(L, a2);
  op_args a = {0};
  a.n = op;
  int32_t status = run_protected(L, p_compare, &a, 0, 2, 0);
  if (status == LUADART_ERRSTACK) {
    lua_pop(L, 2);
    return status;
  }
  if (status == LUADART_OK && result != NULL) *result = a.out;
  return status;
}

int32_t luadart_arith(lua_State* L, int32_t op) {
  if (op < LUA_OPADD || op > LUA_OPBNOT) return LUADART_ERRARG;
  int n = (op == LUA_OPUNM || op == LUA_OPBNOT) ? 1 : 2;
  if (lua_gettop(L) < n) return LUADART_ERRARG;
  op_args a = {0};
  a.n = op;
  return run_protected(L, p_arith, &a, 0, n, 1);
}

int32_t luadart_concat(lua_State* L, int32_t n) {
  if (n < 0 || n > lua_gettop(L)) return LUADART_ERRARG;
  op_args a = {0};
  a.n = n;
  return run_protected(L, p_concat, &a, 0, n, 1);
}

int32_t luadart_tostring_meta(lua_State* L, int32_t idx) {
  if (!index_ok(L, idx)) return LUADART_ERRARG;
  op_args a = {0};
  return run_protected(L, p_tostring_meta, &a, lua_absindex(L, idx), 0, 1);
}

int32_t luadart_where(lua_State* L, int32_t level) {
  if (level < 0) return LUADART_ERRARG;
  op_args a = {0};
  a.n = level;
  return run_protected(L, p_where, &a, 0, 0, 1);
}

int32_t luadart_argerror(lua_State* L, int32_t arg, const uint8_t* extramsg,
                         uint64_t len) {
  if (extramsg == NULL && len != 0) return LUADART_ERRARG;
  op_args a = {0};
  a.n = arg;
  a.s = extramsg == NULL ? (const uint8_t*)"" : extramsg;
  a.len = (size_t)len;
  return run_protected(L, p_argerror, &a, 0, 0, 1);
}

int32_t luadart_stringtonumber(lua_State* L, const uint8_t* s, uint64_t len) {
  if (s == NULL || s[len] != 0 || memchr(s, 0, (size_t)len) != NULL) return 0;
  if (!lua_checkstack(L, 1)) return 0;
  return lua_stringtonumber(L, (const char*)s) != 0;
}

int32_t luadart_ref(lua_State* L, int32_t idx, int32_t* ref) {
  if (ref != NULL) *ref = LUA_NOREF;
  if (!table_at(L, idx) || lua_gettop(L) < 1) return LUADART_ERRARG;
  op_args a = {0};
  int32_t status = run_protected(L, p_ref, &a, lua_absindex(L, idx), 1, 0);
  if (status == LUADART_OK && ref != NULL) *ref = a.out;
  return status;
}

int32_t luadart_unref(lua_State* L, int32_t idx, int32_t ref) {
  if (!table_at(L, idx)) return LUADART_ERRARG;
  op_args a = {0};
  a.n = ref;
  return run_protected(L, p_unref, &a, lua_absindex(L, idx), 0, 0);
}

// --- Load and call -----------------------------------------------------------------

int32_t luadart_load(lua_State* L, const uint8_t* chunk, uint64_t len,
                     const char* name) {
  if (chunk == NULL && len != 0) return LUADART_ERRARG;
  if (!lua_checkstack(L, 1)) return LUADART_ERRSTACK;
  const char* text = chunk == NULL ? "" : (const char*)chunk;
  // lua_load is protected: it returns a status and pushes the error message.
  if (lua_status(L) == LUA_OK) {
    return luaL_loadbufferx(L, text, (size_t)len, name, "t");
  }
  // A suspended or dead thread: load on the main thread, as run_protected.
  lua_State* M = vm_of(L)->main;
  if (!lua_checkstack(M, 1)) return LUADART_ERRSTACK;
  int status = luaL_loadbufferx(M, text, (size_t)len, name, "t");
  lua_xmove(M, L, 1);
  return status;
}

static int traceback_handler(lua_State* L) {
  const char* msg = lua_tostring(L, 1);
  if (msg == NULL) {
    if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) {
      return 1;
    }
    msg = lua_pushfstring(L, "(error object is a %s value)",
                          luaL_typename(L, 1));
  }
  luaL_traceback(L, L, msg, 1);
  return 1;
}

int32_t luadart_pcall(lua_State* L, int32_t nargs, int32_t nresults,
                      int32_t msgh, int32_t flags) {
  if (nargs < 0 || nresults < LUA_MULTRET || lua_gettop(L) < nargs + 1 ||
      (flags & ~LUADART_PCALL_TRACEBACK) != 0 || lua_status(L) != LUA_OK) {
    return LUADART_ERRARG;
  }
  int function = lua_gettop(L) - nargs;
  if (msgh != 0) {
    // The handler stays below the function, as with lua_pcall.
    if ((flags & LUADART_PCALL_TRACEBACK) || !stack_index_ok(L, msgh) ||
        lua_absindex(L, msgh) >= function) {
      return LUADART_ERRARG;
    }
    msgh = lua_absindex(L, msgh);
  }
  int extra = nresults > nargs ? nresults - nargs : 0;
  if (!lua_checkstack(L, extra + 2)) return LUADART_ERRSTACK;
  if ((flags & LUADART_PCALL_TRACEBACK) == 0) {
    return map_status(L, pcall_tracked(L, nargs, nresults, msgh));
  }
  int base = lua_gettop(L) - nargs;
  lua_pushcfunction(L, traceback_handler);
  lua_insert(L, base);
  int status = pcall_tracked(L, nargs, nresults, base);
  lua_remove(L, base);
  return map_status(L, status);
}

int32_t luadart_resume(lua_State* co, lua_State* from, int32_t nargs,
                       int32_t* nresults) {
  if (nresults != NULL) *nresults = 0;
  luadart_vm* vm = vm_of(co);
  if (from == NULL) from = vm->main;
  if (co == from || vm_of(from) != vm || nargs < 0) return LUADART_ERRARG;
  // Every case where lua_resume would push an error message outside its
  // protected body is rejected here.
  int status = lua_status(co);
  lua_Debug ar;
  if (status == LUA_OK) {
    if (lua_getstack(co, 0, &ar)) return LUADART_ERRARG;  // running or normal
    if (lua_gettop(co) < nargs + 1) return LUADART_ERRARG;  // dead
  } else if (status == LUA_YIELD) {
    if (lua_gettop(co) < nargs) return LUADART_ERRARG;
  } else {
    return LUADART_ERRARG;  // dead after an error
  }
  // lua_resume runs inside a protected call on `from`, so the rare error
  // that it raises outside its own protection ends in this file.
  op_args a = {0};
  a.co = co;
  a.from = from;
  a.n = nargs;
  int32_t outer = run_protected(from, p_resume, &a, 0, 0, 0);
  if (outer != LUADART_OK) {
    if (outer == LUADART_ERRARG || outer == LUADART_ERRSTACK) return outer;
    if (!lua_checkstack(co, 1)) {
      lua_pop(from, 1);
      return LUADART_ERRSTACK;
    }
    lua_xmove(from, co, 1);
    return outer;
  }
  if (a.status == LUA_OK || a.status == LUA_YIELD) {
    if (nresults != NULL) *nresults = a.nres;
    return a.status;
  }
  return map_status(co, a.status);
}

int32_t luadart_closethread(lua_State* co, lua_State* from) {
  luadart_vm* vm = vm_of(co);
  if (from == NULL) from = vm->main;
  if (co == vm->main || co == from || vm_of(from) != vm) return LUADART_ERRARG;
  lua_Debug ar;
  if (lua_status(co) == LUA_OK && lua_getstack(co, 0, &ar)) {
    return LUADART_ERRARG;  // running or normal
  }
  return lua_closethread(co, from);
}
