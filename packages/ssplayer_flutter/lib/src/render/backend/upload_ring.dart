import 'dart:typed_data';

/// Where [UploadRing.put] placed a run of bytes.
typedef UploadSlice<B> = ({B buffer, int offset, int length});

/// The bytes a frame's draws upload — vertices, indices and uniforms — placed
/// in buffers kept from frame to frame instead of buffers made per draw.
///
/// A buffer made per draw is left to the GC, since flutter_gpu's
/// `DeviceBuffer` has no destroy, and flutter_gpu's own `HostBuffer` cannot
/// take vertex data in its place: past its block size it adds a block every
/// frame and never reuses one, and bytes that would straddle a block's end
/// fail to write.
///
/// Each of [depth] frames owns blocks of its own, written again only when the
/// ring comes back round to it, [depth] frames later: the margin `HostBuffer`
/// keeps as well, for a GPU still reading an earlier frame. A frame's bytes go
/// one run after another; a run that does not fit moves to the frame's next
/// block, made when there is none. The next time that frame comes round, its
/// blocks are replaced by one half as large again as everything they held, so
/// a frame settles on a single block that is never resized.
///
/// Generic over the buffer type, and takes its factory and writer, so the
/// placement is testable without a GPU context, as `TargetRing` is.
class UploadRing<B> {
  UploadRing(
    this.depth, {
    required B Function(int sizeInBytes) create,
    required void Function(B buffer, ByteData bytes, int offset) write,
    this.initialSize = 32 * 1024,
  })  : assert(depth > 0),
        _create = create,
        _write = write;

  /// How many frames own blocks of their own.
  final int depth;

  /// The size of a frame's first block.
  final int initialSize;

  final B Function(int sizeInBytes) _create;
  final void Function(B buffer, ByteData bytes, int offset) _write;

  final List<_Frame<B>> _frames = <_Frame<B>>[];
  int _cursor = -1;

  /// Starts the next frame: the frame [depth] frames back hands its blocks
  /// over, consolidated into one if they were more.
  void beginFrame() {
    _cursor = _frames.isEmpty ? 0 : (_cursor + 1) % depth;
    if (_cursor == _frames.length) _frames.add(_Frame<B>());
    final frame = _frames[_cursor];
    if (frame.blocks.length > 1) {
      final size = _roundUp(frame.used + frame.used ~/ 2, 1024);
      frame.blocks
        ..clear()
        ..add(_Block<B>(_create(size), size));
    }
    frame
      ..block = 0
      ..offset = 0
      ..used = 0;
  }

  /// Writes [bytes] into this frame's blocks at an offset that is a multiple of
  /// [alignment], and says where. Only valid between [beginFrame] calls; the
  /// slice stays as written until the ring comes back round to this frame.
  UploadSlice<B> put(ByteData bytes, int alignment) {
    assert(_cursor >= 0, 'put before beginFrame');
    final frame = _frames[_cursor];
    final length = bytes.lengthInBytes;
    while (true) {
      if (frame.block < frame.blocks.length) {
        final block = frame.blocks[frame.block];
        final at = _roundUp(frame.offset, alignment);
        if (at + length <= block.size) {
          if (length > 0) _write(block.buffer, bytes, at);
          frame.used += at + length - frame.offset;
          frame.offset = at + length;
          return (buffer: block.buffer, offset: at, length: length);
        }
        frame
          ..block += 1
          ..offset = 0;
        continue;
      }
      final last = frame.blocks.isEmpty ? 0 : frame.blocks.last.size;
      var size = last + last ~/ 2;
      if (size < initialSize) size = initialSize;
      if (size < length) size = _roundUp(length, 1024);
      frame.blocks.add(_Block<B>(_create(size), size));
    }
  }

  /// Blocks held across every frame, for tests.
  int get debugBlockCount =>
      _frames.fold(0, (n, frame) => n + frame.blocks.length);

  /// Drops every block (the GC reclaims them).
  void clear() {
    _frames.clear();
    _cursor = -1;
  }

  static int _roundUp(int value, int multiple) =>
      multiple <= 1 ? value : (value + multiple - 1) ~/ multiple * multiple;
}

class _Frame<B> {
  final List<_Block<B>> blocks = <_Block<B>>[];
  int block = 0;
  int offset = 0;

  /// Bytes this frame placed, padding included: what a single block for it
  /// has to hold.
  int used = 0;
}

class _Block<B> {
  _Block(this.buffer, this.size);
  final B buffer;
  final int size;
}
