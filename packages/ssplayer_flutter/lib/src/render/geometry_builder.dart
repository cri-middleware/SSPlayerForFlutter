import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flat_buffers/flat_buffers.dart' as fb;
import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;
import 'package:ssruntime_dart/framedata.dart' as fbs;

import 'effect.dart';
import 'part_color.dart';

/// The Brain's shape SoA for one frame, bundled for [DrawFrame].
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

/// The Brain's mesh SoA for one frame, bundled for [DrawFrame].
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
  /// (ForGodot makes the same defensive check).
  (int, int)? indexRange(int p) {
    if (p < 0 || p + 1 >= indexOffsets.length) return null;
    final start = indexOffsets[p];
    final end = indexOffsets[p + 1];
    if (end <= start || end > indices.length) return null;
    if ((end - start) % 3 != 0) return null;
    return (start, end);
  }
}

/// Per-frame draw inputs bundled for the geometry builders.
///
/// Mirrors ForGodot's `DrawFrame` struct and the Web port's raw frame
/// views: it gathers the FlatBuffers `FrameData` root together with the Brain's
/// SoA buffers (all zero-copy typed views, valid only until the next `update` —
/// consume within the frame) so the per-kind builders take one argument instead
/// of a long parameter list.
///
/// SoA strides: world = 16 floats/part, `local`/`uv` = 10
/// floats/part (`lt,rt,lb,rb,center`). Cell meta (parts × 6) and the mesh /
/// shape SoA travel alongside, one entry per part.
///
/// [partByIndex] maps a part index (as found in [drawOrder]) to its
/// [fbs.PartState], materialized once per frame because the `parts` vector is
/// not guaranteed part-index ordered. It is a **dense list indexed by part
/// index** (part indices are 0-based and contiguous — the same indexing
/// `MaskPartFlags.readAll` relies on), not a `Map`: an array write + O(1) index
/// read with no per-key hashing, and a single contiguous allocation per frame.
/// Look parts up through [partOf], which bounds-checks (a `drawOrder` entry can
/// name a part absent from this frame's `parts` vector); a slot is null for any
/// index not present.
///
/// Built from the frame's bytes ([build]'s `frameBytes`), it reads the part
/// states in place instead: a dense table of where each part's `PartState`
/// sits, [alphaOf] straight from it, [drawOrder] a view over the vector, and a
/// [fbs.PartState] made only when [partOf] or [partByIndex] asks for one.
class DrawFrame {
  // Upper bound on the dense [partByIndex] array (see [build]). ~1M slots is far
  // above any real pack's part count, so it never truncates valid content; it
  // only caps a corrupt/hostile part index that would otherwise OOM the process.
  static const int _maxDenseParts = 1 << 20;

  DrawFrame({
    required this.frameData,
    required this.drawOrder,
    required List<fbs.PartState?> partByIndex,
    required this.world,
    required this.local,
    required this.uv,
    this.mesh,
    this.shape,
    this.alphaScale = 1.0,
    int? partCount,
  })  : _partByIndex = partByIndex,
        partCount = partCount ?? partByIndex.length,
        _bytes = null,
        _data = null,
        _slots = null;

  DrawFrame._fromBytes({
    required this.frameData,
    required this.drawOrder,
    required Uint8List bytes,
    required ByteData data,
    required Int32List slots,
    required this.partCount,
    required this.world,
    required this.local,
    required this.uv,
    this.mesh,
    this.shape,
    this.alphaScale = 1.0,
  })  : _partByIndex = null,
        _bytes = bytes,
        _data = data,
        _slots = slots;

