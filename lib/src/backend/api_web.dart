// The web backend: the C ABI in the Emscripten module of
// tool/kiln/build_web.dart, called synchronously on the current thread.
// lib/src/backend/api_native.dart has the same functions over dart:ffi.

import 'dart:js_interop';
import 'dart:typed_data';

import 'web_module.dart';

export 'api_web.g.dart';

/// Marks objects that own native memory. dart:ffi has the real one.
abstract interface class Finalizable {}

/// Bytes of a pointer (wasm32).
const pointerSize = 4;

/// Loads the Emscripten module from [moduleUri], by default the file that
/// the build hook installs (`kiln/lua_dart/lua_dart_module.mjs`).
Future<void> loadRuntime_({Uri? moduleUri}) => loadModule(moduleUri);

bool get runtimeLoaded => moduleLoaded;

Uri? get runtimeModuleUri_ => moduleUrl;

int memAlloc(int bytes) {
  final p = exports.malloc(bytes.toJS).toDartInt;
  if (p == 0) throw OutOfMemoryError();
  return p;
}

void memFree(int address) => exports.free(address.toJS);

ByteData _data() => exports.heap.toDart.buffer.asByteData();

int readI32(int address) => _data().getInt32(address, Endian.little);

/// A uint64 below 2^53.
int readU64(int address) {
  final data = _data();
  return data.getUint32(address, Endian.little) +
      data.getUint32(address + 4, Endian.little) * 0x100000000;
}

int readPointer(int address) => _data().getUint32(address, Endian.little);

String readCString(int address) => exports.utf8ToString(address.toJS).toDart;

@JS('TextDecoder')
extension type _TextDecoder._(JSObject _) implements JSObject {
  external factory _TextDecoder(JSString label, _DecoderOptions options);
  external JSString decode(JSUint8Array bytes);
}

@JS('TextEncoder')
extension type _TextEncoder._(JSObject _) implements JSObject {
  external factory _TextEncoder();
  external _EncodeResult encodeInto(JSString s, JSUint8Array into);
}

extension type _EncodeResult._(JSObject _) implements JSObject {
  external JSNumber get written;
}

extension type _Uint8Array._(JSUint8Array _) implements JSUint8Array {
  external JSUint8Array subarray(JSNumber begin, JSNumber end);
  external JSUint8Array slice(JSNumber begin, JSNumber end);
  external void set(JSUint8Array source, JSNumber offset);
}

extension type _DecoderOptions._(JSObject _) implements JSObject {
  external factory _DecoderOptions({bool ignoreBOM});
}

// Not fatal: invalid UTF-8 becomes U+FFFD, as on native. ignoreBOM: a
// leading byte order mark stays in the text.
final _decoder = _TextDecoder('utf-8'.toJS, _DecoderOptions(ignoreBOM: true));
final _encoder = _TextEncoder();

_Uint8Array get _heap => _Uint8Array._(exports.heap);

String decodeUtf8(int address, int length) => _decoder
    .decode(_heap.subarray(address.toJS, (address + length).toJS))
    .toDart;

Uint8List copyBytes(int address, int length) =>
    _heap.slice(address.toJS, (address + length).toJS).toDart;

void writeBytes(int address, Uint8List bytes) =>
    _heap.set(bytes.toJS, address.toJS);

/// Writes [s] as UTF-8 and a NUL at [address], which has room for
/// `3 * s.length + 1` bytes. Returns the UTF-8 length.
int encodeUtf8(String s, int address) {
  final heap = _heap;
  final written = _encoder
      .encodeInto(
        s.toJS,
        heap.subarray(address.toJS, (address + 3 * s.length).toJS),
      )
      .written
      .toDartInt;
  heap.toDart[address + written] = 0;
  return written;
}

/// The host function of luadart_new_state, in the function table: calls
/// [dispatch] with the arguments of luadart_host_fn.
int hostFunction(int Function(int token, int l, int id, int op) dispatch) {
  int call(JSBigInt token, JSNumber l, JSBigInt id, JSNumber op) {
    try {
      return dispatch(
        fromBigInt(token),
        l.toDartInt,
        fromBigInt(id),
        op.toDartInt,
      );
    } catch (_) {
      return -2; // LUADART_HOST_ERROR_NO_OBJECT
    }
  }

  // int32_t (int64_t, lua_State*, int64_t, int32_t)
  return exports.addFunction(call.toJS, 'ijpji'.toJS).toDartInt;
}

final _close = Finalizer<int>((l) {
  if (moduleLoaded) exports.luadart_close(l.toJS);
});
final _release = Finalizer<int>((h) {
  if (moduleLoaded) exports.luadart_interrupt_handle_release(h.toJS);
});

/// Releases the interrupt handle [h] when [owner] is unreachable.
void attachRelease(Finalizable owner, int h) => _release.attach(owner, h);

final _free = Finalizer<int>((address) {
  if (moduleLoaded) memFree(address);
});

/// Closes the state [l] when [owner] is unreachable, unless detached.
void attachClose(Finalizable owner, int l) =>
    _close.attach(owner, l, detach: owner);

void detachClose(Finalizable owner) => _close.detach(owner);

/// Frees [address] when [owner] is unreachable, unless detached.
void attachFree(Finalizable owner, int address) =>
    _free.attach(owner, address, detach: owner);

void detachFree(Finalizable owner) => _free.detach(owner);
