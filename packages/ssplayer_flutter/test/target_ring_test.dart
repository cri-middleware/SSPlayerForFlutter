// The flutter_gpu backend recycles its offscreen render targets through a
// TargetRing instead of allocating one per frame. The GPU path itself can only
// be checked on a real Impeller run, but the ring's contract — how deep it
// grows, how far apart it reuses a target, and what a resize does — is plain
// bookkeeping and is pinned here.
//
// The reuse distance is the part that matters: a target handed to the engine is
// still aliased by the composited ui.Image until the raster thread is done with
// it, so coming back around too early would draw this frame's content into the
// texture the previous frame is still showing.
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/src/render/backend/target_ring.dart';

void main() {
  /// A ring over ints, where each "target" is its creation ordinal, plus the
  /// log of sizes the factory was asked for.
  (TargetRing<int>, List<String>) ringOfInts({int depth = 3}) {
    final created = <String>[];
    var next = 0;
    final ring = TargetRing<int>(depth, (w, h) {
      created.add('${w}x$h');
      return next++;
    });
    return (ring, created);
  }

  test('grows to depth, allocating one target per frame until full', () {
    final (ring, created) = ringOfInts();

    expect(ring.acquire(64, 32), 0);
    expect(ring.acquire(64, 32), 1);
    expect(ring.acquire(64, 32), 2);

    expect(ring.length, 3);
    expect(created, ['64x32', '64x32', '64x32']);
  });

  test('stops allocating once full and cycles in order', () {
    final (ring, created) = ringOfInts();
    for (var i = 0; i < 3; i++) {
      ring.acquire(64, 32);
    }

    // Nine more frames, no further allocation.
    final handed = [for (var i = 0; i < 9; i++) ring.acquire(64, 32)];

    expect(handed, [0, 1, 2, 0, 1, 2, 0, 1, 2]);
    expect(created, hasLength(3), reason: 'allocated after the ring filled');
    expect(ring.length, 3);
  });

  test('every reuse is a full depth of frames after the last one', () {
    final (ring, _) = ringOfInts();
    final lastSeen = <int, int>{};

    // Includes the fill/cycle transition, which is where an off-by-one shows
    // up: incrementing the cursor only once full hands back the second-oldest
    // target on that one frame, halving the margin exactly once.
    for (var frame = 0; frame < 30; frame++) {
      final target = ring.acquire(64, 32);
      final previous = lastSeen[target];
      if (previous != null) {
        expect(frame - previous, 3,
            reason: 'target $target reused ${frame - previous} frames apart');
      }
      lastSeen[target] = frame;
    }
  });

  test('a size change drops the ring and starts over', () {
    final (ring, created) = ringOfInts();
    for (var i = 0; i < 5; i++) {
      ring.acquire(64, 32);
    }
    expect(created, hasLength(3));

    // Targets are fixed-size, so none of the held ones can serve the new size.
    expect(ring.acquire(80, 32), 3);
    expect(ring.length, 1);
    expect(created.last, '80x32');

    // ...and the new size rings up normally from there.
    expect(ring.acquire(80, 32), 4);
    expect(ring.acquire(80, 32), 5);
    expect(ring.acquire(80, 32), 3);
    expect(ring.length, 3);
  });

  test('height alone changing also resets', () {
    final (ring, _) = ringOfInts();
    ring.acquire(64, 32);
    ring.acquire(64, 32);
    expect(ring.length, 2);

    ring.acquire(64, 33);
    expect(ring.length, 1);
  });

  test('clear drops every target and the remembered size', () {
    final (ring, created) = ringOfInts();
    for (var i = 0; i < 3; i++) {
      ring.acquire(64, 32);
    }

    ring.clear();
    expect(ring.length, 0);

    // Same size as before, but nothing is held, so it allocates afresh.
    expect(ring.acquire(64, 32), 3);
    expect(created, hasLength(4));
  });

  test('a depth-1 ring reuses its single target every frame', () {
    final (ring, created) = ringOfInts(depth: 1);

    expect(ring.acquire(64, 32), 0);
    expect(ring.acquire(64, 32), 0);
    expect(ring.acquire(64, 32), 0);
    expect(created, hasLength(1));
  });
}
