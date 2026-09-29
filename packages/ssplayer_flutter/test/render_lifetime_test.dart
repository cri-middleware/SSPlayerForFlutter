// Per-frame render-lifetime contract (regression for "Image has been disposed").
//
// The mask coverage pass recycles resources — the Canvas backend's coverage
// bitmap, the shader pools — that stay live until the recorded picture
// rasterises. Both `releaseCoverage()` and `rewindShaderPools()` MUST therefore
// run once per top-level frame, NOT once per player: an instance child
// draws through its parent's backend into the same picture, so a child that
// re-ran them would free/rebind what the parent's already-recorded mask draws
// still point at — surfacing as "Image has been disposed" when the picture
// finally rasterises (seen on the SpriteStudio "Basic Samples / Mask" packs, which put
// a mask and an instance in the same animation).
//
// This drives a real instance recursion (Instance.ssab → Instance_SourceAnime)
// through a spy backend and asserts the two hooks fire exactly once even though
// the tree has more than one player. It needs the Brain, so it skips when the
// native runtime / example assets are absent.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/src/render/backend/render_backend.dart';
import 'package:ssplayer_flutter/src/render/backend/render_host.dart';
import 'package:ssplayer_flutter/src/render/mask_context.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

void main() {
  test('per-frame lifetime hooks fire once across an instance recursion', () {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Instance.ssab',
      '../../examples/overall/assets/spritestudio/overall/Instance.ssab',
    ]);
    final childPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Instance_SourceAnime.ssab',
      '../../examples/overall/assets/spritestudio/overall/Instance_SourceAnime.ssab',
    ]);
    if (ssabPath == null || childPath == null) {
      markTestSkipped('Instance.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final child = Uint8List.fromList(File(childPath).readAsBytesSync());
    final spy = _SpyBackend();
    final player = SpriteStudioInternalPlayer.load(
      bytes,
      instancePacks: <int, Uint8List>{InstancePart.packHashOf(child): child},
      renderBackendOverride: spy,
    );
    addTearDown(player.dispose);
    expect(player.setupAnimation(SsAnimeInfo(bytes).animationNames.first),
        isTrue);
    player.play();
    player.update(const Duration(milliseconds: 33));

    final recorder = ui.PictureRecorder();
    player.paint(ui.Canvas(recorder),
        dst: const ui.Rect.fromLTWH(0, 0, 256, 256));
    recorder.endRecording().dispose();

    // The recursion really visited a child — otherwise this test proves nothing.
    expect(spy.pushTransforms, greaterThan(0),
        reason: 'Instance.ssab must recurse into a child (pushTransform)');
    // …yet the per-frame hooks ran exactly once for the whole tree.
    expect(spy.beginFrames, 1);
    expect(spy.finishes, 1);
    expect(spy.releaseCoverages, 1,
        reason: 'releaseCoverage is per-frame, never per player — a child '
            'must not drop the parent-tree coverage');
    expect(spy.rewinds, 1,
        reason: 'rewindShaderPools is per-frame, never per player');
  });
}

/// A no-op [RenderBackend] that only counts the lifecycle calls.
class _SpyBackend implements RenderBackend {
  int beginFrames = 0;
  SsRootTransform lastRoot = SsRootTransform.identity;
  int finishes = 0;
  int releaseCoverages = 0;
  int rewinds = 0;
  int pushTransforms = 0;

  @override
  set onResourcesReady(ui.VoidCallback? callback) {} // nothing async here

  @override
  void invalidateTexture(int textureHash) {}

  @override
  void beginFrame(ui.Canvas canvas,
      {ui.Rect? dst,
      ui.Size? sourceSize,
      SsRootTransform root = SsRootTransform.identity}) {
    beginFrames++;
    lastRoot = root;
  }

  @override
  void finish() => finishes++;

  @override
  void releaseCoverage() => releaseCoverages++;

  @override
  void rewindShaderPools() => rewinds++;

  @override
  void pushTransform(ui.Canvas canvas, Float64List world) => pushTransforms++;

  @override
  void popTransform(ui.Canvas canvas) {}



  @override
  void emitNormal(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking) {}

  @override
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking) {}

  @override
  void emitMesh(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking) {}

  @override
  void emitEffect(
      ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame, RenderHost host) {}

  @override
  MaskContext? renderCoverage(DrawFrame frame, RenderHost host, MaskPlan plan,
          Map<int, int> textureByRank) =>
      null;

  @override
  void dispose() {}
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
