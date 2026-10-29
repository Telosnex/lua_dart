// A classic (not module) Worker, as squadron starts them: it loads the
// lua_dart module with import() and runs a chunk.
self.onmessage = async (event) => {
  try {
    const factory = (await import(event.data.moduleUrl)).default;
    const m = await factory();
    const enc = new TextEncoder();
    const host = m.addFunction(() => 0, 'ijpji');
    const L = m._luadart_new_state(0n, host, 1n);
    m._luadart_open_libs(L, 0x1ed, 1);
    const code = enc.encode('return coroutine.wrap(function() return _VERSION end)()');
    const p = m._malloc(code.length + 8);
    m.HEAPU8.set(code, p);
    m.HEAPU8.set(enc.encode('=w\0'), p + code.length);
    let status = m._luadart_load(L, p, BigInt(code.length), p + code.length);
    if (status === 0) status = m._luadart_pcall(L, 0, 1, 0, 0);
    const len = m._malloc(8);
    const s = m._luadart_tolstring(L, -1, len);
    const n = new DataView(m.HEAPU8.buffer).getUint32(len, true);
    const text = new TextDecoder().decode(m.HEAPU8.subarray(s, s + n));
    m._luadart_close(L);
    self.postMessage({status, text});
  } catch (e) {
    self.postMessage({error: String(e)});
  }
};
