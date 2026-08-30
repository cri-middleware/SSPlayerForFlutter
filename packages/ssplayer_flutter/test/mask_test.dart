// Mask (§9) tests. The pure pieces — role classification, writer collection,
// scope/polarity resolution and the coverage UV affine — run everywhere; the
// PartData reader is exercised against real converter output from Mask.ssab and
// skips when the example assets haven't been prepared.
//
// The shaders are NOT covered here: fragment programs don't execute under
// headless `flutter test` (they are still compiled by impellerc, so a syntax or
// dialect error does surface as a test-run failure). Verify Mask.ssab visually
// in the example.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssruntime_dart/framedata.dart' as fbs;

void main() {
  group('MaskPartFlags roles (§1-2)', () {
    test('pure mask writes coverage and is not clipping', () {
      const f = MaskPartFlags(
        pureMask: true,
        maskWrite: false,
        maskInfluence: false,
        visibleInsideMask: false,
      );
      expect(f.isWriter, isTrue);
      expect(f.isClipping, isFalse);
    });

    test('a pure mask stays pure even with mask_write set', () {
      // is_clipping = mask_write && !pure_mask — the pure flag wins.
      const f = MaskPartFlags(
        pureMask: true,
        maskWrite: true,
        maskInfluence: false,
        visibleInsideMask: false,
      );
      expect(f.isWriter, isTrue);
      expect(f.isClipping, isFalse);
    });

    test('mask_write alone is a clipping writer, but not a target on its own',
        () {
      const f = MaskPartFlags(
        pureMask: false,
        maskWrite: true,
        maskInfluence: false,
        visibleInsideMask: false,
      );
      expect(f.isWriter, isTrue);
      expect(f.isClipping, isTrue);
      // Its own colour is NOT clipped by masks: mask_write does not force
      // target-ness (§2-3/§3); with mask_influence 0 the clipping writer draws
      // unmasked. It becomes a target once it also opts in with mask_influence 1.
      expect(f.isTarget, isFalse);
      const withInfluence = MaskPartFlags(
        pureMask: false,
        maskWrite: true,
        maskInfluence: true,
        visibleInsideMask: false,
      );
      expect(withInfluence.isTarget, isTrue);
    });

    test('a plain part opts out of masking with mask_influence == 0', () {
      expect(MaskPartFlags.none.isWriter, isFalse);
      expect(MaskPartFlags.none.isTarget, isFalse);
      const optedIn = MaskPartFlags(
        pureMask: false,
        maskWrite: false,
        maskInfluence: true,
        visibleInsideMask: false,
      );
      expect(optedIn.isTarget, isTrue);
      expect(optedIn.isWriter, isFalse);
    });
  });

  group('MaskPlan scope (§2-1) and polarity (§2-4)', () {
    // One pure mask at rank 5, one clipping writer at rank 10.
    final plan = MaskPlan.fromWriters(
      writers: <MaskWriter>[
        const MaskWriter(
          partIndex: 1,
          drawRank: 5,
          bit: 0,
          opInvert: false,
          isClipping: false,
          threshold: 0.0,
        ),
        const MaskWriter(
          partIndex: 2,
          drawRank: 10,
          bit: 1,
          opInvert: false,
          isClipping: true,
          threshold: 0.0,
        ),
      ],
      bounds: const ui.Rect.fromLTRB(0, 0, 100, 50),
    );

    const target = MaskPartFlags(
      pureMask: false,
      maskWrite: false,
      maskInfluence: true,
      visibleInsideMask: false,
    );

    test('a pure mask applies to the parts drawn before it', () {
      // rank 3 < 5 → in the mask's scope; bit 0 only.
      final bits = plan.bitsFor(3, target);
      expect(bits, isNotNull);
      expect(bits!.increment, 0x1);
      expect(bits.invert, 0);
    });

    test('a clipping writer applies to the parts drawn after it', () {
      // rank 12 > 10 → in the clipping scope; bit 1 only.
      final bits = plan.bitsFor(12, target);
      expect(bits, isNotNull);
      expect(bits!.increment, 0x2);
    });

    test('a part between the two writers is in neither scope', () {
      // rank 7: after the mask (5) and before the clipping writer (10).
      expect(plan.inScope(7), isFalse);
      expect(plan.bitsFor(7, target), isNull);
    });

    test('a part opted out is never tested, even inside a scope', () {
      expect(plan.inScope(3), isTrue);
      expect(plan.bitsFor(3, MaskPartFlags.none), isNull);
    });

    test('visible_inside_mask forces the test out of scope, with no writers',
        () {
      const visInside = MaskPartFlags(
        pureMask: false,
        maskWrite: false,
        maskInfluence: true,
        visibleInsideMask: true,
      );
      // rank 7 is out of every scope, but the part may only appear INSIDE a
      // mask — so it must still run the test and (with an empty writer set)
      // resolve to "not masked" → discarded by the shader's polarity check.
      final bits = plan.bitsFor(7, visInside);
      expect(bits, isNotNull);
      expect(bits!.isEmpty, isTrue);
      expect(bits.visibleInside, isTrue);
    });

    test('the OP splits writers into the increment and invert sets (§2-3)', () {
      final inverting = MaskPlan.fromWriters(
        writers: <MaskWriter>[
          const MaskWriter(
            partIndex: 1,
            drawRank: 5,
            bit: 0,
            opInvert: false,
            isClipping: false,
            threshold: 0.0,
          ),
          const MaskWriter(
            partIndex: 2,
            drawRank: 6,
            bit: 1,
            opInvert: true,
            isClipping: false,
            threshold: 0.0,
          ),
        ],
        bounds: const ui.Rect.fromLTRB(0, 0, 10, 10),
      );
      final bits = inverting.bitsFor(0, target)!;
      expect(bits.increment, 0x1);
      expect(bits.invert, 0x2);
    });
  });

  group('MaskPlan coverage UV (§3-2-2)', () {
    test('the affine maps the bounds onto the unit square', () {
      final plan = MaskPlan.fromWriters(
        writers: <MaskWriter>[
          const MaskWriter(
            partIndex: 0,
            drawRank: 0,
            bit: 0,
            opInvert: false,
            isClipping: false,
            threshold: 0.0,
          ),
        ],
        bounds: const ui.Rect.fromLTRB(-20, 10, 30, 60), // 50 x 50
      );
      final basis = plan.uvBasis;
      final offset = plan.uvOffset;

      List<double> uvOf(double x, double y) => <double>[
            basis[0] * x + basis[1] * y + offset[0],
            basis[2] * x + basis[3] * y + offset[1],
          ];

      expect(uvOf(-20, 10), [closeTo(0, 1e-6), closeTo(0, 1e-6)]); // top-left
      expect(uvOf(30, 60), [closeTo(1, 1e-6), closeTo(1, 1e-6)]); // bottom-right
      expect(uvOf(5, 35), [closeTo(0.5, 1e-6), closeTo(0.5, 1e-6)]); // centre
    });
  });

  test('MaskPartFlags.readAll finds the writers in the real Mask.ssab',
      () async {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Mask.ssab',
      '../../examples/overall/assets/spritestudio/overall/Mask.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Mask.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final flags = MaskPartFlags.readAll(bytes);
    expect(flags, isNotEmpty, reason: 'Mask.ssab should have parts');
    expect(flags.where((f) => f.isWriter), isNotEmpty,
        reason: 'Mask.ssab should have at least one mask writer');
    expect(flags.where((f) => f.isTarget), isNotEmpty,
        reason: 'Mask.ssab should have at least one masked target');
  });

  test('MaskPlan.build collects writers from a real Mask.ssab frame', () async {
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Mask.ssab',
      '../../examples/overall/assets/spritestudio/overall/Mask.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Mask.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final flags = MaskPartFlags.readAll(bytes);
    final player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);

    final info = SsAnimeInfo(bytes);
    expect(player.setupAnimation(info.animationNames.first), isTrue);
    player.play();

    // Masks can animate in and out; scan a range of frames for a plan.
    MaskPlan? plan;
    for (var i = 0; i < 60 && plan == null; i++) {
      player.update(const Duration(milliseconds: 33));
      final fd = player.getFrameData(player.frameNo);
      if (fd == null) continue;
      final frame = DrawFrame.build(
        frameData: fd,
        world: player.worldMatrices(),
        local: player.localVertices(),
        uv: player.localUvs(),
      );
      if (frame == null) continue;
      plan = MaskPlan.build(frame, flags);
    }

    expect(plan, isNotNull,
        reason: 'Mask.ssab should produce mask writers on some frame');
    expect(plan!.writers.length, lessThanOrEqualTo(kMaxMaskWriters));
    expect(plan.bounds.isEmpty, isFalse);

    // Bits are handed out densely, in ascending draw rank — the invariant the
    // shader's bit-0→23 replay order depends on.
    for (var i = 0; i < plan.writers.length; i++) {
      expect(plan.writers[i].bit, i);
      if (i > 0) {
        expect(plan.writers[i].drawRank,
            greaterThan(plan.writers[i - 1].drawRank));
      }
    }
    // §2-5: a collected writer always has a usable cutout threshold.
    for (final w in plan.writers) {
      expect(w.threshold, inInclusiveRange(0.0, 1.0));
    }
  });

  test('a writer op follows the effective mask_influence (own AND inherited)',
      () async {
    // §2-6 (writer side): MaskPlan.build composes each writer's OP with the
    // influence inherited down the instance chain. Under a mask_influence == 0
    // instance every writer moves off the invert (parity) plane onto the
    // increment (union) plane; under an influence == 1 caller the ops are
    // unchanged (the AND identity). comp must touch ONLY the op.
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Mask.ssab',
      '../../examples/overall/assets/spritestudio/overall/Mask.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Mask.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final flags = MaskPartFlags.readAll(bytes);
    final player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);

    final info = SsAnimeInfo(bytes);
    expect(player.setupAnimation(info.animationNames.first), isTrue);
    player.play();

    // An opted-out instance (influence 0) and an opted-in one (influence 1).
    const optOutPart = MaskPartFlags(
      pureMask: false,
      maskWrite: false,
      maskInfluence: false,
      visibleInsideMask: false,
    );
    const optInPart = MaskPartFlags(
      pureMask: false,
      maskWrite: false,
      maskInfluence: true,
      visibleInsideMask: false,
    );
    final optedOut = MaskComposition.identity.compose(optOutPart); // influence 0
    final optedIn = MaskComposition.identity.compose(optInPart); // influence 1

    var checked = false;
    for (var i = 0; i < 60 && !checked; i++) {
      player.update(const Duration(milliseconds: 33));
      final fd = player.getFrameData(player.frameNo);
      if (fd == null) continue;
      final frame = DrawFrame.build(
        frameData: fd,
        world: player.worldMatrices(),
        local: player.localVertices(),
        uv: player.localUvs(),
      );
      if (frame == null) continue;
      final base = MaskPlan.build(frame, flags);
      if (base == null || base.writers.isEmpty) continue;

      final under0 = MaskPlan.build(frame, flags, comp: optedOut)!;
      final under1 = MaskPlan.build(frame, flags, comp: optedIn)!;
      expect(under0.writers.length, base.writers.length);
      expect(under1.writers.length, base.writers.length);
      for (var w = 0; w < base.writers.length; w++) {
        // An influence == 1 caller is the AND identity — ops unchanged.
        expect(under1.writers[w].opInvert, base.writers[w].opInvert);
        // comp changes nothing but the op.
        expect(under0.writers[w].partIndex, base.writers[w].partIndex);
        expect(under0.writers[w].isClipping, base.writers[w].isClipping);
        // Influence 0 forces every writer onto the union (increment) plane.
        expect(under0.writers[w].opInvert, isFalse);
      }
      checked = true;
    }
    expect(checked, isTrue,
        reason: 'Mask.ssab should produce writers on some frame to compose');
  });

  test('a real Mask.ssab frame resolves a mask test for its Mesh parts',
      () async {
    // Mesh mask targets (§11-A) used to fall through unmasked because the Mesh
    // emit path never consulted the plan. Mask.ssab has mesh parts inside a
    // writer's scope, so this pins that the data really exercises the path —
    // without it the mesh gate could regress silently.
    final ssabPath = _firstExisting([
      'examples/overall/assets/spritestudio/overall/Mask.ssab',
      '../../examples/overall/assets/spritestudio/overall/Mask.ssab',
    ]);
    if (ssabPath == null) {
      markTestSkipped('Mask.ssab missing — run deploy-examples.sh');
      return;
    }

    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());
    final flags = MaskPartFlags.readAll(bytes);
    final player = SpriteStudioInternalPlayer.load(bytes);
    addTearDown(player.dispose);

    final info = SsAnimeInfo(bytes);
    expect(player.setupAnimation(info.animationNames.first), isTrue);
    player.play();

    var maskedMeshRanks = 0;
    for (var i = 0; i < 60 && maskedMeshRanks == 0; i++) {
      player.update(const Duration(milliseconds: 33));
      final fd = player.getFrameData(player.frameNo);
      final batches = fd?.drawBatches;
      if (fd == null || batches == null) continue;
      final frame = DrawFrame.build(
        frameData: fd,
        world: player.worldMatrices(),
        local: player.localVertices(),
        uv: player.localUvs(),
      );
      if (frame == null) continue;
      final plan = MaskPlan.build(frame, flags);
      if (plan == null) continue;

      for (final b in batches) {
        if (b.kind != fbs.DrawBatchKind.Mesh) continue;
        for (var k = 0; k < b.count; k++) {
          final rank = b.startRank + k;
          if (rank >= frame.drawOrder.length) break;
          final p = frame.drawOrder[rank];
          if (p < 0 || p >= flags.length) continue;
          final f = flags[p];
          if (f.pureMask) continue;
          if (plan.bitsFor(rank, f) != null) maskedMeshRanks++;
        }
      }
    }

    expect(maskedMeshRanks, greaterThan(0),
        reason: 'Mask.ssab should put at least one Mesh part under a mask');
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
