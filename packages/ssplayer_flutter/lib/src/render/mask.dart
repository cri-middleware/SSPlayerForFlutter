import 'dart:typed_data';
import 'dart:ui' as ui;

import '../ssab/ssab.g.dart' as ssab;
import '../texture_registry.dart';
import 'geometry_builder.dart';

/// Writers one coverage tile tells apart.
///
/// Each writer owns one bit of the coverage bitmap, and the bits live in the
/// RGB channels only (8 × 3 = 24) — alpha is reserved as the premultiplied-blend
/// accumulator, exactly as in ForGodot.
const int kMaskTileBits = 24;

/// Tiles the coverage bitmap splits into at most (a 2×2 grid).
const int kMaskMaxTiles = 4;

/// Maximum mask writers honoured in one frame, across the whole instance tree.
///
/// Past [kMaskTileBits] writers the coverage bitmap is split into 2 and then 4
/// tiles, each holding the same box at a lower resolution, and writer `bit`
/// lives in tile `bit ~/ kMaskTileBits` — the way ForGodot and ForWeb (Pixi)
/// do it. The bitmap does not grow, so many masks cost mask-edge resolution,
/// not memory. Writers past the cap are dropped.
const int kMaxMaskWriters = kMaskTileBits * kMaskMaxTiles;

/// Sentinel [MaskWriter.partIndex] for a writer that belongs to an instance
/// descendant, at any depth: it is not one of the coverage owner's parts, so
/// its geometry cannot be baked from the owner's SoA. The coverage pass skips
/// it in the own-writer loop and bakes it from the parallel [MaskPlan.bubbled]
/// entry (the descendant's own geometry, under the chain of instance matrices)
/// instead. Its scope is its [MaskWriter.open] / [MaskWriter.close] interval
/// on the tree sequence, like any other writer's.
const int kBubbledWriterPart = -2;

/// [MaskWriter.close] of a clipping writer: the end of the tree sequence. A
/// clipping writer keeps clipping everything drawn after it, out through every
/// instance that encloses it, to the end of the top-level animation.
const int kMaskSeqEnd = 1 << 30;

/// [MaskWriter.threshold] for a writer that has no texel to cut out — a Shape
/// (the shape special case), whose whole polygon is the mask. Below every
/// possible alpha, so nothing is ever thresholded away (ForGodot's sentinel
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
  /// instance part's settings compose with these — ask
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

/// The mask settings an instance part hands to the sub-animation it calls.
///
/// A part's own `mask_influence` / `visible_inside_mask` compose with those of
/// the instance part **directly** above it — `mask_influence` with AND,
/// `visible_inside_mask` with OR — and with nothing further up. SpriteStudio
/// 7.5 composes one level only: under an instance part with
/// `mask_influence == 0` the instance's own parts are left unmasked, while a
/// grandchild whose own instance part opts in is masked again. Chaining the
/// flags down the whole hierarchy (as this port once did) settles "not masked"
/// for the entire subtree instead.
///
/// It composes whether or not a mask reaches the caller: the value depends on
/// the instance part alone. [identity] is the unit of both operations and what
/// the top-level animation runs under, so its parts evaluate by their own
/// flags.
///
/// `mask_write` deliberately stays out: writing a mask is a local fact about one
/// part, not something its descendants inherit — and it does NOT make the part
/// itself a target either; a clipping writer's own colour
/// is clipped only on its real `mask_influence`, see [targets].
class MaskComposition {
  const MaskComposition({this.influence = true, this.visibleInside = false});

  /// What the instance part with [flags] hands to its sub-animation: its own
  /// two flags, and nothing it inherited itself.
  factory MaskComposition.ofInstancePart(MaskPartFlags flags) =>
      (flags.maskInfluence && !flags.visibleInsideMask)
          ? identity
          : MaskComposition(
              influence: flags.maskInfluence,
              visibleInside: flags.visibleInsideMask,
            );

  /// The top of a hierarchy: every part evaluates by its own flags.
  static const MaskComposition identity = MaskComposition();

  /// The calling instance part's `mask_influence`, AND-ed into each part's.
  final bool influence;

  /// The calling instance part's `visible_inside_mask`, OR-ed into each part's.
  final bool visibleInside;

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

