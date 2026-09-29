import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../player.dart';
import 'sprite_studio_animation.dart';

/// What a [SpriteStudioPartAnchor] does with its child when the tracked part is
/// hidden on the current frame (its keyframe `hide`, or a visibility override).
enum SpriteStudioAnchorHidden {
  /// Keep following the part's last pose regardless of its hide flag — the child
  /// stays visible. This is the default, and it is what the sibling players do
  /// (ForUnity's `FollowAlways`, ForGodot's `FOLLOW_ALWAYS`, ForWeb's
  /// `onHide: 'follow'`).
  followAlways,

  /// Stop drawing the child while the part is hidden (ForUnity's `Deactivate`,
  /// ForGodot's `HIDE_TARGET`, ForWeb's `onHide: 'hide'`).
  hideChild,
}

/// What a [SpriteStudioPartAnchor] does with its child when the *player* is
/// flipped ([SpriteStudioPlayer.flipX] / [SpriteStudioPlayer.flipY]).
///
/// Either way the child follows the part to its mirrored position; this only
/// decides whether the child's own artwork is mirrored along with it. A weapon
/// sprite usually wants [follow]; a health bar, a name plate or an icon usually
/// wants [cancel], since mirrored text is not text.
///
/// Mirroring the *artist* authored on the part (a negative scale on it or an
/// ancestor) is part of the animation and always reaches the child, whichever of
/// these is chosen.
enum SpriteStudioAnchorMirror {
  /// Mirror the child exactly as the part is mirrored. The default: the child
  /// then sits in the part's own frame, which is what a follower usually means.
  follow,

  /// Keep the child's own orientation, following only the mirrored position.
  ///
  /// Exact — it undoes a ±1 diagonal this library applied itself, leaving no
  /// residue (the siblings, which carry the pose as rotation + scale, cannot do
  /// this without leaving a stray 180° on a horizontal flip; see
  /// `SsRootTransform.mirrorCancel`).
  cancel,
}

/// Sticks [child] to a SpriteStudio part so it tracks that part's position,
/// rotation and scale every frame — the Flutter-idiomatic form of ForUnity's
/// part tracker and ForGodot's part attachment. Where those engines drive a
/// scene-graph node, this drives a Widget: it reads the part's pose from
/// [player] and wraps [child] in a [Transform].
///
/// **In a [SpriteStudioAnimation]**, put it in the widget's `children` and
/// leave [player] out: it finds that widget's player, and `children` already
/// cover the animation's exact box.
///
/// ```dart
/// SpriteStudioAnimation.asset(
///   'assets/spritestudio/Ringo/Ringo.ssab',
///   children: [
///     SpriteStudioPartAnchor(partName: 'apple', child: Icon(Icons.star)),
///   ],
/// )
/// ```
///
/// **Over a [SpriteStudioView]**, pass the view's [player] and put the anchor
/// in the SAME coordinate space as the animation:
/// as a `Positioned.fill` sibling of the [SpriteStudioView] inside a [Stack], so
/// it covers the view's exact box. The view centres the animation's world origin
/// in that box, and the anchor applies the matching centring, so the child lands
/// exactly on the part:
///
/// ```dart
/// Stack(children: [
///   SpriteStudioView(player: player),
///   Positioned.fill(
///     child: SpriteStudioPartAnchor(
///       player: player,
///       partName: 'Weapon',
///       child: const Icon(Icons.star),
///     ),
///   ),
/// ])
/// ```
///
/// **Ownership** is the caller's (constraint-style, like both flagships): the
/// anchor never creates or disposes [child] or [player] — it only reads a pose
/// and applies it. It rebuilds on the player's notifications, so it lands on the
/// same frame the view paints.
///
/// **Anchor point.** The child's own top-left origin is pinned to the part's
/// origin; wrap [child] (e.g. in a `Transform.translate` or `Align`) to attach a
/// different point of it.
///
/// **Flips.** [SpriteStudioPlayer.flipX] / [SpriteStudioPlayer.flipY] carry the
/// anchor with them, so a character can turn around without its followers coming
/// off their parts; [onMirrored] decides whether the child is mirrored too.
///
/// **Fits.** The view hands its fit to the player, and the pose read here
/// carries it, so a view that scales the animation into its box scales where
/// the follower goes with it. That holds only over the view's own box, which
/// is one more reason for the `Positioned.fill` above.
///
/// **v1 limits.** Tracks top-level parts only — a part nested inside an Instance
/// part lives in a child player and is not addressable here yet.
class SpriteStudioPartAnchor extends StatelessWidget {
  const SpriteStudioPartAnchor({
    super.key,
    this.player,
    required this.partName,
    required this.child,
    this.position = true,
    this.rotation = true,
    this.scale = false,
    this.onHidden = SpriteStudioAnchorHidden.followAlways,
    this.onMirrored = SpriteStudioAnchorMirror.follow,
    this.filterQuality,
  });

  /// The player whose part poses this anchor follows, or null for the one of
  /// the [SpriteStudioAnimation] it sits in.
  final SpriteStudioPlayer? player;

  /// The `.ssab` part name to track. An unknown name (or one absent from the
  /// current animation) simply draws nothing until it resolves.
  final String partName;

  /// The widget stuck to the part.
  final Widget child;

  /// Drive the child's position from the part. On by default — a follower that
  /// does not follow the position is not following.
  final bool position;

  /// Drive the child's rotation from the part. On by default.
  final bool rotation;

