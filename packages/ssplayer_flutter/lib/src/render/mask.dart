import 'dart:typed_data';
import 'dart:ui' as ui;

import '../ssab/ssab.g.dart' as ssab;
import 'geometry_builder.dart';

/// Maximum mask writers honoured in one frame (§3-2).
///
/// Each writer owns one bit of the coverage bitmap, and the bits live in the
/// RGB channels only (8 × 3 = 24) — alpha is reserved as the premultiplied-blend
/// accumulator, exactly as in the Godot flagship. Writers past the cap are
/// dropped (the flagship `break`s too).
const int kMaxMaskWriters = 24;

/// The static, per-part mask flags — read **once** from the `.ssab` `PartData`
/// and never re-read per frame (mask §用語表: PartData is static, FrameData is
/// animated).
///
/// The three canonical role expressions (§1-2) are exposed as [isWriter] /
/// [isClipping] / [isTarget]; do not re-derive them at call sites.
class MaskPartFlags {
  const MaskPartFlags({
    required this.pureMask,
    required this.maskWrite,
    required this.maskInfluence,
    required this.visibleInsideMask,
    this.quadGeometry = true,
  });

  /// A part with no mask involvement at all (also the out-of-range fallback).
  static const MaskPartFlags none = MaskPartFlags(
    pureMask: false,
    maskWrite: false,
    maskInfluence: false,
    visibleInsideMask: false,
  );

  /// Whether this part's shape is the plain 4-corner sprite quad
  /// (`local_vertices`) — true for Normal and Mask parts.
  ///
  /// Mesh / Shape / Text / Nines carry their own geometry, which the coverage
  /// pass cannot rasterise yet. Such a part is dropped as a *writer*
  /// ([MaskPlan.build]) rather than clipping its targets with the wrong shape:
  /// per the SDK's role table a Mesh can never be a pure mask, but it CAN be a
  /// clipping writer, and rasterising its undeformed quad would clip to a
  /// rectangle instead of the deformed mesh. Not writing at all is the more
  /// predictable of the two wrongs until the geometry is wired up.
  final bool quadGeometry;

  /// `PartTypeMask || draw_as_mask` — writes coverage and draws NO colour.
  final bool pureMask;

  /// Writes coverage; when the part is not [pureMask] it also draws normally
  /// (a "clipping" writer).
  final bool maskWrite;

  /// **Deliberately overloaded** (§用語表), never normalise it away:
  /// * on a writer → the stencil OP (`false` = increment, `true` = invert);
  /// * on a target → the opt-in flag (`false` = not affected by masks).
  ///
  /// A clipping writer is both at once, from this one value.
  final bool maskInfluence;

  /// Polarity of the mask test for this part **as a target**: draw inside the
  /// mask (`true`) or outside it (`false`). Lives on the target, not the writer.
  final bool visibleInsideMask;

  /// §1-2: `is_writer = pure_mask || mask_write`.
  bool get isWriter => pureMask || maskWrite;

  /// §1-2: `is_clipping = mask_write && !pure_mask` — draws colour AND masks
  /// the parts drawn *after* it (pure masks mask the ones *before*).
  bool get isClipping => maskWrite && !pureMask;

  /// Whether this part is subject to the mask test at all. Clipping writers are
  /// always targets (their `mask_influence` encodes the OP, not an opt-out).
  bool get isTarget => maskInfluence || maskWrite;

  /// Reads the per-part flags out of the `.ssab` `PartData` list, indexed by
  /// part index (`SsAnimeBinary.parts` is part-index ordered).
  ///
  /// Returns an empty list when the pack has no parts. Cheap enough to do once
  /// at load; the result is immutable for the life of the resource.
  static List<MaskPartFlags> readAll(Uint8List ssabBytes) {
    final parts = ssab.SsAnimeBinary(ssabBytes).parts;
    if (parts == null || parts.isEmpty) return const <MaskPartFlags>[];
    return List<MaskPartFlags>.generate(
      parts.length,
      (i) {
        final p = parts[i];
        final type = p.partTypeType;
        return MaskPartFlags(
          pureMask:
              type == ssab.PartTypeTypeId.PartTypeMask || p.drawAsMask,
          maskWrite: p.maskWrite,
          maskInfluence: p.maskInfluence,
          visibleInsideMask: p.visibleInsideMask,
          quadGeometry: type == ssab.PartTypeTypeId.PartTypeNormal ||
              type == ssab.PartTypeTypeId.PartTypeMask,
        );
      },
      growable: false,
    );
  }
}

