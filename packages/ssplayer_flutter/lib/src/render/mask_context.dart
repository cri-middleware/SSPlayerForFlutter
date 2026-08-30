import 'dart:typed_data';
import 'dart:ui' as ui;

import 'mask.dart';

/// The frame's masking state, handed to the batch loop and the render backend.
///
/// Shared by both the player (instance recursion) and the render backends (the
/// peeled draws). [coverage] is the Canvas
/// backend's `ui.Image` coverage bitmap; [coverageHandle] is the flutter_gpu
/// backend's opaque `gpu.Texture` (kept as `Object?` so this file stays
/// Widget/GPU-free). The coverage travels **with** the [MaskDraw] — so a mask
/// inherited by an instance child (§3-2-2) carries the *parent's* coverage while
/// the child's own mask carries the child's, without any shared mutable state.
class MaskContext {
  MaskContext(this.plan, this.coverage,
      {this.coverageHandle, this.comp = MaskComposition.identity});

  final MaskPlan plan;
  final ui.Image? coverage;
  final Object? coverageHandle;

  /// The instance hierarchy above this player (§2-6), [MaskComposition.identity]
  /// at the top level. It governs this player's OWN mask too: a caller that
  /// opted out with `mask_influence == 0` settles "not masked" for everything
  /// below it, own writers included.
  final MaskComposition comp;

  /// The mask test for the target at [rank], or null when it is unmasked.
  MaskBits? bitsForTarget(int rank, MaskPartFlags flags) =>
      plan.bitsFor(rank, flags, comp: comp);

  /// A ready-to-draw bundle for a target of THIS player's own mask.
  MaskDraw drawFor(MaskBits bits) => MaskDraw(
      bits, coverage, plan.uvBasis, plan.uvOffset,
      coverageHandle: coverageHandle);
}

/// Everything a peeled draw needs to run the mask replay: the resolved writer
/// sets + polarity ([bits]), the coverage bitmap ([coverage] / [coverageHandle]),
/// and the local→coverage-UV affine. Unifies an *own* mask (from the player's own
/// [MaskPlan]) and a mask **inherited** by an instance child (§3-2-2), whose
/// affine is the parent's pre-composed with the slot matrix. Either way this is
/// ONE part's resolved test: a child subtree does not share one, it derives a
/// polarity per part through [InheritedMask.drawFor].
class MaskDraw {
  const MaskDraw(this.bits, this.coverage, this.uvBasis, this.uvOffset,
      {this.coverageHandle});

  final MaskBits bits;

  /// The Canvas coverage bitmap; `null` under the flutter_gpu backend.
  final ui.Image? coverage;

  /// The flutter_gpu coverage texture (opaque `gpu.Texture`); `null` under Canvas.
  final Object? coverageHandle;
  final Float32List uvBasis;
  final Float32List uvOffset;

  /// The same coverage and writer set, tested on the other side of the mask.
  ///
  /// Used to re-polarise an inherited mask per child part: scope (§2-1) was
  /// settled once by the instance part's rank, so the writer sets are shared by
  /// the whole sub-animation, while the polarity (§2-4) is composed per part
  /// (§2-6). Cheap — everything but the two-bool [MaskBits] header is shared.
  MaskDraw withPolarity(bool visibleInside) => MaskDraw(
        MaskBits(
          increment: bits.increment,
          invert: bits.invert,
          visibleInside: visibleInside,
        ),
        coverage,
        uvBasis,
        uvOffset,
        coverageHandle: coverageHandle,
      );

