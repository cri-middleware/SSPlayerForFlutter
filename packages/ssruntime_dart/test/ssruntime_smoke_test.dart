import 'dart:ffi' as ffi;

import 'package:test/test.dart';
import 'package:ssruntime_dart/ssruntime_dart.dart';

/// Smoke test for the native-assets `@Native` bindings.
///
/// `dart test` runs `hook/build.dart`, which bundles the prebuilt `libssruntime`
/// (from `native/libs/`, produced by scripts/build-runtime.sh) as a code asset;
/// the `@Native(assetId: 'package:ssruntime_dart/ssruntime')` functions resolve
/// it — no `SSRUNTIME_LIBRARY_PATH` / `DynamicLibrary.open`.
void main() {
  test('@Native ss_runtime_create/destroy resolve the bundled libssruntime', () {
    final ctx = ss_runtime_create();
    expect(ctx, isNot(equals(ffi.nullptr)),
        reason: 'ss_runtime_create via the bundled code asset');
    ss_runtime_destroy(ctx);
  });
}