  /// Under this composition: the OP a writer with [flags] applies — `true` =
  /// invert, `false` = increment. One level, like the target test: the
  /// writer's own `mask_influence` AND the instance part's. A writer inside a
  /// `mask_influence == 0` instance therefore moves to the increment (union)
  /// plane and composes with an outer mask instead of cancelling it.
  bool opInvertFor(MaskPartFlags flags) => influence && flags.maskInfluence;

  @override
  bool operator ==(Object other) =>
      other is MaskComposition &&
      other.influence == influence &&
      other.visibleInside == visibleInside;

  @override
  int get hashCode => Object.hash(influence, visibleInside);
}

/// One coverage-bitmap writer for the current frame.
class MaskWriter {
  /// [open] / [close] default to the writer's scope within a lone animation,
  /// where the tree sequence is simply the draw rank: a pure mask from before
  /// the first part up to itself, a clipping writer from itself to the end.
  const MaskWriter({
    required this.partIndex,
    required this.drawRank,
    required this.bit,
    required this.opInvert,
    required this.isClipping,
    required this.threshold,
    int? open,
    int? close,
  })  : open = open ?? (isClipping ? drawRank : -1),
        close = close ?? (isClipping ? kMaskSeqEnd : drawRank);

  /// The writing part (indexes the SoA buffers).
  final int partIndex;

  /// Its position in its own animation's `draw_order`. Scope is decided by
  /// [open] / [close]; the rank only finds the writer's texture.
  final int drawRank;

  /// Coverage bit, `0..kMaxMaskWriters-1`: bit `bit % kMaskTileBits` of tile
  /// `bit ~/ kMaskTileBits`. Assigned in ascending [drawRank]
  /// simply because [MaskPlan.build] walks `draw_order`; the replay does not
  /// depend on the order (see [MaskBits]).
  final int bit;

  /// Stencil OP: `false` = increment, `true` = invert.
  final bool opInvert;

  /// Clipping writer — masks the parts drawn *after* it.
  final bool isClipping;

  /// Where this writer's bit starts to count on the tree sequence, exclusive:
  /// a target at sequence `s` is reached when `open < s < close`.
  ///
  /// The tree sequence numbers every part of the instance tree in draw order,
  /// a visible instance's sub-animation taking the numbers right after its
  /// instance part. A pure mask spans from the start of its own animation (its
  /// instance part, or -1 at the top) up to itself, so it never reaches out of
  /// the sub-animation that holds it; a clipping writer spans from itself to
  /// [kMaskSeqEnd], so one written inside an instance keeps clipping the
  /// caller's later parts, however deep it sits.
  final int open;

  /// Where this writer's bit stops counting, exclusive. See [open].
  final int close;

  /// Whether this writer reaches the target at tree sequence [seq].
  bool reaches(int seq) => open < seq && seq < close;

  /// Cutout alpha threshold `(255 - mask) / 255`: texels at or below it
  /// do not contribute coverage.
  final double threshold;
}

/// One target's resolved mask test: which writers apply to it, and with what
/// polarity.
///
/// [increment] / [invert] hold one 24-bit set per coverage tile, bit `b` of
/// tile `t` standing for [MaskWriter.bit] `t * kMaskTileBits + b`, already
/// filtered to the writers whose scope reaches this target. Resolving
/// scope on the CPU is why ForGodot's `mask_meta[]` array (4 floats per
/// writer) is not needed here — only these sets reach the shader. 24-bit
/// integers are exactly representable in a float32 uniform.
///
/// Splitting them by OP is also what the replay requires: `Invert` and
/// `IncrementWrap` do not commute, so each accumulates on its own plane and the
/// shader takes the union. The two sets are therefore disjoint by construction —
/// a writer's OP puts it in exactly one — and the replay is independent of the
/// order the bits are walked in.
class MaskBits {
  /// [increment] / [invert] list one set per tile, tile 0 first; missing tiles
  /// are empty.
  const MaskBits({
    required this.increment,
    required this.invert,
    required this.visibleInside,
  });

  /// No writer at all, on either side of the mask.
  static const MaskBits none = MaskBits(
    increment: <int>[],
    invert: <int>[],
    visibleInside: false,
  );

  /// Writers active for this target whose OP is increment, per tile.
  final List<int> increment;

  /// Writers active for this target whose OP is invert, per tile.
  final List<int> invert;

  /// The target's own polarity: draw inside the mask, or outside it.
  final bool visibleInside;

