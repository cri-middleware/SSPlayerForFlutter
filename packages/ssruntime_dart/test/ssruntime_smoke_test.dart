import 'dart:ffi' as ffi;

import 'package:test/test.dart';
// The raw @Native bindings are not exported from the public barrel (it must stay
// dart:ffi-free so Layer 2 compiles for the web); this native-only smoke test
// reaches them directly.
import 'package:ssruntime_dart/src/ssruntime_bindings.g.dart';

/// Smoke test for the native-assets `@Native` bindings.
///
/// `dart test` runs `hook/build.dart`, which bundles the prebuilt `libssruntime`
/// (from `native/libs/`, produced by scripts/build-runtime.sh) as a code asset;
/// the `@Native(assetId: 'package:ssruntime_dart/ssruntime')` functions resolve
/// it.
void main() {
  test('@Native ss_runtime_create/destroy resolve the bundled libssruntime', () {
    final ctx = ss_runtime_create();
    expect(ctx, isNot(equals(ffi.nullptr)),
        reason: 'ss_runtime_create via the bundled code asset');
    ss_runtime_destroy(ctx);
  });
}
