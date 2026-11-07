import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../player.dart';
import 'placement.dart';

/// Layer 4 — the default drawing adapter.
///
/// A leaf render object that observes a [SpriteStudioPlayer] and repaints when
/// it notifies. Rendering itself lives entirely in Layer 2's `paint`; this
/// widget only bridges the player into the widget/RenderObject tree. Optional
/// siblings (Flame component, CustomPaint) can be added the same way.
///
/// ## Size and fit
///
/// It sizes the way `Image` does. Without [width] and [height] it takes the
/// animation's authored canvas ([SpriteStudioPlayer.canvasRect]) as its natural
/// size, shrunk to the incoming constraints with the aspect ratio kept, so it
/// lays out in a `Column`, a `Row` or a `ListView` without being handed numbers.
/// Before a canvas is known it is as small as the constraints allow.
///
/// The canvas is then fitted into the box by [fit] and [alignment]: `contain`
/// by default, centred. [frame] fits a different box — a tighter one around the
/// art, or a larger one for an animation that runs off its canvas. `BoxFit.none`
/// draws unfitted: scale 1, the origin at the box centre, and
/// [SpriteStudioPlayer.offset] / [SpriteStudioPlayer.scale] to place it by hand.
///
/// The fit is handed to the player ([SpriteStudioPlayer.place]) rather than
/// kept here, so a [SpriteStudioPartAnchor] covering the same box lands on the
/// part as it is drawn, fit included.
///
/// ## The box is the frame, on the GPU backend
///
/// This box is what [SpriteStudioPlayer.paint] receives as its `dst`, and the
/// two backends treat it differently:
///
///  * **Canvas** draws in unbounded player-local space. Art that reaches past
///    the box still lands on the canvas (and on whatever is drawn around it,
///    unless an ancestor clips).
///  * **flutter_gpu** renders into an offscreen target exactly the size of the
///    box, so art outside it is cropped *when the frame is rasterised* — before
///    any ancestor transform sees it.
///
/// That difference is invisible while the art stays inside the box. Fitted to
/// its canvas, art the animator let run off the canvas is outside the box, and
/// inside an `InteractiveViewer` panning slides an image that was already
/// cropped on the GPU backend, while the Canvas backend reveals it. Give such an
/// animation a [frame] that covers where it goes.
class SpriteStudioView extends LeafRenderObjectWidget {
  const SpriteStudioView({
    super.key,
    required this.player,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.frame,
  }) : assert(
            fit == BoxFit.contain || fit == BoxFit.cover || fit == BoxFit.none,
            'fit takes BoxFit.contain, BoxFit.cover or BoxFit.none');

  final SpriteStudioPlayer player;

  /// The box's width. Null takes it from the canvas, as `Image` does.
  final double? width;

  /// The box's height. Null takes it from the canvas, as `Image` does.
  final double? height;

  /// How the canvas (or [frame]) is scaled into the box: `contain`, `cover` or
  /// `none`. The other [BoxFit] values are not taken — `fill` would scale the
  /// axes apart, and no sibling Player has the rest.
  final BoxFit fit;

  /// Which point of the canvas (or [frame]) lands on the matching point of the
  /// box. A flip changes which end of the art that is, so a flipped character
  /// aligned to the left still starts at the left edge.
  final AlignmentGeometry alignment;

  /// The box to fit, in player-local pixels, instead of the authored canvas.
  final Rect? frame;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return SpriteStudioRenderBox(
      player: player,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      frame: frame,
      textDirection: Directionality.maybeOf(context),
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, SpriteStudioRenderBox renderObject) {
    renderObject
      ..player = player
      ..width = width
      ..height = height
      ..fit = fit
      ..alignment = alignment
      ..frame = frame
      ..textDirection = Directionality.maybeOf(context);
  }
}

/// The render object behind [SpriteStudioView]: sizes the box, hands the fit to
/// the player, and paints it. Use the widget unless you are composing render
/// objects yourself.
class SpriteStudioRenderBox extends RenderBox {
  SpriteStudioRenderBox({
    required SpriteStudioPlayer player,
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    AlignmentGeometry alignment = Alignment.center,
    Rect? frame,
    TextDirection? textDirection,
  })  : _player = player,
        _width = width,
        _height = height,
        _fit = fit,
        _alignment = alignment,
        _frame = frame,
        _textDirection = textDirection;

  SpriteStudioPlayer _player;
  SpriteStudioPlayer get player => _player;
  set player(SpriteStudioPlayer value) {
    if (identical(_player, value)) return;
    if (attached) _player.removeListener(_onPlayerChanged);
    _player = value;
    if (attached) _player.addListener(_onPlayerChanged);
    markNeedsLayout();
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

  // The placement changes nothing about the size unless the frame does, but
  // it reaches the player from [performLayout], so each of these relayouts.
  BoxFit _fit;
  set fit(BoxFit value) {
    if (_fit == value) return;
    _fit = value;
    markNeedsLayout();
  }

  AlignmentGeometry _alignment;
  set alignment(AlignmentGeometry value) {
    if (_alignment == value) return;
    _alignment = value;
    markNeedsLayout();
  }

  Rect? _frame;
  set frame(Rect? value) {
    if (_frame == value) return;
    _frame = value;
    markNeedsLayout();
  }

  TextDirection? _textDirection;
  set textDirection(TextDirection? value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  /// The box this lays out and fits: the caller's frame, else the canvas.
  Rect? get _box => _frame ?? _player.canvasRect;

  /// What the last layout sized from, so a canvas arriving with the load — or
  /// a new one after the next — relayouts, and an ordinary tick only repaints.
  Rect? _laidOutBox;

  void _onPlayerChanged() {
    if (_box != _laidOutBox) {
      markNeedsLayout();
    } else if (!tickKeptPose(_player)) {
      markNeedsPaint();
    }
  }

  /// `Image`'s sizing: the given dimensions, else the box's, kept in aspect
  /// within the constraints; the smallest size before there is a box.
  Size _sizeFor(BoxConstraints constraints) {
    constraints = BoxConstraints.tightFor(width: _width, height: _height)
        .enforce(constraints);
    final box = _box;
    if (box == null || box.isEmpty) return constraints.smallest;
    return constraints.constrainSizeAndAttemptToPreserveAspectRatio(box.size);
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    if (_width == null && _height == null) return 0.0;
    return _sizeFor(BoxConstraints.tightForFinite(height: height)).width;
  }

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _sizeFor(BoxConstraints.tightForFinite(height: height)).width;

  @override
  double computeMinIntrinsicHeight(double width) {
    if (_width == null && _height == null) return 0.0;
    return _sizeFor(BoxConstraints.tightForFinite(width: width)).height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _sizeFor(BoxConstraints.tightForFinite(width: width)).height;

  @override
  Size computeDryLayout(BoxConstraints constraints) => _sizeFor(constraints);

  @override
  void performLayout() {
    size = _sizeFor(constraints);
    _laidOutBox = _box;
    _player.place(
      size,
      SsPlacement(
        fit: _fit,
        alignment: _alignment.resolve(_textDirection),
        frame: _frame,
      ),
    );
  }

  /// The whole box answers, as an `Image` does, so a `GestureDetector` around
  /// the view hears a tap without being told to be opaque. For the same reason
  /// an animation laid over other widgets takes their taps within its box; a
  /// decorative one lets them through under an `IgnorePointer`, as an `Image`
  /// would.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    // Layer 2 owns all drawing (including its own save/restore) and places the
    // animation's world origin at the center of `dst`, then applies the
    // placement [performLayout] handed the player. Pass the absolute box rect
    // so it composites at the right place.
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
