import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../player.dart';
import '../render/sprite_studio_view.dart';

/// Lets [child] take a pointer only where [player] draws one of [parts] — or
/// any part, when [parts] is null — so an irregular button does not answer
/// taps and hovers around its artwork.
///
/// Wrap the **button**, not the view inside it. A button takes a pointer
/// anywhere in its box whatever its child answers (`InkWell` listens
/// opaquely), so the narrowing has to happen above it. The point is mapped
/// into the [SpriteStudioView] of [player] below this widget, wherever the
/// button's padding put it, and tested with
/// [SpriteStudioPlayer.hitTestPart] on the frame drawn. With no such view
/// below, every point passes.
///
/// ```dart
/// SpriteStudioHitRegion(
///   player: _player,
///   parts: const ['button_face'],
///   child: InkWell(
///     statesController: states,
///     onTap: _start,
///     child: SpriteStudioStateView(player: _player, statesController: states),
///   ),
/// )
/// ```
///
/// Only pointers are narrowed. Keyboard focus and a screen reader's activation
/// reach the button as before.
class SpriteStudioHitRegion extends SingleChildRenderObjectWidget {
  const SpriteStudioHitRegion({
    super.key,
    required this.player,
    this.parts,
    super.child,
  });

  final SpriteStudioPlayer player;

  /// The names of the parts that take a pointer. Null lets every part with
  /// an outline take one.
  final List<String>? parts;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderSpriteStudioHitRegion(player, parts);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSpriteStudioHitRegion renderObject,
  ) {
    renderObject
      ..player = player
      ..parts = parts;
  }
}

/// The render object of [SpriteStudioHitRegion].
class RenderSpriteStudioHitRegion extends RenderProxyBox {
  RenderSpriteStudioHitRegion(this.player, this.parts);

  SpriteStudioPlayer player;
  List<String>? parts;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    final view = _viewOf(this);
    if (view != null && view.hasSize) {
      final toView = Matrix4.tryInvert(view.getTransformTo(this));
      if (toView == null) return false;
      final local = MatrixUtils.transformPoint(toView, position);
      final point = local - view.size.center(Offset.zero);
      if (player.hitTestPart(point, parts: parts) < 0) return false;
    }
    return super.hitTest(result, position: position);
  }

  SpriteStudioRenderBox? _viewOf(RenderObject node) {
    SpriteStudioRenderBox? found;
    node.visitChildren((child) {
      if (found != null) return;
      if (child is SpriteStudioRenderBox && identical(child.player, player)) {
        found = child;
      } else {
        found = _viewOf(child);
      }
    });
    return found;
  }
}
