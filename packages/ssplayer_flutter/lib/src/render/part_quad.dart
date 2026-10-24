import 'dart:math' as math;
import 'dart:ui' as ui;

/// A part's outline as drawn: four corners in the space
/// `SpriteStudioPlayer.partTransform` reports, measured from the centre of the
/// view's box.
///
/// Four points rather than a [ui.Rect], because a rotated, skewed or
/// vertex-deformed part is not axis-aligned. The corners are the part's own —
/// [leftTop] is the corner the cell's top left is drawn at — so a rotated or
/// flipped part has them wherever the pose put them. [bounds] is the
/// axis-aligned box around them.
class SsPartQuad {
  const SsPartQuad(
      this.leftTop, this.rightTop, this.leftBottom, this.rightBottom);

  final ui.Offset leftTop;
  final ui.Offset rightTop;
  final ui.Offset leftBottom;
  final ui.Offset rightBottom;

  /// The smallest axis-aligned rectangle that holds all four corners.
  ui.Rect get bounds => ui.Rect.fromLTRB(
        math.min(math.min(leftTop.dx, rightTop.dx),
            math.min(leftBottom.dx, rightBottom.dx)),
        math.min(math.min(leftTop.dy, rightTop.dy),
            math.min(leftBottom.dy, rightBottom.dy)),
        math.max(math.max(leftTop.dx, rightTop.dx),
            math.max(leftBottom.dx, rightBottom.dx)),
        math.max(math.max(leftTop.dy, rightTop.dy),
            math.max(leftBottom.dy, rightBottom.dy)),
      );

  /// Whether [point] lies inside the outline `leftTop → rightTop → rightBottom
  /// → leftBottom`, by the even-odd rule, so a deform that folds the quad over
  /// itself still answers.
  bool contains(ui.Offset point) {
    final outline = [leftTop, rightTop, rightBottom, leftBottom];
    var inside = false;
    for (var i = 0, j = 3; i < 4; j = i++) {
      final a = outline[i], b = outline[j];
      if ((a.dy > point.dy) != (b.dy > point.dy) &&
          point.dx < (b.dx - a.dx) * (point.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SsPartQuad &&
          other.leftTop == leftTop &&
          other.rightTop == rightTop &&
          other.leftBottom == leftBottom &&
          other.rightBottom == rightBottom;

  @override
  int get hashCode => Object.hash(leftTop, rightTop, leftBottom, rightBottom);

  @override
  String toString() =>
      'SsPartQuad($leftTop, $rightTop, $leftBottom, $rightBottom)';
}
