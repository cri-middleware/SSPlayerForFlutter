import 'package:flutter_test/flutter_test.dart';
import 'package:ssgen_flutter/sswatch.dart';

void main() {
  group('--run passthrough', () {
    test('collects unrecognized args for flutter run', () {
      final o = SsWatchOptions.parse(['--run', '-d', 'macos', '--profile']);
      expect(o.run, isTrue);
      expect(o.passthrough, ['-d', 'macos', '--profile']);
    });

    test('--run off by default; device flag still peeled from passthrough', () {
      final o = SsWatchOptions.parse(['-d', 'emulator-5554', '--device']);
      expect(o.run, isFalse);
      expect(o.device, isTrue);
      expect(o.passthrough, ['-d', 'emulator-5554']);
    });
  });

  group('withLiveReloadDefine', () {
    test('appends the define when absent', () {
      expect(withLiveReloadDefine(['-d', 'macos']), [
        '-d',
        'macos',
        '--dart-define=SS_LIVE_RELOAD=true',
      ]);
    });

    test('leaves an existing define untouched (any value)', () {
      final args = ['--dart-define=SS_LIVE_RELOAD=false', '-d', 'macos'];
      expect(withLiveReloadDefine(args), same(args));
    });
  });

  group('noLiveReloadReason', () {
    test('a debug launch can take a push, on any target', () {
      expect(noLiveReloadReason(['-d', 'macos']), isNull);
      expect(noLiveReloadReason(['-d', 'chrome', '--device']), isNull);
    });

    test('--wasm, --release and --profile are refused up front', () {
      for (final mode in ['--wasm', '--release', '--profile']) {
        expect(noLiveReloadReason(['-d', 'chrome', mode]), isNotNull,
            reason: mode);
      }
    });
  });

  group('ChangeRunner', () {
    test('coalesces a burst into a single run', () async {
      var runs = 0;
      final r = ChangeRunner(
        debounce: const Duration(milliseconds: 20),
        onChange: () async => runs++,
      );
      r
        ..bump()
        ..bump()
        ..bump();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runs, 1);
      r.dispose();
    });
  });

  group('SsWatchOptions.parse', () {
    test('defaults when no flags given', () {
      final o = SsWatchOptions.parse([]);
      expect(o.vmServiceUri, isNull);
      expect(o.vmServiceUriFile, isNull);
      expect(o.projectRoot, isNull);
      expect(o.sourceDir, isNull);
      expect(o.debounceMs, 250);
      expect(o.once, isFalse);
      expect(o.help, isFalse);
    });

    test('peels off every flag', () {
      final o = SsWatchOptions.parse([
        '--vmservice-uri=http://127.0.0.1:1234/abc=/',
        '--vmservice-uri-file=/tmp/uri.txt',
        '--project-root=/tmp/app',
        '--source=/tmp/src',
        '--debounce=500',
        '--once',
      ]);
      expect(o.vmServiceUri, 'http://127.0.0.1:1234/abc=/');
      expect(o.vmServiceUriFile, '/tmp/uri.txt');
      expect(o.projectRoot, '/tmp/app');
      expect(o.sourceDir, '/tmp/src');
      expect(o.debounceMs, 500);
      expect(o.once, isTrue);
    });

    test('a URI with an = in it is not truncated', () {
      // The token=… suffix flutter appends contains `=`; substring-after-first-=
      // must keep the whole value.
      final o = SsWatchOptions.parse(['--vmservice-uri=ws://h:1/tok=en=/ws']);
      expect(o.vmServiceUri, 'ws://h:1/tok=en=/ws');
    });

    test('--help / -h sets help', () {
      expect(SsWatchOptions.parse(['--help']).help, isTrue);
      expect(SsWatchOptions.parse(['-h']).help, isTrue);
    });

    test('device flags default off / parse when given', () {
      final off = SsWatchOptions.parse([]);
      expect(off.device, isFalse);
      expect(off.embeddedDir, isNull);

      final on = SsWatchOptions.parse([
        '--device',
        '--embedded-dir=/tmp/emb',
      ]);
      expect(on.device, isTrue);
      expect(on.embeddedDir, '/tmp/emb');
    });

    test('a bad --debounce keeps the default', () {
      expect(SsWatchOptions.parse(['--debounce=nope']).debounceMs, 250);
    });

    test('unknown args are ignored, not fatal', () {
      final o = SsWatchOptions.parse(['--totally-unknown', '--once']);
      expect(o.once, isTrue);
    });
  });

  group('normalizeVmServiceUri', () {
    test('passes a ws/wss URI through unchanged', () {
      expect(
        normalizeVmServiceUri('ws://127.0.0.1:1234/abc=/ws'),
        'ws://127.0.0.1:1234/abc=/ws',
      );
      expect(
        normalizeVmServiceUri('wss://host:1/tok/ws'),
        'wss://host:1/tok/ws',
      );
    });

    test('converts an http URI to the ws form with a /ws suffix', () {
      final ws = normalizeVmServiceUri('http://127.0.0.1:1234/abc=/');
      expect(ws, startsWith('ws://127.0.0.1:1234/abc=/'));
      expect(ws, endsWith('/ws'));
    });

    test('trims surrounding whitespace (a URI file may carry a newline)', () {
      expect(
        normalizeVmServiceUri('  ws://h:1/t/ws\n'),
        'ws://h:1/t/ws',
      );
    });
  });

  // The device push is the only path whose routing depends on a naming
  // convention (the app's `ssAssetDir` last segment naming a `<stem>.sspj`).
  // Nothing else here reaches it, and a mismatch used to reload nothing in
  // silence — so pin every outcome.
  group('ssProjectStem / ssAssetDirStem', () {
    test('a .sspj path loses its extension, either separator', () {
      expect(ssProjectStem('SpriteStudio_Source/Ringo/Ringo.sspj'), 'Ringo');
      expect(ssProjectStem(r'C:\src\Doll\Doll.sspj'), 'Doll');
      expect(ssProjectStem('bare'), 'bare');
    });

    test('a project whose name holds a dot keeps everything before the last',
        () {
      expect(ssProjectStem('src/My.Project/My.Project.sspj'), 'My.Project');
    });

    test('an asset dir keeps its last segment verbatim — it is a directory', () {
      expect(ssAssetDirStem('assets/spritestudio/Ringo'), 'Ringo');
      // Not a file: a dotted directory must NOT be truncated, or it would stop
      // matching the `My.Project.sspj` the reconvert wrote it from.
      expect(ssAssetDirStem('assets/spritestudio/My.Project'), 'My.Project');
      expect(ssAssetDirStem('assets/spritestudio/Ringo/'), 'Ringo');
      expect(ssAssetDirStem('Ringo'), 'Ringo');
    });
  });

  group('routeEmbeddedPush', () {
    SsPushRouting route(
      String assetDir, {
      Set<String> converted = const {'Ringo'},
      Set<String> projects = const {'Ringo', 'Doll'},
      bool packExists = true,
    }) =>
        routeEmbeddedPush(
          assetDir: assetDir,
          convertedStems: converted,
          projectStems: projects,
          packExists: () => packExists,
        );

    test('pushes when the project reconverted and holds the pack', () {
      expect(route('assets/spritestudio/Ringo'), SsPushRouting.push);
    });

    test('an untouched project is an ordinary no-op, not a mismatch', () {
      expect(route('assets/spritestudio/Doll'),
          SsPushRouting.projectUnchanged);
    });

    test('an asset dir matching no project is reported, never silent', () {
      expect(route('assets/anim/hero'), SsPushRouting.unknownProject);
    });

    test('a reconverted project that emits no such pack is reported', () {
      expect(route('assets/spritestudio/Ringo', packExists: false),
          SsPushRouting.packMissing);
    });

    test('the pack is only looked for once the names agree', () {
      var looked = false;
      routeEmbeddedPush(
        assetDir: 'assets/anim/hero',
        convertedStems: const {'Ringo'},
        projectStems: const {'Ringo'},
        packExists: () {
          looked = true;
          return true;
        },
      );
      expect(looked, isFalse, reason: 'no stat for a dir that cannot match');
    });
  });
}
