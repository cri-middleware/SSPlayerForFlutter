import 'dart:typed_data';
import 'dart:ui' as ui;

import '../ssab/framedata.g.dart' as fbs;

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
/// [fbs.PartState]; the `parts` vector is not guaranteed part-index ordered, so
/// the lookup is materialized once per frame. This is the seam where the §7D
/// raw-`ByteData` fast path — reading `PartState` / `parts_color` by byte offset
/// instead of via the FlatBuffers accessors — will slot in when it matters.
class DrawFrame {
  DrawFrame({
    required this.frameData,
    required this.drawOrder,
    required this.partByIndex,
    required this.world,
    required this.local,
    required this.uv,
  });

  /// Bundles the frame's FlatBuffers root with its SoA views. Returns null when
  /// the frame carries no drawable structure (`draw_order` / `parts` absent).
  static DrawFrame? build({
    required fbs.FrameData frameData,
    required Float32List world,
    required Float32List local,
    required Float32List uv,
  }) {
    final drawOrder = frameData.drawOrder;
    final parts = frameData.parts;
    if (drawOrder == null || parts == null) return null;
    return DrawFrame(
      frameData: frameData,
      drawOrder: drawOrder,
      partByIndex: <int, fbs.PartState>{
        for (final p in parts) p.partIndex: p,
      },
      world: world,
      local: local,
      uv: uv,
    );
  }

  final fbs.FrameData frameData;
  final List<int> drawOrder;
  final Map<int, fbs.PartState> partByIndex;
  final Float32List world; // parts × 16
  final Float32List local; // parts × 10 (lt,rt,lb,rb,center)
  final Float32List uv; // parts × 10 (texture-pixel space)

  /// Floats per part in each SoA buffer.
  static const int worldStride = 16;
  static const int vertexStride = 10; // local vertices and UVs share this

  /// The hierarchical alpha for part [partIndex], clamped to 0..1 (1 if the part
  /// is not present in the `parts` vector).
  double alphaOf(int partIndex) =>
      (partByIndex[partIndex]?.alpha ?? 1.0).clamp(0.0, 1.0);
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
class GeometryBuilder {
  /// Two triangles per quad: `lt,rt,lb,rb` → `{lt,rt,lb, rt,rb,lb}`.
  static const List<int> _quad = [0, 1, 2, 1, 3, 2];

  /// Bakes one Normal batch into a single indexed [ui.Vertices]: for each part
  /// in `draw_order[start_rank .. start_rank+count)`, transforms its 4 local
  /// corners (lt,rt,lb,rb) by the world matrix (`x'=m0·x+m4·y+m12`,
  /// `y'=m1·x+m5·y+m13`), copies the texture-pixel UVs as-is, sets each vertex
  /// color to white × part alpha, and appends the quad indices. Returns null
  /// when nothing was emitted.
  ui.Vertices? buildNormalBatch(fbs.DrawBatch batch, DrawFrame frame) {
    final count = batch.count;
    if (count == 0) return null;

    final start = batch.startRank;
    final drawOrder = frame.drawOrder;
    final world = frame.world;
    final local = frame.local;
    final uv = frame.uv;

    final positions = Float32List(count * 4 * 2); // 4 corners × (x,y)
    final texCoords = Float32List(count * 4 * 2);
    final colors = Int32List(count * 4);
    final indices = Uint16List(count * 6); // 2 triangles per quad

    var vBase = 0; // vertices emitted so far
    var fPos = 0; // float cursor into positions/texCoords
    var cPos = 0; // color cursor
    var iPos = 0; // index cursor

    for (var k = 0; k < count; k++) {
      final orderIdx = start + k;
      if (orderIdx >= drawOrder.length) break;
      final p = drawOrder[orderIdx];

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
    return ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions.sublist(0, fPos),
      textureCoordinates: texCoords.sublist(0, fPos),
      colors: colors.sublist(0, cPos),
      indices: indices.sublist(0, iPos),
    );
  }
}
