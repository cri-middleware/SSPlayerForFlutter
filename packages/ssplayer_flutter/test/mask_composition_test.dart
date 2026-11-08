// Mask settings compose across ONE instance level.
//
// A part's own `mask_influence` / `visible_inside_mask` compose with those of
// the instance part directly above it — `mask_influence` with AND,
// `visible_inside_mask` with OR — and with nothing further up. That is what
// SpriteStudio 7.6 draws (InstancePropagationTired3 and the S01_Overlap /
// OV_Top data behind the ForGodot fix): under an instance part with
// `mask_influence == 0` the instance's own parts go unmasked, but a
// grandchild whose own instance part opts in is masked again. Chaining both
// flags down the whole hierarchy would let one opted-out caller unmask its
// entire subtree.
//
// The composition applies whether or not anything masks the caller, and the
// same one level decides a writer's OP. The identity (influence = true,
// visible_inside = false) is what keeps unnested playback unchanged, so it is
// pinned here too.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/src/render/mask_context.dart';

/// A part that opts in and draws outside the mask — the ordinary target.
const _plain = MaskPartFlags(
  pureMask: false,
  maskWrite: false,
  maskInfluence: true,
  visibleInsideMask: false,
);

/// The same, but drawing INSIDE the mask.
const _inside = MaskPartFlags(
  pureMask: false,
  maskWrite: false,
  maskInfluence: true,
  visibleInsideMask: true,
);

/// A part opting out of masking altogether.
const _optedOut = MaskPartFlags(
  pureMask: false,
  maskWrite: false,
  maskInfluence: false,
  visibleInsideMask: false,
);

/// A clipping writer with `mask_influence == 0`: draws colour AND writes
/// coverage, but its own colour is NOT clipped by masks (its write OP
/// bit is 0, which is not an opt-IN for being masked).
const _clipping = MaskPartFlags(
  pureMask: false,
  maskWrite: true,
  maskInfluence: false,
  visibleInsideMask: false,
);

/// A clipping writer that also opts IN as a target (`mask_influence == 1`): its
/// own colour IS clipped by other masks, and its own write OP is invert.
const _clippingInfluence = MaskPartFlags(
  pureMask: false,
  maskWrite: true,
  maskInfluence: true,
  visibleInsideMask: false,
);

