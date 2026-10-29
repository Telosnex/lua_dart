// lua_dart: a stable C ABI over the reference Lua 5.4 (PUC-Rio).
//
// Rules of this ABI:
//
// * Fixed-width types only. lua_State is opaque.
// * No Lua error crosses the boundary. Lua raises errors with longjmp, and a
//   longjmp over a Dart frame is undefined behavior. Every function that can
//   raise a Lua error (allocation, metamethods, the garbage collector) runs
//   inside lua_pcall here and returns a status.
// * Every stack index is checked. A bad index or a missing stack slot gives
//   LUADART_ERRARG or LUADART_ERRSTACK and leaves the stack unchanged.
// * Host functions are Lua C closures of one trampoline. The trampoline calls
//   the luadart_host_fn of the state, and raises the Lua error itself after
//   the host function returns (see luadart_host_fn).
// * Chunks load as text only. Precompiled bytecode is never accepted.
// * A lua_State and its threads are used by one OS thread at a time.
//   luadart_interrupt and the luadart_interrupt_handle_* functions are the
//   only functions that another thread may call.
//
// Status results of the functions that return a status:
//
// * LUADART_OK: the function did what its Lua API counterpart does.
// * LUADART_ERRRUN, LUADART_ERRMEM, LUADART_ERRERR, LUADART_ERRSYNTAX,
//   LUADART_ERRINTERRUPT: the inputs that the function
//   consumes are consumed, and the error object is on the top of the stack.
// * LUADART_ERRARG, LUADART_ERRSTACK: the stack is unchanged and there is no
//   error object.
#ifndef LUA_DART_H
#define LUA_DART_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUADART_ABI_VERSION 2

typedef struct lua_State lua_State;

// Status values. 0 to 5 are the values of the Lua API.
#define LUADART_OK 0
#define LUADART_YIELD 1
#define LUADART_ERRRUN 2
#define LUADART_ERRSYNTAX 3
#define LUADART_ERRMEM 4
#define LUADART_ERRERR 5
// A stack index is not valid, or an argument is out of range.
#define LUADART_ERRARG 100
// The stack cannot grow by the slots that the function needs.
#define LUADART_ERRSTACK 101
// luadart_interrupt was called.
#define LUADART_ERRINTERRUPT 103

// Value types, as in lua.h.
#define LUADART_TNONE (-1)
#define LUADART_TNIL 0
#define LUADART_TBOOLEAN 1
#define LUADART_TLIGHTUSERDATA 2
#define LUADART_TNUMBER 3
#define LUADART_TSTRING 4
#define LUADART_TTABLE 5
#define LUADART_TFUNCTION 6
#define LUADART_TUSERDATA 7
#define LUADART_TTHREAD 8

// Standard libraries for luadart_open_libs.
#define LUADART_LIB_BASE (1u << 0)
#define LUADART_LIB_PACKAGE (1u << 1)
#define LUADART_LIB_COROUTINE (1u << 2)
#define LUADART_LIB_TABLE (1u << 3)
#define LUADART_LIB_IO (1u << 4)
#define LUADART_LIB_OS (1u << 5)
#define LUADART_LIB_STRING (1u << 6)
#define LUADART_LIB_MATH (1u << 7)
#define LUADART_LIB_UTF8 (1u << 8)
#define LUADART_LIB_DEBUG (1u << 9)
// json.decode and json.encode, with the values of dart:convert
// (src/lua_dart_json.c has the rules). Safe in a sandbox.
#define LUADART_LIB_JSON (1u << 10)
#define LUADART_LIB_ALL 0x7FFu

// json.decode gives an empty JSON array a metatable with this field set to
// true; json.encode writes an empty table with it as [], not {}.
#define LUADART_JSON_ARRAY_MARKER "__json_array"

// luadart_open_libs flag. The package, io and debug libraries are not
// allowed. Base: `load` accepts text chunks only, and `dofile` and
// `loadfile` are removed. Os: `execute`, `exit`, `getenv`, `remove`,
// `rename`, `setlocale` and `tmpname` are removed.
#define LUADART_OPEN_SANDBOX (1u << 0)

// luadart_pcall flag: the error object is a string with a stack traceback.
#define LUADART_PCALL_TRACEBACK (1 << 0)

// Operations of luadart_host_fn.
#define LUADART_HOST_CALL 0
#define LUADART_HOST_RELEASE 1

