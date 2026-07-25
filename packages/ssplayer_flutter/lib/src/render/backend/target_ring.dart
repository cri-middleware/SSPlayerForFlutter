/// A fixed-depth ring of reusable, fixed-size render targets.
///
/// Exists because a render target cannot be recycled the frame after it is
/// used: the composited `ui.Image` aliases its texture until the layer
/// rasterises, which happens on the raster thread *after* paint returns. The
/// engine keeps at most two frames in flight (raster works on frame N while the
/// UI thread builds N+1), so a depth of 3 leaves a full frame of margin before
/// any target comes back around.
///
/// Generic over the target type, and takes its factory, so the cycling and
/// resize behaviour is testable without a GPU context — the headless test
/// binding has no Impeller context, and `gpu.Texture` cannot be created there.
///
/// Targets are released by dropping the reference: `gpu.Texture` has no
/// explicit destroy in the flutter_gpu API and is reclaimed by the GC. That is
/// also why the ring matters — a per-frame target leaves its (large) GPU
/// allocation waiting on a collection that may be many frames away.
class TargetRing<T> {
  TargetRing(this.depth, this._create) : assert(depth > 0);

  /// How many targets to cycle through once the ring is full.
  final int depth;

  final T Function(int width, int height) _create;

  final List<T> _slots = <T>[];
  int _cursor = -1;
  int _width = 0;
  int _height = 0;

  /// Targets currently held (grows to [depth], then stops).
  int get length => _slots.length;

  /// The target to render into, sized [width] x [height] in device pixels.
  ///
  /// Grows the ring until it is [depth] deep, then cycles. A size change drops
  /// every held target and starts over: targets are fixed-size, so a stale one
  /// would be the wrong shape. Propagates whatever the factory throws.
  T acquire(int width, int height) {
    if (width != _width || height != _height) {
      _slots.clear();
      _cursor = -1;
      _width = width;
      _height = height;
    }
    // Advance first, then allocate only if the cursor has run off the end. The
    // invariant is simply "_cursor names the slot in use", which holds while
    // growing and after wrapping alike — so the frame that first reuses a
    // target is a full `depth` frames on from it, with no special case at the
    // transition and no dependence on what the reset leaves in `_cursor`.
    _cursor = _slots.isEmpty ? 0 : (_cursor + 1) % depth;
    if (_cursor == _slots.length) {
      final created = _create(width, height);
      _slots.add(created);
      return created;
    }
    return _slots[_cursor];
  }

  /// Drops every held target (the GC reclaims them) and forgets the size.
  void clear() {
    _slots.clear();
    _cursor = -1;
    _width = 0;
    _height = 0;
  }
}
