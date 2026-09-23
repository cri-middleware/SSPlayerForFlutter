import 'dart:typed_data';
import 'dart:ui' as ui;

import '../ssab/ssab.g.dart' as ssab;
import '../texture_registry.dart';
import 'geometry_builder.dart';

/// Maximum mask writers honoured in one frame.
///
/// Each writer owns one bit of the coverage bitmap, and the bits live in the
/// RGB channels only (8 × 3 = 24) — alpha is reserved as the premultiplied-blend
/// accumulator, exactly as in the Godot flagship. Writers past the cap are
/// dropped (the flagship `break`s too).
const int kMaxMaskWriters = 24;

/// Sentinel [MaskWriter.partIndex] for a writer **carried up** from an instance
/// child (carry-over): it is not one of THIS player's parts, so its
/// geometry cannot be baked from this player's SoA. The coverage pass skips it
/// in the own-writer loop and bakes it from the parallel [MaskPlan.bubbled]
/// entry (the child's own geometry, under the instance slot matrix) instead. It
/// still resolves scope like any clipping writer, ranked at the instance part.
const int kBubbledWriterPart = -2;

/// [MaskWriter.threshold] for a writer that has no texel to cut out — a Shape
/// (the shape special case), whose whole polygon is the mask. Below every
/// possible alpha, so nothing is ever thresholded away (the flagship's sentinel
/// too).
const double noCutoutThreshold = -1.0;

/// The static, per-part mask flags — read **once** from the `.ssab` `PartData`
/// and never re-read per frame (PartData is static, FrameData is
/// animated).
///
/// The three canonical role expressions are exposed as [isWriter] /
/// [isClipping] / [isTarget]; do not re-derive them at call sites.
class MaskPartFlags {
  const MaskPartFlags({
    required this.pureMask,
    required this.maskWrite,
    required this.maskInfluence,
    required this.visibleInsideMask,
    this.quadGeometry = true,
    this.shapeGeometry = false,
    this.meshGeometry = false,
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
  /// Mesh / Text / Nines carry their own geometry, which the coverage pass
  /// cannot rasterise yet. Such a part is dropped as a *writer*
  /// ([MaskPlan.build]) rather than clipping its targets with the wrong shape:
  /// a Mesh can never be a pure mask, but it CAN be a
  /// clipping writer, and rasterising its undeformed quad would clip to a
  /// rectangle instead of the deformed mesh. Not writing at all is the more
  /// predictable of the two wrongs until the geometry is wired up.
  final bool quadGeometry;

  /// A Shape part: its coverage is its **polygon**, taken from the shape
  /// SoA rather than the sprite quad.
  ///
  /// A shape writer also bypasses the alpha cutout entirely — it has no
  /// cell and therefore no texel alpha to threshold, so the whole shape is the mask.
  /// That is why it is a separate flag rather than another [quadGeometry] case:
  /// the two differ in both geometry *and* thresholding.
  final bool shapeGeometry;

  /// A Mesh part: its coverage is its deformed triangle mesh, taken from the
  /// mesh SoA (already world-space). Like a shape it bypasses the alpha cutout —
  /// Flutter fragment shaders take no per-vertex UV varying, so the mesh
  /// texel alpha cannot be thresholded per fragment; the triangle geometry *is*
  /// the mask. A slight over-cover versus a texel-cutout mesh, but a mesh
  /// clipping writer (e.g. `Mesh-WriteMask-True`) clips its targets using that
  /// geometry.
  final bool meshGeometry;

  /// Whether this part can write coverage at all — i.e. the coverage pass knows
  /// how to rasterise its shape. Text / Nines are still dropped as writers
  /// rather than clipping their targets with a wrong-shaped stand-in.
  bool get drawableWriter => quadGeometry || shapeGeometry || meshGeometry;

  /// `PartTypeMask || draw_as_mask` — writes coverage and draws NO colour.
  final bool pureMask;

  /// Writes coverage; when the part is not [pureMask] it also draws normally
  /// (a "clipping" writer).
  final bool maskWrite;

  /// **Deliberately overloaded**, never normalise it away:
  /// * on a writer → the stencil OP (`false` = increment, `true` = invert);
  /// * on a target → the opt-in flag (`false` = not affected by masks).
  ///
  /// A clipping writer is both at once, from this one value.
  final bool maskInfluence;

  /// Polarity of the mask test for this part **as a target**: draw inside the
  /// mask (`true`) or outside it (`false`). Lives on the target, not the writer.
  final bool visibleInsideMask;

  /// `is_writer = pure_mask || mask_write`.
  bool get isWriter => pureMask || maskWrite;

  /// `is_clipping = mask_write && !pure_mask` — draws colour AND masks
  /// the parts drawn *after* it (pure masks mask the ones *before*).
  bool get isClipping => maskWrite && !pureMask;

  /// Whether this part's own colour is subject to the mask test at all, judged
  /// on its own flags — i.e. whether its `mask_influence` opts it in.
  ///
  /// `mask_write` does NOT force this: a clipping writer
  /// draws its pixels first and only then writes its clip below ("pixels, then
  /// mask"), so its own write must not clip its own colour — it is still clipped
  /// by OTHER masks purely on its real `mask_influence`. A clipping writer with
  /// `mask_influence == 0` therefore draws unmasked.
  ///
  /// This is the top-level reading. Inside an instance sub-animation the
  /// caller's settings compose with these — ask
  /// [MaskComposition.targets] there, which reduces to this under
  /// [MaskComposition.identity].
  bool get isTarget => MaskComposition.identity.targets(this);

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
          shapeGeometry: type == ssab.PartTypeTypeId.PartTypeShape,
          meshGeometry: type == ssab.PartTypeTypeId.PartTypeMesh,
        );
      },
      growable: false,
    );
  }
}

