import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ssruntime_dart/framedata.dart' as fbs;

import '../geometry_builder.dart';
import '../mask.dart';
import '../mask_context.dart';
import 'render_host.dart';

/// The pixel-operation seam under L2 (design: keep the batch-loop / mask-plan /
/// instance-recursion control flow in the player, delegate only *drawing*).
///
/// Two implementations: `CanvasBackend` (dart:ui `Canvas.drawVertices` — the
/// default, the only Web path, and the visual-parity reference) and
/// `FlutterGpuBackend` (Impeller). Both end at the same `paint(canvas)` — the GPU
/// backend has no on-screen target and composites its render target back with
/// `canvas.drawImage` in [finish] — so the L2 `paint` signature never changes.
///
/// A backend instance is per-player but shared across the instance recursion:
/// [emitNormal] & friends take the [RenderHost] *per call* so a child's batches
/// draw through the same backend using the CHILD's host. The `canvas` is likewise
/// threaded per call (a child draws under the parent's `canvas.transform`).
abstract class RenderBackend {
  /// Begins a top-level frame — called only from the root `paint()`, never from
  /// the recursive `_paintTree`. Canvas: saves + translates the world origin to
  /// the centre of [dst]/[sourceSize]. GPU: allocates a render target + builds
  /// the ortho projection.
  void beginFrame(ui.Canvas canvas, {ui.Rect? dst, ui.Size? sourceSize});

  /// Ends the top-level frame. Canvas: restores. GPU: submits the command buffer
  /// and composites the render target onto [beginFrame]'s canvas.
  void finish();

  /// Rewinds the per-frame shader/scratch pools. Called **once per top-level
  /// frame**, before [beginFrame] — never per player: the pool hands out shader
  /// objects that a recorded picture reads at raster time, so rewinding it in
  /// the middle of a frame would let an instance child overwrite the uniforms of
  /// draws its parent has already recorded.
  void rewindShaderPools();

  /// Releases the previous frame's coverage resources (last frame's have been
  /// rasterised by now). Called **once per top-level frame**, before
  /// [beginFrame] — never per player, for the same reason: a masked parent's
  /// coverage must outlive its instance children's drawing.
  void releaseCoverage();

  /// Emits one Normal batch (§7/§9/§10), preserving draw order. Plain parts batch;
  /// parts with PartColor and/or a mask test are peeled (Canvas) or folded into
  /// per-vertex attributes (GPU, Phase 5).
  void emitNormal(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask);

  /// Emits one Shape batch (§11): per-vertex colour, mask targets peeled.
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask);

  /// Emits one Mesh batch (§8): world-space verts, one indexed draw. Parts
  /// carrying PartColor (§10, *whole-only* — the `lt` corner tints the whole
  /// part) and/or a mask test (§9) are peeled out of that draw, the same way
  /// [emitNormal] peels its own.
  void emitMesh(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, MaskContext? maskCtx, MaskDraw? inheritedMask);

  /// Emits one Effect batch (§8): the particle plans, grouped per cellmap+blend.
  void emitEffect(
      ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame, RenderHost host);

  /// Rasterises the mask writers' coverage for [plan] and returns the frame's
  /// [MaskContext], or null when nothing can be drawn yet (program still
  /// compiling) or no writer contributed. [textureByRank] maps each drawRank to
  /// its texture hash (writers take their texel from the batch that owns them).
  MaskContext? renderCoverage(DrawFrame frame, RenderHost host, MaskPlan plan,
      Map<int, int> textureByRank);

  /// Brackets an instance child's recursive draw (§8) with the child→parent
  /// world transform ([world], column-major 2D affine from `world2dOf`). Canvas:
  /// `canvas.save()` + `canvas.transform`. GPU: composes [world] into the current
  /// projection so the child's local geometry lands in place. The child draws
  /// through THIS backend (shared across the recursion) between the two calls.
  void pushTransform(ui.Canvas canvas, Float64List world);
  void popTransform(ui.Canvas canvas);

  /// Brackets an instance child's draw with a **group tint** — the PartColor
  /// (§10) carried by the instance part itself, applied to the whole sub-
  /// animation once it is composited (§8).
  ///
  /// [matrix] is the row-major 4×5 colour matrix from
  /// `PartColor.wholeTintMatrix` (an Instance part is whole-only, like a Mesh).
  /// Canvas: `saveLayer` with a `ColorFilter.matrix`. GPU: an offscreen pass the
  /// subtree draws into, composited back through the colour-matrix pipeline.
  /// Calls nest with [pushTransform]/[popTransform] and with each other.
  ///
  /// The tint is a *group* operation on purpose — one filter over the finished
  /// subtree — unlike alpha, which folds per-part down the chain
  /// (`DrawFrame.alphaScale`). Overlapping semi-transparent children therefore
  /// tint as a unit.
  void pushGroupTint(ui.Canvas canvas, List<double> matrix);
  void popGroupTint(ui.Canvas canvas);

  /// Releases backend-owned GPU/Canvas resources. Called from the player's
  /// `dispose()`.
  void dispose();
}