  /// The increment set of [tile] (0 past the listed tiles).
  int incrementOf(int tile) => tile < increment.length ? increment[tile] : 0;

  /// The invert set of [tile] (0 past the listed tiles).
  int invertOf(int tile) => tile < invert.length ? invert[tile] : 0;

  /// Whether the writer holding [MaskWriter.bit] [bit] reaches this target.
  bool has(int bit) {
    final tile = bit ~/ kMaskTileBits;
    final mask = 1 << (bit % kMaskTileBits);
    return (incrementOf(tile) | invertOf(tile)) & mask != 0;
  }

  /// No writer reaches this target. With [visibleInside] the part draws
  /// nowhere (it may only appear inside a mask); otherwise it draws everywhere.
  bool get isEmpty =>
      increment.every((s) => s == 0) && invert.every((s) => s == 0);

  /// The test fails at every pixel: no writer reaches a part that may only
  /// appear inside a mask. A draw path skips such a part outright rather than
  /// running a shader that would discard every fragment.
  bool get drawsNothing => isEmpty && visibleInside;
}

/// One instance descendant's writer, at any depth, baked into the top-level
/// player's coverage — pure masks and clipping writers alike, since every
/// writer of the tree shares the one bitmap.
///
/// It carries everything the coverage bake needs to rasterise the writer into
/// the owner's bitmap — the descendant's own [geometry]/[textures]/[frame] and
/// the descendant-local→owner-local [slot] — so the bake stays a pure function
/// of the plan. Its coverage [bit], op and interval live in a parallel
/// [MaskWriter] (`partIndex == kBubbledWriterPart`) in [MaskPlan.writers],
/// which is what [MaskPlan.bitsFor] resolves targets against.
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

  /// The descendant's SoA→vertex baker (its geometry, not the owner's).
  final GeometryBuilder geometry;

  /// The descendant's texture registry (its cell atlases).
  final TextureRegistry textures;

  /// The descendant's frame at the clock the Brain last stepped it to.
  final DrawFrame frame;

  /// The writer's static role — its geometry kind (quad / shape / mesh).
  final MaskPartFlags flags;

  /// The writer's part index INSIDE the descendant (indexes its SoA).
  final int childPartIndex;

  /// Coverage bit in the OWNER's plan.
  final int bit;

  /// Cutout alpha threshold; [noCutoutThreshold] for shape / mesh.
  final double threshold;

  /// The writer's cell-atlas texture hash, or null for a shape / mesh
  /// writer (geometry-as-mask, no texel to sample).
  final int? textureHash;

  /// Descendant-local → owner-local affine (the product of the instance slot
  /// matrices down to it, column-major 4×4) — the backends place the
  /// descendant's geometry with it.
  final Float64List slot;
}

/// The frame's mask plan: which parts write coverage, the box the coverage
/// bitmap spans, and the per-target scope resolution.
///
/// One plan serves the whole instance tree: the top-level player collects its
/// own writers and every visible descendant's ([bubbled]) into it, each placed
/// on the tree sequence by its [MaskWriter.open] / [MaskWriter.close] interval,
/// and every player of the tree tests its targets against it.
///
/// Pure data + geometry — no `Canvas`, no FFI — so it is unit-testable without
/// a GPU. The owning player rasterises [writers] into the bitmap and feeds
/// [bitsFor] to the target shader.
class MaskPlan {
  MaskPlan._({
    required this.writers,
    required this.bounds,
    this.bubbled = const <BubbledWriter>[],
  });

  /// Builds a plan from ready-made [writers] (`bit` equal to the list
  /// position) spanning [bounds].
  ///
  /// [MaskPlan.build] is the entry point for a lone animation; the player
  /// assembles the instance tree's plan through this.
  factory MaskPlan.fromWriters({
    required List<MaskWriter> writers,
    required ui.Rect bounds,
    List<BubbledWriter> bubbled = const <BubbledWriter>[],
  }) =>
      MaskPlan._(writers: writers, bounds: bounds, bubbled: bubbled);

  /// This frame's writers, bit `i` at position `i`. Includes the sentinels
  /// (`partIndex == kBubbledWriterPart`) standing for instance descendants'
  /// writers — present so [bitsFor] resolves them; their geometry is baked
  /// from [bubbled].
  final List<MaskWriter> writers;

