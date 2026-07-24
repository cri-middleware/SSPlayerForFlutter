import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../player.dart';

/// Layer 4 — the default drawing adapter.
///
/// A leaf render object that observes a [SpriteStudioPlayer] and repaints when
/// it notifies. Rendering itself lives entirely in Layer 2's `paint`; this
/// widget only bridges the player into the widget/RenderObject tree. Optional
/// siblings (Flame component, CustomPaint) can be added the same way.
///
/// Sizing honours [width]/[height] (or the incoming constraints). BoxFit /
/// alignment of the animation's design bounds into the box is not currently
/// supported.
class SpriteStudioView extends LeafRenderObjectWidget {
  const SpriteStudioView({
    super.key,
    required this.player,
    this.width,
    this.height,
  });

  final SpriteStudioPlayer player;
  final double? width;
  final double? height;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return SpriteStudioRenderBox(
      player: player,
      width: width,
      height: height,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, SpriteStudioRenderBox renderObject) {
    renderObject
      ..player = player
      ..width = width
      ..height = height;
  }
}

class SpriteStudioRenderBox extends RenderBox {
  SpriteStudioRenderBox({
    required SpriteStudioPlayer player,
    double? width,
    double? height,
  })  : _player = player,
        _width = width,
        _height = height;

  SpriteStudioPlayer _player;
  SpriteStudioPlayer get player => _player;
  set player(SpriteStudioPlayer value) {
    if (identical(_player, value)) return;
    if (attached) _player.removeListener(_onPlayerChanged);
    _player = value;
    if (attached) _player.addListener(_onPlayerChanged);
    markNeedsPaint();
  }

  double? _width;
  set width(double? value) {
    if (_width == value) return;
    _width = value;
    markNeedsLayout();
  }

  double? _height;
  set height(double? value) {
    if (_height == value) return;
    _height = value;
    markNeedsLayout();
  }

  void _onPlayerChanged() => markNeedsPaint();

  @override
  bool get sizedByParent => false;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    return constraints.constrain(Size(
      _width ?? double.infinity,
      _height ?? double.infinity,
    ));
  }

  @override
  void performLayout() {
    size = computeDryLayout(constraints);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Layer 2 owns all drawing (including its own save/restore) and places the
    // animation's world origin at the center of `dst`. Pass the absolute box
    // rect so it composites at the right place.
    _player.paint(context.canvas, dst: offset & size, sourceSize: size);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _player.addListener(_onPlayerChanged);
  }

  @override
  void detach() {
    _player.removeListener(_onPlayerChanged);
    super.detach();
  }
}
