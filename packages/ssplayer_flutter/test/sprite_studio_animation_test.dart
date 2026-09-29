// The owning widget: everything the quickstart used to make the caller write —
// the ticker, the load, the selection, the disposal — done once, here.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

/// Pump until [until] holds, letting the widget's **real** work progress.
///
/// The load reads the bundle and decodes images, which is real asynchrony, while
/// `testWidgets` runs the body in a fake-async zone. `runAsync` steps out so the
/// real work can advance; the `pump` after it flushes the fake zone's
/// continuations. Neither alone is enough — which is also why a `Completer` does
/// not work here: it would be completed from the fake zone and awaited in the
/// real one, and neither side would ever run.
Future<void> pumpUntil(WidgetTester tester, bool Function() until) async {
  for (var i = 0; i < 400; i++) {
    if (until()) return;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  fail('timed out waiting for the widget');
}

bool get _drawing => find.byType(SpriteStudioView).evaluate().isNotEmpty;

/// Steps the fake clock one display frame at a time, so the player's ticker
/// sees ordinary deltas rather than one jump it would cap.
Future<void> pumpFrames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final assetDir = _firstExisting([
    'examples/overall/assets/spritestudio/overall',
    '../../examples/overall/assets/spritestudio/overall',
  ]);

  Widget wrap(Widget child) =>
      Directionality(textDirection: TextDirection.ltr, child: child);

  testWidgets('loads, selects the pack first animation, and plays',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing — run scripts/deploy-examples.sh');
      return;
    }
    SpriteStudioPlayer? seen;
    await tester.pumpWidget(wrap(SpriteStudioAnimation.asset(
      'assets/x/Basic.ssab',
      width: 100,
      height: 100,
      bundle: _DirBundle(assetDir),
      onPlayerCreated: (p) => seen = p,
    )));
    expect(seen, isNotNull, reason: 'onPlayerCreated fires before the load');
    await pumpUntil(tester, () => _drawing);

    final player = seen!;
    // No `animation:` was given, so the pack's first is selected rather than
    // nothing — an unselected pack draws an empty box, which is exactly what a
    // failed load looks like too.
    expect(player.currentAnimation, player.animationNames.first);
    expect(player.isPlaying, isTrue, reason: 'playing defaults to on');
    expect(player.loopCount, -1);
  });

  testWidgets('shows the placeholder until the first frame is drawable',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    await tester.pumpWidget(wrap(SpriteStudioAnimation.asset(
      'assets/x/Basic.ssab',
      bundle: _DirBundle(assetDir),
      placeholder: const Text('loading'),
    )));
    // Before the load resolves: the placeholder, not an empty box that reads as
    // a broken pack.
    expect(find.text('loading'), findsOneWidget);
    expect(_drawing, isFalse);

    await pumpUntil(tester, () => _drawing);
    expect(find.text('loading'), findsNothing);
  });

  testWidgets('playing off from the first build leaves the first frame posed',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    SpriteStudioPlayer? seen;
    // One bundle across builds: a different one is a different source, and the
    // widget builds a new player for it.
    final bundle = _DirBundle(assetDir);
    Widget build(bool playing) => wrap(SpriteStudioAnimation.asset(
          'assets/x/Basic.ssab',
          playing: playing,
          bundle: bundle,
          onPlayerCreated: (p) => seen = p,
        ));
    await tester.pumpWidget(build(false));
    await pumpUntil(tester, () => _drawing);

    expect(seen!.isPlaying, isFalse);
    expect(seen!.currentAnimation, isNotNull, reason: 'still selected + posed');

    // Nothing has run yet, so turning it on heads out from the start.
    await tester.pumpWidget(build(true));
    expect(seen!.isPlaying, isTrue);
    expect(seen!.isPausing, isFalse);
  });

  testWidgets('playing is a state: off holds in place, on carries on',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    SpriteStudioPlayer? seen;
    final bundle = _DirBundle(assetDir);
    Widget build(bool playing) => wrap(SpriteStudioAnimation.asset(
          'assets/x/Basic.ssab',
          playing: playing,
          bundle: bundle,
          onPlayerCreated: (p) => seen = p,
        ));
    await tester.pumpWidget(build(true));
    await pumpUntil(tester, () => _drawing);
    await pumpFrames(tester, 10);
    final player = seen!;

    await tester.pumpWidget(build(false));
    expect(player.isPausing, isTrue);
    final held = player.frameNo;
    expect(held, greaterThan(0), reason: 'it had advanced before the hold');
    await pumpFrames(tester, 10);
    expect(player.frameNo, held, reason: 'a hold does not advance');

    // On again: a resume from where it stood, not a head-out. The next ticks
    // move it on from `held`; a rewind would have put it back near 0 first.
    await tester.pumpWidget(build(true));
    expect(player.isPausing, isFalse);
    expect(player.frameNo, held);
    await pumpFrames(tester, 2);
    expect(player.frameNo, greaterThan(held));
  });

  testWidgets('playing on after every loop has played starts over',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    SpriteStudioPlayer? seen;
    final bundle = _DirBundle(assetDir);
    Widget build(bool playing) => wrap(SpriteStudioAnimation.asset(
          'assets/x/Basic.ssab',
          loopCount: 1,
          playing: playing,
          bundle: bundle,
          onPlayerCreated: (p) => seen = p,
        ));
    await tester.pumpWidget(build(true));
    await pumpUntil(tester, () => _drawing);
    final player = seen!;
    for (var i = 0; i < 2000 && !player.isFinished; i++) {
      await pumpFrames(tester, 1);
    }
    expect(player.isFinished, isTrue);

    await tester.pumpWidget(build(false));
    await tester.pumpWidget(build(true));
    expect(player.isFinished, isFalse);
    expect(player.isPlaying, isTrue);
    expect(player.frameNo, player.startFrame);
  });

  testWidgets('changing the animation does not rebuild the player',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    final created = <SpriteStudioPlayer>[];
    final bundle = _DirBundle(assetDir);
    Widget build(String? animation) => wrap(SpriteStudioAnimation.asset(
          'assets/x/Basic.ssab',
          animation: animation,
          bundle: bundle,
          onPlayerCreated: created.add,
        ));

    await tester.pumpWidget(build(null));
    await pumpUntil(tester, () => _drawing);
    final names = created.single.animationNames;
    expect(names, isNotEmpty);
    await pumpFrames(tester, 10);
    final before = created.single.frameNo;
    expect(before, greaterThan(0));

    // Naming what was already selected implicitly: the animation prop changed,
    // so `didUpdateWidget` takes its animation branch — but the pack did not.
    await tester.pumpWidget(build(names.first));
    await tester.pump();

    // One player for the life of the asset key. Re-reading the pack to change
    // which animation is selected would throw away its textures and its clock.
    expect(created, hasLength(1));
    expect(created.single.currentAnimation, names.first);
    // And the selection did not move, so nothing heads out: no rewind.
    expect(created.single.isPlaying, isTrue);
    expect(created.single.frameNo, greaterThanOrEqualTo(before));
  });

  testWidgets('switching the animation starts the new one while playing',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    SpriteStudioPlayer? seen;
    final bundle = _DirBundle(assetDir);
    Widget build(String? animation, {bool playing = true}) =>
        wrap(SpriteStudioAnimation.asset(
          'assets/x/PartsColor.ssab',
          animation: animation,
          playing: playing,
          bundle: bundle,
          onPlayerCreated: (p) => seen = p,
        ));
    await tester.pumpWidget(build(null));
    await pumpUntil(tester, () => _drawing);
    final player = seen!;
    final names = player.animationNames;
    expect(names, hasLength(greaterThanOrEqualTo(2)));

    // A state-driven switch, the declarative widget's reason to exist.
    // `setAnimation` alone selects and poses; this one has to keep moving.
    await tester.pumpWidget(build(names[1]));
    expect(player.currentAnimation, names[1]);
    expect(player.isPlaying, isTrue);
    await pumpFrames(tester, 10);
    expect(player.frameNo, greaterThan(0));

    // Not playing: the switch poses the new animation and leaves it there.
    await tester.pumpWidget(build(names[1], playing: false));
    await tester.pumpWidget(build(names[0], playing: false));
    expect(player.currentAnimation, names[0]);
    expect(player.isPlaying, isFalse);

    // A name the pack lacks selects nothing, so nothing heads out either.
    await tester.pumpWidget(build(names[0]));
    expect(player.isPlaying, isTrue);
    await pumpFrames(tester, 10);
    final running = player.frameNo;
    await tester.pumpWidget(build('no_such_animation'));
    expect(player.currentAnimation, names[0]);
    expect(player.isPlaying, isTrue);
    expect(player.frameNo, running);
  });

  testWidgets('speedScale and the flips reach the player before the load',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    SpriteStudioPlayer? seen;
    final bundle = _DirBundle(assetDir);
    Widget build({double speed = 2, bool flipY = false}) =>
        wrap(SpriteStudioAnimation.asset(
          'assets/x/Basic.ssab',
          speedScale: speed,
          flipX: true,
          flipY: flipY,
          bundle: bundle,
          onPlayerCreated: (p) {
            seen = p;
            // Before the load, and already carrying the parameters.
            expect(p.speedScale, 2);
            expect(p.flipX, isTrue);
          },
        ));
    await tester.pumpWidget(build());
    await pumpUntil(tester, () => _drawing);
    expect(seen!.speedScale, 2, reason: 'the load keeps what was cached');
    expect(seen!.flipX, isTrue);

    await tester.pumpWidget(build(speed: 0.5, flipY: true));
    expect(seen!.speedScale, 0.5);
    expect(seen!.flipY, isTrue);
  });

  testWidgets('a call made through onPlayerCreated stands until its '
      'parameter changes', (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    SpriteStudioPlayer? seen;
    final bundle = _DirBundle(assetDir);
    Widget build({double speed = 1, Widget? placeholder}) =>
        wrap(SpriteStudioAnimation.asset(
          'assets/x/Basic.ssab',
          speedScale: speed,
          placeholder: placeholder,
          bundle: bundle,
          onPlayerCreated: (p) {
            seen = p;
            p.speedScale = 3;
          },
        ));
    await tester.pumpWidget(build());
    await pumpUntil(tester, () => _drawing);
    expect(seen!.speedScale, 3, reason: 'the load did not put the prop back');

    // A rebuild that does not change it leaves it alone.
    await tester.pumpWidget(build(placeholder: const SizedBox()));
    expect(seen!.speedScale, 3);

    await tester.pumpWidget(build(speed: 1.5));
    expect(seen!.speedScale, 1.5);
  });

  testWidgets('a load failure reaches onError, not the zone', (tester) async {
    Object? reported;
    await tester.pumpWidget(wrap(SpriteStudioAnimation.asset(
      'assets/nope/Missing.ssab',
      bundle: _EmptyBundle(),
      placeholder: const Text('loading'),
      onError: (e, _) => reported = e,
    )));
    await pumpUntil(tester, () => reported != null);

    // Still the placeholder: there is nothing to draw, and the widget does not
    // pretend otherwise.
    expect(find.text('loading'), findsOneWidget);
    expect(_drawing, isFalse);
  });
}

/// Serves any key by its basename out of a directory read into memory up front.
class _DirBundle extends CachingAssetBundle {
  _DirBundle(String dir) {
    for (final f in Directory(dir).listSync().whereType<File>()) {
      _files[f.uri.pathSegments.last] = f.readAsBytesSync();
    }
  }
  final Map<String, Uint8List> _files = {};

  @override
  Future<ByteData> load(String key) async {
    final bytes = _files[key.split('/').last];
    if (bytes == null) throw FlutterError('not in bundle: $key');
    return ByteData.sublistView(bytes);
  }
}

class _EmptyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      throw FlutterError('not in bundle: $key');
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (Directory(p).existsSync()) return p;
  }
  return null;
}