// Results of luadart_host_fn for LUADART_HOST_CALL, other than a result
// count.
// The error object is on the top of the stack; the trampoline raises it.
#define LUADART_HOST_ERROR (-1)
// The host function failed and pushed no error object.
#define LUADART_HOST_ERROR_NO_OBJECT (-2)

// Called on the thread that runs Lua.
//
// LUADART_HOST_CALL: `L` is the thread that called host function
// `function_id`; its arguments are at 1 .. luadart_gettop(L). Return the
// number of results on the top of the stack, LUADART_HOST_ERROR, or
// LUADART_HOST_ERROR_NO_OBJECT.
//
// LUADART_HOST_RELEASE: the garbage collector freed the last closure of
// `function_id`. Do not call Lua. The result is ignored.
//
// `token` is the value given to luadart_new_state.
typedef int32_t (*luadart_host_fn)(int64_t token, lua_State* L,
                                   int64_t function_id, int32_t op);

// --- Library ---------------------------------------------------------------

// LUADART_ABI_VERSION of the library.
int32_t luadart_abi_version(void);

// A static NUL-terminated string such as "lua_dart ABI 2; Lua 5.4.9".
const char* luadart_build_info(void);

// LUA_REGISTRYINDEX, the pseudo-index of the registry.
int32_t luadart_registry_index(void);

// --- State -----------------------------------------------------------------

// A new state with no libraries. `memory_limit` is in bytes; 0 means no
// limit. `host` may be NULL; then calls of host functions raise an error.
// NULL if memory runs out.
lua_State* luadart_new_state(uint64_t memory_limit, luadart_host_fn host,
                             int64_t host_token);

// Closes the state of `L` (any thread of it). The host function is detached
// first, and Lua code does not run during the close: finalizers that run Lua
// code fail. Safe on NULL. Do not call it while Lua runs on the state.
void luadart_close(lua_State* L);

// Opens the standard libraries in `libs` (LUADART_LIB_*) as globals.
// `flags`: LUADART_OPEN_SANDBOX. Returns a status.
int32_t luadart_open_libs(lua_State* L, uint32_t libs, uint32_t flags);

// --- Limits ----------------------------------------------------------------

// Bytes; 0 means no limit. An allocation over the limit fails with a Lua
// memory error. Memory in use above a new lower limit stays allocated.
void luadart_set_memory_limit(lua_State* L, uint64_t bytes);

// Bytes in use by the state.
uint64_t luadart_memory_used(lua_State* L);

// Makes the running Lua code of the state fail with LUADART_ERRINTERRUPT at
// its next VM instruction, and all Lua code after it, until
// luadart_clear_interrupt: a `pcall` in the script cannot continue. The only
// function that another OS thread may call. Lua code in one C function call,
// for example one `string.find`, is not interrupted.
void luadart_interrupt(lua_State* L);

// Clears an interrupt. Call it on the thread that uses the state, while no
// Lua code runs.
void luadart_clear_interrupt(lua_State* L);

// An interrupt that another thread can trigger at any time, also while the
// state closes or after it closed. luadart_interrupt is only safe while the
// state is open. A handle has a reference count; it is freed when the count
// is 0. A handle is attached to at most one state at a time.
typedef struct luadart_interrupt_handle luadart_interrupt_handle;

// A new handle with one reference, or NULL if no memory. Any thread.
luadart_interrupt_handle* luadart_interrupt_handle_new(void);

// Adds a reference. Any thread.
void luadart_interrupt_handle_retain(luadart_interrupt_handle* h);

// Removes a reference; frees the handle at 0. Any thread. NULL does nothing.
void luadart_interrupt_handle_release(luadart_interrupt_handle* h);

// Interrupts the attached state (luadart_interrupt), and every state that
// the handle is attached to later. Any thread.
void luadart_interrupt_handle_trigger(luadart_interrupt_handle* h);

// 1 if the handle was triggered, else 0. Any thread.
int32_t luadart_interrupt_handle_triggered(luadart_interrupt_handle* h);

// Attaches the handle to the state. Takes over one reference of the caller,
// also on failure. LUADART_ERRARG if the state has a handle, or the handle
// has a state. If the handle was triggered, interrupts the state at once.
// luadart_close detaches the handle.
int32_t luadart_attach_interrupt_handle(lua_State* L,
                                        luadart_interrupt_handle* h);

