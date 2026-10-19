// A clipping mask written INSIDE an instance child must keep clipping the
// parent animation's parts drawn after the instance (SS7.5
// InstancePropagation). The top-level player bakes every writer of the
// instance tree into one coverage, transformed by the chain of slot matrices,
// and places each on its interval of the tree sequence: a clipping writer's
// runs from itself to the end of the tree.
//
// The reference behaviour is ForGodot's `fix(mask): an instance part's mask
// flags reach one level, always` and the tree sequence it introduced. Shaders
// don't execute headless, so this drives a spy backend and asserts on the plan
// the coverage pass builds — that a descendant's clipping writer appears and
// reaches the owner's later parts. A parallel pass renders the same frames
// through the real CanvasBackend to exercise the descendant bake without
// throwing.
//
// The packs are the SDK's "overall" InstancePropagation animation and its
// Source01 sub-animation, as scripts/deploy-examples.sh converts them; the test
// skips when they are absent.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/src/render/backend/render_backend.dart';
import 'package:ssplayer_flutter/src/render/backend/render_host.dart';
import 'package:ssplayer_flutter/src/render/mask.dart'
    show kBubbledWriterPart, kMaskSeqEnd;
import 'package:ssplayer_flutter/src/render/mask_context.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

/// A plain target part (opts in with mask_influence), for probing whether a
/// bubbled writer's bit reaches a part drawn after the instance.
const _target = MaskPartFlags(
  pureMask: false,
  maskWrite: false,
  maskInfluence: true,
  visibleInsideMask: false,
);

void main() {
  final parentPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/InstancePropagation.ssab',
    '../../examples/overall/assets/spritestudio/overall/InstancePropagation.ssab',
  ]);
  final childPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/InstancePropagation_Source01.ssab',
    '../../examples/overall/assets/spritestudio/overall/InstancePropagation_Source01.ssab',
  ]);

  ({Uint8List parent, Uint8List child})? assets;
  if (parentPath != null && childPath != null) {
    assets = (
      parent: Uint8List.fromList(File(parentPath).readAsBytesSync()),
      child: Uint8List.fromList(File(childPath).readAsBytesSync()),
    );
  }

  Map<int, Uint8List> packs(Uint8List child) =>
      <int, Uint8List>{InstancePart.packHashOf(child): child};

  test('an instance child\'s clipping mask carries up to the parent\'s later '
      'parts', () {
    final a = assets;
    if (a == null) {
      markTestSkipped(
          'InstancePropagation.ssab missing — run deploy-examples.sh');
      return;
    }
    // Guard the guard: the fixture must actually mount its instance child, or
    // there is nothing to carry up and the test would assert nothing.
    expect(InstancePart.readAll(a.parent), isNotEmpty,
        reason: 'InstancePropagation must host an instance part');

    final names = SsAnimeInfo(a.parent).animationNames;
    expect(names, isNotEmpty);

    var sawBubbled = false;
    var sawBitReachLaterPart = false;

    for (final name in names) {
      final spy = _CoveragePlanSpy();
      final player = SpriteStudioInternalPlayer.load(
        a.parent,
        instancePacks: packs(a.child),
        renderBackendOverride: spy,
      );
      addTearDown(player.dispose);
      expect(player.setupAnimation(name), isTrue);
      player.play();

      for (var i = 0; i < 60; i++) {
        player.update(const Duration(milliseconds: 33));
        final recorder = ui.PictureRecorder();
        player.paint(ui.Canvas(recorder),
            dst: const ui.Rect.fromLTWH(0, 0, 256, 256));
        recorder.endRecording().dispose();
      }

      for (final plan in spy.plans) {
        if (plan.bubbled.isEmpty) continue;
        sawBubbled = true;

        // A descendant's writer is a sentinel in `writers`, paired with its
        // bake by bit.
        for (final w in plan.writers) {
          if (w.partIndex != kBubbledWriterPart) continue;
          expect(plan.bubbled.any((b) => b.bit == w.bit), isTrue,
              reason: 'the sentinel must pair a BubbledWriter by bit');
          if (!w.isClipping) continue;
          // A clipping writer's interval runs to the end of the tree, so its
          // bit reaches whatever the caller draws after the instance.
          expect(w.close, kMaskSeqEnd);
          final bits = plan.bitsFor(w.open + 1, _target);
          if (bits != null && bits.has(w.bit)) {
            sawBitReachLaterPart = true;
          }
        }
      }
    }

    expect(sawBubbled, isTrue,
        reason: 'no frame carried a child clipping writer up into the parent '
            'coverage — the InstancePropagation carry-over never fired');
    expect(sawBitReachLaterPart, isTrue,
        reason: "a carried-up clipping writer's bit must reach a parent part "
            'drawn after the instance');
  });

  test('the real CanvasBackend bakes the carried-up writers without throwing',
      () {
    final a = assets;
    if (a == null) {
      markTestSkipped('InstancePropagation.ssab missing');
      return;
    }
    // No renderBackendOverride → the default CanvasBackend, whose coverage pass
    // now walks plan.bubbled. Textures are not decoded headless, so a quad
    // writer's cutout is skipped, but the bubbled loop, its slot transform and
    // any shape/mesh bit-fill still run — a crash-smoke over the new bake path.
    final player = SpriteStudioInternalPlayer.load(
      a.parent,
      instancePacks: packs(a.child),
    );
    addTearDown(player.dispose);
    expect(player.setupAnimation(SsAnimeInfo(a.parent).animationNames.first),
        isTrue);
    player.play();

    expect(() {
      for (var i = 0; i < 60; i++) {
        player.update(const Duration(milliseconds: 33));
        final recorder = ui.PictureRecorder();
        player.paint(ui.Canvas(recorder),
            dst: const ui.Rect.fromLTWH(0, 0, 256, 256));
        recorder.endRecording().dispose();
      }
    }, returnsNormally);
  });
}

/// A [RenderBackend] that records the [MaskPlan] handed to every coverage pass,
/// so the carry-over machinery can be asserted without a GPU.
class _CoveragePlanSpy implements RenderBackend {
  final List<MaskPlan> plans = <MaskPlan>[];

  @override
  MaskContext? renderCoverage(DrawFrame frame, RenderHost host, MaskPlan plan,
      Map<int, int> textureByRank) {
    plans.add(plan);
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
