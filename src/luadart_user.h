// Included at the end of lua.h (LUA_USER_H). It makes Lua deterministic: the
// same code and inputs give the same results in every state, on every
// platform.
#ifndef LUADART_USER_H
#define LUADART_USER_H

// A fixed seed for string hashes, so the order of pairs and next is the same
// in every state. Reference Lua takes it from addresses and the time, against
// hash flooding. A state has a memory limit and an interrupt for that.
#define luai_makeseed(L) ((unsigned int)0x2A3C5E71u)

// table.sort chooses no random pivot: reference Lua uses clock and time, so
// the order of equal elements changes from run to run.
#define l_randomizePivot() 0u

#endif