// Detaches the handle of the state and releases its reference. Nothing if
// the state has no handle.
void luadart_detach_interrupt_handle(lua_State* L);

// lua_gc for LUA_GCSTOP (0), LUA_GCRESTART (1), LUA_GCCOLLECT (2),
// LUA_GCCOUNT (3), LUA_GCCOUNTB (4), LUA_GCSTEP (5) and LUA_GCISRUNNING (9).
// `*out` gets the result of lua_gc. Returns a status.
int32_t luadart_gc(lua_State* L, int32_t what, int32_t arg, int32_t* out);

// --- Stack -----------------------------------------------------------------

int32_t luadart_gettop(lua_State* L);

// Returns a status. Growing the stack pushes nils.
int32_t luadart_settop(lua_State* L, int32_t idx);

// The absolute index of a valid stack index, or the registry index; 0 if
// `idx` is not valid.
int32_t luadart_absindex(lua_State* L, int32_t idx);

// 1 if the stack has, or could grow to have, `n` more free slots; else 0.
int32_t luadart_checkstack(lua_State* L, int32_t n);

int32_t luadart_pushvalue(lua_State* L, int32_t idx);
int32_t luadart_rotate(lua_State* L, int32_t idx, int32_t n);
int32_t luadart_copy(lua_State* L, int32_t from_idx, int32_t to_idx);

// Pops `n` values from `from` and pushes them on `to`. Both threads must be
// of one state.
int32_t luadart_xmove(lua_State* from, lua_State* to, int32_t n);

// --- Access ----------------------------------------------------------------

// LUADART_T*; LUADART_TNONE for an index without a value.
int32_t luadart_type(lua_State* L, int32_t idx);

int32_t luadart_isinteger(lua_State* L, int32_t idx);
// 1 for a number or a string convertible to a number.
int32_t luadart_isnumber(lua_State* L, int32_t idx);
// 1 for a string or a number.
int32_t luadart_isstring(lua_State* L, int32_t idx);
// 1 if the value is a function made by luadart_push_host_function.
int32_t luadart_is_host_function(lua_State* L, int32_t idx);
int32_t luadart_toboolean(lua_State* L, int32_t idx);
int64_t luadart_tointegerx(lua_State* L, int32_t idx, int32_t* isnum);
double luadart_tonumberx(lua_State* L, int32_t idx, int32_t* isnum);

// The bytes of a string or of a number in the format of `tostring`, else
// NULL. Unlike lua_tolstring, a number on the stack stays a number.
// The bytes of a string are valid while the string is on the stack; the bytes
// of a number are valid until the next call of this function on the state.
const uint8_t* luadart_tolstring(lua_State* L, int32_t idx, uint64_t* len);

uint64_t luadart_rawlen(lua_State* L, int32_t idx);
int32_t luadart_rawequal(lua_State* L, int32_t idx1, int32_t idx2);

// The thread at `idx`, else NULL. It stays valid while Lua refers to it.
lua_State* luadart_tothread(lua_State* L, int32_t idx);

// lua_status of the thread.
int32_t luadart_status(lua_State* L);

// --- Push ------------------------------------------------------------------

int32_t luadart_pushnil(lua_State* L);
int32_t luadart_pushboolean(lua_State* L, int32_t b);
int32_t luadart_pushinteger(lua_State* L, int64_t n);
int32_t luadart_pushnumber(lua_State* L, double n);
int32_t luadart_pushlstring(lua_State* L, const uint8_t* s, uint64_t len);
int32_t luadart_pushglobaltable(lua_State* L);

// Pushes a Lua function that calls the host function of the state with
// `function_id`. LUADART_HOST_RELEASE tells when it is garbage.
int32_t luadart_push_host_function(lua_State* L, int64_t function_id);

// Pushes a new thread and sets `*out` to it.
int32_t luadart_newthread(lua_State* L, lua_State** out);

// --- Tables ----------------------------------------------------------------
// The getters set `*type` (if not NULL) to the type of the pushed value.

int32_t luadart_createtable(lua_State* L, int32_t narr, int32_t nrec);
// t[k] with k on the top; pops k.
int32_t luadart_gettable(lua_State* L, int32_t idx, int32_t* type);
int32_t luadart_getfield(lua_State* L, int32_t idx, const uint8_t* k,
                         uint64_t klen, int32_t* type);
