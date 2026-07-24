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
  MaskContext(this.plan, this.coverage, {this.coverageHandle});

  final MaskPlan plan;
  final ui.Image? coverage;
  final Object? coverageHandle;

  /// The mask test for the target at [rank], or null when it is unmasked.
  MaskBits? bitsForTarget(int rank, MaskPartFlags flags) =>
      plan.bitsFor(rank, flags);

  /// A ready-to-draw bundle for a target of THIS player's own mask.
  MaskDraw drawFor(MaskBits bits) => MaskDraw(
      bits, coverage, plan.uvBasis, plan.uvOffset,
      coverageHandle: coverageHandle);
}

/// Everything a peeled draw needs to run the mask replay: the resolved writer
/// sets + polarity ([bits]), the coverage bitmap ([coverage] / [coverageHandle]),
/// and the local→coverage-UV affine. Unifies an *own* mask (from the player's own
/// [MaskPlan]) and a mask **inherited** by an instance child (§3-2-2), whose
/// affine is the parent's pre-composed with the slot matrix. The child gates its
/// whole subtree with one of these, using the instance part's rank/polarity.
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

  /// Composes this player-local→UV mask with an instance slot matrix
  /// (`world2dOf`, child-local → parent-local, column-major), yielding the
  /// child-local → UV affine the child's fragments need (§3-2-2's
  /// `M_child = M_parent · slot_xf`). [bits] and the coverage are carried over
  /// unchanged — the whole child is judged by the instance part's single resolved
  /// test against the *parent's* coverage.
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
