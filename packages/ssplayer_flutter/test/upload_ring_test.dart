// The flutter_gpu backend uploads a frame's vertices, indices and uniforms
// through an UploadRing instead of a buffer per draw. The GPU path itself can
// only be checked on a real Impeller run, but where the ring puts bytes — how
// far apart it reuses a block, how it grows, what it aligns — is plain
// bookkeeping and is pinned here.
//
// The reuse distance is the part that matters: a block written while the GPU
// still reads an earlier frame from it would corrupt that frame's draws.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/src/render/backend/upload_ring.dart';

/// A stand-in buffer: its creation ordinal, its size and its bytes.
class _Buffer {
  _Buffer(this.id, int size) : bytes = Uint8List(size);
  final int id;
  final Uint8List bytes;
}

void main() {
  (UploadRing<_Buffer>, List<int>) ring({int depth = 4, int initial = 64}) {
    final created = <int>[];
    final ring = UploadRing<_Buffer>(
      depth,
      initialSize: initial,
      create: (size) {
        created.add(size);
        return _Buffer(created.length - 1, size);
      },
      write: (buffer, bytes, offset) => buffer.bytes.setRange(
          offset, offset + bytes.lengthInBytes, bytes.buffer.asUint8List(
              bytes.offsetInBytes, bytes.lengthInBytes)),
    );
    return (ring, created);
  }

  ByteData bytesOf(int length, int fill) =>
      ByteData.sublistView(Uint8List(length)..fillRange(0, length, fill));

  test('places runs one after another, aligned, and writes them', () {
    final (r, _) = ring();
    r.beginFrame();
    final a = r.put(bytesOf(10, 1), 16);
    final b = r.put(bytesOf(4, 2), 16);
    final c = r.put(bytesOf(4, 3), 4);
    expect([a.offset, b.offset, c.offset], [0, 16, 20]);
    expect(b.buffer, same(a.buffer));
    expect(a.buffer.bytes.sublist(16, 24), [2, 2, 2, 2, 3, 3, 3, 3]);
  });

  test('a frame reuses its block only once the ring comes back round', () {
    final (r, created) = ring(depth: 3);
    final used = <int>[];
    for (var f = 0; f < 9; f++) {
      r.beginFrame();
      used.add(r.put(bytesOf(8, f), 16).buffer.id);
    }
    expect(used, [0, 1, 2, 0, 1, 2, 0, 1, 2]);
    expect(created, hasLength(3), reason: 'allocated once the ring was full');
  });

  test('a run that does not fit moves to a new block, and the frame settles '
      'on one block half as large again as it held', () {
    // One frame deep, so every beginFrame comes back round to it.
    final (r, created) = ring(depth: 1, initial: 64);
    r.beginFrame();
    final first = r.put(bytesOf(48, 1), 16);
    final second = r.put(bytesOf(48, 2), 16); // 48 + 48 > 64
    expect(second.buffer, isNot(same(first.buffer)));
    expect(second.offset, 0);
    expect(created, [64, 96]);
    // What the first block held stays as written.
    expect(first.buffer.bytes.sublist(0, 48), everyElement(1));

    r.beginFrame(); // back round: the two blocks become one
    expect(created, [64, 96, 1024]);
    final again = r.put(bytesOf(48, 3), 16);
    final more = r.put(bytesOf(48, 4), 16);
    expect(more.buffer, same(again.buffer));
    expect(more.offset, 48);

    for (var i = 0; i < 6; i++) {
      r.beginFrame();
      r.put(bytesOf(48, 5), 16);
      r.put(bytesOf(48, 6), 16);
    }
    expect(created, hasLength(3), reason: 'a settled frame allocates no more');
    expect(r.debugBlockCount, 1);
  });

  test('a run larger than any block gets a block of its own size', () {
    final (r, created) = ring(initial: 64);
    r.beginFrame();
    final big = r.put(bytesOf(5000, 7), 16);
    expect(big.offset, 0);
    expect(created.last, greaterThanOrEqualTo(5000));
    expect(big.buffer.bytes.sublist(0, 5000), everyElement(7));
  });

  test('clear drops every block', () {
    final (r, _) = ring();
    r.beginFrame();
    r.put(bytesOf(8, 1), 16);
    expect(r.debugBlockCount, 1);
    r.clear();
    expect(r.debugBlockCount, 0);
  });
}