  /// Instance descendants' writers, each parallel to a sentinel in [writers]
  /// by [BubbledWriter.bit]. Empty in the common case (no instance writes a
  /// mask this frame).
  final List<BubbledWriter> bubbled;

  /// Union of the writers' outlines in the coverage owner's **player-local**
  /// space. Each coverage tile is stretched over exactly this box, so the
  /// local→UV map is resolution-independent.
  final ui.Rect bounds;

  /// Tiles the coverage bitmap is split into: one while the writers fit a
  /// tile's bits, then 2 side by side, then 2×2 ([kMaxMaskWriters]).
  late final int tileCount = () {
    var top = 0;
    for (final w in writers) {
      if (w.bit >= top) top = w.bit + 1;
    }
    return top <= kMaskTileBits ? 1 : (top <= kMaskTileBits * 2 ? 2 : 4);
  }();

  /// Columns of the tile grid.
  int get tilesX => tileCount >= 2 ? 2 : 1;

  /// Rows of the tile grid.
  int get tilesY => tileCount >= 4 ? 2 : 1;

  /// Grow-only scratch for [collect]'s per-writer world outlines.
  ///
  /// Static because [collect] is, which is safe only because the outline never
  /// escapes the callback that folds it into a bbox — [collect] is
  /// synchronous, so no second caller can be inside it at the same time.
  static Float32List _outlineScratch = Float32List(8); // one sprite quad

  /// Collects one animation's writers for this frame by walking `draw_order`
  /// in rank order, handing each to [add] with its world outline (valid only
  /// for the duration of the call). Returns whether a writer was dropped for
  /// want of a bit.
  ///
  /// [flags] is indexed by part index ([MaskPartFlags.readAll]). [comp] is
  /// what the instance part calling this animation hands down
  /// ([MaskComposition.identity] at the top); it decides each writer's OP.
  /// [seq] places the animation's ranks on the tree sequence (null: the rank
  /// is the sequence, as for a lone animation) and [startSeq] is where the
  /// animation starts on it — its instance part's number, or -1 at the top.
  /// Bits are numbered from [firstBit], and collection stops at
  /// [kMaxMaskWriters]: the writers past it are ignored.
  ///
  /// A writer writes nothing this frame when its `mask` is 0 **or** it is
  /// hidden, and is then treated exactly as if it did not exist. Hide has to
  /// be read here: the Brain drops a hidden `PartTypeMask` and clipping writer
  /// from `draw_order`, but a hidden `draw_as_mask` Shape / Nines keeps its
  /// Mask batch — only its colour batch goes.
  static bool collect(
    DrawFrame frame,
    List<MaskPartFlags> flags, {
    required void Function(MaskWriter writer, Float32List outline) add,
    MaskComposition comp = MaskComposition.identity,
    List<int>? seq,
    int startSeq = -1,
    int firstBit = 0,
  }) {
    final drawOrder = frame.drawOrder;
    if (seq != null && seq.length != drawOrder.length) return false;
    var bit = firstBit;

    for (var rank = 0; rank < drawOrder.length; rank++) {
      final p = drawOrder[rank];
      final f = p < flags.length ? flags[p] : MaskPartFlags.none;
      if (!f.isWriter) continue;
      // A writer whose geometry the coverage pass cannot rasterise (Text /
      // Nines) is dropped rather than clipping its targets with a
      // wrong-shaped stand-in.
      if (!f.drawableWriter) continue;

      // mask == 0 opts the writer out entirely. This is a rule of its own
      // — `mask` also serves as the cutout threshold, it *doubles as* the
      // threshold — so it still applies to a shape, which has no cutout at
      // all. A part with no state this frame was not evaluated and writes
      // nothing either.
      final state = frame.partOf(p);
      if (state == null) continue;
      final mask = state.mask;
      if (mask <= 0.0 || state.$hide) continue;
      if (bit >= kMaxMaskWriters) return true; // no bit left for it

      // World outline: a shape's is its polygon, a mesh's is its (world-space)
      // vertices, everything else's is the sprite quad. A shape/mesh part has no
      // cell and so no `local_vertices`, which is why they cannot share the quad
      // path here.
      // Handed to [add] and dropped, so all three share one grow-only buffer
      // rather than allocating per writer per frame.
      final outline = f.shapeGeometry
          ? GeometryBuilder.shapeWorldOutlineOf(p, frame, _outlineScratch)
          : f.meshGeometry
              ? GeometryBuilder.meshWorldOutlineOf(p, frame, _outlineScratch)
              : GeometryBuilder.worldCornersOf(p, frame, _outlineScratch);
      if (outline == null) continue; // no geometry this frame — nothing to write
      // Too small to reuse: the helper allocated an exact-size buffer, so adopt
      // it and the next writer reuses that instead.
      if (outline.length > _outlineScratch.length) _outlineScratch = outline;

      final at = seq == null ? rank : seq[rank];
      final clipping = f.isClipping;
      add(
        MaskWriter(
          partIndex: p,
          drawRank: rank,
          bit: bit,
          opInvert: comp.opInvertFor(f),
          isClipping: clipping,
          // A shape has no texel to threshold, so its whole polygon is the mask
          // (the shape special case); a mesh could threshold in principle but
          // our coverage pass can't sample its per-vertex UV (no shader
          // varyings), so it too falls back to geometry-as-mask. -1 is
          // ForGodot's "never cut out" sentinel.
          threshold: f.shapeGeometry || f.meshGeometry
              ? noCutoutThreshold
              : ((255.0 - mask) / 255.0).clamp(0.0, 1.0),
          open: clipping ? at : startSeq,
          close: clipping ? kMaskSeqEnd : at,
        ),
        outline,
      );
      bit++;
    }
    return false;
  }