/// The mask settings an instance hierarchy has accumulated above a part.
///
/// A mask reaching an instance part applies to the whole sub-animation, but the
/// calling part's settings do **not** replace the callee's — SpriteStudio
/// composes them, and both directions matter:
///
/// * `mask_influence` chains with **AND**. Once a caller opts out, "not masked"
///   is settled for the entire subtree — including against the sub-animation's
///   *own* masks, which is why this travels with the child rather than only with
///   the inherited coverage.
/// * `visible_inside_mask` accumulates with **OR**. Any level asking to draw
///   inside the mask puts everything below it inside.
///
/// [identity] is the unit of both, so a top-level animation resolves to each
/// part's own flags and unnested playback is unchanged.
///
/// `mask_write` deliberately stays out: writing a mask is a local fact about one
/// part, not something its descendants inherit — and it does NOT make the part
/// itself a target either; a clipping writer's own colour
/// is clipped only on its real `mask_influence`, see [targets].
class MaskComposition {
  const MaskComposition({this.influence = true, this.visibleInside = false});

  /// The top of a hierarchy: every part evaluates by its own flags.
  static const MaskComposition identity = MaskComposition();

  /// AND-chain of `mask_influence` — false once any caller opted out.
  final bool influence;

  /// OR-chain of `visible_inside_mask`.
  final bool visibleInside;

  /// Folds one more level in: [flags] is the calling instance part's.
  MaskComposition compose(MaskPartFlags flags) => MaskComposition(
        influence: influence && flags.maskInfluence,
        visibleInside: visibleInside || flags.visibleInsideMask,
      );

  /// Under this composition: is a part with [flags] subject to the mask
  /// test at all? Target-ness is the composed `mask_influence` ALONE.
  ///
  /// `mask_write` must NOT force it: a clipping writer
  /// draws its colour first, then writes its clip below, so gating its own
  /// colour with its own `mask_write` made a `visible_inside_mask` writer with
  /// no covering mask vanish. A clipping writer's own colour is clipped by OTHER
  /// masks purely on its real (composed) `mask_influence`; with influence 0 it
  /// draws unmasked.
  bool targets(MaskPartFlags flags) => influence && flags.maskInfluence;

