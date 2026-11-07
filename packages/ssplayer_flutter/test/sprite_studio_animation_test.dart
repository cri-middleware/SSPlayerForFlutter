// The owning widget: the ticker, the load, the selection and the disposal, done
// once, here.
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

  testWidgets('changing the asset key builds a new player', (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing — run scripts/deploy-examples.sh');
      return;
    }
    final bundle = _DirBundle(assetDir);
    final created = <SpriteStudioPlayer>[];
    Widget at(String key) => wrap(SpriteStudioAnimation.asset(
          key,
          width: 100,
          height: 100,
          bundle: bundle,
          onPlayerCreated: created.add,
        ));

    await tester.pumpWidget(at('assets/x/Basic.ssab'));
    await pumpUntil(tester, () => _drawing);

    await tester.pumpWidget(at('assets/x/Mask.ssab'));
    expect(tester.takeException(), isNull);
    await pumpUntil(tester, () => _drawing);

    expect(created, hasLength(2));
    expect(created.last.isPlaying, isTrue);
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

  testWidgets('with a transition a switch crossfades, and the prop goes back',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    SpriteStudioPlayer? seen;
    final bundle = _DirBundle(assetDir);
    Widget build(String? animation) => wrap(SpriteStudioAnimation.asset(
          'assets/x/PartsColor.ssab',
          animation: animation,
          transition: const Duration(milliseconds: 300),
          bundle: bundle,
          onPlayerCreated: (p) => seen = p,
        ));
    await tester.pumpWidget(build(null));
    await pumpUntil(tester, () => _drawing);
    final player = seen!;
    final names = player.animationNames;
    expect(names, hasLength(greaterThanOrEqualTo(2)));
    // The first selection is always a switch: there is nothing to fade from.
    expect(player.trackFadeProgress(0), isNull);
    await pumpFrames(tester, 5);

    await tester.pumpWidget(build(names[1]));
    expect(player.currentAnimation, names[1]);
    expect(player.trackFadeProgress(0), isNotNull, reason: 'it crossfades');
    expect(player.isPlaying, isTrue);

    // Back by the prop, mid-fade. Had the crossfade left the old name
    // recorded, this would read as no change and stay.
    await tester.pumpWidget(build(names[0]));
    expect(player.currentAnimation, names[0]);
    await pumpFrames(tester, 30);
    expect(player.trackFadeProgress(0), isNull);
    expect(player.isPlaying, isTrue);
  });

  testWidgets('a one-shot switch plays out and hands back, props alone',
      (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    // The Quick Start's state-driven example: the one-shot's loop count and its
    // name change in the same rebuild, and its finish flips the state back.
    SpriteStudioPlayer? seen;
    var names = const <String>[];
    var oneShot = false;
    final bundle = _DirBundle(assetDir);
    late StateSetter setOuter;
    await tester.pumpWidget(wrap(StatefulBuilder(builder: (context, setState) {
      setOuter = setState;
      return SpriteStudioAnimation.asset(
        'assets/x/PartsColor.ssab',
        animation: names.isEmpty ? null : (oneShot ? names[1] : names[0]),
        loopCount: oneShot ? 1 : -1,
        bundle: bundle,
        onPlayerCreated: (p) => seen = p,
        onAnimationFinished: () => setOuter(() => oneShot = false),
      );
    })));
    await pumpUntil(tester, () => _drawing);
    final player = seen!;
    setOuter(() => names = player.animationNames);
    await tester.pump();

    setOuter(() => oneShot = true);
    await tester.pump();
    expect(player.currentAnimation, names[1]);
    expect(player.loopCount, 1, reason: 'kept across the switch');
    expect(player.isPlaying, isTrue);

    for (var i = 0; i < 4000 && oneShot; i++) {
      await pumpFrames(tester, 1);
    }
    expect(oneShot, isFalse, reason: 'the one-shot finished');
    await tester.pump();
    expect(player.currentAnimation, names[0]);
    expect(player.loopCount, -1);
    expect(player.isPlaying, isTrue);
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
    void mine() {}
    final bundle = _DirBundle(assetDir);
    Widget build({double speed = 1, Widget? placeholder}) =>
        wrap(SpriteStudioAnimation.asset(
          'assets/x/Basic.ssab',
          speedScale: speed,
          placeholder: placeholder,
          bundle: bundle,
          onPlayerCreated: (p) {
            seen = p;
            p
              ..speedScale = 3
              ..onAnimationLooped = mine;
          },
        ));
    await tester.pumpWidget(build());
    await pumpUntil(tester, () => _drawing);
    expect(seen!.speedScale, 3, reason: 'the load did not put the prop back');

    // A rebuild that changes neither leaves both alone.
    await tester.pumpWidget(build(placeholder: const SizedBox()));
    expect(seen!.speedScale, 3);
    expect(seen!.onAnimationLooped, same(mine),
        reason: 'no onAnimationLooped parameter, so the slot is not ours');

    await tester.pumpWidget(build(speed: 1.5));
    expect(seen!.speedScale, 1.5);
  });

  testWidgets('the event parameters fire, and follow the closure they are '
      'given', (tester) async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing');
      return;
    }
    SpriteStudioPlayer? seen;
    final log = <String>[];
    final bundle = _DirBundle(assetDir);
    // Two cycles, so the keys are crossed again after the closure is swapped.
    Widget build(String tag, {bool withUserData = true}) =>
        wrap(SpriteStudioAnimation.asset(
          'assets/x/UserData.ssab',
          loopCount: 2,
          bundle: bundle,
          onPlayerCreated: (p) => seen = p,
          onLoaded: (_) => log.add('loaded'),
          onAnimationStarted: () => log.add('started'),
          onAnimationLooped: () => log.add('looped'),
          onAnimationFinished: () => log.add('finished'),
          onUserData: withUserData ? (_) => log.add('userData:$tag') : null,
        ));
    await tester.pumpWidget(build('a'));
    await pumpUntil(tester, () => _drawing);
    expect(log.take(2), ['started', 'loaded'],
        reason: 'the start the widget issues after the load is reported, '
            'before onLoaded');

    // A new closure on each build is what inline callbacks look like; the one
    // given last is the one that fires.
    log.clear();
    await tester.pumpWidget(build('b'));
    final player = seen!;
    for (var i = 0; i < 4000 && !player.isFinished; i++) {
      await pumpFrames(tester, 1);
    }
    expect(log, contains('looped'));
    expect(log, contains('userData:b'));
    expect(log, isNot(contains('userData:a')));
    expect(log.last, 'finished');

    // Dropping the parameter releases the player's slot.
    await tester.pumpWidget(build('b', withUserData: false));
    expect(player.onUserData, isNull);
  });

  group('children', () {
    // Basic's first part below the root, found from the pack rather than named
    // here, so the test follows whatever the fixture calls it.
    Future<String> aPart(WidgetTester tester, AssetBundle bundle) async {
      SpriteStudioPlayer? seen;
      await tester.pumpWidget(wrap(SpriteStudioAnimation.asset(
        'assets/x/Basic.ssab',
        bundle: bundle,
        onPlayerCreated: (p) => seen = p,
      )));
      await pumpUntil(tester, () => _drawing);
      return seen!.partNames.names
          .firstWhere((n) => seen!.partTransform(n) != null && n != 'root');
    }

    testWidgets('an anchor in them follows a part with no player of its own',
        (tester) async {
      if (assetDir == null) {
        markTestSkipped('overall assets missing');
        return;
      }
      final bundle = _DirBundle(assetDir);
      final part = await aPart(tester, bundle);
      final marker = GlobalKey();
      SpriteStudioPlayer? seen;
      // Tight constraints, which a view alone fills: the children must cover
      // that same box, or the anchor centres on a different one.
      await tester.pumpWidget(wrap(Center(
        child: SizedBox(
          width: 300,
          height: 200,
          child: SpriteStudioAnimation.asset(
            'assets/x/Basic.ssab',
            bundle: bundle,
            onPlayerCreated: (p) => seen = p,
            children: [
              SpriteStudioPartAnchor(
                partName: part,
                child: SizedBox(key: marker, width: 1, height: 1),
              ),
            ],
          ),
        ),
      )));
      await pumpUntil(tester, () => find.byKey(marker).evaluate().isNotEmpty);

      final view = tester.getRect(find.byType(SpriteStudioView));
      expect(view.size, const Size(300, 200));
      final t = seen!.partTransform(part)!.getTranslation();
      final at = tester.getTopLeft(find.byKey(marker));
      expect(at.dx, closeTo(view.center.dx + t.x, 1e-6));
      expect(at.dy, closeTo(view.center.dy + t.y, 1e-6));
    });

    testWidgets('are built with the first frame, not over the placeholder',
        (tester) async {
      if (assetDir == null) {
        markTestSkipped('overall assets missing');
        return;
      }
      await tester.pumpWidget(wrap(SpriteStudioAnimation.asset(
        'assets/x/Basic.ssab',
        bundle: _DirBundle(assetDir),
        placeholder: const Text('loading'),
        children: const [Text('over')],
      )));
      expect(find.text('loading'), findsOneWidget);
      expect(find.text('over'), findsNothing);
      await pumpUntil(tester, () => _drawing);
      expect(find.text('over'), findsOneWidget);
    });

    testWidgets('reach the player through playerOf', (tester) async {
      if (assetDir == null) {
        markTestSkipped('overall assets missing');
        return;
      }
      SpriteStudioPlayer? created, reached;
      await tester.pumpWidget(wrap(SpriteStudioAnimation.asset(
        'assets/x/Basic.ssab',
        bundle: _DirBundle(assetDir),
        onPlayerCreated: (p) => created = p,
        children: [
          Builder(builder: (context) {
            reached = SpriteStudioAnimation.playerOf(context);
            return const SizedBox();
          }),
        ],
      )));
      await pumpUntil(tester, () => reached != null);
      expect(reached, same(created));
    });
  });

  testWidgets('an anchor with no player and none above it says so',
      (tester) async {
    await tester.pumpWidget(wrap(const SpriteStudioPartAnchor(
      partName: 'apple',
      child: SizedBox(),
    )));
    final error = tester.takeException();
    expect(error, isA<FlutterError>());
    expect('$error', contains('no player to follow'));
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
