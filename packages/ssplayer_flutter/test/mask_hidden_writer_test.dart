// A hidden mask writer writes nothing, exactly like one whose `mask` is 0.
//
// The Brain drops a hidden `PartTypeMask` and a hidden clipping writer from
// `draw_order`, so for those "hidden" needed no check here. A hidden
// `draw_as_mask` Shape / Nines is the exception: only its colour batch goes, and
// its Mask batch stays in the plan. This port relied on `draw_order` alone, so
// hiding `Shape-Mask-True` in the SDK's Mask animation left its square hole
// cut in the jigsaw behind it. SpriteStudio 7.5 removes the hole; so does every
// sibling that reads `hide` alongside `mask`.
//
// Shaders don't execute headless, so this drives a spy backend and asserts on
// the writer set the coverage pass is handed.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/src/render/backend/render_backend.dart';
import 'package:ssplayer_flutter/src/render/backend/render_host.dart';
import 'package:ssplayer_flutter/src/render/mask_context.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

const _writer = 'Shape-Mask-True';

void main() {
  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Mask.ssab',
    '../../examples/overall/assets/spritestudio/overall/Mask.ssab',
  ]);

  /// The part indices the coverage pass was asked to bake, over a few frames.
  Set<int> bakedWriters(Uint8List bytes, {required bool hide}) {
    final spy = _WriterSpy();
    final player =
        SpriteStudioInternalPlayer.load(bytes, renderBackendOverride: spy);
    addTearDown(player.dispose);
    expect(player.setupAnimation(SsAnimeInfo(bytes).animationNames.first),
        isTrue);
    if (hide) {
      expect(player.setPartVisibilityOverride(_writer, true), isTrue);
    }
    player.play();
    for (var i = 0; i < 5; i++) {
      player.update(const Duration(milliseconds: 33));
      final recorder = ui.PictureRecorder();
      player.paint(ui.Canvas(recorder),
          dst: const ui.Rect.fromLTWH(0, 0, 256, 256));
      recorder.endRecording().dispose();
    }
    return spy.writers;
  }

  test('a hidden draw_as_mask shape writes no coverage', () {
    final path = ssabPath;
    if (path == null) {
      markTestSkipped('Mask.ssab missing — run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(path).readAsBytesSync());
    final probe = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(probe.dispose);
    final index = probe.findPartIndex(_writer);
    expect(index, greaterThanOrEqualTo(0),
        reason: 'Mask.ssab must carry $_writer, or this asserts nothing');

    // Guard the guard: shown, it is a writer.
    expect(bakedWriters(bytes, hide: false), contains(index));
    // Hidden, it is not — while it is still in the frame's draw plan.
    expect(bakedWriters(bytes, hide: true), isNot(contains(index)));
  });
}

/// A [RenderBackend] that records the writers of every coverage pass.
class _WriterSpy implements RenderBackend {
  final Set<int> writers = <int>{};

  @override
  MaskContext? renderCoverage(DrawFrame frame, RenderHost host, MaskPlan plan,
      Map<int, int> textureByRank) {
    for (final w in plan.writers) {
      writers.add(w.partIndex);
    }
    return MaskContext(plan, null);
  }

  @override
  void beginFrame(ui.Canvas canvas,
      {ui.Rect? dst,
      ui.Size? sourceSize,
      SsRootTransform root = SsRootTransform.identity}) {}

  @override
  void emitTextured(ui.Canvas canvas, List<fbs.DrawBatch> batches, int from,
      int to, DrawFrame frame, RenderHost host, PlayerMask masking) {}

  @override
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking) {}

  @override
  void emitEffect(ui.Canvas canvas, List<fbs.DrawBatch> batches, int from,
      int to, DrawFrame frame, RenderHost host) {}

  @override
  set onResourcesReady(ui.VoidCallback? callback) {}

  @override
  void finish() {}

  @override
  void releaseCoverage() {}

  @override
  void rewindShaderPools() {}

  @override
  void pushTransform(ui.Canvas canvas, Float64List world) {}

  @override
  void popTransform(ui.Canvas canvas) {}

  @override
  void dispose() {}
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