  /// Under this composition: which side of the mask a part draws on.
  bool visibleInsideFor(MaskPartFlags flags) =>
      visibleInside || flags.visibleInsideMask;
}

/// One coverage-bitmap writer for the current frame.
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

  /// Its position in `draw_order` — the scope pivot.
  final int drawRank;

  /// Coverage bit, `0..kMaxMaskWriters-1`. Assigned in ascending [drawRank]
  /// simply because [MaskPlan.build] walks `draw_order`; the replay does not
  /// depend on the order (see [MaskBits]).
  final int bit;

  /// Stencil OP: `false` = increment, `true` = invert.
  final bool opInvert;

  /// Clipping writer — masks the parts drawn *after* it.
  final bool isClipping;

  /// Cutout alpha threshold `(255 - mask) / 255`: texels at or below it
  /// do not contribute coverage.
  final double threshold;
}

/// One target's resolved mask test: which writers apply to it, and with what
/// polarity.
///
/// [increment] / [invert] are 24-bit sets indexed by [MaskWriter.bit], already
/// filtered to the writers whose scope reaches this target. Resolving
/// scope on the CPU is why the flagship's `mask_meta[]` array (4 floats per
/// writer) is not needed here — only these two sets reach the shader. 24-bit
/// integers are exactly representable in a float32 uniform.
///
/// Splitting them by OP is also what the replay requires: `Invert` and
/// `IncrementWrap` do not commute, so each accumulates on its own plane and the
/// shader takes the union. The two sets are therefore disjoint by construction —
/// a writer's OP puts it in exactly one — and the replay is independent of the
/// order the bits are walked in.
class MaskBits {
  const MaskBits({
    required this.increment,
    required this.invert,
    required this.visibleInside,
  });

  /// Writers active for this target whose OP is increment.
  final int increment;

  /// Writers active for this target whose OP is invert.
  final int invert;

  /// The target's own polarity: draw inside the mask, or outside it.
  final bool visibleInside;

  /// No writer reaches this target. With [visibleInside] the part draws
  /// nowhere (it may only appear inside a mask); otherwise it draws everywhere.
  bool get isEmpty => increment == 0 && invert == 0;
}

/// One instance child's clipping writer **carried up** into the owner's
/// coverage so it clips the owner's parts drawn after the instance.
///
/// It carries everything the coverage bake needs to rasterise the child writer
/// into the owner's bitmap — the child's own [geometry]/[textures]/[frame] and
/// the child-local→owner-local [slot] — so the bake stays a pure function of the
/// plan. Its coverage [bit], op and rank live in a parallel [MaskWriter]
/// (`partIndex == kBubbledWriterPart`) in [MaskPlan.writers], which is what
/// [MaskPlan.bitsFor] resolves owner targets against.
class BubbledWriter {
  const BubbledWriter({
    required this.geometry,
    required this.textures,
    required this.frame,
    required this.flags,
    required this.childPartIndex,
    required this.bit,
    required this.threshold,
    required this.textureHash,
    required this.slot,
  });

  /// The child's SoA→vertex baker (its geometry, not the owner's).
  final GeometryBuilder geometry;

  /// The child's texture registry (its cell atlases).
  final TextureRegistry textures;

  /// The child's frame at the clock the Brain last stepped it to.
  final DrawFrame frame;

  /// The child writer's static role — its geometry kind (quad / shape / mesh).
  final MaskPartFlags flags;

  /// The writer's part index INSIDE the child (indexes the child's SoA).
  final int childPartIndex;

  /// Coverage bit in the OWNER's plan (continues after the owner's own writers).
  final int bit;

  /// Cutout alpha threshold; [noCutoutThreshold] for shape / mesh.
  final double threshold;

  /// The child writer's cell-atlas texture hash, or null for a shape / mesh
  /// writer (geometry-as-mask, no texel to sample).
  final int? textureHash;

