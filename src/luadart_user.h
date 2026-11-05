// Included at the end of lua.h (LUA_USER_H). It makes Lua deterministic: the
// same code and inputs give the same results in every state, on every
// platform.
#ifndef LUADART_USER_H
#define LUADART_USER_H

// The seed of string hashes is fixed in luadart_new_state (lua_dart.c), so
// the order of pairs and next is the same in every state. luai_makeseed stays
// random: since Lua 5.5 it also seeds math.random.

// table.sort chooses no random pivot: reference Lua uses luaL_makeseed, so
// the order of equal elements changes from run to run.
#define l_randomizePivot(L) 0u

#endif
