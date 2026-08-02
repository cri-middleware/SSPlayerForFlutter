import 'dart:ui' as ui;

import 'package:vector_math/vector_math_64.dart' show Matrix4;

/// The player-level flip / offset — what a player draws, mirrored and shifted,
/// with nothing else moved.
///
/// The sibling ports exist because negating a node's scale to mirror a character
/// drags its children along: ForUnity's `FlipX` / `FlipY` / `Offset` and
/// ForGodot's `flip_h` / `flip_v` / `offset`. Flutter has no colliders to drag,
/// but wrapping a [SpriteStudioView] in `Transform.flip` is still not the same
/// thing — it mirrors every *sibling* of the view too, most importantly the
/// widgets a `SpriteStudioPartAnchor` is sticking to parts. This mirrors the
/// animation and leaves the widget tree alone.
///
/// **One place, two consumers.** This is the only place the flip becomes
/// numbers, and both the drawing path (`RenderBackend.beginFrame`) and the part
/// poses (`SpriteStudioInternalPlayer.partWorldMatrix`) read it — a follower
/// pinned to a part must not come off the moment the player is flipped, which is
/// exactly what happens if the flip goes into the geometry alone.
///
/// The transform is `drawn = offset + scale · local`: the flip is a ±1 per-axis
/// scale about the animation's own origin, and [offset] shifts the result and is
/// therefore **not** itself mirrored (both siblings agree on this order).
class SsRootTransform {
  const SsRootTransform({
    this.flipX = false,
    this.flipY = false,
    this.offset = ui.Offset.zero,
  });

  /// Draw as authored — what a player has until something sets otherwise.
  static const SsRootTransform identity = SsRootTransform();

  /// Mirror the drawn animation horizontally, in the manner of Flutter's own
  /// `Transform.flip(flipX: …)`.
  final bool flipX;

  /// Mirror it vertically.
  final bool flipY;

  /// Shift the drawn animation by this many player-local (logical) pixels,
  /// applied after the flip. There is no pixels-per-unit step in this port — the
  /// view draws the animation unscaled — so this is in the same units as the
  /// animation's own coordinates.
  final ui.Offset offset;

  /// The horizontal half of the flip as a scale factor (−1 when [flipX]).
  double get scaleX => flipX ? -1.0 : 1.0;

  /// The vertical half (−1 when [flipY]).
  double get scaleY => flipY ? -1.0 : 1.0;

  /// Whether this draws the animation exactly as authored, letting both backends
  /// skip the transform entirely.
  bool get isIdentity => !flipX && !flipY && offset == ui.Offset.zero;

  /// Whether this transform is a **reflection** — an odd number of mirrored axes.
  ///
  /// Note what this does *not* tell you: whether a given part's pose is mirrored.
  /// That is the product of this flip and whatever mirroring the artist authored
  /// on the part or an ancestor, so the two cancel in pairs — flipping a player
  /// makes an authored-mirrored part come out *un*-mirrored. Read the sign off
  /// the matrix you are holding (`Matrix4.determinant()`), never off this.
  bool get isMirrored => flipX != flipY;

  /// This transform with the given fields replaced.
  SsRootTransform copyWith({bool? flipX, bool? flipY, ui.Offset? offset}) =>
      SsRootTransform(
        flipX: flipX ?? this.flipX,
        flipY: flipY ?? this.flipY,
        offset: offset ?? this.offset,
      );

  /// [partWorld] with this root transform folded in — the same pose the geometry
  /// is drawn at, so a follower lands on the part it is pinned to.
  Matrix4 compose(Matrix4 partWorld) {
    if (isIdentity) return partWorld;
    final sx = scaleX;
    final sy = scaleY;
    return partWorld.clone()
      ..[0] = sx * partWorld[0]
      ..[1] = sy * partWorld[1]
      ..[4] = sx * partWorld[4]
      ..[5] = sy * partWorld[5]
      ..[12] = sx * partWorld[12] + offset.dx
      ..[13] = sy * partWorld[13] + offset.dy;
  }

  /// Right-multiplying a composed part pose by this undoes the flip's effect on
  /// the follower's **own** orientation while keeping it at the mirrored
  /// position — a widget stuck to a part stays readable when the player turns
  /// around.
  ///
  /// It is exact, and cheaply so: conjugating by a ±1 diagonal cancels it
  /// outright, with none of the residue that dogs the siblings (both express the
  /// pose as rotation + scale, where a mirror can only ride in the scale, and
  /// dropping it leaves a stray 180° on the horizontal flip). Nothing is guessed
  /// from the determinant either — this undoes a transform we applied ourselves,
  /// so mirroring the artist authored on the part passes through untouched, as it
  /// should: that one is part of the animation.
  Matrix4 get mirrorCancel => Matrix4.diagonal3Values(scaleX, scaleY, 1.0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SsRootTransform &&
          other.flipX == flipX &&
          other.flipY == flipY &&
          other.offset == offset;

  @override
  int get hashCode => Object.hash(flipX, flipY, offset);

  @override
  String toString() =>
      'SsRootTransform(flipX: $flipX, flipY: $flipY, offset: $offset)';
}
