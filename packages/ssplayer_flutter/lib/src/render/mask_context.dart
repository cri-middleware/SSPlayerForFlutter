import 'dart:typed_data';
import 'dart:ui' as ui;

import 'mask.dart';

/// The frame's rasterised coverage: the instance tree's [plan] and the bitmap
/// its writers were baked into.
///
/// Built once per frame by the top-level player's backend
/// ([RenderBackend.renderCoverage]) and shared by every player of the tree,
/// each through its own [PlayerMask]. [coverage] is the Canvas backend's
/// `ui.Image` coverage bitmap; [coverageHandle] is the flutter_gpu backend's
/// opaque `gpu.Texture` (kept as `Object?` so this file stays Widget/GPU-free).
class MaskContext {
  MaskContext(this.plan, this.coverage, {this.coverageHandle});

  final MaskPlan plan;
  final ui.Image? coverage;
  final Object? coverageHandle;
}

/// Everything a peeled draw needs to run the mask replay: the resolved writer
/// sets + polarity ([bits]), the coverage bitmap ([coverage] / [coverageHandle]),
/// and the drawing player's local→coverage-UV affine. This is ONE part's
/// resolved test.
class MaskDraw {
  const MaskDraw(this.bits, this.coverage, this.uvBasis, this.uvOffset,
      {this.coverageHandle, this.tilesX = 1, this.tilesY = 1});

  /// A test that fails everywhere: the part may only appear inside a mask and
  /// none reaches it ([MaskBits.drawsNothing]). Carries no coverage — the draw
  /// paths skip the part before they would bind any.
  static final MaskDraw nothing = MaskDraw(
    const MaskBits(increment: <int>[], invert: <int>[], visibleInside: true),
    null,
    Float32List(4),
    Float32List(2),
  );

  /// Floats [writeReplay] writes.
  static const int replayFloats = 20;

  final MaskBits bits;

  /// The Canvas coverage bitmap; `null` under the flutter_gpu backend.
  final ui.Image? coverage;

  /// The flutter_gpu coverage texture (opaque `gpu.Texture`); `null` under Canvas.
  final Object? coverageHandle;
  final Float32List uvBasis;
  final Float32List uvOffset;

  /// The coverage tile grid ([MaskPlan.tilesX] × [MaskPlan.tilesY]).
  final int tilesX;
  final int tilesY;

  /// Skip the part: see [nothing].
  bool get drawsNothing => bits.drawsNothing;

  /// Writes the replay the flutter_gpu shaders take — five `vec4`s, in the
  /// order of `shaders/gpu/partcolor.vert`'s mask attributes and
  /// `shaders/gpu/shapemask.frag`'s `MaskInfo` block:
  ///
  /// `(visibleInside, enabled, tilesX, tilesY)`, the UV basis
  /// `[m00, m01, m10, m11]`, `(ox, oy, 0, 0)`, the per-tile increment sets and
  /// the per-tile invert sets. [draw] null writes all zeros, which the shaders
  /// read as "not masked".
  static void writeReplay(MaskDraw? draw, Float32List out, [int at = 0]) {
    if (draw == null) {
      out.fillRange(at, at + replayFloats, 0.0);
      return;
    }
    final b = draw.bits;
    out[at] = b.visibleInside ? 1.0 : 0.0;
    out[at + 1] = 1.0; // enabled
    out[at + 2] = draw.tilesX.toDouble();
    out[at + 3] = draw.tilesY.toDouble();
    out[at + 4] = draw.uvBasis[0];
    out[at + 5] = draw.uvBasis[1];
    out[at + 6] = draw.uvBasis[2];
    out[at + 7] = draw.uvBasis[3];
    out[at + 8] = draw.uvOffset[0];
    out[at + 9] = draw.uvOffset[1];
    out[at + 10] = 0.0;
    out[at + 11] = 0.0;
    for (var t = 0; t < kMaskMaxTiles; t++) {
      out[at + 12 + t] = b.incrementOf(t).toDouble();
      out[at + 16 + t] = b.invertOf(t).toDouble();
    }
  }
}

