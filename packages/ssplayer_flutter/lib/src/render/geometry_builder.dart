import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/framedata.dart' as fbs;

import 'part_color.dart';

/// The Brain's shape SoA for one frame (§11), bundled for [DrawFrame].
///
/// Deliberately **not** CSR, unlike [MeshBuffers]: the Brain writes a fixed
/// [stride] of 12 vertices per part and reports how many of them are live in
/// [counts]. A non-shape part carries count 0 and zero-filled slots, so the
/// buffers are always `parts × 24` long whether or not the animation has shapes.
class ShapeBuffers {
  const ShapeBuffers({
    required this.vertices,
    required this.boxCoords,
    required this.counts,
  });

  /// Interleaved `[x,y,…]` **local-space** positions, `part * 24 + 2*v`.
  ///
  /// Local, not world — the opposite of [MeshBuffers] and the same as
  /// `local_vertices`: the caller applies the world matrix. Pivot and the Y-Down
  /// flip are already baked in; do not re-apply either.
  final Float32List vertices;

  /// Interleaved `[fx,fy,…]` normalised box coordinates, same stride: `(0,0)` is
  /// the LT corner of the shape's pre-pivot bounding box, `(1,1)` the RB — free
  /// of pivot and coordinate system. The Brain emits these purely so a Body can
  /// bilinearly interpolate the four PartColor corners onto vertices that are
  /// not corners (a star's points, a fan's center).
  final Float32List boxCoords;

  /// Live vertex count per part. The only valid slice — there is no offsets
  /// array, and `DrawBatch.vertex_count` is 0 for a Shape batch (the Brain fills
  /// it for Normal only).
  final Int32List counts;

  /// Floats per part in [vertices] / [boxCoords] (12 vertices × 2).
  static const int stride = 24;

  /// The largest polygon the Brain can emit — a Star (center + 10 points +
  /// closing vertex).
  static const int maxVertices = 12;

  /// True when this frame carries no shape data at all.
  bool get isEmpty => counts.isEmpty || vertices.isEmpty;

  /// Part [p]'s live vertex count, or 0 when it draws no shape this frame.
  ///
  /// Guards the buffers as well as the count: fewer than 3 vertices cannot form
  /// a triangle, and the Brain itself skips such parts (a zero-sized shape).
  int countOf(int p) {
    if (p < 0 || p >= counts.length) return 0;
    final n = counts[p];
    if (n < 3 || n > maxVertices) return 0;
    final end = p * stride + n * 2;
    if (end > vertices.length || end > boxCoords.length) return 0;
    return n;
  }
}

/// The Brain's mesh SoA for one frame (§8), bundled for [DrawFrame].
///
/// Every buffer is concatenated across all parts and sliced by a **CSR prefix
/// sum** (`length == parts + 1`): part `p` owns `[offsets[p], offsets[p + 1])`,
/// and a non-mesh part has an empty range. [x] / [y] are a separate-axis SoA and
/// are **already world-transformed** — unlike the Normal path's `local_vertices`
/// they must NOT be multiplied by the world matrix again. [uv] is interleaved
/// `[u,v,…]` in texture-pixel space and shares [vertexOffsets] (vertex `v` lives
/// at `2v`). [indices] are part-local and 0-based, so they need rebasing onto
/// the emitted vertex block.
class MeshBuffers {
  const MeshBuffers({
    required this.x,
    required this.y,
    required this.uv,
    required this.indices,
    required this.vertexOffsets,
    required this.indexOffsets,
  });

  final Float32List x;
  final Float32List y;
  final Float32List uv;
  final Int32List indices;
  final Uint32List vertexOffsets;
  final Uint32List indexOffsets;

  /// True when this frame carries no mesh data at all.
  bool get isEmpty => vertexOffsets.isEmpty || x.isEmpty;

  /// Part [p]'s `[start, end)` vertex range, or null when it owns no mesh
  /// vertices (a non-mesh part, or a buffer too short to trust).
  (int, int)? vertexRange(int p) {
    if (p < 0 || p + 1 >= vertexOffsets.length) return null;
    final start = vertexOffsets[p];
    final end = vertexOffsets[p + 1];
    if (end <= start) return null;
    if (end > x.length || end > y.length || end * 2 > uv.length) return null;
    return (start, end);
  }

  /// Part [p]'s `[start, end)` index range, or null when it owns none.
  ///
  /// A range whose length is not a multiple of 3 is rejected: the indices are
  /// triangles, so a partial one means the buffer is not what we think it is
  /// (the flagship makes the same defensive check).
  (int, int)? indexRange(int p) {
    if (p < 0 || p + 1 >= indexOffsets.length) return null;
    final start = indexOffsets[p];
    final end = indexOffsets[p + 1];
    if (end <= start || end > indices.length) return null;
    if ((end - start) % 3 != 0) return null;
    return (start, end);
  }
}