int32_t luadart_geti(lua_State* L, int32_t idx, int64_t i, int32_t* type);
int32_t luadart_getglobal(lua_State* L, const uint8_t* name, uint64_t len,
                          int32_t* type);
int32_t luadart_rawget(lua_State* L, int32_t idx, int32_t* type);
int32_t luadart_rawgeti(lua_State* L, int32_t idx, int64_t i, int32_t* type);
// Pushes the metatable and returns 1, or returns 0 and pushes nothing.
int32_t luadart_getmetatable(lua_State* L, int32_t idx);

// t[k] = v with k and v on the top; pops both.
int32_t luadart_settable(lua_State* L, int32_t idx);
// The setters below pop the value on the top.
int32_t luadart_setfield(lua_State* L, int32_t idx, const uint8_t* k,
                         uint64_t klen);
int32_t luadart_seti(lua_State* L, int32_t idx, int64_t i);
int32_t luadart_setglobal(lua_State* L, const uint8_t* name, uint64_t len);
int32_t luadart_rawset(lua_State* L, int32_t idx);
int32_t luadart_rawseti(lua_State* L, int32_t idx, int64_t i);
// Pops a table or nil and sets it as the metatable of the value at `idx`.
int32_t luadart_setmetatable(lua_State* L, int32_t idx);

// lua_next: pops a key, and pushes the next key and value and sets
// `*has_next` to 1, or sets it to 0 at the end.
int32_t luadart_next(lua_State* L, int32_t idx, int32_t* has_next);

// --- Operations ------------------------------------------------------------

// Pushes #v, with metamethods.
int32_t luadart_len(lua_State* L, int32_t idx);
// `*result` is lua_compare with LUA_OPEQ (0), LUA_OPLT (1) or LUA_OPLE (2).
int32_t luadart_compare(lua_State* L, int32_t idx1, int32_t idx2, int32_t op,
                        int32_t* result);
// lua_arith with LUA_OPADD (0) .. LUA_OPBNOT (13).
int32_t luadart_arith(lua_State* L, int32_t op);
int32_t luadart_concat(lua_State* L, int32_t n);
// Pushes luaL_tolstring of the value: `tostring`, with `__tostring` and
// `__name`.
int32_t luadart_tostring_meta(lua_State* L, int32_t idx);
// Pushes luaL_where for the caller `level` levels up: 1 is the function that
// called the running host function.
int32_t luadart_where(lua_State* L, int32_t level);
// Pushes the message that luaL_argerror raises for argument `arg` of the
// running host function, for example "x.lua:3: bad argument #1 to 'f'
// (string expected, got nil)". `extramsg` has `len` bytes.
int32_t luadart_argerror(lua_State* L, int32_t arg, const uint8_t* extramsg,
                         uint64_t len);
// lua_stringtonumber. `s` has `len` bytes and a NUL after them. Returns 1 and
// pushes the number, or returns 0.
int32_t luadart_stringtonumber(lua_State* L, const uint8_t* s, uint64_t len);
// luaL_ref: pops a value and sets `*ref`. LUA_REFNIL (-1) for nil.
int32_t luadart_ref(lua_State* L, int32_t idx, int32_t* ref);
int32_t luadart_unref(lua_State* L, int32_t idx, int32_t ref);

// --- Load and call -----------------------------------------------------------

// Loads a text chunk and pushes it as a function, or pushes the error
// message. `name` is NUL-terminated, for example "=input".
int32_t luadart_load(lua_State* L, const uint8_t* chunk, uint64_t len,
                     const char* name);

// lua_pcall. `msgh` is 0 or the stack index of a message handler below the
// function. `flags`: LUADART_PCALL_TRACEBACK, which needs `msgh` 0.
int32_t luadart_pcall(lua_State* L, int32_t nargs, int32_t nresults,
                      int32_t msgh, int32_t flags);

// lua_resume of `co` from `from` (the running thread; NULL for the main
// thread). `*nresults` gets the count of yielded or returned values. A thread
// that cannot be resumed gives LUADART_ERRARG.
int32_t luadart_resume(lua_State* co, lua_State* from, int32_t nargs,
                       int32_t* nresults);

// lua_closethread: closes the pending to-be-closed variables of `co` and
// resets it. A running or normal thread gives LUADART_ERRARG.
int32_t luadart_closethread(lua_State* co, lua_State* from);

#ifdef __cplusplus
}
#endif

#endif  // LUA_DART_H
