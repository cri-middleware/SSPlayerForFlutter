import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ssruntime_dart/framedata.dart' as fbs;

import '../geometry_builder.dart';
import '../mask.dart';
import '../mask_context.dart';
import '../root_transform.dart';
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
/// [emitTextured] & friends take the [RenderHost] *per call* so a child's batches
/// draw through the same backend using the CHILD's host. The `canvas` is likewise
/// threaded per call (a child draws under the parent's `canvas.transform`).
abstract class RenderBackend {
  /// Invoked when a resource the backend was still preparing becomes usable, so
  /// the host can paint the frame again and pick it up.
  ///
  /// The GPU backend uploads textures asynchronously (`Image.toByteData`) and
  /// skips the parts using one until it lands. Without this hook that only
  /// resolves on the *next* paint, which a playing animation supplies and a
  /// paused, seeked or single-shot one never does — leaving it blank forever.
  /// Always fired outside the synchronous paint (after an await). No-op on
  /// Canvas, which prepares nothing asynchronously.
  set onResourcesReady(ui.VoidCallback? callback);

  /// Begins a top-level frame — called only from the root `paint()`, never from
  /// the recursive `_paintTree`. Canvas: saves + translates the world origin to
  /// the centre of [dst]/[sourceSize]. GPU: allocates a render target + builds
  /// the ortho projection.
  ///
  /// [root] is the player's flip / offset, which belongs here rather than in the
  /// geometry bake: both backends already carry a root transform (the centring
  /// translate / the ortho projection), so folding it in costs one composition
  /// instead of a term on every vertex — and it leaves the whole tree *below* it
  /// in player-local space, which is what keeps the mask coverage pass and the
  /// runtime-effect shaders (both of which work in that space) untouched.
  /// Instance children inherit it by construction: they draw through this same
  /// backend without ever beginning a frame of their own.
  void beginFrame(ui.Canvas canvas,
      {ui.Rect? dst,
      ui.Size? sourceSize,
      SsRootTransform root = SsRootTransform.identity});

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

  /// Emits the Normal and Mesh batches `batches[from, to)`, which share one
  /// texture and blend, preserving draw order.
  ///
  /// Plain parts draw as one run, and the run carries across the batch
  /// boundaries: the Brain cuts a batch wherever the part kind changes, though
  /// both kinds go through the same textured draw. Parts with PartColor, a
  /// mask test or an integration shader flush the run and keep their own
  /// kind's path — peeled (Canvas) or folded into per-vertex attributes
  /// (GPU). A Mesh part's PartColor is *whole-only*: the `lt` corner tints the
  /// whole part.
  void emitTextured(ui.Canvas canvas, List<fbs.DrawBatch> batches, int from,
      int to, DrawFrame frame, RenderHost host, PlayerMask masking);

  /// Emits one Shape batch: per-vertex colour, mask targets peeled.
  void emitShape(ui.Canvas canvas, fbs.DrawBatch batch, DrawFrame frame,
      RenderHost host, PlayerMask masking);

  /// Emits the Effect batches `batches[from, to)` — consecutive effect parts
  /// — in draw order: their particle plans' commands, grouped per
  /// cellmap+blend, and a group runs on from one part's plan into the next.
  void emitEffect(ui.Canvas canvas, List<fbs.DrawBatch> batches, int from,
      int to, DrawFrame frame, RenderHost host);

  /// Rasterises the mask writers' coverage for [plan] and returns the frame's
  /// [MaskContext], or null when nothing can be drawn yet (program still
  /// compiling) or no writer contributed. [textureByRank] maps each drawRank to
  /// its texture hash (writers take their texel from the batch that owns them).
  MaskContext? renderCoverage(DrawFrame frame, RenderHost host, MaskPlan plan,
      Map<int, int> textureByRank);

  /// Brackets an instance child's recursive draw with the child→parent
  /// world transform ([world], column-major 2D affine from `world2dOf`). Canvas:
  /// `canvas.save()` + `canvas.transform`. GPU: composes [world] into the current
  /// projection so the child's local geometry lands in place. The child draws
  /// through THIS backend (shared across the recursion) between the two calls.
  void pushTransform(ui.Canvas canvas, Float64List world);
  void popTransform(ui.Canvas canvas);

  // There is deliberately NO group-tint hook here. An instance part's PartColor
  // does not reach its child subtree in any player of this family — Godot
  // modulates the child with `Color(1, 1, 1, part_alpha)`, and wgpu says "no player
  // propagates an instance part's tint". Only alpha crosses, and it crosses as
  // `DrawFrame.alphaScale`, folded per part.
  //
  // A `pushGroupTint`/`popGroupTint` pair used to live here (Canvas `saveLayer`,
  // GPU sub-texture). Besides applying a tint that should not exist, it
  // *isolated* the subtree, which silently broke every non-source-over blend
  // inside it — an additive child drew over an empty layer instead of the scene.
  // Do not reintroduce it without a spec change; a tint that needs isolation is
  // the shape of the bug, not of the feature.

  /// Releases backend-owned GPU/Canvas resources. Called from the player's
  /// `dispose()`.
  void dispose();
}