/// How masking reaches ONE player of the instance tree this frame.
///
/// Three things, and they are independent:
///
/// * [tree] — the one coverage the top-level player rasterised for the whole
///   tree, or null when nothing writes a mask this frame.
/// * [comp] — what the instance part calling this player hands down, which
///   decides each part's opt-in and polarity. One level only: it is the
///   instance part's own flags, never composed with what that part inherited
///   ([MaskComposition]).
/// * [seq] — this player's draw ranks on the tree sequence, which the writers'
///   intervals are expressed in; null when the rank is the sequence (a
///   top-level player with no instances).
///
/// A part that draws only inside a mask is tested even when no coverage exists
/// at all — SpriteStudio 7.5 draws it nowhere then — so a player gets a
/// [PlayerMask] every frame, not only when something masks.
class PlayerMask {
  const PlayerMask._({
    required this.tree,
    required this.comp,
    required this.seq,
    required this.uvBasis,
    required this.uvOffset,
  });

  /// The top-level player's view of [tree] (its own local space is the
  /// coverage's), [seq] numbering its ranks on the tree sequence.
  factory PlayerMask.root(MaskContext? tree, {List<int>? seq}) => tree == null
      ? none
      : PlayerMask._(
          tree: tree,
          comp: MaskComposition.identity,
          seq: seq,
          uvBasis: tree.plan.uvBasis,
          uvOffset: tree.plan.uvOffset,
        );

  /// A top-level player with nothing masking this frame.
  static final PlayerMask none = PlayerMask._(
    tree: null,
    comp: MaskComposition.identity,
    seq: null,
    uvBasis: MaskDraw.nothing.uvBasis,
    uvOffset: MaskDraw.nothing.uvOffset,
  );

  final MaskContext? tree;
  final MaskComposition comp;
  final List<int>? seq;

  /// This player's local → coverage-UV affine: `[m00, m01, m10, m11]`.
  final Float32List uvBasis;

  /// Offset half of [uvBasis].
  final Float32List uvOffset;

  /// The mask test for this player's part at [rank] with [flags], or null
  /// when the part is not masked and keeps the plain batched path.
  /// [MaskDraw.drawsNothing] when it may only appear inside a mask and none
  /// reaches it.
  MaskDraw? drawFor(int rank, MaskPartFlags flags) {
    if (!comp.targets(flags)) return null;
    final visibleInside = comp.visibleInsideFor(flags);
    final t = tree;
    final s = seq;
    final at = s == null ? rank : (rank < s.length ? s[rank] : -1);
    if (t == null || at < 0) return visibleInside ? MaskDraw.nothing : null;
    final bits = t.plan.bitsAt(at, visibleInside: visibleInside);
    if (bits == null) return null;
    if (bits.drawsNothing) return MaskDraw.nothing;
    return MaskDraw(bits, t.coverage, uvBasis, uvOffset,
        coverageHandle: t.coverageHandle,
        tilesX: t.plan.tilesX,
        tilesY: t.plan.tilesY);
  }

  /// The view handed to the sub-animation of the instance part with
  /// [instancePart] flags, placed by [slot] (`world2dOf`, child-local →
  /// this-player-local, column-major) and numbered by [childSeq].
  ///
  /// The coverage and its writer sets carry over unchanged; only the UV affine
  /// is re-composed (`M_child = M_this · slot`) so the child's local fragments
  /// sample the same bitmap. The composition is replaced, not composed — see
  /// [MaskComposition].
  PlayerMask forInstance(
      MaskPartFlags instancePart, Float64List slot, List<int>? childSeq) {
    final comp = MaskComposition.ofInstancePart(instancePart);
    if (tree == null) {
      return PlayerMask._(
        tree: null,
        comp: comp,
        seq: null,
        uvBasis: uvBasis,
        uvOffset: uvOffset,
      );
    }
    final b = uvBasis;
    final s0 = slot[0], s1 = slot[1], s4 = slot[4], s5 = slot[5];
    final tx = slot[12], ty = slot[13];
    return PlayerMask._(
      tree: tree,
      comp: comp,
      seq: childSeq,
      uvBasis: Float32List.fromList(<double>[
        b[0] * s0 + b[1] * s1, // m00
        b[0] * s4 + b[1] * s5, // m01
        b[2] * s0 + b[3] * s1, // m10
        b[2] * s4 + b[3] * s5, // m11
      ]),
      uvOffset: Float32List.fromList(<double>[
        b[0] * tx + b[1] * ty + uvOffset[0],
        b[2] * tx + b[3] * ty + uvOffset[1],
      ]),
    );
  }
}