  /// Drive the child's scale from the part.
  ///
  /// **Off by default**, matching the sibling players: a follower is placed *at*
  /// the part, not *sized by* it, and a health bar or a name plate stretching
  /// with a breathing animation is rarely what was wanted. Turn it on for
  /// something that is part of the artwork — a weapon in a hand.
  ///
  /// With all three on the part's affine is applied as it is, so the part's
  /// mirroring is reproduced exactly. With any of them off the affine is
  /// decomposed and only the enabled axes are rebuilt; a disabled axis takes
  /// the identity, since a wrapped widget has no transform of its own to keep.
  ///
  /// The pose is **skew-free** either way: the Brain applies a part's Skew as a
  /// non-inheriting local-vertex deform, so it never reaches the world matrix
  /// and a follower is never sheared by the part it tracks — matching
  /// SpriteStudio, where Skew does not propagate to a part's children.
  final bool scale;

  /// What to do when the part is hidden this frame. Defaults to
  /// [SpriteStudioAnchorHidden.followAlways], matching the sibling players;
  /// pass [SpriteStudioAnchorHidden.hideChild] to drop the child with the part.
  final SpriteStudioAnchorHidden onHidden;

  /// Whether a flipped player mirrors this child too. **Only bites when
  /// [scale] is on**: a mirror is a sign on the scale, so with [scale] off the
  /// child is never mirrored in the first place. Defaults to
  /// [SpriteStudioAnchorMirror.follow]; use
  /// [SpriteStudioAnchorMirror.cancel] for a child that must stay readable
  /// (text, icons, a health bar).
  final SpriteStudioAnchorMirror onMirrored;

  /// Optional [Transform.filterQuality] — e.g. [FilterQuality.low] to smooth a
  /// rotated or scaled child. Null keeps Flutter's nearest-neighbour default.
  final FilterQuality? filterQuality;

  /// [world] with only the enabled axes kept.
  ///
  /// All three on is the passthrough — the only path that reproduces a
  /// reflection (a mirrored part), which a TRS rebuild cannot represent without
  /// leaving a stray 180 degrees. Otherwise the affine is decomposed and
  /// recomposed, with `scaleY` carrying the determinant's sign so a mirrored
  /// part reads as a negative scale rather than as a 180-degree rotation.
  ///
  /// [world] is skew-free (the Brain applies Skew as a non-inheriting
  /// local-vertex deform), so no path here carries skew onto the follower — and
  /// the decompose reads a cleaner rotation for it than a skewed matrix would.
  Matrix4 _axes(Matrix4 world) {
    if (position && rotation && scale) return world;

    final m = world.storage;
    final a = m[0], b = m[1], c = m[4], d = m[5];
    final tx = position ? m[12] : 0.0;
    final ty = position ? m[13] : 0.0;

    var sx = 1.0, sy = 1.0;
    if (scale) {
      final determinant = a * d - b * c;
      sx = math.sqrt(a * a + b * b);
      sy = math.sqrt(c * c + d * d) * (determinant < 0 ? -1.0 : 1.0);
    }
    final theta = rotation ? math.atan2(b, a) : 0.0;
    final cos = math.cos(theta), sin = math.sin(theta);

    // Column-major, as Matrix4 stores it: scale*rotation for x and y, then z,
    // then the translation.
    return Matrix4(
      sx * cos, sx * sin, 0.0, 0.0,
      -sy * sin, sy * cos, 0.0, 0.0,
      0.0, 0.0, 1.0, 0.0,
      tx, ty, 0.0, 1.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = this.player ?? SpriteStudioAnimation.playerOf(context);
    if (player == null) {
      throw FlutterError.fromParts(<DiagnosticsNode>[
        ErrorSummary('SpriteStudioPartAnchor has no player to follow.'),
        ErrorHint('Put it in the children of a SpriteStudioAnimation, which '
            'hands its player down, or pass player: the one a '
            'SpriteStudioView draws.'),
      ]);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The view centres the animation's world origin in its box, so the
        // follower must offset by the same half-extents. Unbounded axes (the
        // anchor was not given the view's box) fall back to 0 — the caller is
        // expected to `Positioned.fill` it over the view.
        final cx =
            constraints.maxWidth.isFinite ? constraints.maxWidth / 2.0 : 0.0;
        final cy =
            constraints.maxHeight.isFinite ? constraints.maxHeight / 2.0 : 0.0;
        return ListenableBuilder(
          listenable: player,
          builder: (context, _) {
            final world = player.partTransform(partName);
            // Nothing to show: unknown/absent part, or hidden under hideChild.
            // Fill the box regardless so the anchor's layout stays stable.
            if (world == null ||
                (onHidden == SpriteStudioAnchorHidden.hideChild &&
                    player.isPartHidden(partName))) {
              return const SizedBox.expand();
            }
            // `world` already carries the player's flip / offset (it is the pose
            // as drawn), so the child lands on the part across a flip with no
            // help. Cancelling only takes the mirror back out of the child's own
            // frame, on the right so the position it just followed is untouched.
            final followed = _axes(world);
            // Only when the scale came along: a mirror IS a sign on the scale,
            // so dropping the scale has already removed it, and cancelling again
            // would put one back.
            final pose = scale && onMirrored == SpriteStudioAnchorMirror.cancel
                ? followed.multiplied(player.rootTransform.mirrorCancel)
                : followed;
            // A Stack keyed to the view's box (Clip.none so a part near the edge
            // is not clipped); the single positioned child is nudged to the part
            // by `centre · world`.
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  child: Transform(
                    transform: Matrix4.translationValues(cx, cy, 0.0)
                      ..multiply(pose),
                    filterQuality: filterQuality,
                    child: child,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
