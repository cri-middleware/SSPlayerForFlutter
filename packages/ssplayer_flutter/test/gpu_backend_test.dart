import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/src/render/backend/backend_kind.dart';
import 'package:ssplayer_flutter/src/render/backend/gpu_capability.dart';

// The flutter_gpu backend's capability probe and backend resolution. Running this
// file also exercises the package's hook/build.dart (it compiles
// ssplayer.shaderbundle.json through impellerc), so a broken shader or manifest
// fails the test build here.
//
// The headless flutter_tester has no Impeller context, so isFlutterGpuAvailable()
// is expected to be false here — this asserts the graceful Canvas fallback, not
// the GPU path.
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

  // A source-level guard, because nothing here can run a real draw: a
  // `RenderPass` keeps its uniform/texture bindings across `draw()` calls, keyed
  // by (shader, uniform name), so a draw that does not clear first inherits the
  // *previous pipeline's* live bindings. Several pipelines share this backend's
  // one pass, and the result on Metal is a silently mis-rendered draw. Routing
  // every draw through `_beginDraw` is what makes that impossible, and this
  // pins it: a new draw path that calls `bindPipeline` directly fails here
  // rather than on someone's device.
  test('every GPU draw clears bindings before binding its pipeline', () {
    final source = _readBackendSource();
    if (source == null) {
      markTestSkipped('flutter_gpu_backend.dart not found from this cwd');
      return;
    }
    final lines = source.split('\n');
    final direct = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains('bindPipeline(')) direct.add(i + 1);
    }
    // Exactly one, and it is the one inside _beginDraw.
    expect(direct, hasLength(1),
        reason: 'bindPipeline must only be called from _beginDraw; found at '
            'lines $direct');
    final helper = source.indexOf('static void _beginDraw(');
    expect(helper, isNonNegative, reason: '_beginDraw helper is missing');
    final body = source.substring(helper, source.indexOf('}', helper));
    expect(body.indexOf('clearBindings()'), isNonNegative,
        reason: '_beginDraw must clear the pass bindings');
    expect(body.indexOf('clearBindings()'), lessThan(body.indexOf('bindPipeline(')),
        reason: 'bindings must be cleared BEFORE the pipeline is bound');
  });
}

String? _readBackendSource() {
  const rel = 'lib/src/render/backend/flutter_gpu_backend.dart';
  for (final path in <String>[rel, 'packages/ssplayer_flutter/$rel']) {
    final file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  return null;
}
