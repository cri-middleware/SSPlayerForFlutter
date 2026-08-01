// Mask settings compose across the instance hierarchy (§2-6).
//
// A mask reaching an instance part applies to the whole sub-animation, but the
// calling part's settings do NOT replace the callee's: `mask_influence` chains
// with AND, `visible_inside_mask` accumulates with OR. This port resolved both
// from the instance part alone and stamped one finished test over every part of
// the child, so the sub-animation's own flags never entered the decision — and
// it disagreed with SS7.5 in both directions:
//
//   * a callee opting out with `mask_influence == 0` was masked anyway;
//   * a callee's `visible_inside_mask` was flattened to the caller's.
//
// The identity (influence = true, visible_inside = false) is what keeps unnested
// playback unchanged, so it is pinned here too.
//
// Multi-level nesting chains by handing each level a composed value; that it
// *chains* is covered below, but agreement with SS7.5 beyond one level is
// unverified — as it is in the SDK guide and in the sibling ports.
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

/// The same, but drawing INSIDE the mask (§2-4).
const _inside = MaskPartFlags(
  pureMask: false,
  maskWrite: false,
  maskInfluence: true,
  visibleInsideMask: true,
);

/// A part opting out of masking altogether (§2-2).
const _optedOut = MaskPartFlags(
  pureMask: false,
  maskWrite: false,
  maskInfluence: false,
  visibleInsideMask: false,
);

/// A clipping writer: draws colour AND writes coverage. Its `mask_influence`
/// encodes the write OP, so it is a target no matter what the chain says.
const _clipping = MaskPartFlags(
  pureMask: false,
  maskWrite: true,
  maskInfluence: false,
  visibleInsideMask: false,
);

