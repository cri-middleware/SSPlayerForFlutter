import 'package:ssruntime_dart/effect_draw_plan.dart' as efbs;

import '../../texture_registry.dart';
import '../geometry_builder.dart';
import '../mask.dart';

/// The narrow surface a [RenderBackend] needs from its owning L2 player to draw
/// one player's batches.
///
/// Kept deliberately small so a backend never reaches into playback / FFI /
/// transport state. Per-player data (geometry scratch, textures, mask roles,
/// effect plans) is read through this; the batch-loop control flow, mask
/// planning and instance recursion stay in the player.
///
/// It is passed *per emit call* rather than held by the backend, because a
/// backend instance is shared across the instance recursion: a child's batches
/// draw through the same backend but with the CHILD's host.
abstract class RenderHost {
  /// The pure SoA→vertex baker (shared compute for both backends).
  GeometryBuilder get geometry;

  /// texture_hash → decoded image / shader (shared across an instance tree).
  TextureRegistry get textures;

  /// Static per-part mask role; [MaskPartFlags.none] past the part range.
  MaskPartFlags flagsFor(int partIndex);

  /// The particle plan for effect part [partIndex], or null when its slot drew
  /// nothing. Valid only until the next update (aliases the Brain's memory).
  efbs.EffectDrawPlan? effectPlanFor(int partIndex);

  /// Whether this player hosts any effect parts (skips the Effect path when not).
  bool get hasEffects;
}
