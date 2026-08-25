import 'package:flutter/widgets.dart';

import '../player.dart';

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
/// **Placement.** Put the anchor in the SAME coordinate space as the animation:
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
/// **v1 limits.** Tracks top-level parts only — a part nested inside an Instance
/// part lives in a child player and is not addressable here yet. Assumes the
/// view draws unscaled (BoxFit placement is not implemented on the view yet); if
/// that lands, the anchor will need the same fit applied.
class SpriteStudioPartAnchor extends StatelessWidget {
  const SpriteStudioPartAnchor({
    super.key,
    required this.player,
    required this.partName,
    required this.child,
    this.onHidden = SpriteStudioAnchorHidden.followAlways,
    this.onMirrored = SpriteStudioAnchorMirror.follow,
    this.filterQuality,
  });

  /// The player whose part poses this anchor follows.
  final SpriteStudioPlayer player;

  /// The `.ssab` part name to track. An unknown name (or one absent from the
  /// current animation) simply draws nothing until it resolves.
  final String partName;

  /// The widget stuck to the part.
  final Widget child;

  /// What to do when the part is hidden this frame. Defaults to
  /// [SpriteStudioAnchorHidden.followAlways], matching the sibling players;
  /// pass [SpriteStudioAnchorHidden.hideChild] to drop the child with the part.
  final SpriteStudioAnchorHidden onHidden;

  /// Whether a flipped player mirrors this child too. Defaults to
  /// [SpriteStudioAnchorMirror.follow]; use
  /// [SpriteStudioAnchorMirror.cancel] for a child that must stay readable
  /// (text, icons, a health bar).
  final SpriteStudioAnchorMirror onMirrored;

  /// Optional [Transform.filterQuality] — e.g. [FilterQuality.low] to smooth a
  /// rotated or scaled child. Null keeps Flutter's nearest-neighbour default.
  final FilterQuality? filterQuality;

  @override
  Widget build(BuildContext context) {
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
            final pose = onMirrored == SpriteStudioAnchorMirror.cancel
                ? world.multiplied(player.rootTransform.mirrorCancel)
                : world;
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
