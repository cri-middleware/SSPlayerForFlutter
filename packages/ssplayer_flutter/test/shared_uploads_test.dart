// The flutter_gpu backends of every player share one upload per decoded image
// through SharedUploads. The GPU half can only run on a real Impeller target,
// but who starts an upload, who is told when it lands and what a failure
// leaves behind are plain bookkeeping and are pinned here.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/src/render/backend/shared_uploads.dart';

/// A stand-in backend: what it was told, by its one stable callback.
class _Backend {
  int ready = 0;
  void onReady() => ready++;
}

void main() {
  test('backends asking for one image share one upload', () async {
    final uploads = SharedUploads<String>();
    final image = Object();
    final done = Completer<String?>();
    var started = 0;
    Future<String?> upload() {
      started++;
      return done.future;
    }

    final a = _Backend(), b = _Backend();
    expect(uploads.lookup(image, upload, a.onReady), isNull);
    expect(uploads.lookup(image, upload, b.onReady), isNull);
    // A backend asks every frame it draws without it; it is told once.
    expect(uploads.lookup(image, upload, a.onReady), isNull);
    expect(started, 1);

    done.complete('texture');
    await pumpEventQueue();
    expect([a.ready, b.ready], [1, 1]);
    expect(uploads.lookup(image, upload, a.onReady), 'texture');
    expect(uploads.lookup(image, upload, b.onReady), 'texture');
    expect(started, 1);
    expect([a.ready, b.ready], [1, 1], reason: 'nobody waits for a landed one');
  });

  test('a different image is a different upload', () async {
    final uploads = SharedUploads<String>();
    final first = Object(), replacement = Object();
    final backend = _Backend();
    uploads.lookup(first, () async => 'first', backend.onReady);
    uploads.lookup(replacement, () async => 'replacement', backend.onReady);
    await pumpEventQueue();
    expect(uploads.lookup(first, () async => 'again', backend.onReady), 'first');
    expect(uploads.lookup(replacement, () async => 'again', backend.onReady),
        'replacement');
  });

  test('an upload that fails or makes nothing is tried again', () async {
    final uploads = SharedUploads<String>();
    final image = Object();
    final backend = _Backend();
    var started = 0;

    uploads.lookup(image, () async {
      started++;
      throw StateError('upload');
    }, backend.onReady);
    await pumpEventQueue();
    uploads.lookup(image, () async {
      started++;
      return null;
    }, backend.onReady);
    await pumpEventQueue();
    expect(uploads.lookup(image, () async {
      started++;
      return 'texture';
    }, backend.onReady), isNull);
    await pumpEventQueue();

    expect(started, 3);
    expect(backend.ready, 1, reason: 'only the upload that landed is news');
    expect(uploads.lookup(image, () async => 'again', backend.onReady),
        'texture');
  });
}
