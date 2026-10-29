// Copied from telosnex lib/features/eval/lua_bridge.dart.
// ignore_for_file: type=lint
import 'package:lua_dart/lua_dart.dart';

// ── Lua → Dart conversion ───────────────────────────────────────────

/// Convert a Lua value at [index] to a Dart object.
///
/// - nil → null
/// - boolean → bool
/// - number → int or double
/// - string → String
/// - table → List (if sequential integer keys from 1) or Map
dynamic luaToDart(LuaState ls, int index) {
  final t = ls.type(index);
  switch (t) {
    case .luaNil:
    case .luaNone:
      return null;
    case .luaBoolean:
      return ls.toBoolean(index);
    case .luaNumber:
      final asInt = ls.toIntegerX(index);
      if (asInt != null) {
        // Check if the number is actually an integer (no fractional part).
        final asNum = ls.toNumber(index);
        if (asNum == asInt.toDouble()) return asInt;
        return asNum;
      }
      return ls.toNumber(index);
    case .luaString:
      return ls.toStr(index);
    case .luaTable:
      return _luaTableToDart(ls, index);
    case .luaFunction:
    case .luaLightUserdata: // coverage:ignore-line
    case .luaUserdata: // coverage:ignore-line
    case .luaThread: // coverage:ignore-line
      return ls.toStr(index) ?? ls.typeName(t);
  }
}

/// Convert a Lua table at [index] to a Dart Map or List.
const _kLuaArrayMeta = '__telosnex_array';

dynamic _luaTableToDart(LuaState ls, int index) {
  final absIdx = ls.absIndex(index);
  final len = ls.rawLen(absIdx);

  // Empty Lua tables are ambiguous: `{}` can mean [] or {}.
  // When Dart->Lua sees an empty List, dartToLua tags the table's
  // metatable with `__telosnex_array = true`. Preserve that intent
  // on the way back so empty lists roundtrip as List, not Map.
  if (len == 0 && ls.getMetatable(absIdx)) {
    ls.getField(-1, _kLuaArrayMeta);
    final isArray = ls.toBoolean(-1);
    ls.pop(2); // marker + metatable
    if (isArray) return <dynamic>[];
  }

  // Array iff the key set is exactly the integers 1..len. The previous
  // heuristic only probed the first iteration key; a table mixing an array
  // part with hash keys (`{[1]="a", x="b"}`), a sparse table
  // (`{[1]="a", [3]="c"}`), or a sequence with a nil hole then converted
  // to a List of the first `len` slots and SILENTLY DROPPED every other
  // entry — corrupting persisted Mod state on every render/persist cycle.
  // Such tables now fall through to the Map path, which preserves all
  // entries (numeric keys stringified, as JSON requires).
  if (len > 0) {
    bool isArray = true;
    int keyCount = 0;
    ls.pushNil();
    while (ls.next(absIdx)) {
      final key = ls.toIntegerX(-2);
      if (key == null || key < 1 || key > len) {
        isArray = false;
        ls.pop(2); // pop key + value
        break;
      }
      keyCount++;
      ls.pop(1); // pop value, keep key for next iteration
    }
    // keyCount < len means holes below the raw length (e.g. {"a", nil,
    // "c"} when rawLen reports 3): not a dense array either.
    if (isArray && keyCount == len) {
      final list = <dynamic>[];
      for (int i = 1; i <= len; i++) {
        ls.rawGetI(absIdx, i);
        list.add(luaToDart(ls, -1));
        ls.pop(1);
      }
      return list;
    }
  }

  // General table → Map<String, dynamic>.
  final map = <String, dynamic>{};
  ls.pushNil();
  while (ls.next(absIdx)) {
    final key = ls.toStr(-2) ?? ls.toInteger(-2).toString();
    map[key] = luaToDart(ls, -1);
    ls.pop(1); // pop value, keep key for next iteration
  }
  return map;
}

// ── Dart → Lua conversion ───────────────────────────────────────────

/// Push a Dart value onto the Lua stack.
void dartToLua(LuaState ls, dynamic value) {
  if (value == null) {
    ls.pushNil();
  } else if (value is bool) {
    ls.pushBoolean(value);
  } else if (value is int) {
    ls.pushInteger(value);
  } else if (value is double) {
    ls.pushNumber(value);
  } else if (value is String) {
    ls.pushString(value);
  } else if (value is List) {
    ls.createTable(value.length, 0);
    for (int i = 0; i < value.length; i++) {
      dartToLua(ls, value[i]);
      ls.rawSetI(-2, i + 1); // Lua arrays are 1-based
    }
    if (value.isEmpty) {
      // Empty Lua tables are shape-ambiguous. Tag the metatable so
      // luaToDart can roundtrip this back to [] instead of {}.
      ls.createTable(0, 1);
      ls.pushBoolean(true);
      ls.setField(-2, _kLuaArrayMeta);
      ls.setMetatable(-2);
    }
  } else if (value is Map) {
    ls.createTable(0, value.length);
    for (final entry in value.entries) {
      ls.pushString(entry.key.toString());
      dartToLua(ls, entry.value);
      ls.setTable(-3);
    }
  } else {
    ls.pushString(value.toString());
  }
}