void main() {
  group('MaskComposition', () {
    test('the identity leaves a part evaluating by its own flags', () {
      const id = MaskComposition.identity;
      expect(id.targets(_plain), isTrue);
      expect(id.targets(_optedOut), isFalse);
      // A clipping writer with mask_influence 0 is NOT a target of a mask (its
      // write OP does not opt it in); one with mask_influence 1 is.
      expect(id.targets(_clipping), isFalse);
      expect(id.targets(_clippingInfluence), isTrue);
      expect(id.visibleInsideFor(_plain), isFalse);
      expect(id.visibleInsideFor(_inside), isTrue);
      // Which is exactly what the top-level reading on the flags says.
      for (final f in <MaskPartFlags>[
        _plain,
        _inside,
        _optedOut,
        _clipping,
        _clippingInfluence,
      ]) {
        expect(id.targets(f), f.isTarget);
      }
    });

    test('an instance part hands down its own flags, not what it inherited',
        () {
      expect(MaskComposition.ofInstancePart(_plain), MaskComposition.identity);
      final out = MaskComposition.ofInstancePart(_optedOut);
      expect(out.influence, isFalse);
      expect(out.visibleInside, isFalse);
      final inside = MaskComposition.ofInstancePart(_inside);
      expect(inside.influence, isTrue);
      expect(inside.visibleInside, isTrue);
      // There is nothing to chain: the value depends on the instance part
      // alone, so a grandchild under an opted-in instance part is back to the
      // identity however its grandparent was set.
      expect(MaskComposition.ofInstancePart(_plain).targets(_plain), isTrue);
    });

    test('mask_influence composes with AND, visible_inside_mask with OR', () {
      final out = MaskComposition.ofInstancePart(_optedOut);
      expect(out.targets(_plain), isFalse,
          reason: 'the instance part opted its sub-animation out');
      final inside = MaskComposition.ofInstancePart(_inside);
      expect(inside.visibleInsideFor(_plain), isTrue);
      // And a callee asking for inside puts itself there under a plain caller.
      expect(MaskComposition.identity.visibleInsideFor(_inside), isTrue);
    });

    test('a writer OP takes the same one level', () {
      // Own mask_influence AND the instance part's: under an opted-out
      // instance a writer moves to the increment plane…
      expect(
          MaskComposition.ofInstancePart(_optedOut)
              .opInvertFor(_clippingInfluence),
          isFalse);
      // …and under an opted-in one it keeps its own OP.
      expect(
          MaskComposition.ofInstancePart(_plain)
              .opInvertFor(_clippingInfluence),
          isTrue);
      expect(MaskComposition.identity.opInvertFor(_clipping), isFalse);
    });

    test('mask_write does not compose, and does not make its part a target', () {
      final out = MaskComposition.ofInstancePart(_optedOut);
      // The clipping writer's own colour is clipped only on its real influence,
      // not forced by mask_write: with influence 0 it is not a target,
      // under any caller…
      expect(out.targets(_clipping), isFalse);
      expect(MaskComposition.identity.targets(_clipping), isFalse);
      // …while writing a mask is a local fact that descendants do not inherit:
      // what an instance part hands down is decided by its mask_influence.
      expect(MaskComposition.ofInstancePart(_clipping).influence, isFalse);
    });
  });

  group('MaskPlan.bitsFor under a composition', () {
    // One pure-mask writer at rank 4, so ranks 0..3 are in its scope.
    final plan = MaskPlan.fromWriters(
      writers: const <MaskWriter>[
        MaskWriter(
          partIndex: 4,
          drawRank: 4,
          bit: 0,
          opInvert: true,
          isClipping: false,
          threshold: 0.0,
        ),
      ],
      bounds: const ui.Rect.fromLTRB(0, 0, 10, 10),
    );

    test('the identity reproduces the pre-composition behaviour', () {
      final bits = plan.bitsFor(0, _plain);
      expect(bits, isNotNull);
      expect(bits!.invertOf(0), 0x1);
      expect(bits.visibleInside, isFalse);
      expect(plan.bitsFor(0, _optedOut), isNull);
    });

    test('an opted-out caller unmasks a target the plan would otherwise claim',
        () {
      final out = MaskComposition.ofInstancePart(_optedOut);
      expect(plan.bitsFor(0, _plain, comp: out), isNull);
    });

    test('the caller\'s polarity reaches a part that did not ask for it', () {
      final inside = MaskComposition.ofInstancePart(_inside);
      expect(plan.bitsFor(0, _plain, comp: inside)!.visibleInside, isTrue);
    });

    test('a part keeps its own polarity under a plain caller', () {
      // The callee asked to draw inside, the caller did not: the callee wins.
      final plainCaller = MaskComposition.ofInstancePart(_plain);
      expect(plan.bitsFor(0, _inside, comp: plainCaller)!.visibleInside, isTrue);
    });

    test('visible_inside still forces the test out of scope', () {
      // Rank 9 is past the writer, so no scope — but a part that may only appear
      // inside a mask must still run the test (and be discarded by the empty
      // set). That has to hold when the polarity came from the caller, too.
      final inside = MaskComposition.ofInstancePart(_inside);
      final bits = plan.bitsFor(9, _plain, comp: inside);
      expect(bits, isNotNull);
      expect(bits!.isEmpty, isTrue);
      expect(bits.visibleInside, isTrue);
      // Whereas the same part with no inherited polarity is simply unmasked.
      expect(plan.bitsFor(9, _plain), isNull);
    });

    test('a clipping writer with mask_influence 0 is not a target', () {
      final out = MaskComposition.ofInstancePart(_optedOut);
      // Rank 0 is in the pure mask's scope, but the clipping writer opted out of
      // being masked (influence 0), so its own colour is not clipped —
      // whether or not a caller opted out too.
      expect(plan.bitsFor(0, _clipping, comp: out), isNull);
      expect(plan.bitsFor(0, _clipping), isNull);
      // With mask_influence 1 it IS a target and picks up the writer's bit.
      expect(plan.bitsFor(0, _clippingInfluence)!.invertOf(0), 0x1);
    });
  });

  group('PlayerMask resolves per part on the tree sequence', () {
    // Seq 0..9: a pure mask at 4 inside the child animation (which starts
    // after its instance part at seq 2), and a clipping writer at 6.
    final plan = MaskPlan.fromWriters(
      writers: const <MaskWriter>[
        MaskWriter(
          partIndex: -2,
          drawRank: 1,
          bit: 0,
          opInvert: true,
          isClipping: false,
          threshold: 0.0,
          open: 2,
          close: 4,
        ),
        MaskWriter(
          partIndex: -2,
          drawRank: 3,
          bit: 1,
          opInvert: false,
          isClipping: true,
          threshold: 0.0,
          open: 6,
        ),
      ],
      bounds: const ui.Rect.fromLTRB(0, 0, 10, 10),
    );
    final root = PlayerMask.root(MaskContext(plan, null),
        seq: <int>[0, 1, 2, 7, 8]); // the child's parts took 3..6
    final slot = Float64List(16)
      ..[0] = 1
      ..[5] = 1
      ..[10] = 1
      ..[15] = 1;

    test('a pure mask inside an instance reaches only its own animation', () {
      final child = root.forInstance(_plain, slot, <int>[3, 4, 5, 6]);
      expect(child.drawFor(0, _plain)!.bits.invertOf(0), 0x1,
          reason: 'drawn before the pure mask, in the same animation');
      // The caller's parts before the instance are outside its interval.
      expect(root.drawFor(1, _plain), isNull);
    });

    test('a clipping mask inside an instance clips the caller after it', () {
      expect(root.drawFor(3, _plain)!.bits.incrementOf(0), 0x2);
      expect(root.drawFor(4, _plain)!.bits.incrementOf(0), 0x2);
    });

    test('an opted-out instance part leaves only its own parts unmasked', () {
      final child = root.forInstance(_optedOut, slot, <int>[3, 4, 5, 6]);
      expect(child.drawFor(0, _plain), isNull);
      // A grandchild under an opted-in instance part is masked again.
      final grand = child.forInstance(_plain, slot, <int>[3]);
      expect(grand.drawFor(0, _plain)!.bits.invertOf(0), 0x1);
    });

    test('a part drawing inside with no mask anywhere draws nothing', () {
      expect(PlayerMask.none.drawFor(0, _inside)!.drawsNothing, isTrue);
      expect(PlayerMask.none.drawFor(0, _plain), isNull);
      // The same under an instance part that asks for inside, coverage or not.
      final child =
          PlayerMask.none.forInstance(_inside, slot, null);
      expect(child.drawFor(0, _plain)!.drawsNothing, isTrue);
      // …but not when the instance part opted out of masking.
      expect(PlayerMask.none.forInstance(_optedOut, slot, null)
          .drawFor(0, _inside), isNull);
    });

    test('a part drawing inside that no writer reaches draws nothing', () {
      expect(root.drawFor(1, _inside)!.drawsNothing, isTrue);
      expect(root.drawFor(4, _inside)!.drawsNothing, isFalse);
    });
  });

  test('the slot affine composes without disturbing the writer sets', () {
    // `M_child = M_parent · slot_xf`: re-basing the UV is orthogonal to the
    // per-part composition.
    final plan = MaskPlan.fromWriters(
      writers: const <MaskWriter>[
        MaskWriter(
          partIndex: 0,
          drawRank: 0,
          bit: 0,
          opInvert: false,
          isClipping: true,
          threshold: 0.0,
        ),
      ],
      bounds: const ui.Rect.fromLTRB(-0.2, -0.8, 1.8, 3.2),
    );
    final root = PlayerMask.root(MaskContext(plan, null));
    // uvBasis = [0.5, 0, 0, 0.25], uvOffset = [0.1, 0.2].
    // A slot that scales by 2 and translates by (4, 8), column-major 4x4.
    final slot = Float64List(16);
    slot[0] = 2;
    slot[5] = 2;
    slot[12] = 4;
    slot[13] = 8;

    // Tolerance is float32's — the affine is carried in a Float32List uniform.
    final child = root.forInstance(_plain, slot, <int>[1]);
    final d = child.drawFor(0, _plain)!;
    expect(d.uvBasis[0], closeTo(1.0, 1e-6)); // 0.5 * 2
    expect(d.uvBasis[3], closeTo(0.5, 1e-6)); // 0.25 * 2
    expect(d.uvOffset[0], closeTo(0.5 * 4 + 0.1, 1e-6));
    expect(d.uvOffset[1], closeTo(0.25 * 8 + 0.2, 1e-6));
    expect(d.bits.incrementOf(0), 0x1);
  });
}