void main() {
  group('MaskComposition (§2-6)', () {
    test('the identity leaves a part evaluating by its own flags', () {
      const id = MaskComposition.identity;
      expect(id.targets(_plain), isTrue);
      expect(id.targets(_optedOut), isFalse);
      expect(id.targets(_clipping), isTrue);
      expect(id.visibleInsideFor(_plain), isFalse);
      expect(id.visibleInsideFor(_inside), isTrue);
      // Which is exactly what the top-level reading on the flags says.
      for (final f in <MaskPartFlags>[_plain, _inside, _optedOut, _clipping]) {
        expect(id.targets(f), f.isTarget);
      }
    });

    test('mask_influence chains with AND and never comes back', () {
      const id = MaskComposition.identity;
      expect(id.compose(_plain).influence, isTrue);
      // One caller opting out settles it…
      final out = id.compose(_optedOut);
      expect(out.influence, isFalse);
      // …for every level below, whatever they ask for.
      expect(out.compose(_plain).influence, isFalse);
      expect(out.compose(_plain).compose(_plain).influence, isFalse);
    });

    test('visible_inside_mask accumulates with OR', () {
      const id = MaskComposition.identity;
      expect(id.compose(_plain).visibleInside, isFalse);
      final inside = id.compose(_inside);
      expect(inside.visibleInside, isTrue);
      // Once inside, a plain callee below stays inside.
      expect(inside.compose(_plain).visibleInside, isTrue);
      // And a callee asking for inside puts itself there under a plain caller.
      expect(id.compose(_plain).visibleInsideFor(_inside), isTrue);
    });

    test('a callee opted out by the chain is not a target', () {
      final out = MaskComposition.identity.compose(_optedOut);
      expect(out.targets(_plain), isFalse,
          reason: 'the caller settled "not masked" for the subtree');
    });

    test('mask_write does not compose, but keeps its own part a target', () {
      final out = MaskComposition.identity.compose(_optedOut);
      // The clipping writer itself stays a target of its own mask…
      expect(out.targets(_clipping), isTrue);
      // …while writing a mask is a local fact that descendants do not inherit:
      // the chain below a clipping writer is decided by its mask_influence.
      expect(MaskComposition.identity.compose(_clipping).influence, isFalse);
    });
  });

  group('MaskPlan.bitsFor under a composition', () {
    // One pure-mask writer at rank 4, so ranks 0..3 are in its scope (§2-1).
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
      expect(bits!.invert, 0x1);
      expect(bits.visibleInside, isFalse);
      expect(plan.bitsFor(0, _optedOut), isNull);
    });

    test('an opted-out caller unmasks a target the plan would otherwise claim',
        () {
      final out = MaskComposition.identity.compose(_optedOut);
      expect(plan.bitsFor(0, _plain, comp: out), isNull);
    });

    test('the caller\'s polarity reaches a part that did not ask for it', () {
      final inside = MaskComposition.identity.compose(_inside);
      expect(plan.bitsFor(0, _plain, comp: inside)!.visibleInside, isTrue);
    });

    test('a part keeps its own polarity under a plain caller', () {
      // The flattening bug in the other direction: the callee asked to draw
      // inside, the caller did not, and the caller used to win.
      final plainCaller = MaskComposition.identity.compose(_plain);
      expect(plan.bitsFor(0, _inside, comp: plainCaller)!.visibleInside, isTrue);
    });

    test('visible_inside still forces the test out of scope', () {
      // Rank 9 is past the writer, so no scope — but a part that may only appear
      // inside a mask must still run the test (and be discarded by the empty
      // set). That has to hold when the polarity came from the caller, too.
      final inside = MaskComposition.identity.compose(_inside);
      final bits = plan.bitsFor(9, _plain, comp: inside);
      expect(bits, isNotNull);
      expect(bits!.isEmpty, isTrue);
      expect(bits.visibleInside, isTrue);
      // Whereas the same part with no inherited polarity is simply unmasked.
      expect(plan.bitsFor(9, _plain), isNull);
    });

    test('a clipping writer stays a target under an opted-out caller', () {
      final out = MaskComposition.identity.compose(_optedOut);
      // Rank 0 is in the pure mask's scope; mask_write does not compose away.
      expect(plan.bitsFor(0, _clipping, comp: out), isNotNull);
    });
  });

  group('InheritedMask resolves per child part (§3-2-2)', () {
    final source = MaskDraw(
      const MaskBits(increment: 0x2, invert: 0x1, visibleInside: false),
      null,
      Float32List.fromList(<double>[1, 0, 0, 1]),
      Float32List.fromList(<double>[0, 0]),
    );

    test('every child part shares the writer sets — scope was settled above',
        () {
      final inh = const InheritedMask(comp: MaskComposition.identity)
          .forChild(_plain, source);
      final a = inh.drawFor(_plain)!;
      final b = inh.drawFor(_inside)!;
      expect(a.bits.increment, 0x2);
      expect(a.bits.invert, 0x1);
      expect(b.bits.increment, 0x2);
      expect(b.bits.invert, 0x1);
    });

    test('…but each derives its own polarity', () {
      final inh = const InheritedMask(comp: MaskComposition.identity)
          .forChild(_plain, source);
      expect(inh.drawFor(_plain)!.bits.visibleInside, isFalse);
      expect(inh.drawFor(_inside)!.bits.visibleInside, isTrue,
          reason: "the callee's own visible_inside_mask must survive");
    });

    test('a caller drawing inside puts the whole child inside', () {
      final inh = const InheritedMask(comp: MaskComposition.identity)
          .forChild(_inside, source);
      expect(inh.drawFor(_plain)!.bits.visibleInside, isTrue);
      expect(inh.drawFor(_inside)!.bits.visibleInside, isTrue);
    });

    test('a child part that opts out is not masked by the caller', () {
      final inh = const InheritedMask(comp: MaskComposition.identity)
          .forChild(_plain, source);
      expect(inh.drawFor(_optedOut), isNull,
          reason: 'the blanket stamp used to mask it anyway');
    });

    test('an opted-out caller unmasks the entire child', () {
      // The instance part itself is not a target, so nothing reaches the child.
      final inh = const InheritedMask(comp: MaskComposition.identity)
          .forChild(_optedOut, null);
      expect(inh.comp.influence, isFalse);
      expect(inh.drawFor(_plain), isNull);
      expect(inh.drawFor(_inside), isNull);
    });

    test('no ancestor coverage means no inherited test, chain or not', () {
      final inh = const InheritedMask(comp: MaskComposition.identity)
          .forChild(_plain, null);
      expect(inh.comp.influence, isTrue, reason: 'the chain still propagates');
      expect(inh.drawFor(_plain), isNull);
    });

    test('the chain reaches a second level', () {
      final first = const InheritedMask(comp: MaskComposition.identity)
          .forChild(_inside, source);
      final second = first.forChild(_plain, first.drawFor(_plain));
      // OR carried down two levels…
      expect(second.drawFor(_plain)!.bits.visibleInside, isTrue);
      // …and AND settles at whichever level opts out.
      final blocked = first.forChild(_optedOut, null);
      expect(blocked.drawFor(_plain), isNull);
    });
  });

  test('the slot affine composes without disturbing the writer sets', () {
    // §3-2-2 `M_child = M_parent · slot_xf`: re-basing the UV is orthogonal to
    // the per-part composition, so the two can be applied in either order.
    final source = MaskDraw(
      const MaskBits(increment: 0x2, invert: 0x1, visibleInside: false),
      null,
      Float32List.fromList(<double>[0.5, 0, 0, 0.25]),
      Float32List.fromList(<double>[0.1, 0.2]),
    );
    // A slot that scales by 2 and translates by (4, 8), column-major 4x4.
    final slot = Float64List(16);
    slot[0] = 2;
    slot[5] = 2;
    slot[12] = 4;
    slot[13] = 8;

    // Tolerance is float32's — the affine is carried in a Float32List uniform.
    final composed = source.composeSlot(slot);
    expect(composed.uvBasis[0], closeTo(1.0, 1e-6)); // 0.5 * 2
    expect(composed.uvBasis[3], closeTo(0.5, 1e-6)); // 0.25 * 2
    expect(composed.uvOffset[0], closeTo(0.5 * 4 + 0.1, 1e-6));
    expect(composed.uvOffset[1], closeTo(0.25 * 8 + 0.2, 1e-6));

    // Re-polarising afterwards leaves the affine alone.
    final repolarised = composed.withPolarity(true);
    expect(repolarised.uvBasis, composed.uvBasis);
    expect(repolarised.uvOffset, composed.uvOffset);
    expect(repolarised.bits.increment, 0x2);
    expect(repolarised.bits.invert, 0x1);
    expect(repolarised.bits.visibleInside, isTrue);
  });
}