/// Per-frame draw inputs bundled for the geometry builders (design §7).
///
/// Mirrors the Godot flagship `DrawFrame` struct and the Web port's raw frame
/// views: it gathers the FlatBuffers `FrameData` root together with the Brain's
/// SoA buffers (all zero-copy typed views, valid only until the next `update` —
/// consume within the frame) so the per-kind builders take one argument instead
/// of a long parameter list.
///
/// SoA strides (design §7 / §0-A): world = 16 floats/part, `local`/`uv` = 10
/// floats/part (`lt,rt,lb,rb,center`). Cell meta (parts × 6) and the mesh/shape
/// SoA are added here as their kinds are ported (Phase 2).
///
/// [partByIndex] maps a part index (as found in [drawOrder]) to its
/// [fbs.PartState], materialized once per frame because the `parts` vector is
/// not guaranteed part-index ordered. It is a **dense list indexed by part
/// index** (part indices are 0-based and contiguous — the same indexing
/// `MaskPartFlags.readAll` relies on), not a `Map`: an array write + O(1) index
/// read with no per-key hashing, and a single contiguous allocation per frame.
/// Look parts up through [partOf], which bounds-checks (a `drawOrder` entry can
/// name a part absent from this frame's `parts` vector); a slot is null for any
/// index not present. This is the seam where the §7D raw-`ByteData` fast path —
/// reading `PartState` / `parts_color` by byte offset instead of via the
/// FlatBuffers accessors — will slot in when it matters.
class DrawFrame {
  DrawFrame({
    required this.frameData,
    required this.drawOrder,
    required this.partByIndex,
    required this.world,
    required this.local,
    required this.uv,
    this.mesh,
    this.shape,
    this.alphaScale = 1.0,
  });

  /// Bundles the frame's FlatBuffers root with its SoA views. Returns null when
  /// the frame carries no drawable structure (`draw_order` / `parts` absent).
  ///
  /// [mesh] is only needed by animations that actually have a Mesh batch; the
  /// caller fetches it lazily and leaves it null otherwise.
  static DrawFrame? build({
    required fbs.FrameData frameData,
    required Float32List world,
    required Float32List local,
    required Float32List uv,
    MeshBuffers? mesh,
    ShapeBuffers? shape,
    double alphaScale = 1.0,
  }) {
    final drawOrder = frameData.drawOrder;
    final parts = frameData.parts;
    if (drawOrder == null || parts == null) return null;
    // Dense list keyed by part index — no hashing, one contiguous allocation.
    // Sized to the largest index present (parts are 0-based/contiguous, but the
    // vector may be a subset and is not index-ordered, so scan for the max).
    var maxIndex = -1;
    for (final p in parts) {
      if (p.partIndex > maxIndex) maxIndex = p.partIndex;
    }
    final partByIndex = List<fbs.PartState?>.filled(maxIndex + 1, null);
    for (final p in parts) {
      if (p.partIndex >= 0) partByIndex[p.partIndex] = p;
    }
    return DrawFrame(
      frameData: frameData,
      drawOrder: drawOrder,
      partByIndex: partByIndex,
      world: world,
      local: local,
      uv: uv,
      mesh: mesh,
      shape: shape,
      alphaScale: alphaScale,
    );
  }

  final fbs.FrameData frameData;
  final List<int> drawOrder;

  /// Part states keyed by part index (dense; see the class doc). Read it through
  /// [partOf] rather than indexing directly — an index out of range (a part in
  /// `drawOrder` but absent from this frame's `parts`) must resolve to null, not
  /// throw.
  final List<fbs.PartState?> partByIndex;
  final Float32List world; // parts × 16
  final Float32List local; // parts × 10 (lt,rt,lb,rb,center)
  final Float32List uv; // parts × 10 (texture-pixel space)

  /// The frame's mesh SoA (§8), or null when the animation has no Mesh batch.
  final MeshBuffers? mesh;

  /// The frame's shape SoA (§11), or null when the animation has no Shape part.
  final ShapeBuffers? shape;

  /// An extra opacity multiplier applied on top of every part's own alpha.
  ///
  /// 1.0 for a root player. For an instance child (§8) it carries the product of
  /// the instance parts' alphas down the chain — that modulation lives in the
  /// *parent's* FrameData, so the Brain cannot fold it in the way it folds the
  /// hierarchical alpha within one pack.
  final double alphaScale;

  /// Floats per part in each SoA buffer.
  static const int worldStride = 16;
  static const int vertexStride = 10; // local vertices and UVs share this

  /// The [fbs.PartState] for [partIndex], or null when that index is not present
  /// in this frame's `parts` vector (bounds-checked — a `drawOrder` entry may
  /// name a part with no state this frame).
  fbs.PartState? partOf(int partIndex) =>
      (partIndex >= 0 && partIndex < partByIndex.length)
          ? partByIndex[partIndex]
          : null;

  List<fbs.PartAttributePartColor>? _partsColor;
  bool _partsColorFetched = false;

  /// The frame's `parts_color` vector, fetched once and cached (incl. a null
  /// result). `frameData.partsColor` builds a fresh lazy list wrapper — and a
  /// full-length backing cache on first index — every call, so reading it
  /// through here instead of re-fetching per part ([PartColor.read]) shares one
  /// wrapper across the whole frame. Pass the result to [PartColor.read].
  List<fbs.PartAttributePartColor>? get partsColor {
    if (!_partsColorFetched) {
      _partsColor = frameData.partsColor;
      _partsColorFetched = true;
    }
    return _partsColor;
  }

  /// The hierarchical alpha for part [partIndex], clamped to 0..1 (1 if the part
  /// is not present in the `parts` vector), times this frame's [alphaScale].
  ///
  /// The Brain has already resolved the parent chain *within* this pack, so this
  /// never walks it. Note the PartColor path does NOT go through here: there the
  /// hierarchical alpha is pre-folded into the corner alphas (§1-3) and
  /// re-multiplying it would double-apply.
  double alphaOf(int partIndex) =>
      (partOf(partIndex)?.alpha ?? 1.0).clamp(0.0, 1.0) * alphaScale;
}

