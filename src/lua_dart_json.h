// The json library of lua_dart (lua_dart_json.c). Not part of the C ABI.
#ifndef LUA_DART_JSON_H
#define LUA_DART_JSON_H

#include "lua.h"

// luaopen_* of the json library: a table with decode and encode. The state
// must come from luadart_new_state.
int luadart_open_json(lua_State* L);

#endif