  /// Composes this player-local→UV mask with an instance slot matrix
  /// (`world2dOf`, child-local → parent-local, column-major), yielding the
  /// child-local → UV affine the child's fragments need (§3-2-2's
  /// `M_child = M_parent · slot_xf`). The coverage and the writer sets carry
  /// over unchanged — the sub-animation sits at the instance part's rank, so
  /// scope is settled — while [bits]'s polarity is superseded per part by
  /// [InheritedMask.drawFor].
  MaskDraw composeSlot(Float64List slot) {
    final b = uvBasis;
    final s0 = slot[0], s1 = slot[1], s4 = slot[4], s5 = slot[5];
    final tx = slot[12], ty = slot[13];
    return MaskDraw(
      bits,
      coverage,
      Float32List.fromList(<double>[
        b[0] * s0 + b[1] * s1, // m00
        b[0] * s4 + b[1] * s5, // m01
        b[2] * s0 + b[3] * s1, // m10
        b[2] * s4 + b[3] * s5, // m11
      ]),
      Float32List.fromList(<double>[
        b[0] * tx + b[1] * ty + uvOffset[0],
        b[2] * tx + b[3] * ty + uvOffset[1],
      ]),
      coverageHandle: coverageHandle,
    );
  }
}

/// What an instance child inherits from the part that called it (§2-6 / §3-2-2).
///
/// Two things travel together, and they are independent:
///
/// * [comp] — the AND/OR chain. It always propagates, and it governs the
///   child's **own** mask as much as an inherited one: a caller with
///   `mask_influence == 0` settles "not masked" for the whole subtree.
/// * [source] — the ancestor's coverage, already re-based onto child-local
///   coordinates, or null when no ancestor mask reaches this child (the child's
///   own mask, if any, still runs).
///
/// Splitting them is what fixes the flattening this port shipped: the caller's
/// resolved test used to be stamped over every part of the sub-animation, so the
/// callee's own `mask_influence` / `visible_inside_mask` never entered the
/// decision. It disagreed with SS7.5 in both directions — a callee opting out
/// was masked anyway, and a callee's polarity was replaced by the caller's.
class InheritedMask {
  const InheritedMask({required this.comp, this.source});

  /// The chain so far ([MaskComposition.identity] means "as if top-level").
  final MaskComposition comp;

  /// The ancestor's coverage + writer sets + child-local→UV affine. Its
  /// [MaskDraw.bits] polarity is a placeholder — [drawFor] replaces it per part.
  final MaskDraw? source;

  /// The test a child part with [flags] runs against the ancestor's coverage,
  /// or null when the composition rules the part out (it then draws unmasked,
  /// unless its own player's mask claims it first) or no ancestor mask reaches.
  MaskDraw? drawFor(MaskPartFlags flags) {
    final s = source;
    if (s == null || !comp.targets(flags)) return null;
    return s.withPolarity(comp.visibleInsideFor(flags));
  }

  /// One more level down: [flags] is an instance part inside the child, [source]
  /// the coverage that reaches it (its own player's mask first, else this one
  /// re-based by [MaskDraw.composeSlot]).
  ///
  /// Nesting therefore chains by handing each level a composed value, with no
  /// extra bookkeeping — which is also why multi-level nesting is untested here,
  /// exactly as in the SDK guide and the sibling ports.
  InheritedMask forChild(MaskPartFlags flags, MaskDraw? source) =>
      InheritedMask(comp: comp.compose(flags), source: source);
}

/// Resolves the mask test for one part at [rank] with [flags]: this player's OWN
/// mask when the part is a target of it, otherwise the mask inherited from a
/// parent instance (§2-6 / §3-2-2).
///
/// An instance sub-animation is parent-driven and passes [maskCtx] as null (it
/// rasterises no own coverage — see `_paintTree`), so its parts resolve straight
/// to the inherited outer mask. At the top-level player [inheritedMask] is null,
/// so parts resolve to the own mask. This is coverage plumbing only — the target
/// opt-in and polarity stay the composition's ([MaskContext.comp] /
/// [InheritedMask]).
MaskDraw? resolvePartMask(MaskContext? maskCtx, InheritedMask? inheritedMask,
    int rank, MaskPartFlags flags) {
  final ownBits = maskCtx?.bitsForTarget(rank, flags);
  return ownBits != null
      ? maskCtx!.drawFor(ownBits)
      : inheritedMask?.drawFor(flags);
}