  /// Child-local → owner-local affine (the instance slot matrix, column-major
  /// 4×4) — the backends place the child geometry with it.
  final Float64List slot;
}

/// The frame's mask plan: which parts write coverage, the player-local box the
/// coverage bitmap spans, and the per-target scope resolution.
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
    this.bubbled = const <BubbledWriter>[],
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
    List<BubbledWriter> bubbled = const <BubbledWriter>[],
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
      bubbled: bubbled,
    );
  }

  /// This frame's writers, in ascending [MaskWriter.drawRank] / [MaskWriter.bit].
  /// Includes carry-over sentinels (`partIndex == kBubbledWriterPart`) for the
  /// instance children's bubbled clipping writers — present so [bitsFor] resolves
  /// them for the owner's later parts; their geometry is baked from [bubbled].
  final List<MaskWriter> writers;

  /// Instance children's clipping writers carried up into this coverage,
  /// each parallel to a sentinel in [writers] by [BubbledWriter.bit]. Empty in
  /// the common case (no instance child writes a mask this frame).
  final List<BubbledWriter> bubbled;

  /// Union of the writers' world quads in **player-local** space. The coverage
  /// bitmap is stretched over exactly this box, so the local→UV map is
  /// resolution-independent.
  final ui.Rect bounds;

  /// Highest rank among pure-mask writers (-1 when none): every part below it
  /// is potentially masked.
  final int _maxMaskRank;

  /// Lowest rank among clipping writers (-1 when none): every part above it is
  /// potentially masked.
  final int _minClipRank;

  /// Collects the frame's writers by walking `draw_order` in rank order.
  /// Returns null when nothing writes coverage this frame — the
  /// caller then skips the whole mask machinery.
  ///
  /// [flags] is indexed by part index ([MaskPartFlags.readAll]). Parts whose
  /// animated `mask` attribute is 0 are skipped (opt-out); `hide` needs no
  /// check because the Brain already drops hidden parts from `draw_order`.
  /// Grow-only scratch for [build]'s per-writer world outlines.
  ///
  /// Static because [build] is, which is safe only because the outline never
  /// escapes the loop iteration that folds it into the bbox — [build] is
  /// synchronous, so no second caller can be inside it at the same time.
  static Float32List _outlineScratch = Float32List(8); // one sprite quad

  static MaskPlan? build(DrawFrame frame, List<MaskPartFlags> flags,
      {MaskComposition comp = MaskComposition.identity}) {
    final drawOrder = frame.drawOrder;
    final writers = <MaskWriter>[];
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;

    for (var rank = 0; rank < drawOrder.length; rank++) {
      if (writers.length >= kMaxMaskWriters) break;
      final p = drawOrder[rank];
      final f = p < flags.length ? flags[p] : MaskPartFlags.none;
      if (!f.isWriter) continue;
      // A writer whose geometry the coverage pass cannot rasterise (Mesh /
      // Text / Nines) is dropped rather than clipping its targets with a
      // wrong-shaped stand-in.
      if (!f.drawableWriter) continue;

      // mask == 0 opts the writer out entirely. This is a rule of its own
      // — `mask` also serves as the cutout threshold (0 disables the
      // writer), it *doubles as* the threshold — so it still applies to a shape, which has
      // no cutout at all.
      final mask = frame.partOf(p)?.mask ?? 0.0;
      if (mask <= 0.0) continue;

      // World outline: a shape's is its polygon, a mesh's is its (world-space)
      // vertices, everything else's is the sprite quad. A shape/mesh part has no
      // cell and so no `local_vertices`, which is why they cannot share the quad
      // path here.
      // Folded into the bbox below and dropped, so all three share one grow-only
      // buffer rather than allocating per writer per frame.
      final outline = f.shapeGeometry
          ? GeometryBuilder.shapeWorldOutlineOf(p, frame, _outlineScratch)
          : f.meshGeometry
              ? GeometryBuilder.meshWorldOutlineOf(p, frame, _outlineScratch)
              : GeometryBuilder.worldCornersOf(p, frame, _outlineScratch);
      if (outline == null) continue; // no geometry this frame — nothing to write
      // Too small to reuse: the helper allocated an exact-size buffer, so adopt
      // it and the next writer reuses that instead.
      if (outline.length > _outlineScratch.length) _outlineScratch = outline;

      writers.add(MaskWriter(
        partIndex: p,
        drawRank: rank,
        bit: writers.length,
        // Writer side: the OP — and therefore which plane the bit lands
        // on — follows the EFFECTIVE mask_influence, own AND the influence
        // inherited down the instance chain ([comp]). A writer inside a
        // mask_influence == 0 instance moves from the invert (parity) plane to
        // the increment (union) plane, so it composes with an outer mask as a
        // union instead of cancelling it. Top-level [comp] is the identity, so a
        // standalone animation is unchanged.
        opInvert: f.maskInfluence && comp.influence,
        isClipping: f.isClipping,
        // A shape has no texel to threshold, so its whole polygon is the mask
        // (the shape special case); a mesh could threshold in principle but our
        // coverage pass can't sample its per-vertex UV (no shader varyings), so
        // it too falls back to geometry-as-mask. -1 is the flagship's "never cut
        // out" sentinel.
        threshold: f.shapeGeometry || f.meshGeometry
            ? noCutoutThreshold
            : ((255.0 - mask) / 255.0).clamp(0.0, 1.0),
      ));

      for (var c = 0; c * 2 + 1 < outline.length; c++) {
        final x = outline[c * 2], y = outline[c * 2 + 1];
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

  /// Whether any writer's scope reaches a target at [rank] — the cheap
  /// early-out the flagship calls `_part_in_mask_scope`.
  bool inScope(int rank) =>
      (_maxMaskRank >= 0 && rank < _maxMaskRank) ||
      (_minClipRank >= 0 && rank > _minClipRank);

  /// The mask test for the target at [rank], or null when the part is not
  /// masked and keeps the plain batched path.
  ///
  /// A part is tested when it opts in ([MaskComposition.targets]) **and** either
  /// a writer's scope reaches it or it is `visible_inside_mask` — the latter
  /// draws only inside a mask, so it must run the test even out of scope (where
  /// the empty writer set then correctly discards it).
  ///
  /// Scope: a pure mask applies to parts drawn *before* it
  /// (`rank < writer.drawRank`); a clipping writer to parts drawn *after* it.
  ///
  /// [comp] is the instance hierarchy above this player; it governs the
  /// opt-in and the polarity, so a caller that opted out disables even this
  /// player's own mask. [MaskComposition.identity] at the top level leaves the
  /// part's own flags deciding.
  MaskBits? bitsFor(int rank, MaskPartFlags flags,
      {MaskComposition comp = MaskComposition.identity}) {
    if (!comp.targets(flags)) return null;
    final visibleInside = comp.visibleInsideFor(flags);
    if (!inScope(rank) && !visibleInside) return null;

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
      visibleInside: visibleInside,
    );
  }

  /// The player-local → coverage-UV affine, as the shader wants it:
  /// `[m00, m01, m10, m11]` with the offset in [uvOffset]. The box maps onto the
  /// full `[0,1]²` texture, so this is independent of the bitmap's pixel size.
  /// Cached: it is read once per peeled target (and per masked instance child),
  /// so recomputing it each access would allocate needlessly.
  late final Float32List uvBasis = Float32List.fromList(<double>[
    1.0 / bounds.width, 0.0, //
    0.0, 1.0 / bounds.height,
  ]);

  /// Offset half of the [uvBasis] affine (cached, see [uvBasis]).
  late final Float32List uvOffset = Float32List.fromList(<double>[
    -bounds.left / bounds.width,
    -bounds.top / bounds.height,
  ]);
}