/// One coverage-bitmap writer for the current frame (§3-2-1).
class MaskWriter {
  const MaskWriter({
    required this.partIndex,
    required this.drawRank,
    required this.bit,
    required this.opInvert,
    required this.isClipping,
    required this.threshold,
  });

  /// The writing part (indexes the SoA buffers).
  final int partIndex;

  /// Its position in `draw_order` — the scope pivot (§2-1).
  final int drawRank;

  /// Coverage bit, `0..kMaxMaskWriters-1`. Assigned in ascending [drawRank],
  /// which is what lets the replay loop walk bits in order (see [MaskBits]).
  final int bit;

  /// Stencil OP: `false` = increment, `true` = invert (§2-3).
  final bool opInvert;

  /// Clipping writer — masks the parts drawn *after* it (§2-1).
  final bool isClipping;

  /// Cutout alpha threshold `(255 - mask) / 255` (§2-5): texels at or below it
  /// do not contribute coverage.
  final double threshold;
}

/// One target's resolved mask test: which writers apply to it, and with what
/// polarity.
///
/// [increment] / [invert] are 24-bit sets indexed by [MaskWriter.bit], already
/// filtered to the writers whose scope (§2-1) reaches this target. Because bits
/// are handed out in ascending draw rank, the shader can replay the ops in the
/// correct order by simply walking bits 0→23 — which is why the flagship's
/// `mask_meta[]` array (4 floats per writer) is not needed here: scope is
/// resolved on the CPU and only these two sets reach the shader. 24-bit integers
/// are exactly representable in a float32 uniform.
class MaskBits {
  const MaskBits({
    required this.increment,
    required this.invert,
    required this.visibleInside,
  });

  /// Writers active for this target whose OP is increment (§2-3).
  final int increment;

  /// Writers active for this target whose OP is invert (§2-3).
  final int invert;

  /// The target's own polarity (§2-4): draw inside the mask, or outside it.
  final bool visibleInside;

  /// No writer reaches this target. With [visibleInside] the part draws
  /// nowhere (it may only appear inside a mask); otherwise it draws everywhere.
  bool get isEmpty => increment == 0 && invert == 0;
}

/// The frame's mask plan: which parts write coverage, the player-local box the
/// coverage bitmap spans, and the per-target scope resolution (§3-2).
///
/// Pure data + geometry — no `Canvas`, no FFI — so it is unit-testable without
/// a GPU. The owning player rasterises [writers] into the bitmap and feeds
/// [bitsFor] to the target shader.
class MaskPlan {
  MaskPlan._({
    required this.writers,
    required this.bounds,
    required int maxMaskRank,
    required int minClipRank,
  })  : _maxMaskRank = maxMaskRank,
        _minClipRank = minClipRank;

  /// Builds a plan from ready-made [writers] (ascending `drawRank`, `bit` equal
  /// to the list position) spanning [bounds], deriving the scope pivots.
  ///
  /// [MaskPlan.build] is the normal entry point; this is for callers that drive
  /// the writer set themselves (and for tests).
  factory MaskPlan.fromWriters({
    required List<MaskWriter> writers,
    required ui.Rect bounds,
  }) {
    var maxMaskRank = -1;
    var minClipRank = -1;
    for (final w in writers) {
      if (w.isClipping) {
        if (minClipRank < 0 || w.drawRank < minClipRank) minClipRank = w.drawRank;
      } else if (w.drawRank > maxMaskRank) {
        maxMaskRank = w.drawRank;
      }
    }
    return MaskPlan._(
      writers: writers,
      bounds: bounds,
      maxMaskRank: maxMaskRank,
      minClipRank: minClipRank,
    );
  }

  /// This frame's writers, in ascending [MaskWriter.drawRank] / [MaskWriter.bit].
  final List<MaskWriter> writers;

  /// Union of the writers' world quads in **player-local** space. The coverage
  /// bitmap is stretched over exactly this box, so the local→UV map is
  /// resolution-independent (§3-2-2).
  final ui.Rect bounds;

  /// Highest rank among pure-mask writers (-1 when none): every part below it
  /// is potentially masked.
  final int _maxMaskRank;

  /// Lowest rank among clipping writers (-1 when none): every part above it is
  /// potentially masked.
  final int _minClipRank;

