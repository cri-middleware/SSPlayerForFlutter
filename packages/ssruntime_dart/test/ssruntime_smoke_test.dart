import 'dart:io';

import 'package:test/test.dart';
import 'package:ssruntime_dart/ssruntime_dart.dart';

/// Smoke test for the Layer-1 runtime loader/bindings.
///
/// Loading `libssruntime` needs the native library: set
/// `SSRUNTIME_LIBRARY_PATH` (e.g. the framework binary built by
/// scripts/build-runtime.sh). When unset, the loading test skips — the
/// rendering pipeline is exercised end-to-end by ssplayer_flutter's tests.
void main() {
  test('SsRuntime.open loads the Brain when SSRUNTIME_LIBRARY_PATH is set', () {
    final path = Platform.environment['SSRUNTIME_LIBRARY_PATH'];
    if (path == null || path.isEmpty) {
      markTestSkipped('set SSRUNTIME_LIBRARY_PATH to exercise the loader');
      return;
    }
    final rt = SsRuntime.open();
    expect(rt.bindings, isA<SsRuntimeBindings>());
    expect(rt.dynamicLibrary.providesSymbol('ss_runtime_create'), isTrue);
  });
}
