// Instance (§8) tests. The ssab reads, pack resolution, the slot matrix and the
// alpha plumbing run everywhere; the slot API + child playback are then driven
// against real converter output from Instance.ssab (+ its Instance_SourceAnime
// child pack) and skip when the example assets haven't been prepared.
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show Matrix4, MatrixUtils;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

void main() {
  group('InstancePart.resolvePack', () {
    final own = Uint8List.fromList(<int>[1, 2, 3]);
    final ext = Uint8List.fromList(<int>[9, 9, 9]);

    InstancePart partWith(int packHash) => InstancePart(
          partIndex: 0,
          packName: 'Other',
          packNameHash: packHash,
          animeName: 'anime_1',
          animeNameHash: 7,
        );

    test('an external pack wins over the own binary', () {
      final got = InstancePart.resolvePack(partWith(42),
          ownBytes: own, ownPackHash: 1, packs: <int, Uint8List>{42: ext});
      expect(got, same(ext));
    });

    test('a reference to the own pack resolves to the own binary', () {
      // The overwhelmingly common case: an animation instancing a sibling
      // animation in the same .ssab. It is deliberately absent from
      // external_instances, so nothing would ever put it in `packs`.
      final got = InstancePart.resolvePack(partWith(1),
          ownBytes: own, ownPackHash: 1);
      expect(got, same(own));
    });

    test('a pack-less reference (hash 0) falls back to the own binary', () {
      final got = InstancePart.resolvePack(partWith(0),
          ownBytes: own, ownPackHash: 1);
      expect(got, same(own));
    });

    test('an unresolved external pack returns null rather than the own binary',
        () {
      // Guards against the tempting "just fall back to ourselves" bug, which
      // would silently play the WRONG animation instead of drawing nothing.
      final got = InstancePart.resolvePack(partWith(42),
          ownBytes: own, ownPackHash: 1, packs: <int, Uint8List>{7: ext});
      expect(got, isNull);
    });

    test('an external pack wins even when its hash collides with the own pack',
        () {
      final got = InstancePart.resolvePack(partWith(1),
          ownBytes: own, ownPackHash: 1, packs: <int, Uint8List>{1: ext});
      expect(got, same(ext));
    });
  });

  group('GeometryBuilder.world2dOf', () {
    // A world matrix with junk in every slot the 2D affine must ignore, so a
    // wholesale 4x4 copy would be caught.
    DrawFrame frameWithWorld(List<double> m) => DrawFrame(
          frameData: _emptyFrameData(),
          drawOrder: const <int>[0],
          partByIndex: const [],
          world: Float32List.fromList(m),
          local: Float32List(10),
          uv: Float32List(10),
        );

    test('carries the 2D affine and ignores the source Z/W rows', () {
      final m = List<double>.filled(16, 0.0);
      m[0] = 2.0; // m0
      m[1] = 3.0; // m1
      m[4] = 4.0; // m4
      m[5] = 5.0; // m5
      m[12] = 60.0; // tx
      m[13] = 70.0; // ty
      // Junk the Body must not propagate into Canvas.transform.
      m[2] = 99.0;
      m[10] = 0.5; // a Z scale that would squash the child
      m[11] = 0.25; // a perspective term
      m[14] = 88.0;
      m[15] = 4.0;

      final got = GeometryBuilder.world2dOf(0, frameWithWorld(m))!;

      expect(got[0], 2.0);
      expect(got[1], 3.0);
      expect(got[4], 4.0);
      expect(got[5], 5.0);
      expect(got[12], 60.0);
      expect(got[13], 70.0);
      // Identity Z row + no perspective, regardless of the source.
      expect(got[10], 1.0);
      expect(got[15], 1.0);
      for (final i in const <int>[2, 3, 6, 7, 8, 9, 11, 14]) {
        expect(got[i], 0.0, reason: 'index $i must be zero');
      }
    });

    test('Flutter maps a point through it exactly as the vertex bake does', () {
      // The real contract: interpreted by the same Matrix4 that Canvas.transform
      // uses, our matrix must move a point to where `x' = m0x + m4y + m12` /
      // `y' = m1x + m5y + m13` — the transform every other kind bakes by hand —
      // would have put it. Otherwise an instance child lands somewhere its
      // siblings never would.
      final m = List<double>.filled(16, 0.0);
      m[0] = 2.0;
      m[1] = 3.0;
      m[4] = 4.0;
      m[5] = 5.0;
      m[12] = 60.0;
      m[13] = 70.0;
      m[10] = 0.5; // junk the 2D path must ignore
      m[15] = 4.0;
      final got = GeometryBuilder.world2dOf(0, frameWithWorld(m))!;

      const x = 11.0, y = 13.0;
      final mapped = MatrixUtils.transformPoint(
          Matrix4.fromFloat64List(got), const ui.Offset(x, y));
      expect(mapped.dx, closeTo(2.0 * x + 4.0 * y + 60.0, 1e-9));
      expect(mapped.dy, closeTo(3.0 * x + 5.0 * y + 70.0, 1e-9));
    });

    test('returns null for a part outside the SoA', () {
      expect(GeometryBuilder.world2dOf(4, frameWithWorld(List.filled(16, 0.0))),
          isNull);
    });
  });

  group('alpha plumbing', () {
    test('PartColor.passthrough carries the alpha; identity does not', () {
      // The bug this guards: a part peeled onto the shader ONLY for a mask test
      // has no PartColor, and the shader has no PartState.alpha term of its own
      // (§1-3 — on the PartColor path the Brain pre-folds it). Handing it the
      // shared alpha-1 identity renders it fully opaque.
      expect(PartColor.identity.lt.a, 1.0);

      final pc = PartColor.passthrough(0.25);
      for (final c in <PartColorCorner>[pc.lt, pc.rt, pc.lb, pc.rb]) {
        expect(c.a, 0.25);
        expect(c.rate, 0.0, reason: 'rate 0 collapses to a texel passthrough');
        expect(<double>[c.r, c.g, c.b], everyElement(1.0));
      }
    });

    test('scaleAlpha scales alpha only, and is identity at 1.0', () {
      const pc = PartColor(
        coef: <double>[-1.0, 1.0, 0.0, 0.0],
        lt: PartColorCorner(0.1, 0.2, 0.3, 0.8, 0.5),
        rt: PartColorCorner(0.1, 0.2, 0.3, 0.4, 0.5),
        lb: PartColorCorner(0.1, 0.2, 0.3, 1.0, 0.5),
        rb: PartColorCorner(0.1, 0.2, 0.3, 0.0, 0.5),
      );

      expect(pc.scaleAlpha(1.0), same(pc));

      final half = pc.scaleAlpha(0.5);
      expect(half.lt.a, 0.4);
      expect(half.rt.a, closeTo(0.2, 1e-9));
      expect(half.lb.a, 0.5);
      expect(half.rb.a, 0.0);
      // RGB and rate must survive untouched — the flagship modulates alpha only.
      expect(half.lt.r, 0.1);
      expect(half.lt.g, 0.2);
      expect(half.lt.b, 0.3);
      expect(half.lt.rate, 0.5);
      expect(half.coef, pc.coef);
    });

    test('DrawFrame.alphaScale multiplies each part alpha, defaulting to 1', () {
      DrawFrame frameWith(double scale) => DrawFrame(
            frameData: _emptyFrameData(),
            drawOrder: const <int>[0],
            partByIndex: const [],
            world: Float32List(16),
            local: Float32List(10),
            uv: Float32List(10),
            alphaScale: scale,
          );

      // A part absent from `parts` reads as alpha 1, so this isolates the scale.
      expect(frameWith(1.0).alphaOf(0), 1.0);
      expect(frameWith(0.5).alphaOf(0), 0.5);
    });
  });

  group('Instance.ssab (real converter output)', () {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Instance.ssab',
      '../../examples/overall/assets/spritestudio/overall/Instance.ssab',
    ]);
    final childPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Instance_SourceAnime.ssab',
      '../../examples/overall/assets/spritestudio/overall/Instance_SourceAnime.ssab',
    ]);

    final assets = (ssabPath == null || childPath == null)
        ? null
        : (
            bytes: Uint8List.fromList(File(ssabPath).readAsBytesSync()),
            child: Uint8List.fromList(File(childPath).readAsBytesSync()),
          );

    SpriteStudioInternalPlayer loadPlayer(
        ({Uint8List bytes, Uint8List child}) a) {
      final player = SpriteStudioInternalPlayer.load(
        a.bytes,
        instancePacks: <int, Uint8List>{
          InstancePart.packHashOf(a.child): a.child,
        },
      );
      expect(player.setupAnimation(SsAnimeInfo(a.bytes).animationNames.first),
          isTrue);
      return player;
    }

    test('reads every instance binding out of the ssab', () {
      final a = assets;
      if (a == null) {
        markTestSkipped('Instance.ssab missing — run deploy-examples.sh');
        return;
      }
      final parts = InstancePart.readAll(a.bytes);
      expect(parts, isNotEmpty);
      for (final p in parts) {
        expect(p.packName, 'Instance_SourceAnime');
        expect(p.animeName, 'anime_1');
        expect(p.animeNameHash, isNot(0));
      }
      // Part indices must be strictly ascending — they double as slot indices.
      final indices = parts.map((p) => p.partIndex).toList();
      expect(indices, orderedEquals(<int>[...indices]..sort()));
      expect(indices.toSet().length, indices.length);
    });

    test('the external pack manifest names the child pack', () {
      final a = assets;
      if (a == null) {
        markTestSkipped('Instance.ssab missing');
        return;
      }
      expect(InstancePart.externalPackNames(a.bytes),
          <String>['Instance_SourceAnime']);
      // The child is a leaf: it must not send the loader looking further.
      expect(InstancePart.externalPackNames(a.child), isEmpty);
    });

    test('spawns a live child per instance part', () {
      final a = assets;
      if (a == null) {
        markTestSkipped('Instance.ssab missing');
        return;
      }
      final player = loadPlayer(a);
      addTearDown(player.dispose);

      final parts = player.instanceParts;
      expect(parts, isNotEmpty);
      for (final p in parts) {
        final slot = player.instanceSlotFor(p.partIndex);
        expect(slot, isNotNull, reason: 'part ${p.partIndex} got no child');
        expect(slot!.child.instanceContext, isNot(ffi.nullptr),
            reason: 'the child must own a real Context to be stepped');
        expect(slot.slot, isNot(ffi.nullptr));
        // Each part gets its OWN child: 21 parts share one source animation but
        // must not share a clock, or every INDEP_*/LOOP_* variant would play in
        // lockstep.
        expect(
          player.instanceParts
              .where((o) => o.partIndex != p.partIndex)
              .every((o) =>
                  player.instanceSlotFor(o.partIndex)!.child.instanceContext !=
                  slot.child.instanceContext),
          isTrue,
          reason: 'instance children must not share a Context',
        );
      }
    });

    test('without the child pack no children spawn, and nothing throws', () {
      final a = assets;
      if (a == null) {
        markTestSkipped('Instance.ssab missing');
        return;
      }
      // Instance_SourceAnime is external, so with no packs it cannot resolve.
      final player = SpriteStudioInternalPlayer.load(a.bytes);
      addTearDown(player.dispose);
      expect(player.setupAnimation(SsAnimeInfo(a.bytes).animationNames.first),
          isTrue);
      expect(player.instanceParts, isNotEmpty,
          reason: 'the bindings are still read');
      for (final p in player.instanceParts) {
        expect(player.instanceSlotFor(p.partIndex), isNull);
      }
      // The whole frame must still update and paint — an unresolved pack is a
      // missing child, not a broken animation.
      player.play();
      player.update(const Duration(milliseconds: 33));
      final recorder = ui.PictureRecorder();
      player.paint(ui.Canvas(recorder), sourceSize: const ui.Size(256, 256));
      recorder.endRecording().dispose();
    });

    test('the Brain advances the children as the parent plays', () {
      final a = assets;
      if (a == null) {
        markTestSkipped('Instance.ssab missing');
        return;
      }
      final player = loadPlayer(a);
      addTearDown(player.dispose);
      player.play();

      var sawVisible = false;
      final advanced = <int>{};
      for (var i = 0; i < 60; i++) {
        player.update(const Duration(milliseconds: 33));
        for (final p in player.instanceParts) {
          final slot = player.instanceSlotFor(p.partIndex)!;
          if (!slot.visible) continue;
          sawVisible = true;
          if (slot.childFrame > 0.0) advanced.add(p.partIndex);
          // The child context must actually be where the slot says it is —
          // paint samples the child's own clock.
          expect(slot.child.frameNo, closeTo(slot.childFrame, 1e-3));
        }
      }
      expect(sawVisible, isTrue, reason: 'no instance child ever became visible');
      expect(advanced, isNotEmpty, reason: 'no child clock ever advanced');
    });

    test('an independent child keeps running while the parent is paused', () {
      final a = assets;
      if (a == null) {
        markTestSkipped('Instance.ssab missing');
        return;
      }
      final player = loadPlayer(a);
      addTearDown(player.dispose);
      player.play();
      // Get past frame 0 so the INDEP_* keys have fired.
      for (var i = 0; i < 20; i++) {
        player.update(const Duration(milliseconds: 33));
      }

      // Ask the Brain which slots it is running independently rather than
      // guessing from part names.
      final independent = <InstanceSlot<SpriteStudioInternalPlayer>>[
        for (final p in player.instanceParts)
          if (player.instanceSlotFor(p.partIndex)!.isIndependent)
            player.instanceSlotFor(p.partIndex)!
      ];
      expect(independent, isNotEmpty,
          reason: 'Instance.ssab authors INDEP_* parts; none reported '
              'independent, so the event never reached the slot');

      player.pause();
      final parentBefore = player.frameNo;
      final childBefore = <InstanceSlot<SpriteStudioInternalPlayer>, double>{
        for (final s in independent) s: s.childFrame,
      };
      for (var i = 0; i < 10; i++) {
        player.update(const Duration(milliseconds: 33));
      }

      expect(player.frameNo, closeTo(parentBefore, 1e-6),
          reason: 'the parent must stay put while paused');
      expect(
        independent.any((s) => (s.childFrame - childBefore[s]!).abs() > 1e-6),
        isTrue,
        reason: 'an independent child runs on its own real-time clock; pausing '
            'the parent must not freeze it',
      );
    });

    test('paint draws the children (the frame is not empty)', () async {
      final a = assets;
      if (a == null) {
        markTestSkipped('Instance.ssab missing');
        return;
      }
      final player = loadPlayer(a);
      addTearDown(player.dispose);
      // The children are textured from the child pack's own cellmaps.
      await SsTextureLoader.loadEmbedded(player.textures, a.child);
      player.play();
      for (var i = 0; i < 10; i++) {
        player.update(const Duration(milliseconds: 33));
      }

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      player.paint(canvas, sourceSize: const ui.Size(256, 256));
      final picture = recorder.endRecording();
      addTearDown(picture.dispose);

      // An Instance batch must actually be present, or this asserts nothing.
      final fd = player.getFrameData(player.frameNo)!;
      expect(
        fd.drawBatches!.where((b) => b.kind == fbs.DrawBatchKind.Instance),
        isNotEmpty,
        reason: 'Instance.ssab should emit Instance batches',
      );
    });

    test('play() re-arms the slots so a replay re-fires its children', () {
      final a = assets;
      if (a == null) {
        markTestSkipped('Instance.ssab missing');
        return;
      }
      final player = loadPlayer(a);
      addTearDown(player.dispose);
      player.play();
      for (var i = 0; i < 30; i++) {
        player.update(const Duration(milliseconds: 33));
      }

      player.play(); // explicit head-out
      for (final p in player.instanceParts) {
        final slot = player.instanceSlotFor(p.partIndex)!;
        expect(slot.childFrame, 0.0);
        expect(slot.visible, isFalse);
      }
    });
  });
}

/// A structurally valid but empty `FrameData` — these cases exercise the SoA
/// math, which never reads the FlatBuffers root.
fbs.FrameData _emptyFrameData() =>
    fbs.FrameData(fbs.FrameDataObjectBuilder().toBytes());

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