  /// Collects the frame's writers by walking `draw_order` in rank order
  /// (§3-2-1). Returns null when nothing writes coverage this frame — the
  /// caller then skips the whole mask machinery.
  ///
  /// [flags] is indexed by part index ([MaskPartFlags.readAll]). Parts whose
  /// animated `mask` attribute is 0 are skipped (§2-2 opt-out); `hide` needs no
  /// check because the Brain already drops hidden parts from `draw_order`.
  static MaskPlan? build(DrawFrame frame, List<MaskPartFlags> flags) {
    final drawOrder = frame.drawOrder;
    final writers = <MaskWriter>[];
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;

    for (var rank = 0; rank < drawOrder.length; rank++) {
      if (writers.length >= kMaxMaskWriters) break;
      final p = drawOrder[rank];
      final f = p < flags.length ? flags[p] : MaskPartFlags.none;
      if (!f.isWriter) continue;
      // The coverage pass rasterises the sprite quad; a writer with its own
      // geometry (Mesh / Shape / …) would clip to the wrong shape.
      if (!f.quadGeometry) continue;

      // §2-2: mask == 0 opts the writer out entirely. (Equivalently its cutout
      // threshold would be 1.0 and it would write nothing.)
      final mask = frame.partByIndex[p]?.mask ?? 0.0;
      if (mask <= 0.0) continue;

      final corners = GeometryBuilder.worldCornersOf(p, frame);
      if (corners == null) continue; // no geometry this frame — nothing to write

      writers.add(MaskWriter(
        partIndex: p,
        drawRank: rank,
        bit: writers.length,
        opInvert: f.maskInfluence,
        isClipping: f.isClipping,
        threshold: ((255.0 - mask) / 255.0).clamp(0.0, 1.0),
      ));

      for (var c = 0; c < 4; c++) {
        final x = corners[c * 2], y = corners[c * 2 + 1];
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }

    if (writers.isEmpty) return null;
    if (!(right > left) || !(bottom > top)) return null; // degenerate box

    return MaskPlan.fromWriters(
      writers: writers,
      bounds: ui.Rect.fromLTRB(left, top, right, bottom),
    );
  }

  /// Whether any writer's scope reaches a target at [rank] (§2-1) — the cheap
  /// early-out the flagship calls `_part_in_mask_scope`.
  bool inScope(int rank) =>
      (_maxMaskRank >= 0 && rank < _maxMaskRank) ||
      (_minClipRank >= 0 && rank > _minClipRank);

  /// The mask test for the target at [rank], or null when the part is not
  /// masked and keeps the plain batched path.
  ///
  /// A part is tested when it opts in ([MaskPartFlags.isTarget]) **and** either
  /// a writer's scope reaches it or it is `visible_inside_mask` — the latter
  /// draws only inside a mask, so it must run the test even out of scope (where
  /// the empty writer set then correctly discards it).
  ///
  /// Scope (§2-1): a pure mask applies to parts drawn *before* it
  /// (`rank < writer.drawRank`); a clipping writer to parts drawn *after* it.
  MaskBits? bitsFor(int rank, MaskPartFlags flags) {
    if (!flags.isTarget) return null;
    if (!inScope(rank) && !flags.visibleInsideMask) return null;

    var increment = 0;
    var invert = 0;
    for (final w in writers) {
      final active = w.isClipping ? rank > w.drawRank : rank < w.drawRank;
      if (!active) continue;
      final bit = 1 << w.bit;
      if (w.opInvert) {
        invert |= bit;
      } else {
        increment |= bit;
      }
    }
    return MaskBits(
      increment: increment,
      invert: invert,
      visibleInside: flags.visibleInsideMask,
    );
  }

  /// The player-local → coverage-UV affine (§3-2-2), as the shader wants it:
  /// `[m00, m01, m10, m11]` with the offset in [uvOffset]. The box maps onto the
  /// full `[0,1]²` texture, so this is independent of the bitmap's pixel size.
  Float32List get uvBasis => Float32List.fromList(<double>[
        1.0 / bounds.width, 0.0, //
        0.0, 1.0 / bounds.height,
      ]);

  /// Offset half of the [uvBasis] affine.
  Float32List get uvOffset => Float32List.fromList(<double>[
        -bounds.left / bounds.width,
        -bounds.top / bounds.height,
      ]);
}
