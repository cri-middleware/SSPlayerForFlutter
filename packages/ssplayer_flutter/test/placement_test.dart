// Fit and align: the arithmetic, the box it fits, how the view sizes from it,
// and that the drawing and the part poses both carry the result.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  group('SsRootTransform scale', () {
    test('scales the pose, and mirrorCancel leaves the scale in', () {
      const t = SsRootTransform(flipX: true, scale: 2);
      expect(t.isIdentity, isFalse);
      expect(t.scaleX, -2);
      expect(t.scaleY, 2);
      final pose = t.compose(Matrix4.translationValues(10, 20, 0));
      expect(pose.getTranslation().x, -20);
      expect(pose.getTranslation().y, 40);
      // Only the flip's sign comes back out; the size stays.
      final cancelled = pose.multiplied(t.mirrorCancel);
      expect(cancelled.storage[0], 2);
      expect(cancelled.storage[5], 2);
    });
  });
}