/// A baked, ready-to-draw vertex block — the inspectable form of what
/// [GeometryBuilder.buildMeshParts] hands to `Canvas.drawVertices`.
///
/// [positions] and [texCoords] are interleaved `[x,y,…]` (texCoords in
/// texture-pixel space), [colors] is one ARGB per vertex, and [indices] are
/// already rebased onto this block.
class MeshGeometry {
  const MeshGeometry({
    required this.positions,
    required this.texCoords,
    required this.colors,
    required this.indices,
  });

  final Float32List positions;

  /// Null for a kind that samples no texture — a Shape (§11) is coloured purely
  /// by [colors], so there is nothing to map. `Vertices.raw` requires this to be
  /// either absent or exactly as long as [positions].
  final Float32List? texCoords;
  final Int32List colors;
  final Uint16List indices;

  /// Wraps this block for `Canvas.drawVertices`.
  ui.Vertices toVertices() => ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: texCoords,
        colors: colors,
        indices: indices,
      );
}

/// Per-part quad + affine map for the PartColor shader path (parts_color §1).
///
/// The four world-transformed corners drive a fill path; `origin` + `inv` map a
/// fragment position back to quad-local `(s,t)` inside `shaders/partcolor.frag`
/// (`s = inv[0]·dx + inv[1]·dy`, `t = inv[2]·dx + inv[3]·dy`, `d = frag - origin`),
/// and `uvA`/`uvB` carry the corner UVs (texture pixels) the shader bilinearly
/// samples. Built by [GeometryBuilder.buildPartColorQuad].
class PartColorQuad {
  const PartColorQuad({
    required this.corners,
    required this.originX,
    required this.originY,
    required this.inv,
    required this.uvA,
    required this.uvB,
  });

  /// World corners, 8 floats: `ltx,lty, rtx,rty, lbx,lby, rbx,rby`.
  final Float32List corners;

  /// LT world corner — the affine's frag-space origin (shader `uOrigin`).
  final double originX;
  final double originY;

  /// 2×2 inverse affine `[m00,m01,m10,m11]` mapping `frag - origin` → `(s,t)`.
  final Float32List inv;

  /// `(LT.u,LT.v, RT.u,RT.v)` and `(LB.u,LB.v, RB.u,RB.v)` in texture pixels.
  final Float32List uvA;
  final Float32List uvB;
}

/// Bakes the Brain's SoA buffers into `ui.Vertices` for `Canvas.drawVertices`
/// (design §7C).
///
/// Pure geometry construction — no `Canvas`, no FFI — so it is unit-testable in
/// isolation and reusable headless / from Flame / flutter_gpu, matching the
/// sibling ports' `GeometryBuilder` (Web) / `SpriteStudioGeometryBuilder`
/// (Unity). The owning [SpriteStudioInternalPlayer] gathers the [DrawFrame],
/// dispatches on `DrawBatch.kind`, and draws the returned vertices; this class
/// only bakes them.
///
/// Phase 1 implements [buildNormalBatch] (the Normal quad path). The Shape /
/// Mesh / effect-quad builders and the 5-vertex center fan + PartColor CUSTOM0
/// attributes (needed when `update_flag & (AttributeVertex | AttributePartColor)`)
/// are Phase 2.
///
/// **Buffer reuse / aliasing contract.** The bake methods write into grow-only
/// scratch buffers held on this instance rather than allocating fresh arrays per
/// batch, so a steady-state frame does no per-batch vertex allocation. Two
/// consequences the callers already honour:
///  * the [MeshGeometry] returned by [buildMeshGeometry] / [buildShapeParts] /
///    [buildEffectCommand] **aliases the scratch** — consume it (`toVertices()`,
///    or read its arrays) BEFORE the next bake call on the same builder, which
///    overwrites the scratch. Every call site does (draw / build a Path
///    immediately); a `ui.Vertices` copies at construction so it is unaffected;
///  * each [SpriteStudioInternalPlayer] owns its own builder, so an instance
///    child's recursive paint never races the parent's scratch.
class GeometryBuilder {
  /// Two triangles per quad: `lt,rt,lb,rb` → `{lt,rt,lb, rt,rb,lb}`.
  static const List<int> _quad = [0, 1, 2, 1, 3, 2];

  // Grow-only scratch for the per-batch vertex arrays (see the class doc's
  // reuse/aliasing contract). Separate cells because a single bake needs
  // positions, UVs, colours and indices live at once; sized to the largest
  // batch seen so far and never shrunk.
  Float32List _posScratch = Float32List(0);
  Float32List _uvScratch = Float32List(0);
  Int32List _colScratch = Int32List(0);
  Uint16List _idxScratch = Uint16List(0);

  Float32List _pos(int n) =>
      _posScratch.length >= n ? _posScratch : (_posScratch = Float32List(n));
  Float32List _uvs(int n) =>
      _uvScratch.length >= n ? _uvScratch : (_uvScratch = Float32List(n));
  Int32List _cols(int n) =>
      _colScratch.length >= n ? _colScratch : (_colScratch = Int32List(n));
  Uint16List _idx(int n) =>
      _idxScratch.length >= n ? _idxScratch : (_idxScratch = Uint16List(n));

