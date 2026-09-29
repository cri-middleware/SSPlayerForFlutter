import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Alignment, BoxFit;

import 'root_transform.dart';

/// How a view fits the animation into its box: which box ([frame]), how it is
/// scaled ([fit]) and where it lands ([alignment]).
///
/// The family's placement, spelled the way Flutter's `Image` spells it. [fit]
/// takes the three values every sibling Player shares — `contain`, `cover` and
/// `none` — and nothing else: `fill` would scale the axes apart, and the rest
/// would be a vocabulary only this Player had. [alignment] is continuous, and
/// the nine points the siblings name are its corners, edges and centre.
///
/// The caller's own flips, offset and scale ride on top, from the
/// [SsRootTransform] handed to [resolve]: the scale multiplies the fit's, a flip
/// changes which end of the box the alignment anchors to, and the offset is
/// added last.
@immutable
class SsPlacement {
  const SsPlacement({
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.frame,
  }) : assert(
            fit == BoxFit.contain || fit == BoxFit.cover || fit == BoxFit.none,
            'fit takes BoxFit.contain, BoxFit.cover or BoxFit.none');

  /// How the box is scaled to the view. `none` is no fit: the caller's scale,
  /// with the origin at the view's centre.
  final BoxFit fit;

  /// Which point of the box lands on the matching point of the view.
  final Alignment alignment;

  /// The box to fit, in player-local units, or null for the authored canvas the
  /// caller passes to [resolve].
  final ui.Rect? frame;

  /// The transform that draws the box into a [view]-sized box, on top of the
  /// caller's [root]. [canvas] is the box used when [frame] is null.
  ///
  /// The result is measured from the view's centre, which is where both backends
  /// put the origin before applying it. A zero-sized box or view leaves nothing
  /// to divide by, so it comes back unfitted, as `none` does — a view laid out
  /// collapsed gets its animation back the moment it has a size.
  SsRootTransform resolve(ui.Size view, ui.Rect? canvas, SsRootTransform root) {
    final box = frame ?? canvas;
    if (fit == BoxFit.none || box == null || box.isEmpty || view.isEmpty) {
      return root;
    }
    final sx = view.width / box.width;
    final sy = view.height / box.height;
    final s = (fit == BoxFit.contain ? math.min(sx, sy) : math.max(sx, sy)) *
        root.scale;
    final x = _origin(view.width, root.flipX ? -s : s, box.left, box.width,
        alignment.x);
    final y = _origin(view.height, root.flipY ? -s : s, box.top, box.height,
        alignment.y);
    return root.copyWith(
      scale: s,
      offset: ui.Offset(x - view.width / 2, y - view.height / 2) + root.offset,
    );
  }

  /// Where the origin goes along one axis, in view coordinates, so that the
  /// box `[lo, lo + size]` drawn at the signed scale [s] sits at [side]: `-1`
  /// its low edge on the view's, `1` its high edge on the view's, and between.
  ///
  /// Solved with the sign in: a negative [s] swaps which end of the box is the
  /// low one on screen, so a flipped character aligned left still has its own
  /// left-most pixel on the view's left edge. Mirroring an unflipped solution
  /// afterwards would move it off.
  static double _origin(
      double view, double s, double lo, double size, double side) {
    final drawnLow = math.min(s * lo, s * (lo + size));
    return (view - s.abs() * size) * (side + 1) / 2 - drawnLow;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SsPlacement &&
          other.fit == fit &&
          other.alignment == alignment &&
          other.frame == frame;

  @override
  int get hashCode => Object.hash(fit, alignment, frame);

  @override
  String toString() =>
      'SsPlacement(fit: $fit, alignment: $alignment, frame: $frame)';
}
