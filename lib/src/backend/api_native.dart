// The native backend: the C ABI through dart:ffi. lib/src/backend/
// api_web.dart has the same functions over WebAssembly. Pointers are int
// addresses in both.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../lua_dart_bindings_generated.dart' as b;
import 'constants.g.dart';

export 'dart:ffi' show Finalizable;

export 'api_native.g.dart';

/// Bytes of a pointer.
const pointerSize = 8;

/// Native code needs no loading.
Future<void> loadRuntime_({Uri? moduleUri}) async {}

bool get runtimeLoaded => true;

int memAlloc(int bytes) {
  final p = malloc<Uint8>(bytes);
  if (p == nullptr) throw OutOfMemoryError();
  return p.address;
}

void memFree(int address) => malloc.free(Pointer<Uint8>.fromAddress(address));

@pragma('vm:prefer-inline')
int readI32(int address) => Pointer<Int32>.fromAddress(address).value;

/// A uint64 below 2^63.
@pragma('vm:prefer-inline')
int readU64(int address) => Pointer<Int64>.fromAddress(address).value;

@pragma('vm:prefer-inline')
int readPointer(int address) => Pointer<IntPtr>.fromAddress(address).value;

String readCString(int address) =>
    Pointer<Utf8>.fromAddress(address).toDartString();

/// [length] bytes at [address] as UTF-8; invalid UTF-8 becomes U+FFFD. A
/// leading byte order mark stays: utf8.decode would drop it.
String decodeUtf8(int address, int length) {
  final view = Pointer<Uint8>.fromAddress(address).asTypedList(length);
  for (var i = 0; i < length; i++) {
    if (view[i] >= 0x80) {
      if (length >= 3 &&
          view[0] == 0xEF &&
          view[1] == 0xBB &&
          view[2] == 0xBF) {
        // Decode after a space, which is then removed: utf8.decode keeps a
        // mark that is not at the start.
        return utf8.decode([0x20, ...view], allowMalformed: true).substring(1);
      }
      return utf8.decode(view, allowMalformed: true);
    }
  }
  return String.fromCharCodes(view);
}

Uint8List copyBytes(int address, int length) =>
    Uint8List.fromList(Pointer<Uint8>.fromAddress(address).asTypedList(length));

void writeBytes(int address, Uint8List bytes) => Pointer<Uint8>.fromAddress(
  address,
).asTypedList(bytes.length).setAll(0, bytes);

/// Writes [s] as UTF-8 and a NUL at [address], which has room for
/// `3 * s.length + 1` bytes. Returns the UTF-8 length.
int encodeUtf8(String s, int address) {
  final n = s.length;
  final buffer = Pointer<Uint8>.fromAddress(address);
  for (var i = 0; i < n; i++) {
    final unit = s.codeUnitAt(i);
    if (unit >= 0x80) {
      final bytes = utf8.encode(s);
      buffer.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return bytes.length;
    }
    buffer[i] = unit;
  }
  buffer[n] = 0;
  return n;
}

/// The host function of luadart_new_state: calls [dispatch] with the
/// arguments of luadart_host_fn.
int hostFunction(int Function(int token, int l, int id, int op) dispatch) {
  final callable = NativeCallable<b.luadart_host_fnFunction>.isolateLocal(
    (int token, Pointer<b.lua_State> l, int id, int op) =>
        dispatch(token, l.address, id, op),
    exceptionalReturn: LUADART_HOST_ERROR_NO_OBJECT,
  );
  callable.keepIsolateAlive = false;
  return callable.nativeFunction.address;
}

final _close = NativeFinalizer(
  Native.addressOf<NativeFunction<Void Function(Pointer<b.lua_State>)>>(
    b.luadart_close,
  ).cast(),
);
final _free = NativeFinalizer(malloc.nativeFree);
final _release = NativeFinalizer(
  Native.addressOf<
        NativeFunction<Void Function(Pointer<b.luadart_interrupt_handle>)>
      >(b.luadart_interrupt_handle_release)
      .cast(),
);

/// Releases the interrupt handle [h] when [owner] is unreachable.
void attachRelease(Finalizable owner, int h) =>
    _release.attach(owner, Pointer.fromAddress(h));

/// Closes the state [l] when [owner] is unreachable, unless detached.
void attachClose(Finalizable owner, int l) =>
    _close.attach(owner, Pointer.fromAddress(l), detach: owner);

void detachClose(Finalizable owner) => _close.detach(owner);

/// Frees [address] when [owner] is unreachable, unless detached.
void attachFree(Finalizable owner, int address) =>
    _free.attach(owner, Pointer.fromAddress(address), detach: owner);

void detachFree(Finalizable owner) => _free.detach(owner);
