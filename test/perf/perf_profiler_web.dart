// The browser has no VM service: profiling is off there.
class PerfProfiler {
  Future<bool> connect() async => false;
  Future<void> clearSamples() async {}
  Future<void> collectAndPrint({int topN = 20, String? label}) async {}
  Future<void> dispose() async {}
}
