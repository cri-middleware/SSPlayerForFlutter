import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/src/render/backend/backend_kind.dart';
import 'package:ssplayer_flutter/src/render/backend/gpu_capability.dart';

// Phase 0 scaffolding checks for the flutter_gpu backend: the capability probe
// and backend resolution. Running this file also exercises the package's new
// hook/build.dart (it compiles ssplayer.shaderbundle.json through impellerc),
// so a broken shader or manifest fails the test build here.
//
// The headless flutter_tester has no Impeller context, so isFlutterGpuAvailable()
// is expected to be false here — this asserts the graceful Canvas fallback, not
// the GPU path (which is verified on a real macOS/iOS/Android run in Phase 1+).
void main() {
  test('SpriteStudioBackend has the three expected kinds', () {
    expect(SpriteStudioBackend.values,
        containsAll([SpriteStudioBackend.auto, SpriteStudioBackend.canvas,
          SpriteStudioBackend.gpu]));
  });

  test('capability probe returns a bool without throwing', () {
    // Must never throw regardless of platform — the whole point of the probe.
    final available = isFlutterGpuAvailable();
    expect(available, isA<bool>());
    // Cached: a second call agrees with the first.
    expect(isFlutterGpuAvailable(), available);
  });

  test('canvas is always resolved to canvas', () {
    expect(resolveBackend(SpriteStudioBackend.canvas),
        SpriteStudioBackend.canvas);
  });

  test('auto/gpu resolve to gpu iff flutter_gpu is available', () {
    final expected = isFlutterGpuAvailable()
        ? SpriteStudioBackend.gpu
        : SpriteStudioBackend.canvas;
    expect(resolveBackend(SpriteStudioBackend.auto), expected);
    expect(resolveBackend(SpriteStudioBackend.gpu), expected);
  });

  test('headless flutter_tester has no Impeller, so falls back to canvas', () {
    // If this ever fails because the tester gained a GPU context, it is not a
    // bug — relax this expectation. It documents the current headless reality.
    expect(isFlutterGpuAvailable(), isFalse);
    expect(resolveBackend(SpriteStudioBackend.auto), SpriteStudioBackend.canvas);
  });
}