  /// Collects one lone animation's writers into a plan. Returns null when
  /// nothing writes coverage this frame — the caller then skips the whole mask
  /// machinery.
  ///
  /// The player builds the instance tree's plan itself (see [collect]); this
  /// is the single-animation case, and what the tests drive.
  static MaskPlan? build(DrawFrame frame, List<MaskPartFlags> flags,
      {MaskComposition comp = MaskComposition.identity}) {
    final writers = <MaskWriter>[];
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;

    collect(frame, flags, comp: comp, add: (w, outline) {
      writers.add(w);
      for (var c = 0; c * 2 + 1 < outline.length; c++) {
        final x = outline[c * 2], y = outline[c * 2 + 1];
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    });

    if (writers.isEmpty) return null;
    if (!(right > left) || !(bottom > top)) return null; // degenerate box

    return MaskPlan.fromWriters(
      writers: writers,
      bounds: ui.Rect.fromLTRB(left, top, right, bottom),
    );
  }

  /// Whether any writer reaches a target at tree sequence [seq] — the cheap
  /// early-out.
  bool inScope(int seq) {
    for (final w in writers) {
      if (w.reaches(seq)) return true;
    }
    return false;
  }

  /// The writer sets reaching the target at tree sequence [seq], tested on the
  /// [visibleInside] side, or null when no writer reaches it and it draws
  /// outside — it then keeps the plain batched path.
  ///
  /// A `visible_inside_mask` target always gets a test, even with no writer
  /// reaching it: it may only appear inside a mask, and the empty writer set
  /// then correctly hides it ([MaskBits.drawsNothing]).
  MaskBits? bitsAt(int seq, {required bool visibleInside}) {
    Int32List? increment;
    Int32List? invert;
    for (final w in writers) {
      if (!w.reaches(seq)) continue;
      final tile = w.bit ~/ kMaskTileBits;
      final bit = 1 << (w.bit % kMaskTileBits);
      if (w.opInvert) {
        (invert ??= Int32List(kMaskMaxTiles))[tile] |= bit;
      } else {
        (increment ??= Int32List(kMaskMaxTiles))[tile] |= bit;
      }
    }
    if (increment == null && invert == null && !visibleInside) return null;
    return MaskBits(
      increment: increment ?? const <int>[],
      invert: invert ?? const <int>[],
      visibleInside: visibleInside,
    );
  }

  /// The mask test for the target at tree sequence [seq] with [flags], or null
  /// when the part is not masked and keeps the plain batched path.
  ///
  /// A part is tested when it opts in ([MaskComposition.targets]) **and**
  /// either a writer reaches it or it draws inside ([bitsAt]). [comp] is what
  /// the instance part above this part's animation hands down;
  /// [MaskComposition.identity] at the top level leaves the part's own flags
  /// deciding.
  MaskBits? bitsFor(int seq, MaskPartFlags flags,
      {MaskComposition comp = MaskComposition.identity}) {
    if (!comp.targets(flags)) return null;
    return bitsAt(seq, visibleInside: comp.visibleInsideFor(flags));
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