  /// Bakes the given [parts] (part indices, already in draw order) into a single
  /// indexed [ui.Vertices]: for each part transforms its 4 local corners
  /// (lt,rt,lb,rb) by the world matrix (`x'=m0·x+m4·y+m12`, `y'=m1·x+m5·y+m13`),
  /// copies the texture-pixel UVs as-is, sets each vertex color to white × part
  /// alpha, and appends the quad indices. Returns null when nothing was emitted.
  ///
  /// The caller (internal player) passes a *run* of consecutive plain (non-
  /// PartColor) parts so PartColored parts can be peeled onto their own shader
  /// draw without disturbing z-order; an all-plain batch is one run == the whole
  /// batch (identical to the old single-bake path).
  ui.Vertices? buildNormalParts(List<int> parts, DrawFrame frame) {
    final count = parts.length;
    if (count == 0) return null;

    final world = frame.world;
    final local = frame.local;
    final uv = frame.uv;

    final positions = _pos(count * 4 * 2); // 4 corners × (x,y)
    final texCoords = _uvs(count * 4 * 2);
    final colors = _cols(count * 4);
    final indices = _idx(count * 6); // 2 triangles per quad

    var vBase = 0; // vertices emitted so far
    var fPos = 0; // float cursor into positions/texCoords
    var cPos = 0; // color cursor
    var iPos = 0; // index cursor

    for (var k = 0; k < count; k++) {
      final p = parts[k];

      final m = p * DrawFrame.worldStride;
      final v = p * DrawFrame.vertexStride; // local vertices & UVs share stride
      // Only the 4 corners (8 floats) are read for the Normal quad path.
      if (m + 16 > world.length || v + 8 > local.length || v + 8 > uv.length) {
        continue;
      }

      final alpha = frame.alphaOf(p);
      final color = ((alpha * 255).round() & 0xFF) << 24 | 0x00FFFFFF;

      final m0 = world[m], m1 = world[m + 1];
      final m4 = world[m + 4], m5 = world[m + 5];
      final m12 = world[m + 12], m13 = world[m + 13];

      // Corners: lt=(0,1) rt=(2,3) lb=(4,5) rb=(6,7).
      for (var c = 0; c < 4; c++) {
        final lx = local[v + c * 2];
        final ly = local[v + c * 2 + 1];
        positions[fPos] = m0 * lx + m4 * ly + m12;
        positions[fPos + 1] = m1 * lx + m5 * ly + m13;
        texCoords[fPos] = uv[v + c * 2]; // texture-pixel UV, used as-is
        texCoords[fPos + 1] = uv[v + c * 2 + 1];
        fPos += 2;
        colors[cPos++] = color;
      }
      for (final q in _quad) {
        indices[iPos++] = vBase + q;
      }
      vBase += 4;
    }

    if (vBase == 0) return null;
    // Zero-copy views over the head of each scratch buffer, NOT `sublist` (which
    // allocates a full copy): `ui.Vertices.raw` copies its inputs into engine
    // memory at construction, so a view is safe and skips one array copy per
    // buffer. A view spans `[0, n)` — the untouched tail (when a part was
    // skipped, so `fPos < length`) is never referenced.
    return ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.view(positions.buffer, positions.offsetInBytes, fPos),
      textureCoordinates:
          Float32List.view(texCoords.buffer, texCoords.offsetInBytes, fPos),
      colors: Int32List.view(colors.buffer, colors.offsetInBytes, cPos),
      indices: Uint16List.view(indices.buffer, indices.offsetInBytes, iPos),
    );
  }

  /// Bakes the given mesh [parts] into a single indexed [ui.Vertices] (§8).
  ///
  /// Thin wrapper over [buildMeshGeometry] — see it for the contract. Returns
  /// null when nothing was emitted.
  ui.Vertices? buildMeshParts(List<int> parts, DrawFrame frame) =>
      buildMeshGeometry(parts, frame)?.toVertices();

  /// Bakes the given mesh [parts] (part indices, already in draw order) into
  /// raw vertex arrays (§8).
  ///
  /// Much simpler than the Normal path: the Brain hands over **world-space**
  /// vertices, so there is no matrix to apply — the SoA X/Y are interleaved into
  /// positions, the texture-pixel UVs are copied as-is (Flutter's identity
  /// `ImageShader` samples in image pixels, so they need no normalising), each
  /// vertex takes white × the part's hierarchical alpha, and the part-local
  /// indices are rebased onto the emitted vertex block — a Mesh `DrawBatch` is
  /// batchable and may carry several parts, so the rebase is load-bearing.
  ///
  /// Returns null when nothing was emitted. Split out from [buildMeshParts] so
  /// the bake is inspectable (a `ui.Vertices` is opaque) — the "already
  /// world-space" invariant is the one thing worth pinning down in a test.
  MeshGeometry? buildMeshGeometry(List<int> parts, DrawFrame frame) {
    final mesh = frame.mesh;
    if (mesh == null || mesh.isEmpty || parts.isEmpty) return null;

    // Size the buffers exactly: walk the CSR ranges once up front.
    var vTotal = 0;
    var iTotal = 0;
    for (final p in parts) {
      final vr = mesh.vertexRange(p);
      final ir = mesh.indexRange(p);
      if (vr == null || ir == null) continue;
      vTotal += vr.$2 - vr.$1;
      iTotal += ir.$2 - ir.$1;
    }
    if (vTotal == 0 || iTotal == 0) return null;
    // ui.Vertices indices are 16-bit; a part tree this big is not a thing, but
    // silently wrapping would corrupt the geometry.
    if (vTotal > 0xFFFF) return null;

    final positions = _pos(vTotal * 2);
    final texCoords = _uvs(vTotal * 2);
    final colors = _cols(vTotal);
    final indices = _idx(iTotal);

    var vBase = 0; // vertices emitted so far (the index rebase)
    var fPos = 0;
    var cPos = 0;
    var iPos = 0;

    for (final p in parts) {
      final vr = mesh.vertexRange(p);
      final ir = mesh.indexRange(p);
      if (vr == null || ir == null) continue;

      final alpha = frame.alphaOf(p);
      final color = ((alpha * 255).round() & 0xFF) << 24 | 0x00FFFFFF;

      for (var v = vr.$1; v < vr.$2; v++) {
        positions[fPos] = mesh.x[v]; // already world-space
        positions[fPos + 1] = mesh.y[v];
        texCoords[fPos] = mesh.uv[v * 2]; // texture-pixel UV, used as-is
        texCoords[fPos + 1] = mesh.uv[v * 2 + 1];
        fPos += 2;
        colors[cPos++] = color;
      }
      final vCount = vr.$2 - vr.$1;
      for (var i = ir.$1; i < ir.$2; i++) {
        final local = mesh.indices[i];
        if (local < 0 || local >= vCount) continue; // corrupt range — drop it
        indices[iPos++] = vBase + local;
      }
      vBase += vCount;
    }

    if (vBase == 0 || iPos == 0) return null;
    // Zero-copy views (see `buildNormalParts`): the buffers are already
    // exact-sized here, so the view spans the whole buffer in the common case
    // and only trims when a corrupt CSR range was dropped mid-loop.
    return MeshGeometry(
      positions: Float32List.view(positions.buffer, positions.offsetInBytes, fPos),
      texCoords: Float32List.view(texCoords.buffer, texCoords.offsetInBytes, fPos),
      colors: Int32List.view(colors.buffer, colors.offsetInBytes, cPos),
      indices: Uint16List.view(indices.buffer, indices.offsetInBytes, iPos),
    );
  }

  /// Bakes one `EffectDrawCommand`'s particle quads into a vertex block (§8) —
  /// the single-command case of [buildEffectGroup]. Returns null when the
  /// command is empty or the plan's buffers are short.
  MeshGeometry? buildEffectCommand(
    efbs.EffectDrawPlan plan,
    efbs.EffectDrawCommand cmd,
    int part,
    DrawFrame frame, {
    required double texWidth,
    required double texHeight,
  }) =>
      buildEffectGroup(plan, <efbs.EffectDrawCommand>[cmd], part, frame,
          texWidth: texWidth, texHeight: texHeight);

  /// Bakes a run of adjacent `EffectDrawCommand`s that share cellmap + blend
  /// into ONE vertex block (§8), so the caller draws the whole group with a
  /// single `drawVertices` instead of one per command (the SDK's suggested
  /// effect optimisation). [cmds] must be same-cellmap / same-blend and in draw
  /// order; [SpriteStudioInternalPlayer] groups them, capping each group so its
  /// vertices stay within the 16-bit index limit.
  ///
  /// Each command slices the plan's flat buffers at its own `particle_offset`
  /// (in quads) with each buffer's stride; a command's indices are 0-based
  /// *within that command*, so the group rebases them onto the running vertex
  /// base (a single command rebases by 0 — the old per-command behaviour). Two
  /// effect-only conventions the bake must honour:
  /// * the plan's verts are in the **effect's own simulation space** — the slot
  ///   API is never handed a matrix — so the effect part's world matrix is
  ///   applied here (the opposite of the mesh path, which arrives world-ready);
  /// * the plan's UVs are **normalised 0..1** (the runtime divides by the
  ///   cellmap's `size_original`), whereas `local_uvs` / `mesh_uvs` are texture
  ///   pixels — so they are scaled up by [texWidth]/[texHeight] to match what
  ///   Flutter's identity `ImageShader` samples in.
  ///
  /// A command whose buffers are short or whose indices are out of range is
  /// skipped whole — validated before any of its data is written, so a corrupt
  /// command never leaves a partial quad behind. Returns null when nothing was
  /// emitted.
  MeshGeometry? buildEffectGroup(
    efbs.EffectDrawPlan plan,
    List<efbs.EffectDrawCommand> cmds,
    int part,
    DrawFrame frame, {
    required double texWidth,
    required double texHeight,
  }) {
    if (cmds.isEmpty) return null;
    final verts = plan.verts;
    final uvs = plan.uvs;
    final planColors = plan.colors;
    final planIndices = plan.indices;
    if (verts == null || uvs == null || planColors == null ||
        planIndices == null) {
      return null;
    }
    final stride = plan.vertStride == 3 ? 3 : 2;

    // Upper bound over the group; the views trim to what is actually written if
    // a command is skipped as corrupt.
    var totalQuads = 0;
    for (final cmd in cmds) {
      totalQuads += cmd.quadCount;
    }
    if (totalQuads == 0) return null;
    final totalVerts = totalQuads * 4;
    if (totalVerts > 0xFFFF) return null; // ui.Vertices indices are 16-bit

    final m = part * DrawFrame.worldStride;
    if (m + 16 > frame.world.length) return null;
    final world = frame.world;
    final m0 = world[m], m1 = world[m + 1];
    final m4 = world[m + 4], m5 = world[m + 5];
    final m12 = world[m + 12], m13 = world[m + 13];

    // The particle colours already carry the emitter's own alpha; fold the
    // part's hierarchical alpha in on top (the slot never sees it).
    final partAlpha = frame.alphaOf(part);

    final positions = _pos(totalVerts * 2);
    final texCoords = _uvs(totalVerts * 2);
    final colors = _cols(totalVerts);
    final indices = _idx(totalQuads * 6);

    var vBase = 0; // running vertex base — the per-command index rebase
    var fPos = 0, cPos = 0, iPos = 0;
    for (final cmd in cmds) {
      final quads = cmd.quadCount;
      if (quads == 0) continue;
      final vertexCount = quads * 4;
      final vOff = cmd.particleOffset * 4 * stride;
      final uOff = cmd.particleOffset * 4 * 2;
      final cOff = cmd.particleOffset * 4 * 4;
      final iOff = cmd.particleOffset * 6;
      final indexCount = quads * 6;
      if (vOff + vertexCount * stride > verts.length ||
          uOff + vertexCount * 2 > uvs.length ||
          cOff + vertexCount * 4 > planColors.length ||
          iOff + indexCount > planIndices.length) {
        continue; // short buffers — skip this command, keep the rest
      }
      // Validate the whole index range BEFORE writing any of this command's
      // data, so a corrupt command leaves no half-written quad behind.
      var valid = true;
      for (var k = 0; k < indexCount; k++) {
        final v = planIndices[iOff + k];
        if (v < 0 || v >= vertexCount) {
          valid = false;
          break;
        }
      }
      if (!valid) continue;

      for (var i = 0; i < vertexCount; i++) {
        final x = verts[vOff + i * stride];
        final y = verts[vOff + i * stride + 1];
        positions[fPos] = m0 * x + m4 * y + m12;
        positions[fPos + 1] = m1 * x + m5 * y + m13;

        texCoords[fPos] = uvs[uOff + i * 2] * texWidth;
        texCoords[fPos + 1] = uvs[uOff + i * 2 + 1] * texHeight;
        fPos += 2;

        final c = cOff + i * 4;
        final a = (planColors[c + 3] * partAlpha * 255).round().clamp(0, 255);
        final r = (planColors[c] * 255).round().clamp(0, 255);
        final g = (planColors[c + 1] * 255).round().clamp(0, 255);
        final b = (planColors[c + 2] * 255).round().clamp(0, 255);
        colors[cPos++] = (a << 24) | (r << 16) | (g << 8) | b;
      }
      for (var k = 0; k < indexCount; k++) {
        indices[iPos++] = vBase + planIndices[iOff + k];
      }
      vBase += vertexCount;
    }

    if (fPos == 0 || iPos == 0) return null;
    // Views trim the shared scratch back to what the group actually wrote (see
    // the class doc's reuse contract).
    return MeshGeometry(
      positions: Float32List.view(positions.buffer, positions.offsetInBytes, fPos),
      texCoords: Float32List.view(texCoords.buffer, texCoords.offsetInBytes, fPos),
      colors: Int32List.view(colors.buffer, colors.offsetInBytes, cPos),
      indices: Uint16List.view(indices.buffer, indices.offsetInBytes, iPos),
    );
  }

  /// The four world-transformed corners of part [part], 8 floats
  /// (`ltx,lty, rtx,rty, lbx,lby, rbx,rby`), or null when the part is outside
  /// the SoA (no geometry this frame).
  ///
  /// Shared by the PartColor quad and the mask coverage pass, which both need
  /// the same `x' = m0·x + m4·y + m12`, `y' = m1·x + m5·y + m13` transform.
  static Float32List? worldCornersOf(int part, DrawFrame frame) {
    final world = frame.world;
    final local = frame.local;
    final m = part * DrawFrame.worldStride;
    final v = part * DrawFrame.vertexStride;
    if (m + 16 > world.length || v + 8 > local.length) return null;

    final m0 = world[m], m1 = world[m + 1];
    final m4 = world[m + 4], m5 = world[m + 5];
    final m12 = world[m + 12], m13 = world[m + 13];

    // World corners: lt=(0,1) rt=(2,3) lb=(4,5) rb=(6,7).
    final corners = Float32List(8);
    for (var c = 0; c < 4; c++) {
      final lx = local[v + c * 2];
      final ly = local[v + c * 2 + 1];
      corners[c * 2] = m0 * lx + m4 * ly + m12;
      corners[c * 2 + 1] = m1 * lx + m5 * ly + m13;
    }
    return corners;
  }

  /// Bakes Shape parts (§11) into one indexed vertex block, or null when none of
  /// them has geometry this frame.
  ///
  /// A Shape is the Normal path's geometry rules with the Mesh path's batching:
  /// vertices are **local** and get the world matrix (Mesh's are already world),
  /// and several parts concatenate into one draw, so each part's fan indices are
  /// rebased onto its vertex base.
  ///
  /// The colour is the whole story here, and it is the one place PartColor does
  /// **not** go through the shader (§1-2-3 「シェイプは合成式をバイパス」):
  ///
  ///  * With PartColor, the vertex colour is `pc.rgba` *directly* — no blend
  ///    formula, forced Mix, rate pinned to 1 — bilinearly weighted per vertex by
  ///    the Brain's box coords. The alpha already carries the hierarchical alpha
  ///    (the converter additionally forces `a = 255` for a Mix shape so the
  ///    product lands exactly on the part's alpha), so it must NOT be
  ///    re-multiplied — only [DrawFrame.alphaScale] is still owed.
  ///  * Without PartColor, it is white at the part's alpha.
  ///
  /// That collapses the whole kind onto plain per-vertex colours, which is why a
  /// Shape needs no texture and no fragment program: the caller draws it with a
  /// white [ui.Paint] under `BlendMode.modulate`.
  MeshGeometry? buildShapeParts(List<int> parts, DrawFrame frame) {
    final shape = frame.shape;
    if (shape == null || parts.isEmpty) return null;

    var vTotal = 0;
    var iTotal = 0;
    for (final p in parts) {
      final n = shape.countOf(p);
      if (n == 0) continue;
      vTotal += n;
      iTotal += (n - 2) * 3; // center-first fan
    }
    if (vTotal == 0 || iTotal == 0) return null;

    final positions = _pos(vTotal * 2);
    final colors = _cols(vTotal);
    final indices = _idx(iTotal);
    var vPos = 0, cPos = 0, iPos = 0, base = 0;
    // Fetch the frame's parts_color vector once (see [DrawFrame.partsColor]).
    final partsColor = frame.partsColor;

    for (final p in parts) {
      final n = shape.countOf(p);
      if (n == 0) continue;

      final m = p * DrawFrame.worldStride;
      if (m + 16 > frame.world.length) continue;
      final m0 = frame.world[m], m1 = frame.world[m + 1];
      final m4 = frame.world[m + 4], m5 = frame.world[m + 5];
      final m12 = frame.world[m + 12], m13 = frame.world[m + 13];

      final state = frame.partOf(p);
      final pc = state == null ? null : PartColor.read(partsColor, state);
      // No PartColor → white at the part's alpha (§1-2-4's default), which also
      // picks up the instance chain's scale. With PartColor the corner alphas
      // already hold the hierarchical alpha, so only the chain scale is applied.
      final plain = pc == null ? _argb(1.0, 1.0, 1.0, frame.alphaOf(p)) : 0;
      final tinted = pc?.scaleAlpha(frame.alphaScale);

      final o = p * ShapeBuffers.stride;
      for (var v = 0; v < n; v++) {
        final lx = shape.vertices[o + 2 * v];
        final ly = shape.vertices[o + 2 * v + 1];
        positions[vPos++] = m0 * lx + m4 * ly + m12;
        positions[vPos++] = m1 * lx + m5 * ly + m13;

        if (tinted == null) {
          colors[cPos++] = plain;
        } else {
          // Bilinear over the box coords — the whole reason the Brain emits
          // them. A fan's center lands at (0.5, 0.5) and gets the average, which
          // is what makes a per-corner-coloured shape gradient smoothly instead
          // of creasing along a diagonal.
          final fx = shape.boxCoords[o + 2 * v];
          final fy = shape.boxCoords[o + 2 * v + 1];
          final wLT = (1.0 - fx) * (1.0 - fy);
          final wRT = fx * (1.0 - fy);
          final wLB = (1.0 - fx) * fy;
          final wRB = fx * fy;
          colors[cPos++] = _argb(
            tinted.lt.r * wLT + tinted.rt.r * wRT + tinted.lb.r * wLB + tinted.rb.r * wRB,
            tinted.lt.g * wLT + tinted.rt.g * wRT + tinted.lb.g * wLB + tinted.rb.g * wRB,
            tinted.lt.b * wLT + tinted.rt.b * wRT + tinted.lb.b * wLB + tinted.rb.b * wRB,
            tinted.lt.a * wLT + tinted.rt.a * wRT + tinted.lb.a * wLB + tinted.rb.a * wRB,
          );
        }
      }

      // Center-first fan: [center, perimeter…, closing]. Rebased onto this
      // part's vertex base so several parts share one draw.
      for (var t = 0; t < n - 2; t++) {
        indices[iPos++] = base;
        indices[iPos++] = base + t + 1;
        indices[iPos++] = base + t + 2;
      }
      base += n;
    }
    if (vPos == 0 || iPos == 0) return null;

    // Zero-copy views (see `buildNormalParts`).
    return MeshGeometry(
      positions: Float32List.view(positions.buffer, positions.offsetInBytes, vPos),
      // A Shape samples nothing; the caller pairs this with a white Paint.
      texCoords: null,
      colors: Int32List.view(colors.buffer, colors.offsetInBytes, cPos),
      indices: Uint16List.view(indices.buffer, indices.offsetInBytes, iPos),
    );
  }

  /// Part [part]'s shape polygon in world space, interleaved `[x,y,…]`, or null
  /// when it draws no shape this frame.
  ///
  /// Every live vertex including the fan's center — callers use it for bounds,
  /// where the center is harmlessly interior.
  static Float32List? shapeWorldOutlineOf(int part, DrawFrame frame) {
    final shape = frame.shape;
    if (shape == null) return null;
    final n = shape.countOf(part);
    if (n == 0) return null;
    final m = part * DrawFrame.worldStride;
    if (m + 16 > frame.world.length) return null;

    final m0 = frame.world[m], m1 = frame.world[m + 1];
    final m4 = frame.world[m + 4], m5 = frame.world[m + 5];
    final m12 = frame.world[m + 12], m13 = frame.world[m + 13];
    final o = part * ShapeBuffers.stride;

    final out = Float32List(n * 2);
    for (var v = 0; v < n; v++) {
      final lx = shape.vertices[o + 2 * v];
      final ly = shape.vertices[o + 2 * v + 1];
      out[v * 2] = m0 * lx + m4 * ly + m12;
      out[v * 2 + 1] = m1 * lx + m5 * ly + m13;
    }
    return out;
  }

  /// Part [part]'s mesh vertices in world space, interleaved `[x,y,…]`, or null
  /// when it has no *drawable* mesh geometry this frame. Mesh SoA is already
  /// world-space (§8) so this is a straight copy — used for the coverage bbox of
  /// a mesh clipping writer (§9). Requires a triangle-bearing index range too, so
  /// the mask planner reserves a coverage bit only for a writer [_renderCoverage]
  /// can actually rasterise (else a vertex-only part would fold phantom verts
  /// into the bbox yet write nothing — an inert bit).
  static Float32List? meshWorldOutlineOf(int part, DrawFrame frame) {
    final mesh = frame.mesh;
    if (mesh == null) return null;
    final vr = mesh.vertexRange(part);
    final ir = mesh.indexRange(part);
    if (vr == null || ir == null) return null;
    final n = vr.$2 - vr.$1;
    if (n <= 0 || ir.$2 - ir.$1 < 3) return null; // no vertices / no triangle
    final out = Float32List(n * 2);
    for (var v = 0; v < n; v++) {
      out[v * 2] = mesh.x[vr.$1 + v];
      out[v * 2 + 1] = mesh.y[vr.$1 + v];
    }
    return out;
  }

  static int _argb(double r, double g, double b, double a) {
    int ch(double v) => (v.clamp(0.0, 1.0) * 255.0).round();
    return (ch(a) << 24) | (ch(r) << 16) | (ch(g) << 8) | ch(b);
  }

  /// Part [part]'s world matrix as a `Canvas.transform` matrix, or null when the
  /// part is outside the SoA.
  ///
  /// Used by Instance (§8) to place a child animation, which — unlike every
  /// other kind — is transformed by the *canvas* rather than by baking vertices.
  ///
  /// Only the 2D affine (`m0, m1, m4, m5, m12, m13`) is carried over, with an
  /// identity Z row, rather than copying the Brain's 4×4 wholesale. Both are
  /// column-major and the six values even land on the same indices, but the
  /// source matrix's Z/W rows are not part of the contract this Body reads
  /// anywhere else — [worldCornersOf] uses exactly these six — and letting a
  /// stray Z scale or perspective term through `Canvas.transform` would silently
  /// distort the whole child subtree.
  static Float64List? world2dOf(int part, DrawFrame frame) {
    final world = frame.world;
    final m = part * DrawFrame.worldStride;
    if (m + 16 > world.length) return null;
    return Float64List(16)
      ..[0] = world[m] // m0
      ..[1] = world[m + 1] // m1
      ..[4] = world[m + 4] // m4
      ..[5] = world[m + 5] // m5
      ..[10] = 1.0
      ..[12] = world[m + 12] // m12 (tx)
      ..[13] = world[m + 13] // m13 (ty)
      ..[15] = 1.0;
  }

  /// Builds the world quad + frag→`(s,t)` affine for part [part]'s PartColor
  /// shader draw (parts_color §1). Transforms the four local corners
  /// (`lt,rt,lb,rb`) by the world matrix, takes `du = rt-lt`, `dv = lb-lt`, and
  /// inverts `[du dv]` so the shader can recover quad-local coordinates from a
  /// fragment position.
  ///
  /// Returns null when the SoA is out of range or the quad is degenerate
  /// (`|det| ~ 0`, e.g. a zero-size part) — nothing visible to draw. Assumes a
  /// non-deformed (affine) quad, which holds for a Normal sprite; vertex-deform
  /// (`AttributeVertex`) breaks the affine assumption and is handled with the
  /// Mesh/deform path.
  PartColorQuad? buildPartColorQuad(int part, DrawFrame frame) {
    final uv = frame.uv;
    final v = part * DrawFrame.vertexStride;
    final corners = worldCornersOf(part, frame);
    if (corners == null || v + 8 > uv.length) return null;

    final ltx = corners[0], lty = corners[1];
    // du = rt - lt (s-axis), dv = lb - lt (t-axis).
    final dux = corners[2] - ltx, duy = corners[3] - lty;
    final dvx = corners[4] - ltx, dvy = corners[5] - lty;
    final det = dux * dvy - dvx * duy;
    if (det.abs() < 1e-6) return null; // degenerate quad — nothing to draw

    final invDet = 1.0 / det;
    // [s;t] = inv([du dv]) · (frag - lt).
    final inv = Float32List.fromList(<double>[
      dvy * invDet, // m00
      -dvx * invDet, // m01
      -duy * invDet, // m10
      dux * invDet, // m11
    ]);

    return PartColorQuad(
      corners: corners,
      originX: ltx,
      originY: lty,
      inv: inv,
      uvA: Float32List.fromList(
          <double>[uv[v], uv[v + 1], uv[v + 2], uv[v + 3]]),
      uvB: Float32List.fromList(
          <double>[uv[v + 4], uv[v + 5], uv[v + 6], uv[v + 7]]),
    );
  }
}