  /// Bundles the frame's FlatBuffers root with its SoA views. Returns null when
  /// the frame carries no drawable structure (`draw_order` / `parts` absent).
  ///
  /// [mesh] is only needed by animations that actually have a Mesh batch; the
  /// caller fetches it lazily and leaves it null otherwise.
  ///
  /// [partByIndexScratch] lets a caller that builds a frame every tick supply a
  /// grow-only backing array instead of paying a `List.filled` per frame (see
  /// [GeometryBuilder.buildFrame]). It is adopted only when it is large enough,
  /// and the frame it produces owns it until the next build — so the caller must
  /// re-read [partByIndex] afterwards rather than assume its array was kept.
  static DrawFrame? build({
    required fbs.FrameData frameData,
    required Float32List world,
    required Float32List local,
    required Float32List uv,
    MeshBuffers? mesh,
    ShapeBuffers? shape,
    double alphaScale = 1.0,
    List<fbs.PartState?>? partByIndexScratch,
    Uint8List? frameBytes,
    Int32List? slotScratch,
  }) {
    if (frameBytes != null && _bytesMatchAccessors != false) {
      final data = ByteData.sublistView(frameBytes);
      final partsAt = _vector(data, _partsSlot, _partStateSize);
      final partsLength = _vectorLength;
      final orderAt = _vector(data, _drawOrderSlot, 2);
      final orderLength = _vectorLength;
      if (partsAt == _absent || orderAt == _absent) return null;
      if (partsAt >= 0 &&
          orderAt >= 0 &&
          (frameBytes.offsetInBytes + orderAt).isEven) {
        var maxIndex = -1;
        for (var i = 0; i < partsLength; i++) {
          final index = data.getInt16(
              partsAt + i * _partStateSize + _partIndexAt, Endian.little);
          if (index > maxIndex) maxIndex = index;
        }
        final size = (maxIndex + 1).clamp(0, _maxDenseParts);
        final slots = slotScratch != null && slotScratch.length >= size
            ? slotScratch
            : Int32List(size);
        slots.fillRange(0, size, -1);
        for (var i = 0; i < partsLength; i++) {
          final at = partsAt + i * _partStateSize;
          final index = data.getInt16(at + _partIndexAt, Endian.little);
          if (index >= 0 && index < size) slots[index] = at;
        }
        final frame = DrawFrame._fromBytes(
          frameData: frameData,
          drawOrder: frameBytes.buffer
              .asUint16List(frameBytes.offsetInBytes + orderAt, orderLength),
          bytes: frameBytes,
          data: data,
          slots: slots,
          partCount: size,
          world: world,
          local: local,
          uv: uv,
          mesh: mesh,
          shape: shape,
          alphaScale: alphaScale,
        );
        if (_bytesMatchAccessors == true || frame._matchesAccessors()) {
          return frame;
        }
      }
    }
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
    // Bound the dense allocation: a corrupt/hostile part index must not be able
    // to request a multi-gigabyte list. Real packs have at most a few thousand
    // parts, so the cap never drops a legitimate one; an index past it resolves
    // to null via [partOf] (bounds-checked) and is simply not drawn.
    final size = (maxIndex + 1).clamp(0, _maxDenseParts);
    // A recycled scratch is only cleared over [0, size) — [partCount] keeps
    // [partOf] from ever reading the stale tail a longer array still holds.
    final List<fbs.PartState?> partByIndex;
    if (partByIndexScratch != null && partByIndexScratch.length >= size) {
      partByIndex = partByIndexScratch..fillRange(0, size, null);
    } else {
      partByIndex = List<fbs.PartState?>.filled(size, null);
    }
    for (final p in parts) {
      if (p.partIndex >= 0 && p.partIndex < size) partByIndex[p.partIndex] = p;
    }
    return DrawFrame(
      frameData: frameData,
      drawOrder: drawOrder,
      partByIndex: partByIndex,
      partCount: size,
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
  /// throw, and a recycled backing array may be longer than [partCount].
  List<fbs.PartState?> get partByIndex => _partByIndex ??=
      List<fbs.PartState?>.generate(partCount, partOf, growable: false);
  List<fbs.PartState?>? _partByIndex;

  /// How much of [partByIndex] belongs to this frame. Equal to its length for a
  /// freshly built table; smaller when the array is a recycled scratch whose
  /// tail still holds a previous frame's parts (see [build]).
  final int partCount;
  final Float32List world; // parts × 16
  final Float32List local; // parts × 10 (lt,rt,lb,rb,center)
  final Float32List uv; // parts × 10 (texture-pixel space)

  /// The frame's mesh SoA, or null when the animation has no Mesh batch.
  final MeshBuffers? mesh;

  /// The frame's shape SoA, or null when the animation has no Shape part.
  final ShapeBuffers? shape;

  /// An extra opacity multiplier applied on top of every part's own alpha.
  ///
  /// 1.0 for a root player. For an instance child it carries the product of
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
  fbs.PartState? partOf(int partIndex) {
    if (partIndex < 0 || partIndex >= partCount) return null;
    final slots = _slots;
    if (slots == null) return _partByIndex![partIndex];
    final at = slots[partIndex];
    return at < 0 ? null : fbs.PartState.reader.read(_context, at);
  }

  // Set only for a frame built from its bytes: the bytes, a view of them, and
  // where in them each part index's `PartState` starts (-1 for none).
  final Uint8List? _bytes;
  final ByteData? _data;
  final Int32List? _slots;
  late final fb.BufferContext _context = fb.BufferContext.fromBytes(_bytes!);

  // FrameData's vtable slots and PartState's layout, as in framedata.g.dart.
  static const int _partsSlot = 4, _drawOrderSlot = 16;
  static const int _partStateSize = 144, _alphaAt = 48, _partIndexAt = 124;
  static const int _absent = -1, _unreadable = -2;

  // Null while every frame built from bytes is still compared with the
  // generated accessors, until one with parts reads the same; false once one
  // does not, for good.
  static bool? _bytesMatchAccessors;
  static int _vectorLength = 0;

  // Where the root table's vector at vtable [slot] starts, its length left in
  // [_vectorLength]: [_absent] when the field is not there (the accessor reads
  // null), [_unreadable] when it does not fit the buffer.
  static int _vector(ByteData data, int slot, int elementSize) {
    final size = data.lengthInBytes;
    if (size < 4) return _unreadable;
    final table = data.getUint32(0, Endian.little);
    if (table + 4 > size) return _unreadable;
    final vtable = table - data.getInt32(table, Endian.little);
    if (vtable < 0 || vtable + 4 > size) return _unreadable;
    if (slot + 2 > data.getUint16(vtable, Endian.little)) return _absent;
    final field = data.getUint16(vtable + slot, Endian.little);
    if (field == 0) return _absent;
    final at = table + field;
    if (at + 4 > size) return _unreadable;
    final vector = at + data.getUint32(at, Endian.little);
    if (vector + 4 > size) return _unreadable;
    _vectorLength = data.getUint32(vector, Endian.little);
    if (vector + 4 + _vectorLength * elementSize > size) return _unreadable;
    return vector + 4;
  }

  // Whether this frame, built from its bytes, holds what the generated
  // accessors read: the draw order, and for every part index its state and
  // alpha. Settles [_bytesMatchAccessors] once a frame with parts agrees.
  bool _matchesAccessors() {
    final parts = frameData.parts;
    final order = frameData.drawOrder;
    var same = parts != null &&
        order != null &&
        order.length == drawOrder.length;
    for (var i = 0; same && i < drawOrder.length; i++) {
      same = order![i] == drawOrder[i];
    }
    if (same) {
      final expected = List<fbs.PartState?>.filled(partCount, null);
      for (final p in parts!) {
        if (p.partIndex >= 0 && p.partIndex < partCount) {
          expected[p.partIndex] = p;
        }
      }
      for (var i = 0; same && i < partCount; i++) {
        final at = _slots![i];
        final state = expected[i];
        same = state == null
            ? at < 0
            : at >= 0 &&
                state.partIndex ==
                    _data!.getInt16(at + _partIndexAt, Endian.little) &&
                state.alpha == _data.getFloat32(at + _alphaAt, Endian.little);
      }
    }
    if (!same) {
      _bytesMatchAccessors = false;
    } else if (partCount > 0) {
      _bytesMatchAccessors = true;
    }
    return same;
  }

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

  List<fbs.PartAttributeShader>? _shaders;
  bool _shadersFetched = false;

  /// The frame's `shaders` vector (the `SHDR` integration-shader attributes),
  /// fetched once and cached (incl. a null result) — same reasoning as
  /// [partsColor]. Pass the result to [PartShader.read].
  List<fbs.PartAttributeShader>? get shaders {
    if (!_shadersFetched) {
      _shaders = frameData.shaders;
      _shadersFetched = true;
    }
    return _shaders;
  }

  /// The hierarchical alpha for part [partIndex], clamped to 0..1 (1 if the part
  /// is not present in the `parts` vector), times this frame's [alphaScale].
  ///
  /// The Brain has already resolved the parent chain *within* this pack, so this
  /// never walks it. Note the PartColor path does NOT go through here: there the
  /// hierarchical alpha is pre-folded into the corner alphas and
  /// re-multiplying it would double-apply.
  double alphaOf(int partIndex) {
    final slots = _slots;
    if (slots == null) {
      return (partOf(partIndex)?.alpha ?? 1.0).clamp(0.0, 1.0) * alphaScale;
    }
    final at = partIndex >= 0 && partIndex < partCount ? slots[partIndex] : -1;
    final alpha =
        at < 0 ? 1.0 : _data!.getFloat32(at + _alphaAt, Endian.little);
    return alpha.clamp(0.0, 1.0) * alphaScale;
  }
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

  /// Null for a kind that samples no texture — a Shape is coloured purely
  /// by [colors], so there is nothing to map. `Vertices.raw` requires this to be
  /// either absent or exactly as long as [positions].
  final Float32List? texCoords;
  final Int32List colors;
  final Uint16List indices;

  /// The axis-aligned bounds of [positions], in the canvas' current space — the
  /// `saveLayer` hint a peeled (masked) draw needs so the layer is no larger
  /// than the geometry. [ui.Rect.zero] when the block is empty.
  ui.Rect get bounds {
    if (positions.length < 2) return ui.Rect.zero;
    var minX = positions[0], maxX = positions[0];
    var minY = positions[1], maxY = positions[1];
    for (var i = 2; i + 1 < positions.length; i += 2) {
      final x = positions[i], y = positions[i + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Wraps this block for `Canvas.drawVertices`.
  ui.Vertices toVertices() => ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: texCoords,
        colors: colors,
        indices: indices,
      );
}

/// An interleaved vertex block for the flutter_gpu path — for the sprite
/// pipeline, 8 floats per vertex `[x, y, u, v, r, g, b, a]` (world-space XY,
/// normalised UV, premultiplied RGBA) plus 16-bit indices; the peeled
/// PartColor bakes ([GeometryBuilder.buildPartColorInterleaved] /
/// [GeometryBuilder.buildMeshPartColorInterleaved]) use the wider
/// [GeometryBuilder.partColorStride] layout instead. Built by
/// [GeometryBuilder.buildNormalInterleaved] and its siblings; the
/// [vertices]/[indices] views alias grow-only scratch, so copy them into a
/// `DeviceBuffer` before the next bake. This is the GPU sibling of
/// [MeshGeometry.toVertices] (which packs the parallel arrays a `ui.Vertices`
/// wants); the compute is shared, only the output layout differs. The stride is
/// not carried here — the bound pipeline's shader reflection defines it, and the
/// bake writes to match.
class InterleavedGeometry {
  const InterleavedGeometry(
      this.vertices, this.indices, this.vertexCount, this.indexCount);

  /// `vertexCount * stride` floats, tightly interleaved in attribute location
  /// order (stride per the pipeline this block feeds — 8 for the sprite
  /// pipeline, [GeometryBuilder.partColorStride] for the PartColor pipeline).
  final Float32List vertices;

  /// `indexCount` 16-bit indices.
  final Uint16List indices;

  final int vertexCount;
  final int indexCount;
}

/// Per-part quad + affine map for the PartColor shader path.
///
/// The four world-transformed corners drive a fill path; `origin` + `inv` map a
/// fragment position back to quad-local `(s,t)` inside `shaders/partcolor.frag`
/// (`s = inv[0]·dx + inv[1]·dy`, `t = inv[2]·dx + inv[3]·dy`, `d = frag - origin`),
/// and `uvA`/`uvB` carry the corner UVs (texture pixels) the shader bilinearly
/// samples. Built by [GeometryBuilder.buildPartColorQuad].
///
/// **Mutable, and the builder hands out a shared instance.** The fields are not
/// `final` so [GeometryBuilder.buildPartColorQuad] can refill one quad per
/// builder instead of allocating one per peeled part per frame; that method's
/// result is therefore valid only until its next call. Construct your own if you
/// need one that outlives a draw.
class PartColorQuad {
  PartColorQuad({
    required this.corners,
    required this.originX,
    required this.originY,
    required this.inv,
    required this.uvA,
    required this.uvB,
    Float32List? center,
  }) : center = center ?? Float32List(4);

  /// World corners, 8 floats: `ltx,lty, rtx,rty, lbx,lby, rbx,rby`.
  Float32List corners;

  /// LT world corner — the affine's frag-space origin (shader `uOrigin`).
  double originX;
  double originY;

  /// 2×2 inverse affine `[m00,m01,m10,m11]` mapping `frag - origin` → `(s,t)`.
  Float32List inv;

  /// `(LT.u,LT.v, RT.u,RT.v)` and `(LB.u,LB.v, RB.u,RB.v)` in texture pixels.
  Float32List uvA;
  Float32List uvB;

  /// The part's centre vertex, `(x, y, u, v)`: world position and texture-pixel
  /// UV, which a vertex-deformed part moves off the corners' average. The GPU
  /// bakes draw it as the hub of the part's fan; the Canvas shader, which sees
  /// the quad only through the affine above, puts the hub at its middle.
  Float32List center;

  /// The cell's UV rect `(minU, minV, maxU, maxV)`, **normalised** by
  /// [texWidth]/[texHeight] — the axis-aligned bounding box of the four corner
  /// UVs.
  ///
  /// The `ss-circle` / `ss-spot` integration shaders centre their
  /// polar unwrap / spotlight on the *cell*, not the atlas, so they need to know
  /// where in the atlas the cell sits. Derived from the quad's own corners
  /// (which is how the Web port does it) rather than from cell metadata, so it
  /// automatically follows a flipped or cell-overridden part.
  Float32List cellRect(double texWidth, double texHeight, [Float32List? out]) {
    var minU = uvA[0], maxU = uvA[0];
    var minV = uvA[1], maxV = uvA[1];
    void fold(double u, double v) {
      if (u < minU) minU = u;
      if (u > maxU) maxU = u;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }

    fold(uvA[2], uvA[3]);
    fold(uvB[0], uvB[1]);
    fold(uvB[2], uvB[3]);
    final invW = texWidth > 0 ? 1.0 / texWidth : 0.0;
    final invH = texHeight > 0 ? 1.0 / texHeight : 0.0;
    final res = out ?? Float32List(4);
    res[0] = minU * invW;
    res[1] = minV * invH;
    res[2] = maxU * invW;
    res[3] = maxV * invH;
    return res;
  }
}

/// Bakes the Brain's SoA buffers into `ui.Vertices` for `Canvas.drawVertices`.
///
/// Pure geometry construction — no `Canvas`, no FFI — so it is unit-testable in
/// isolation and reusable headless / from Flame / flutter_gpu, matching the
/// sibling ports' `GeometryBuilder` (Web) / `SpriteStudioGeometryBuilder`
/// (Unity). The owning [SpriteStudioInternalPlayer] gathers the [DrawFrame],
/// dispatches on `DrawBatch.kind`, and draws the returned vertices; this class
/// only bakes them.
///
/// Bakes every draw kind: Normal ([buildNormalParts]), Mesh ([buildMeshGeometry]),
/// Shape ([buildShapeParts]), Effect ([buildEffectGroup]), plus the PartColor quad
/// ([buildPartColorQuad]). Each has a `…Interleaved` sibling
/// ([buildNormalInterleaved] etc.) that packs one tightly-interleaved attribute
/// buffer for the flutter_gpu backend, sharing this class's compute (world
/// transform, corner-colour bilerp, UV) so the two outputs cannot drift. A run
/// of plain Normal and Mesh parts bakes as one block
/// ([buildTexturedGeometry], [buildTexturedInterleaved]) through the same
/// per-part writers as the Normal and Mesh bakes.
///
/// **Buffer reuse / aliasing contract.** The bake methods write into grow-only
/// scratch buffers held on this instance rather than allocating fresh arrays per
/// batch, so a steady-state frame does no per-batch vertex allocation. Two
/// consequences the callers already honour:
///  * the [MeshGeometry] returned by [buildMeshGeometry] / [buildShapeParts] /
///    [buildEffectCommand] and its siblings **aliases the scratch** — consume it (`toVertices()`,
///    or read its arrays) BEFORE the next bake call on the same builder, which
///    overwrites the scratch. Every call site does (draw / build a Path
///    immediately); a `ui.Vertices` copies at construction so it is unaffected;
///  * each [SpriteStudioInternalPlayer] owns its own builder, so an instance
///    child's recursive paint never races the parent's scratch.
class GeometryBuilder {
  /// A Normal part is a fan of four triangles around its centre vertex:
  /// `lt,rt,lb,rb,centre` → `{c,lt,rt, c,rt,rb, c,rb,lb, c,lb,lt}`. Two triangles
  /// would cut the part along one diagonal, so a deformed part would bend along it
  /// and a four-corner PartColor would shade along it; the Editor draws neither
  /// that way.
  static const List<int> fanIndices = [4, 0, 1, 4, 1, 3, 4, 3, 2, 4, 2, 0];

  /// Vertices per Normal part: its four corners and the centre of [fanIndices].
  static const int _fanVertices = 5;

  /// Most Normal parts one bake can index: indices are 16-bit (`ui.Vertices`
  /// and the GPU index buffer both), and a part is [_fanVertices] vertices.
  ///
  /// Past this the `vBase + q` writes wrap silently in the [Uint16List] and the
  /// batch rasterises as garbage triangles smeared across the atlas, so the
  /// bake declines instead — the same contract the mesh / shape / effect bakes
  /// already enforce with their `vTotal > 0xFFFF` guards. Unreachable for real
  /// content (it takes a run of 13107 consecutive plain parts in one batch);
  /// the check is one comparison per bake against a count already in hand.
  static const int _maxQuads = 0xFFFF ~/ _fanVertices;

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

  final List<int> _singlePartScratch = <int>[0];

  /// A reusable 1-element part list holding [part] — the single-part argument
  /// for the `build*Parts` bakes, which all take a run.
  ///
  /// **Aliases scratch:** every call returns the SAME list. Pass it straight to
  /// the bake and never hold it across a second [singlePart] call (the bakes
  /// consume their `parts` argument before returning, which is what makes this
  /// safe).
  List<int> singlePart(int part) => _singlePartScratch..[0] = part;

  /// Grow-only backing array for [buildFrame]'s dense part table. Handed to
  /// [DrawFrame.build] as its scratch and re-adopted from the frame it returns,
  /// so a resize is picked up automatically.
  List<fbs.PartState?> _partByIndexScratch = const <fbs.PartState?>[];
  Int32List _slotScratch = Int32List(0);

  final Float32List _quadCorners = Float32List(8);
  final Float32List _quadInv = Float32List(4);
  final Float32List _quadUvA = Float32List(4);
  final Float32List _quadUvB = Float32List(4);
  final Float32List _quadCenter = Float32List(4);
  final Float32List _cellRectScratch = Float32List(4);
  late final PartColorQuad _quadScratch = PartColorQuad(
    corners: _quadCorners,
    originX: 0,
    originY: 0,
    inv: _quadInv,
    uvA: _quadUvA,
    uvB: _quadUvB,
    center: _quadCenter,
  );

  /// Computes [quad]'s cell UV rect into this builder's reusable scratch buffer.
  ///
  /// **Aliases scratch** — consume before the next call.
  Float32List cellRectScratch(
          PartColorQuad quad, double texWidth, double texHeight) =>
      quad.cellRect(texWidth, texHeight, _cellRectScratch);

  /// [DrawFrame.build] against this builder's reusable dense part table, so the
  /// per-frame `List.filled` the plain constructor does is paid once per player
  /// instead of once per frame. Identical in every other respect.
  ///
  /// The returned frame's [DrawFrame.partByIndex] therefore **aliases scratch**:
  /// it is valid only until the next [buildFrame] on this builder — the same
  /// lifetime the SoA views it travels with already have.
  DrawFrame? buildFrame({
    required fbs.FrameData frameData,
    Uint8List? frameBytes,
    required Float32List world,
    required Float32List local,
    required Float32List uv,
    MeshBuffers? mesh,
    ShapeBuffers? shape,
    double alphaScale = 1.0,
  }) {
    final frame = DrawFrame.build(
      frameData: frameData,
      world: world,
      local: local,
      uv: uv,
      mesh: mesh,
      shape: shape,
      alphaScale: alphaScale,
      partByIndexScratch: _partByIndexScratch,
      frameBytes: frameBytes,
      slotScratch: _slotScratch,
    );
    // Re-adopt: [DrawFrame.build] reallocates when the scratch is too small.
    if (frame != null) {
      final slots = frame._slots;
      if (slots != null) {
        _slotScratch = slots;
      } else {
        _partByIndexScratch = frame.partByIndex;
      }
    }
    return frame;
  }

  /// Most vertices one textured bake can index: indices are 16-bit
  /// (`ui.Vertices` and the GPU index buffer both). A backend splits a run of
  /// plain parts before it passes this ([texturedVertexCount]).
  static const int maxBakeVertices = 0xFFFF;

  /// The vertices and indices the current bake has written so far, advanced
  /// by the per-part writers ([_writeNormal] and its siblings).
  int _vAt = 0;
  int _iAt = 0;

  /// Bakes the given [parts] (part indices, already in draw order) into a single
  /// indexed [ui.Vertices]: for each part transforms its 4 local corners and
  /// its centre (lt,rt,lb,rb,centre) by the world matrix (`x'=m0·x+m4·y+m12`,
  /// `y'=m1·x+m5·y+m13`), copies the texture-pixel UVs as-is, sets each vertex
  /// color to white × part alpha, and appends the fan's indices. Returns null
  /// when nothing was emitted.
  ui.Vertices? buildNormalParts(List<int> parts, DrawFrame frame) =>
      buildNormalGeometry(parts, frame)?.toVertices();

  /// The inspectable form of [buildNormalParts], as [buildMeshGeometry] is of
  /// [buildMeshParts].
  MeshGeometry? buildNormalGeometry(List<int> parts, DrawFrame frame) {
    final count = parts.length;
    if (count == 0 || count > _maxQuads) return null;

    final positions = _pos(count * _fanVertices * 2); // × (x,y)
    final texCoords = _uvs(count * _fanVertices * 2);
    final colors = _cols(count * _fanVertices);
    final indices = _idx(count * fanIndices.length);

    _vAt = 0;
    _iAt = 0;
    for (var k = 0; k < count; k++) {
      _writeNormal(parts[k], frame, positions, texCoords, colors, indices);
    }
    return _bakedGeometry(positions, texCoords, colors, indices);
  }

  /// Bakes a run of plain Normal and Mesh parts, in draw order, into one
  /// block: what a span of Normal and Mesh batches on one texture and blend
  /// draws as one `drawVertices`. [mesh] runs parallel to [parts] and says
  /// which of them are Mesh parts.
  ///
  /// Each part is written exactly as its own kind's bake writes it
  /// ([buildNormalGeometry], [buildMeshGeometry]), its indices rebased onto
  /// the block. Returns null when nothing was emitted or the run passes
  /// [maxBakeVertices].
  MeshGeometry? buildTexturedGeometry(
      List<int> parts, List<bool> mesh, DrawFrame frame) {
    final (vTotal, iTotal) = _texturedTotals(parts, mesh, frame);
    if (vTotal == 0 || iTotal == 0 || vTotal > maxBakeVertices) return null;

    final positions = _pos(vTotal * 2);
    final texCoords = _uvs(vTotal * 2);
    final colors = _cols(vTotal);
    final indices = _idx(iTotal);
    final meshBuffers = frame.mesh;

    _vAt = 0;
    _iAt = 0;
    for (var k = 0; k < parts.length; k++) {
      final p = parts[k];
      if (!mesh[k]) {
        _writeNormal(p, frame, positions, texCoords, colors, indices);
      } else if (meshBuffers != null) {
        _writeMesh(p, meshBuffers, frame.alphaOf(p), positions, texCoords,
            colors, indices);
      }
    }
    return _bakedGeometry(positions, texCoords, colors, indices);
  }

  /// [buildTexturedGeometry] for `Canvas.drawVertices`.
  ui.Vertices? buildTexturedParts(
          List<int> parts, List<bool> mesh, DrawFrame frame) =>
      buildTexturedGeometry(parts, mesh, frame)?.toVertices();

  /// The vertices part [p] adds to a textured bake ([buildTexturedGeometry],
  /// [buildTexturedInterleaved]): a Normal part's fan, or a Mesh part's own
  /// vertices (0 when it has none).
  static int texturedVertexCount(int p, bool mesh, DrawFrame frame) {
    if (!mesh) return _fanVertices;
    final vr = frame.mesh?.vertexRange(p);
    return vr == null ? 0 : vr.$2 - vr.$1;
  }

  /// The vertex and index totals a textured bake of [parts] writes at most:
  /// a whole fan per Normal part, a Mesh part's own ranges.
  static (int, int) _texturedTotals(
      List<int> parts, List<bool> mesh, DrawFrame frame) {
    final meshBuffers = frame.mesh;
    var vTotal = 0;
    var iTotal = 0;
    for (var k = 0; k < parts.length; k++) {
      if (!mesh[k]) {
        vTotal += _fanVertices;
        iTotal += fanIndices.length;
        continue;
      }
      final vr = meshBuffers?.vertexRange(parts[k]);
      final ir = meshBuffers?.indexRange(parts[k]);
      if (vr == null || ir == null) continue;
      vTotal += vr.$2 - vr.$1;
      iTotal += ir.$2 - ir.$1;
    }
    return (vTotal, iTotal);
  }

  /// Writes Normal part [p]'s fan at the bake's cursors (see
  /// [buildNormalParts]). A part outside the SoA writes nothing.
  void _writeNormal(int p, DrawFrame frame, Float32List positions,
      Float32List texCoords, Int32List colors, Uint16List indices) {
    final world = frame.world;
    final local = frame.local;
    final uv = frame.uv;

    final m = p * DrawFrame.worldStride;
    final v = p * DrawFrame.vertexStride; // local vertices & UVs share stride
    if (m + 16 > world.length || v + 10 > local.length || v + 10 > uv.length) {
      return;
    }

    final alpha = frame.alphaOf(p);
    final color = ((alpha * 255).round() & 0xFF) << 24 | 0x00FFFFFF;

    final m0 = world[m], m1 = world[m + 1];
    final m4 = world[m + 4], m5 = world[m + 5];
    final m12 = world[m + 12], m13 = world[m + 13];

    final vBase = _vAt;
    var fPos = vBase * 2; // float cursor into positions/texCoords
    var iPos = _iAt;
    // lt=(0,1) rt=(2,3) lb=(4,5) rb=(6,7) centre=(8,9).
    for (var c = 0; c < _fanVertices; c++) {
      final lx = local[v + c * 2];
      final ly = local[v + c * 2 + 1];
      positions[fPos] = m0 * lx + m4 * ly + m12;
      positions[fPos + 1] = m1 * lx + m5 * ly + m13;
      texCoords[fPos] = uv[v + c * 2]; // texture-pixel UV, used as-is
      texCoords[fPos + 1] = uv[v + c * 2 + 1];
      fPos += 2;
      colors[vBase + c] = color;
    }
    for (final q in fanIndices) {
      indices[iPos++] = vBase + q;
    }
    _vAt = vBase + _fanVertices;
    _iAt = iPos;
  }

  /// The block the per-part writers left at the head of the scratch, or null
  /// when they wrote nothing.
  ///
  /// Zero-copy views over the head of each scratch buffer, NOT `sublist` (which
  /// allocates a full copy): `ui.Vertices.raw` copies its inputs into engine
  /// memory at construction, so a view is safe and skips one array copy per
  /// buffer. A view spans `[0, n)` — the untouched tail (when a part was
  /// skipped) is never referenced.
  MeshGeometry? _bakedGeometry(Float32List positions, Float32List texCoords,
      Int32List colors, Uint16List indices) {
    if (_vAt == 0 || _iAt == 0) return null;
    return MeshGeometry(
      positions:
          Float32List.view(positions.buffer, positions.offsetInBytes, _vAt * 2),
      texCoords:
          Float32List.view(texCoords.buffer, texCoords.offsetInBytes, _vAt * 2),
      colors: Int32List.view(colors.buffer, colors.offsetInBytes, _vAt),
      indices: Uint16List.view(indices.buffer, indices.offsetInBytes, _iAt),
    );
  }

  // Grow-only scratch for the interleaved flutter_gpu vertex bake (8 floats per
  // vertex). Separate from the parallel-array scratch above; the index scratch
  // ([_idx]) is shared (a player uses one backend, so the two bakes never
  // interleave). Pure typed-data — no flutter_gpu here, so it stays web-safe.
  Float32List _interScratch = Float32List(0);
  Float32List _inter(int n) =>
      _interScratch.length >= n ? _interScratch : (_interScratch = Float32List(n));

  /// Floats per vertex in the peeled-PartColor bakes ([buildPartColorInterleaved]
  /// / [buildMeshPartColorInterleaved]) — 32 floats = 128 bytes, every `vec4`
  /// attribute on a 16-byte boundary so Impeller reads them correctly (the
  /// ShapeMask alignment trap). Layout matches `shaders/gpu/partcolor.vert`:
  /// `[pos.xy, uv.xy, color.rgba, coef.xyz+rate]` then the 20-float mask
  /// replay of `MaskDraw.writeReplay`.
  static const int partColorStride = 32;

  /// Writes one peeled-PartColor vertex (32 floats, [partColorStride]) at [fp]
  /// and returns the next cursor. Shared by the Normal ([buildPartColorInterleaved])
  /// and Mesh ([buildMeshPartColorInterleaved]) bakes so their vertex format can
  /// never drift from the shader's `in` layout.
  ///
  /// [col] is the corner colour whose straight RGBA + [PartColorCorner.rate] this
  /// vertex carries (the shader interpolates them into the gradient), [coef]
  /// is the part's blend coefficient row (constant across the quad), and [mask] is
  /// the 20-float replay `MaskDraw.writeReplay` flattens, or null when the part
  /// is unmasked (→ `enabled = 0`). ALL 32 floats are written every call, so no
  /// stale scratch leaks into the padding lanes.
  static int _writePcVertex(Float32List v, int fp, double x, double y, double u,
      double vv, PartColorCorner col, List<double> coef, Float32List? mask) {
    v[fp] = x; // a_position
    v[fp + 1] = y;
    v[fp + 2] = u; // a_uv (normalised)
    v[fp + 3] = vv;
    v[fp + 4] = col.r; // a_color (straight)
    v[fp + 5] = col.g;
    v[fp + 6] = col.b;
    v[fp + 7] = col.a;
    v[fp + 8] = coef[0]; // a_coef.xyz + rate
    v[fp + 9] = coef[1];
    v[fp + 10] = coef[2];
    v[fp + 11] = col.rate;
    // The mask replay (`MaskDraw.writeReplay`); all zero when the part is
    // unmasked — `enabled` 0 makes maskPasses pass unconditionally.
    if (mask == null) {
      v.fillRange(fp + 12, fp + partColorStride, 0.0);
    } else {
      v.setRange(fp + 12, fp + partColorStride, mask);
    }
    return fp + partColorStride;
  }

  /// Bakes [parts] into a single **interleaved** vertex block for the flutter_gpu
  /// Normal path: 8 floats per vertex `[x, y, u, v, r, g, b, a]` — world-
  /// transformed position, UV **normalised** by [texWidth]/[texHeight], and a
  /// **premultiplied** white×alpha colour (so `texel * colour` in the fragment
  /// shader matches the Canvas `drawVertices(..., BlendMode.modulate, ...)`
  /// reference, where a premultiplied texel is scaled by the vertex alpha).
  ///
  /// Mirrors [buildNormalParts] (same world transform `x'=m0·x+m4·y+m12`, same
  /// fan) but packs one tightly-interleaved buffer + 16-bit indices, which is
  /// what a `DeviceBuffer` binds. Returns null when nothing was emitted. The
  /// returned views alias grow-only scratch — consume (copy into a
  /// `DeviceBuffer`) before the next bake.
  InterleavedGeometry? buildNormalInterleaved(List<int> parts, DrawFrame frame,
      {required double texWidth, required double texHeight}) {
    final count = parts.length;
    if (count == 0 || count > _maxQuads) return null;

    final verts = _inter(count * _fanVertices * 8);
    final indices = _idx(count * fanIndices.length);
    final invW = texWidth > 0 ? 1.0 / texWidth : 0.0;
    final invH = texHeight > 0 ? 1.0 / texHeight : 0.0;

    _vAt = 0;
    _iAt = 0;
    for (var k = 0; k < count; k++) {
      _interleaveNormal(parts[k], frame, verts, indices, invW, invH);
    }
    return _bakedInterleaved(verts, indices);
  }

  /// Interleaved flutter_gpu bake of mesh [parts] — the GPU sibling of
  /// [buildMeshGeometry]. Mesh verts are **already world-space** (no matrix);
  /// UVs are normalised by [texWidth]/[texHeight] and the colour is premultiplied
  /// white×alpha `(a,a,a,a)`. Part-local indices are rebased. Returns null when
  /// nothing was emitted. Views alias scratch — consume before the next bake.
  InterleavedGeometry? buildMeshInterleaved(List<int> parts, DrawFrame frame,
      {required double texWidth, required double texHeight}) {
    final mesh = frame.mesh;
    if (mesh == null || mesh.isEmpty || parts.isEmpty) return null;

    var vTotal = 0;
    var iTotal = 0;
    for (final p in parts) {
      final vr = mesh.vertexRange(p);
      final ir = mesh.indexRange(p);
      if (vr == null || ir == null) continue;
      vTotal += vr.$2 - vr.$1;
      iTotal += ir.$2 - ir.$1;
    }
    if (vTotal == 0 || iTotal == 0 || vTotal > 0xFFFF) return null;

    final verts = _inter(vTotal * 8);
    final indices = _idx(iTotal);
    final invW = texWidth > 0 ? 1.0 / texWidth : 0.0;
    final invH = texHeight > 0 ? 1.0 / texHeight : 0.0;

    _vAt = 0;
    _iAt = 0;
    for (final p in parts) {
      _interleaveMesh(p, mesh, frame.alphaOf(p), verts, indices, invW, invH);
    }
    return _bakedInterleaved(verts, indices);
  }

  /// The flutter_gpu sibling of [buildTexturedGeometry]: a run of plain
  /// Normal and Mesh parts as one sprite-pipeline block, each part written
  /// exactly as [buildNormalInterleaved] or [buildMeshInterleaved] writes it.
  /// Views alias scratch — consume before the next bake.
  InterleavedGeometry? buildTexturedInterleaved(
      List<int> parts, List<bool> mesh, DrawFrame frame,
      {required double texWidth, required double texHeight}) {
    final (vTotal, iTotal) = _texturedTotals(parts, mesh, frame);
    if (vTotal == 0 || iTotal == 0 || vTotal > maxBakeVertices) return null;

    final verts = _inter(vTotal * 8);
    final indices = _idx(iTotal);
    final invW = texWidth > 0 ? 1.0 / texWidth : 0.0;
    final invH = texHeight > 0 ? 1.0 / texHeight : 0.0;
    final meshBuffers = frame.mesh;

    _vAt = 0;
    _iAt = 0;
    for (var k = 0; k < parts.length; k++) {
      final p = parts[k];
      if (!mesh[k]) {
        _interleaveNormal(p, frame, verts, indices, invW, invH);
      } else if (meshBuffers != null) {
        _interleaveMesh(
            p, meshBuffers, frame.alphaOf(p), verts, indices, invW, invH);
      }
    }
    return _bakedInterleaved(verts, indices);
  }

  /// Writes Normal part [p]'s fan at the bake's cursors as
  /// [buildNormalInterleaved] lays it out. A part outside the SoA writes
  /// nothing.
  void _interleaveNormal(int p, DrawFrame frame, Float32List verts,
      Uint16List indices, double invW, double invH) {
    final world = frame.world;
    final local = frame.local;
    final uv = frame.uv;

    final m = p * DrawFrame.worldStride;
    final v = p * DrawFrame.vertexStride;
    if (m + 16 > world.length || v + 10 > local.length || v + 10 > uv.length) {
      return;
    }

    // Premultiplied white × alpha = (a, a, a, a): the exact colour Skia's
    // `modulate` produces from a premultiplied texel and a straight white×α
    // vertex colour (see [buildNormalInterleaved]).
    final a = frame.alphaOf(p);

    final m0 = world[m], m1 = world[m + 1];
    final m4 = world[m + 4], m5 = world[m + 5];
    final m12 = world[m + 12], m13 = world[m + 13];

    final vBase = _vAt;
    var fp = vBase * 8; // float cursor into verts
    var ip = _iAt;
    for (var c = 0; c < _fanVertices; c++) {
      final lx = local[v + c * 2];
      final ly = local[v + c * 2 + 1];
      verts[fp] = m0 * lx + m4 * ly + m12; // x
      verts[fp + 1] = m1 * lx + m5 * ly + m13; // y
      verts[fp + 2] = uv[v + c * 2] * invW; // u (normalised)
      verts[fp + 3] = uv[v + c * 2 + 1] * invH; // v (normalised)
      verts[fp + 4] = a; // r (premultiplied)
      verts[fp + 5] = a; // g
      verts[fp + 6] = a; // b
      verts[fp + 7] = a; // a
      fp += 8;
    }
    for (final q in fanIndices) {
      indices[ip++] = vBase + q;
    }
    _vAt = vBase + _fanVertices;
    _iAt = ip;
  }

  /// Writes Mesh part [p] at the bake's cursors as [buildMeshInterleaved]
  /// lays it out, with [a] as its premultiplied white. A part with no mesh
  /// range writes nothing; an index outside the part's own vertices is dropped.
  void _interleaveMesh(int p, MeshBuffers mesh, double a, Float32List verts,
      Uint16List indices, double invW, double invH) {
    final vr = mesh.vertexRange(p);
    final ir = mesh.indexRange(p);
    if (vr == null || ir == null) return;
    final vBase = _vAt;
    var fp = vBase * 8;
    var ip = _iAt;
    for (var v = vr.$1; v < vr.$2; v++) {
      verts[fp] = mesh.x[v]; // already world-space
      verts[fp + 1] = mesh.y[v];
      verts[fp + 2] = mesh.uv[v * 2] * invW;
      verts[fp + 3] = mesh.uv[v * 2 + 1] * invH;
      verts[fp + 4] = a;
      verts[fp + 5] = a;
      verts[fp + 6] = a;
      verts[fp + 7] = a;
      fp += 8;
    }
    final vCount = vr.$2 - vr.$1;
    for (var i = ir.$1; i < ir.$2; i++) {
      final local = mesh.indices[i];
      if (local < 0 || local >= vCount) continue;
      indices[ip++] = vBase + local;
    }
    _vAt = vBase + vCount;
    _iAt = ip;
  }

  /// The sprite-pipeline block the interleaving writers left at the head of
  /// the scratch, or null when they wrote nothing.
  InterleavedGeometry? _bakedInterleaved(
      Float32List verts, Uint16List indices) {
    if (_vAt == 0 || _iAt == 0) return null;
    return InterleavedGeometry(
      Float32List.view(verts.buffer, verts.offsetInBytes, _vAt * 8),
      Uint16List.view(indices.buffer, indices.offsetInBytes, _iAt),
      _vAt,
      _iAt,
    );
  }

  /// Interleaved flutter_gpu bake of *peeled* Normal [parts] carrying PartColor
  /// and/or a mask test — the per-vertex-attribute feed for the
  /// `PartColorVertex/Fragment` pipeline.
  ///
  /// Each vertex is self-describing ([partColorStride] floats), so a whole RUN
  /// batches into ONE draw with no uniform array. Each part's fan takes its four
  /// corner colours + rates straight from [pcs]`[i]`, and its centre their
  /// average (the rasteriser interpolates the gradient across the fan's
  /// triangles), and its flattened mask replay set from [masks]`[i]`
  /// (null = unmasked). [pcs] / [masks] are parallel to [parts]; a part whose
  /// quad is degenerate is dropped (its [pcs]/[masks] entry with it). Views alias
  /// scratch — consume before the next bake.
  InterleavedGeometry? buildPartColorInterleaved(List<int> parts,
      List<PartColor> pcs, List<Float32List?> masks, DrawFrame frame,
      {required double texWidth, required double texHeight}) {
    final count = parts.length;
    if (count == 0 || count > _maxQuads) return null;

    final verts = _inter(count * _fanVertices * partColorStride);
    final indices = _idx(count * fanIndices.length);
    final invW = texWidth > 0 ? 1.0 / texWidth : 0.0;
    final invH = texHeight > 0 ? 1.0 / texHeight : 0.0;

    var vBase = 0;
    var fp = 0;
    var ip = 0;
    for (var i = 0; i < count; i++) {
      final quad = buildPartColorQuad(parts[i], frame);
      if (quad == null) continue; // degenerate — drop
      final pc = pcs[i];
      final mask = masks[i];
      final c = quad.corners, ua = quad.uvA, ub = quad.uvB;
      // Corners in quad-winding order lt, rt, lb, rb — each carries its own
      // colour + rate so the 4-corner gradient falls out of interpolation.
      fp = _writePcVertex(
          verts, fp, c[0], c[1], ua[0] * invW, ua[1] * invH, pc.lt, pc.coef, mask);
      fp = _writePcVertex(
          verts, fp, c[2], c[3], ua[2] * invW, ua[3] * invH, pc.rt, pc.coef, mask);
      fp = _writePcVertex(
          verts, fp, c[4], c[5], ub[0] * invW, ub[1] * invH, pc.lb, pc.coef, mask);
      fp = _writePcVertex(
          verts, fp, c[6], c[7], ub[2] * invW, ub[3] * invH, pc.rb, pc.coef, mask);
      final o = quad.center;
      fp = _writeFanCentre(
          verts, fp, partColorStride, o[0], o[1], o[2] * invW, o[3] * invH);
      for (final q in fanIndices) {
        indices[ip++] = vBase + q;
      }
      vBase += _fanVertices;
    }
    if (vBase == 0) return null;
    return InterleavedGeometry(
      Float32List.view(verts.buffer, verts.offsetInBytes, fp),
      Uint16List.view(indices.buffer, indices.offsetInBytes, ip),
      vBase,
      ip,
    );
  }

  /// Floats per vertex in the integration-shader bake
  /// ([buildSsShaderInterleaved]) — 12 floats = 48 bytes, every `vec4` attribute
  /// on a 16-byte boundary (and the stride itself a multiple of 16) so Impeller
  /// reads them correctly. Layout matches `shaders/gpu/ssshader.vert`:
  /// `[pos.xy, uv.xy, color.rgba, coef.xyz+rate]`.
  static const int ssShaderStride = 12;

  /// Interleaved flutter_gpu bake of ONE `SHDR` shader part's [quad] — the feed
  /// for the `SsShaderVertex/Fragment` pipeline.
  ///
  /// The [buildPartColorInterleaved] layout minus the mask-replay attributes
  /// (shader × mask is not combined — a masked part drops its shader), and
  /// single-part rather than a run: the effect's parameters are a per-part
  /// uniform block, so there is nothing to batch across parts.
  ///
  /// The caller supplies the [quad] it already built (it needs
  /// [PartColorQuad.cellRect] for the same draw) and the *effective* [pc] — the
  /// part's own PartColor scaled by the instance chain, or
  /// [PartColor.passthrough] when it has none. Views alias scratch — consume
  /// before the next bake.
  InterleavedGeometry? buildSsShaderInterleaved(PartColorQuad quad, PartColor pc,
      {required double texWidth, required double texHeight}) {
    final verts = _inter(_fanVertices * ssShaderStride);
    final indices = _idx(fanIndices.length);
    final invW = texWidth > 0 ? 1.0 / texWidth : 0.0;
    final invH = texHeight > 0 ? 1.0 / texHeight : 0.0;

    final c = quad.corners, ua = quad.uvA, ub = quad.uvB;
    var fp = 0;
    // Corners in quad-winding order lt, rt, lb, rb — each carries its own colour
    // + rate so the 4-corner gradient falls out of interpolation.
    fp = _writeSsVertex(
        verts, fp, c[0], c[1], ua[0] * invW, ua[1] * invH, pc.lt, pc.coef);
    fp = _writeSsVertex(
        verts, fp, c[2], c[3], ua[2] * invW, ua[3] * invH, pc.rt, pc.coef);
    fp = _writeSsVertex(
        verts, fp, c[4], c[5], ub[0] * invW, ub[1] * invH, pc.lb, pc.coef);
    fp = _writeSsVertex(
        verts, fp, c[6], c[7], ub[2] * invW, ub[3] * invH, pc.rb, pc.coef);
    final o = quad.center;
    fp = _writeFanCentre(
        verts, fp, ssShaderStride, o[0], o[1], o[2] * invW, o[3] * invH);
    var ip = 0;
    for (final q in fanIndices) {
      indices[ip++] = q;
    }
    return InterleavedGeometry(
      Float32List.view(verts.buffer, verts.offsetInBytes, fp),
      Uint16List.view(indices.buffer, indices.offsetInBytes, ip),
      _fanVertices,
      ip,
    );
  }

  /// Writes one integration-shader vertex ([ssShaderStride] floats) at [fp] and
  /// returns the next cursor. ALL 12 floats are written every call, so no stale
  /// scratch leaks through.
  static int _writeSsVertex(Float32List v, int fp, double x, double y, double u,
      double vv, PartColorCorner col, List<double> coef) {
    v[fp] = x; // a_position
    v[fp + 1] = y;
    v[fp + 2] = u; // a_uv (normalised)
    v[fp + 3] = vv;
    v[fp + 4] = col.r; // a_color (straight)
    v[fp + 5] = col.g;
    v[fp + 6] = col.b;
    v[fp + 7] = col.a;
    v[fp + 8] = coef[0]; // a_coef.xyz + rate
    v[fp + 9] = coef[1];
    v[fp + 10] = coef[2];
    v[fp + 11] = col.rate;
    return fp + ssShaderStride;
  }

  /// Writes a fan's centre vertex at [fp], after the four corners the previous
  /// four [stride]-float vertices hold, and returns the next cursor: position
  /// and UV from [x]/[y]/[u]/[vv], colour and rate the corners' average, and
  /// every other lane (the blend coefficients, a mask replay) copied from the
  /// last corner, which shares them. Both the [partColorStride] and the
  /// [ssShaderStride] layout keep colour in lanes 4–7 and rate in lane 11.
  static int _writeFanCentre(Float32List v, int fp, int stride, double x,
      double y, double u, double vv) {
    v.setRange(fp, fp + stride, v, fp - stride);
    v[fp] = x;
    v[fp + 1] = y;
    v[fp + 2] = u;
    v[fp + 3] = vv;
    for (var lane = 4; lane < 8; lane++) {
      v[fp + lane] = _cornerMean(v, fp, stride, lane);
    }
    v[fp + 11] = _cornerMean(v, fp, stride, 11);
    return fp + stride;
  }

  /// The mean of [lane] over the four [stride]-float vertices before [fp].
  static double _cornerMean(Float32List v, int fp, int stride, int lane) =>
      (v[fp - 4 * stride + lane] +
          v[fp - 3 * stride + lane] +
          v[fp - 2 * stride + lane] +
          v[fp - stride + lane]) *
      0.25;

  /// Interleaved flutter_gpu bake of *peeled* mesh [parts] — the mesh sibling of
  /// [buildPartColorInterleaved], for a mesh part carrying PartColor and/or
  /// a mask test. Feeds the **same** `PartColorVertex/Fragment` pipeline in
  /// the same [partColorStride]-float layout, which needs no mesh-specific shader:
  ///
  ///  * **Whole-only** (Mesh = same value on every vertex): every vertex carries the `lt`
  ///    corner's colour + rate, so there is no gradient to reconstruct.
  ///  * the mask replay samples the coverage through the `v_local` varying, and a
  ///    mesh vertex is already player-local world-space — the same space the
  ///    peeled quad corners are in.
  ///
  /// [pcs] / [masks] are parallel to [parts] (`pcs[i]` / `masks[i]` describe
  /// `parts[i]`; `masks[i]` null = unmasked). Views alias scratch — consume
  /// before the next bake.
  InterleavedGeometry? buildMeshPartColorInterleaved(List<int> parts,
      List<PartColor> pcs, List<Float32List?> masks, DrawFrame frame,
      {required double texWidth, required double texHeight}) {
    final mesh = frame.mesh;
    if (mesh == null || mesh.isEmpty || parts.isEmpty) return null;

    var vTotal = 0;
    var iTotal = 0;
    for (final p in parts) {
      final vr = mesh.vertexRange(p);
      final ir = mesh.indexRange(p);
      if (vr == null || ir == null) continue;
      vTotal += vr.$2 - vr.$1;
      iTotal += ir.$2 - ir.$1;
    }
    if (vTotal == 0 || iTotal == 0 || vTotal > 0xFFFF) return null;

    final verts = _inter(vTotal * partColorStride);
    final indices = _idx(iTotal);
    final invW = texWidth > 0 ? 1.0 / texWidth : 0.0;
    final invH = texHeight > 0 ? 1.0 / texHeight : 0.0;

    var vBase = 0;
    var fp = 0;
    var ip = 0;
    for (var slot = 0; slot < parts.length; slot++) {
      final p = parts[slot];
      final vr = mesh.vertexRange(p);
      final ir = mesh.indexRange(p);
      if (vr == null || ir == null) continue;
      final pc = pcs[slot];
      final mask = masks[slot];
      // Whole-only: the lt corner (colour + rate) applies to every vertex.
      for (var v = vr.$1; v < vr.$2; v++) {
        fp = _writePcVertex(verts, fp, mesh.x[v], mesh.y[v],
            mesh.uv[v * 2] * invW, mesh.uv[v * 2 + 1] * invH, pc.lt, pc.coef, mask);
      }
      final vCount = vr.$2 - vr.$1;
      for (var i = ir.$1; i < ir.$2; i++) {
        final local = mesh.indices[i];
        if (local < 0 || local >= vCount) continue;
        indices[ip++] = vBase + local;
      }
      vBase += vCount;
    }
    if (vBase == 0 || ip == 0) return null;
    return InterleavedGeometry(
      Float32List.view(verts.buffer, verts.offsetInBytes, fp),
      Uint16List.view(indices.buffer, indices.offsetInBytes, ip),
      vBase,
      ip,
    );
  }

  /// Interleaved flutter_gpu bake of shape [parts] — the GPU sibling of
  /// [buildShapeParts]. A Shape samples no texture, so UV is `(0,0)` (the caller
  /// binds a 1×1 white texel and the `texel * colour` shader collapses to the
  /// colour). Per-vertex colour is baked here — plain = premultiplied white×alpha,
  /// PartColor = the bilinear box-coord gradient, premultiplied — so a
  /// PartColored Shape needs no shader on the GPU path (only a *mask-target*
  /// shape does, which is peeled later). Center-first fan. Returns null when empty.
  InterleavedGeometry? buildShapeInterleaved(List<int> parts, DrawFrame frame) {
    final shape = frame.shape;
    if (shape == null || parts.isEmpty) return null;

    var vTotal = 0;
    var iTotal = 0;
    for (final p in parts) {
      final n = shape.countOf(p);
      if (n == 0) continue;
      vTotal += n;
      iTotal += (n - 2) * 3;
    }
    if (vTotal == 0 || iTotal == 0 || vTotal > 0xFFFF) return null;

    final verts = _inter(vTotal * 8);
    final indices = _idx(iTotal);
    final partsColor = frame.partsColor;

    var fp = 0;
    var ip = 0;
    var base = 0;
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
      final tinted = pc?.scaleAlpha(frame.alphaScale);
      final plainA = frame.alphaOf(p); // premult white×alpha = (a,a,a,a)

      final o = p * ShapeBuffers.stride;
      for (var v = 0; v < n; v++) {
        final lx = shape.vertices[o + 2 * v];
        final ly = shape.vertices[o + 2 * v + 1];
        verts[fp] = m0 * lx + m4 * ly + m12;
        verts[fp + 1] = m1 * lx + m5 * ly + m13;
        verts[fp + 2] = 0.0;
        verts[fp + 3] = 0.0;

        double r, g, b, a;
        if (tinted == null) {
          r = plainA;
          g = plainA;
          b = plainA;
          a = plainA;
        } else {
          final fx = shape.boxCoords[o + 2 * v];
          final fy = shape.boxCoords[o + 2 * v + 1];
          final wLT = (1.0 - fx) * (1.0 - fy);
          final wRT = fx * (1.0 - fy);
          final wLB = (1.0 - fx) * fy;
          final wRB = fx * fy;
          final sr = tinted.lt.r * wLT +
              tinted.rt.r * wRT +
              tinted.lb.r * wLB +
              tinted.rb.r * wRB;
          final sg = tinted.lt.g * wLT +
              tinted.rt.g * wRT +
              tinted.lb.g * wLB +
              tinted.rb.g * wRB;
          final sb = tinted.lt.b * wLT +
              tinted.rt.b * wRT +
              tinted.lb.b * wLB +
              tinted.rb.b * wRB;
          final sa = tinted.lt.a * wLT +
              tinted.rt.a * wRT +
              tinted.lb.a * wLB +
              tinted.rb.a * wRB;
          // Straight → premultiplied (Skia premultiplies the Canvas vertex
          // colour before the white-paint modulate, so the drawn colour is this).
          a = sa.clamp(0.0, 1.0);
          r = (sr * sa).clamp(0.0, 1.0);
          g = (sg * sa).clamp(0.0, 1.0);
          b = (sb * sa).clamp(0.0, 1.0);
        }
        verts[fp + 4] = r;
        verts[fp + 5] = g;
        verts[fp + 6] = b;
        verts[fp + 7] = a;
        fp += 8;
      }
      for (var t = 0; t < n - 2; t++) {
        indices[ip++] = base;
        indices[ip++] = base + t + 1;
        indices[ip++] = base + t + 2;
      }
      base += n;
    }
    if (base == 0 || ip == 0) return null;
    return InterleavedGeometry(
      Float32List.view(verts.buffer, verts.offsetInBytes, fp),
      Uint16List.view(indices.buffer, indices.offsetInBytes, ip),
      base,
      ip,
    );
  }

  /// Like [buildShapeInterleaved] but for a **masked** Shape — the vertex is
  /// `[pos.xy, local.xy, rgba]` (8 floats), mirroring the sprite pipeline's
  /// working layout. The middle slot repeats the player-local position (which the
  /// shader genuinely uses as `v_local` for the mask UV) so `a_color` (a `vec4`)
  /// lands at byte offset 16 — the alignment Impeller expects for a vertex
  /// `vec4`. A tighter `[pos.xy, rgba]` (6-float) layout puts `a_color` at offset
  /// 8, which the GPU misreads as position bytes and renders white; a *dummy*
  /// padding attribute would instead be stripped by impellerc (breaking
  /// reflection), so the pad must carry real, used data (see
  /// `shaders/gpu/shapemask.vert`). Premultiplied colour, center-first fan.
  /// Returns null if empty.
  InterleavedGeometry? buildShapeColorInterleaved(
      List<int> parts, DrawFrame frame) {
    final shape = frame.shape;
    if (shape == null || parts.isEmpty) return null;

    var vTotal = 0;
    var iTotal = 0;
    for (final p in parts) {
      final n = shape.countOf(p);
      if (n == 0) continue;
      vTotal += n;
      iTotal += (n - 2) * 3;
    }
    if (vTotal == 0 || iTotal == 0 || vTotal > 0xFFFF) return null;

    final verts = _inter(vTotal * 8);
    final indices = _idx(iTotal);
    final partsColor = frame.partsColor;

    var fp = 0;
    var ip = 0;
    var base = 0;
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
      final tinted = pc?.scaleAlpha(frame.alphaScale);
      final plainA = frame.alphaOf(p);

      final o = p * ShapeBuffers.stride;
      for (var v = 0; v < n; v++) {
        final lx = shape.vertices[o + 2 * v];
        final ly = shape.vertices[o + 2 * v + 1];
        final wx = m0 * lx + m4 * ly + m12;
        final wy = m1 * lx + m5 * ly + m13;
        verts[fp] = wx;
        verts[fp + 1] = wy;
        verts[fp + 2] = wx; // a_local: player-local pos again (v_local for the mask)
        verts[fp + 3] = wy;

        double r, g, b, a;
        if (tinted == null) {
          r = plainA;
          g = plainA;
          b = plainA;
          a = plainA;
        } else {
          final fx = shape.boxCoords[o + 2 * v];
          final fy = shape.boxCoords[o + 2 * v + 1];
          final wLT = (1.0 - fx) * (1.0 - fy);
          final wRT = fx * (1.0 - fy);
          final wLB = (1.0 - fx) * fy;
          final wRB = fx * fy;
          final sr = tinted.lt.r * wLT +
              tinted.rt.r * wRT +
              tinted.lb.r * wLB +
              tinted.rb.r * wRB;
          final sg = tinted.lt.g * wLT +
              tinted.rt.g * wRT +
              tinted.lb.g * wLB +
              tinted.rb.g * wRB;
          final sb = tinted.lt.b * wLT +
              tinted.rt.b * wRT +
              tinted.lb.b * wLB +
              tinted.rb.b * wRB;
          final sa = tinted.lt.a * wLT +
              tinted.rt.a * wRT +
              tinted.lb.a * wLB +
              tinted.rb.a * wRB;
          a = sa.clamp(0.0, 1.0);
          r = (sr * sa).clamp(0.0, 1.0);
          g = (sg * sa).clamp(0.0, 1.0);
          b = (sb * sa).clamp(0.0, 1.0);
        }
        verts[fp + 4] = r;
        verts[fp + 5] = g;
        verts[fp + 6] = b;
        verts[fp + 7] = a;
        fp += 8;
      }
      for (var t = 0; t < n - 2; t++) {
        indices[ip++] = base;
        indices[ip++] = base + t + 1;
        indices[ip++] = base + t + 2;
      }
      base += n;
    }
    if (base == 0 || ip == 0) return null;
    return InterleavedGeometry(
      Float32List.view(verts.buffer, verts.offsetInBytes, fp),
      Uint16List.view(indices.buffer, indices.offsetInBytes, ip),
      base,
      ip,
    );
  }

  /// Bakes the given mesh [parts] into a single indexed [ui.Vertices].
  ///
  /// Thin wrapper over [buildMeshGeometry] — see it for the contract. Returns
  /// null when nothing was emitted.
  ui.Vertices? buildMeshParts(List<int> parts, DrawFrame frame) =>
      buildMeshGeometry(parts, frame)?.toVertices();

  /// Bakes the given mesh [parts] (part indices, already in draw order) into
  /// raw vertex arrays.
  ///
  /// Much simpler than the Normal path: the Brain hands over **world-space**
  /// vertices, so there is no matrix to apply — the SoA X/Y are interleaved into
  /// positions, the texture-pixel UVs are copied as-is (Flutter's identity
  /// `ImageShader` samples in image pixels, so they need no normalising), each
  /// vertex takes white × the part's hierarchical alpha, and the part-local
  /// indices are rebased onto the emitted vertex block — a Mesh `DrawBatch` is
  /// batchable and may carry several parts, so the rebase is load-bearing.
  ///
  /// [alphaOverride] replaces that per-part hierarchical alpha for every vertex.
  /// It is the PartColor case: with a tint the Brain has pre-folded the
  /// hierarchical alpha into the corner alphas, so `PartState.alpha` must NOT be
  /// used as well (the two multiplied would double-apply it); the caller
  /// passes `pc.lt.a` instead. Mesh is whole-only, so one value covers the part.
  ///
  /// Returns null when nothing was emitted. Split out from [buildMeshParts] so
  /// the bake is inspectable (a `ui.Vertices` is opaque) — the "already
  /// world-space" invariant is the one thing worth pinning down in a test.
  MeshGeometry? buildMeshGeometry(List<int> parts, DrawFrame frame,
      {double? alphaOverride}) {
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

    _vAt = 0;
    _iAt = 0;
    for (final p in parts) {
      _writeMesh(p, mesh, alphaOverride ?? frame.alphaOf(p), positions,
          texCoords, colors, indices);
    }
    return _bakedGeometry(positions, texCoords, colors, indices);
  }

  /// Writes Mesh part [p] at the bake's cursors (see [buildMeshGeometry]),
  /// white × [alpha]. A part with no mesh range writes nothing.
  void _writeMesh(int p, MeshBuffers mesh, double alpha, Float32List positions,
      Float32List texCoords, Int32List colors, Uint16List indices) {
    final vr = mesh.vertexRange(p);
    final ir = mesh.indexRange(p);
    if (vr == null || ir == null) return;

    final color =
        ((alpha.clamp(0.0, 1.0) * 255).round() & 0xFF) << 24 | 0x00FFFFFF;

    final vBase = _vAt; // the index rebase
    var fPos = vBase * 2;
    var cPos = vBase;
    var iPos = _iAt;
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
    _vAt = vBase + vCount;
    _iAt = iPos;
  }

  /// Bakes one `EffectDrawCommand`'s particle quads into a vertex block —
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
  /// into ONE vertex block, so the caller draws the whole group with a
  /// single `drawVertices` instead of one per command.
  /// [cmds] must be same-cellmap / same-blend and in draw
  /// order; [SpriteStudioInternalPlayer] groups them, capping each group so its
  /// vertices stay within the 16-bit index limit.
  ///
  /// Each command slices the plan's flat buffers at its own `particle_offset`
  /// (in quads) with each buffer's stride; a command's indices are 0-based
  /// *within that command*, so the group rebases them onto the running vertex
  /// base (a single command rebases by 0). Two
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
    final totalQuads = _effectQuads(cmds);
    if (totalQuads == 0 || totalQuads * 4 > 0xFFFF) return null;

    final positions = _pos(totalQuads * 4 * 2);
    final texCoords = _uvs(totalQuads * 4 * 2);
    final colors = _cols(totalQuads * 4);
    final indices = _idx(totalQuads * 6);

    _vAt = 0;
    _iAt = 0;
    _writeEffectCommands(plan, cmds, 0, cmds.length, part, frame, texWidth,
        texHeight, positions, texCoords, colors, indices);
    return _bakedGeometry(positions, texCoords, colors, indices);
  }

  /// Bakes a group that runs on across effect parts — what a span of Effect
  /// batches draws as one `drawVertices`: [buildEffectGroup] for commands of
  /// several plans. [plans] and [parts] run parallel to [cmds] and say whose
  /// plan and part each command is; each command is written exactly as
  /// [buildEffectGroup] writes it, under its own part's world matrix and alpha.
  /// Returns null when nothing was emitted.
  MeshGeometry? buildEffectRun(
    List<efbs.EffectDrawPlan> plans,
    List<efbs.EffectDrawCommand> cmds,
    List<int> parts,
    DrawFrame frame, {
    required double texWidth,
    required double texHeight,
  }) {
    final totalQuads = _effectQuads(cmds);
    if (totalQuads == 0 || totalQuads * 4 > 0xFFFF) return null;

    final positions = _pos(totalQuads * 4 * 2);
    final texCoords = _uvs(totalQuads * 4 * 2);
    final colors = _cols(totalQuads * 4);
    final indices = _idx(totalQuads * 6);

    _vAt = 0;
    _iAt = 0;
    var from = 0;
    while (from < cmds.length) {
      final plan = plans[from];
      final part = parts[from];
      var to = from + 1;
      while (to < cmds.length &&
          identical(plans[to], plan) &&
          parts[to] == part) {
        to++;
      }
      _writeEffectCommands(plan, cmds, from, to, part, frame, texWidth,
          texHeight, positions, texCoords, colors, indices);
      from = to;
    }
    return _bakedGeometry(positions, texCoords, colors, indices);
  }

  /// The quads [cmds] hold: an upper bound on what a group bakes, which skips
  /// a corrupt command.
  static int _effectQuads(List<efbs.EffectDrawCommand> cmds) {
    var quads = 0;
    for (var i = 0; i < cmds.length; i++) {
      quads += cmds[i].quadCount;
    }
    return quads;
  }

  /// Writes `cmds[from, to)`, all of [plan] on effect part [part], at the
  /// bake's cursors (see [buildEffectGroup]). Nothing is written when the
  /// plan's buffers are missing or the part is outside the SoA.
  void _writeEffectCommands(
      efbs.EffectDrawPlan plan,
      List<efbs.EffectDrawCommand> cmds,
      int from,
      int to,
      int part,
      DrawFrame frame,
      double texWidth,
      double texHeight,
      Float32List positions,
      Float32List texCoords,
      Int32List colors,
      Uint16List indices) {
    final typed = EffectPlanArrays.of(plan);
    final Float32List verts, uvs, planColors;
    final Int32List planIndices;
    if (typed != null) {
      verts = typed.verts;
      uvs = typed.uvs;
      planColors = typed.colors;
      planIndices = typed.indices;
    } else {
      final v = plan.verts, u = plan.uvs, c = plan.colors, x = plan.indices;
      if (v == null || u == null || c == null || x == null) return;
      verts = Float32List.fromList(v);
      uvs = Float32List.fromList(u);
      planColors = Float32List.fromList(c);
      planIndices = Int32List.fromList(x);
    }
    final stride = plan.vertStride == 3 ? 3 : 2;

    final m = part * DrawFrame.worldStride;
    if (m + 16 > frame.world.length) return;
    final world = frame.world;
    final m0 = world[m], m1 = world[m + 1];
    final m4 = world[m + 4], m5 = world[m + 5];
    final m12 = world[m + 12], m13 = world[m + 13];

    // The particle colours already carry the emitter's own alpha; fold the
    // part's hierarchical alpha in on top (the slot never sees it).
    final partAlpha = frame.alphaOf(part);

    var vBase = _vAt; // running vertex base — the per-command index rebase
    var fPos = vBase * 2, cPos = vBase, iPos = _iAt;
    for (var at = from; at < to; at++) {
      final cmd = cmds[at];
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
    _vAt = vBase;
    _iAt = iPos;
  }

  /// Interleaved flutter_gpu bake of an effect command group — the GPU
  /// sibling of [buildEffectGroup]. Reuses that bake (world transform, per-command
  /// index rebase, colour fold) and repacks its output: UVs back to **normalised**
  /// 0..1 (the Canvas path scales them to texture pixels for the identity
  /// ImageShader; the GPU sampler wants normalised), and the straight ARGB colour
  /// premultiplied. Returns null when nothing was emitted.
  InterleavedGeometry? buildEffectGroupInterleaved(
    efbs.EffectDrawPlan plan,
    List<efbs.EffectDrawCommand> cmds,
    int part,
    DrawFrame frame, {
    required double texWidth,
    required double texHeight,
  }) {
    final g = buildEffectGroup(plan, cmds, part, frame,
        texWidth: texWidth, texHeight: texHeight);
    return g == null ? null : _effectInterleaved(g, texWidth, texHeight);
  }

  /// The flutter_gpu sibling of [buildEffectRun], repacked as
  /// [buildEffectGroupInterleaved] repacks [buildEffectGroup].
  InterleavedGeometry? buildEffectRunInterleaved(
    List<efbs.EffectDrawPlan> plans,
    List<efbs.EffectDrawCommand> cmds,
    List<int> parts,
    DrawFrame frame, {
    required double texWidth,
    required double texHeight,
  }) {
    final g = buildEffectRun(plans, cmds, parts, frame,
        texWidth: texWidth, texHeight: texHeight);
    return g == null ? null : _effectInterleaved(g, texWidth, texHeight);
  }

  InterleavedGeometry? _effectInterleaved(
      MeshGeometry g, double texWidth, double texHeight) {
    final tc = g.texCoords;
    if (tc == null) return null; // an effect group always has UVs
    final cols = g.colors;

    final n = g.positions.length ~/ 2; // vertex count
    final verts = _inter(n * 8);
    final invW = texWidth > 0 ? 1.0 / texWidth : 0.0;
    final invH = texHeight > 0 ? 1.0 / texHeight : 0.0;

    var fp = 0;
    for (var i = 0; i < n; i++) {
      verts[fp] = g.positions[i * 2];
      verts[fp + 1] = g.positions[i * 2 + 1];
      verts[fp + 2] = tc[i * 2] * invW; // texture-pixel → normalised
      verts[fp + 3] = tc[i * 2 + 1] * invH;
      final argb = cols[i];
      final a = ((argb >> 24) & 0xFF) / 255.0;
      final r = ((argb >> 16) & 0xFF) / 255.0;
      final gg = ((argb >> 8) & 0xFF) / 255.0;
      final b = (argb & 0xFF) / 255.0;
      verts[fp + 4] = r * a; // straight → premultiplied
      verts[fp + 5] = gg * a;
      verts[fp + 6] = b * a;
      verts[fp + 7] = a;
      fp += 8;
    }
    // g.indices is already a rebased 16-bit view (over a different scratch cell),
    // so it is carried through unchanged.
    return InterleavedGeometry(
      Float32List.view(verts.buffer, verts.offsetInBytes, fp),
      g.indices,
      n,
      g.indices.length,
    );
  }

  /// The four world-transformed corners of part [part], 8 floats
  /// (`ltx,lty, rtx,rty, lbx,lby, rbx,rby`), or null when the part is outside
  /// the SoA (no geometry this frame).
  ///
  /// Shared by the PartColor quad and the mask coverage pass, which both need
  /// the same `x' = m0·x + m4·y + m12`, `y' = m1·x + m5·y + m13` transform.
  ///
  /// [out] is an optional scratch of at least 8 floats, with the same aliasing
  /// contract as [shapeWorldOutlineOf]'s.
  static Float32List? worldCornersOf(int part, DrawFrame frame,
      [Float32List? out]) {
    final world = frame.world;
    final local = frame.local;
    final m = part * DrawFrame.worldStride;
    final v = part * DrawFrame.vertexStride;
    if (m + 16 > world.length || v + 8 > local.length) return null;

    final m0 = world[m], m1 = world[m + 1];
    final m4 = world[m + 4], m5 = world[m + 5];
    final m12 = world[m + 12], m13 = world[m + 13];

    // World corners: lt=(0,1) rt=(2,3) lb=(4,5) rb=(6,7).
    final corners = _outlineBuf(out, 8);
    for (var c = 0; c < 4; c++) {
      final lx = local[v + c * 2];
      final ly = local[v + c * 2 + 1];
      corners[c * 2] = m0 * lx + m4 * ly + m12;
      corners[c * 2 + 1] = m1 * lx + m5 * ly + m13;
    }
    // Exact length: [out] may be a buffer a longer outline grew, and a caller
    // that walks `.length` (MaskPlan's bbox fold) must not see its stale tail.
    return _outlineView(corners, 8);
  }

  /// Bakes Shape parts into one indexed vertex block, or null when none of
  /// them has geometry this frame.
  ///
  /// A Shape is the Normal path's geometry rules with the Mesh path's batching:
  /// vertices are **local** and get the world matrix (Mesh's are already world),
  /// and several parts concatenate into one draw, so each part's fan indices are
  /// rebased onto its vertex base.
  ///
  /// The colour is the whole story here, and it is the one place PartColor does
  /// **not** go through the shader (a shape bypasses the composite formula):
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
    if (vTotal == 0 || iTotal == 0 || vTotal > 0xFFFF) return null;

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
      // No PartColor → white at the part's alpha, which also
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

    // Zero-copy views (see `_bakedGeometry`).
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
  ///
  /// [out] is an optional grow-only scratch; when it is supplied and big enough
  /// the result is a **view into it**, valid only until the next call that
  /// shares it.
  static Float32List? shapeWorldOutlineOf(int part, DrawFrame frame,
      [Float32List? out]) {
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

    final buf = _outlineBuf(out, n * 2);
    for (var v = 0; v < n; v++) {
      final lx = shape.vertices[o + 2 * v];
      final ly = shape.vertices[o + 2 * v + 1];
      buf[v * 2] = m0 * lx + m4 * ly + m12;
      buf[v * 2 + 1] = m1 * lx + m5 * ly + m13;
    }
    return _outlineView(buf, n * 2);
  }

  /// Backing store for an outline of [need] floats: [out] when it is big enough
  /// (grow-only scratch), a fresh buffer otherwise.
  static Float32List _outlineBuf(Float32List? out, int need) =>
      (out != null && out.length >= need) ? out : Float32List(need);

  /// [buf]'s first [need] floats. A view rather than the buffer itself so a
  /// caller's `outline.length` still bounds the real data when [buf] is an
  /// oversized scratch — the view object is the only allocation left.
  static Float32List _outlineView(Float32List buf, int need) =>
      buf.length == need
          ? buf
          : Float32List.view(buf.buffer, buf.offsetInBytes, need);

  /// Part [part]'s mesh vertices in world space, interleaved `[x,y,…]`, or null
  /// when it has no *drawable* mesh geometry this frame. Mesh SoA is already
  /// world-space so this is a straight copy — used for the coverage bbox of
  /// a mesh clipping writer. Requires a triangle-bearing index range too, so
  /// the mask planner reserves a coverage bit only for a writer
  /// `_renderCoverage` can actually rasterise (else a vertex-only part would
  /// fold phantom verts into the bbox yet write nothing — an inert bit).
  ///
  /// [out] is an optional grow-only scratch, with the same aliasing contract as
  /// [shapeWorldOutlineOf]'s.
  static Float32List? meshWorldOutlineOf(int part, DrawFrame frame,
      [Float32List? out]) {
    final mesh = frame.mesh;
    if (mesh == null) return null;
    final vr = mesh.vertexRange(part);
    final ir = mesh.indexRange(part);
    if (vr == null || ir == null) return null;
    final n = vr.$2 - vr.$1;
    if (n <= 0 || ir.$2 - ir.$1 < 3) return null; // no vertices / no triangle
    final buf = _outlineBuf(out, n * 2);
    for (var v = 0; v < n; v++) {
      buf[v * 2] = mesh.x[vr.$1 + v];
      buf[v * 2 + 1] = mesh.y[vr.$1 + v];
    }
    return _outlineView(buf, n * 2);
  }

  static int _argb(double r, double g, double b, double a) {
    int ch(double v) => (v.clamp(0.0, 1.0) * 255.0).round();
    return (ch(a) << 24) | (ch(r) << 16) | (ch(g) << 8) | ch(b);
  }

  /// Part [part]'s world matrix as a `Canvas.transform` matrix, or null when the
  /// part is outside the SoA.
  ///
  /// Used by Instance to place a child animation, which — unlike every
  /// other kind — is transformed by the *canvas* rather than by baking vertices.
  ///
  /// Only the 2D affine (`m0, m1, m4, m5, m12, m13`) is carried over, with an
  /// identity Z row, rather than copying the Brain's 4×4 wholesale. Both are
  /// column-major and the six values even land on the same indices, but the
  /// source matrix's Z/W rows are not part of the contract this Body reads
  /// anywhere else — [worldCornersOf] uses exactly these six — and letting a
  /// stray Z scale or perspective term through `Canvas.transform` would silently
  /// distort the whole child subtree.
  ///
  /// [out] is an optional 16-element scratch to write into (fully overwritten,
  /// zeros included) — valid only until the next call that shares it.
  static Float64List? world2dOf(int part, DrawFrame frame, [Float64List? out]) {
    final world = frame.world;
    final m = part * DrawFrame.worldStride;
    if (m + 16 > world.length) return null;
    final r = out ?? Float64List(16);
    // Every slot is written, not just the six that carry data: a recycled
    // scratch must not keep the previous part's Z/W row.
    r[0] = world[m]; // m0
    r[1] = world[m + 1]; // m1
    r[2] = 0.0;
    r[3] = 0.0;
    r[4] = world[m + 4]; // m4
    r[5] = world[m + 5]; // m5
    r[6] = 0.0;
    r[7] = 0.0;
    r[8] = 0.0;
    r[9] = 0.0;
    r[10] = 1.0;
    r[11] = 0.0;
    r[12] = world[m + 12]; // m12 (tx)
    r[13] = world[m + 13]; // m13 (ty)
    r[14] = 0.0;
    r[15] = 1.0;
    return r;
  }

  /// Builds the world quad + frag→`(s,t)` affine for part [part]'s PartColor
  /// shader draw. Transforms the four local corners
  /// (`lt,rt,lb,rb`) by the world matrix, takes `du = rt-lt`, `dv = lb-lt`, and
  /// inverts `[du dv]` so the shader can recover quad-local coordinates from a
  /// fragment position.
  ///
  /// Returns null when the SoA is out of range or the quad is degenerate
  /// (`|det| ~ 0`, e.g. a zero-size part) — nothing visible to draw. Assumes a
  /// non-deformed (affine) quad: on a vertex-deformed part (`AttributeVertex`) the
  /// outline is right but the texture inside it is mapped as if undeformed.
  ///
  /// **Aliases scratch** — every call refills and returns the SAME
  /// [PartColorQuad] (and the same backing `Float32List`s), so consume it before
  /// the next call on this builder. Note [buildPartColorInterleaved] calls this
  /// per part, so a quad must not be held across one.
  PartColorQuad? buildPartColorQuad(int part, DrawFrame frame) {
    final uv = frame.uv;
    final local = frame.local;
    final world = frame.world;
    final v = part * DrawFrame.vertexStride;
    final corners = worldCornersOf(part, frame, _quadCorners);
    if (corners == null || v + 10 > uv.length || v + 10 > local.length) {
      return null;
    }

    final ltx = corners[0], lty = corners[1];
    // du = rt - lt (s-axis), dv = lb - lt (t-axis).
    final dux = corners[2] - ltx, duy = corners[3] - lty;
    final dvx = corners[4] - ltx, dvy = corners[5] - lty;
    final det = dux * dvy - dvx * duy;
    if (det.abs() < 1e-6) return null; // degenerate quad — nothing to draw

    final invDet = 1.0 / det;
    // [s;t] = inv([du dv]) · (frag - lt).
    _quadInv[0] = dvy * invDet;
    _quadInv[1] = -dvx * invDet;
    _quadInv[2] = -duy * invDet;
    _quadInv[3] = dux * invDet;

    _quadUvA[0] = uv[v];
    _quadUvA[1] = uv[v + 1];
    _quadUvA[2] = uv[v + 2];
    _quadUvA[3] = uv[v + 3];

    _quadUvB[0] = uv[v + 4];
    _quadUvB[1] = uv[v + 5];
    _quadUvB[2] = uv[v + 6];
    _quadUvB[3] = uv[v + 7];

    final m = part * DrawFrame.worldStride;
    final cx = local[v + 8], cy = local[v + 9];
    _quadCenter[0] = world[m] * cx + world[m + 4] * cy + world[m + 12];
    _quadCenter[1] = world[m + 1] * cx + world[m + 5] * cy + world[m + 13];
    _quadCenter[2] = uv[v + 8];
    _quadCenter[3] = uv[v + 9];

    _quadScratch.originX = ltx;
    _quadScratch.originY = lty;
    return _quadScratch;
  }
}
