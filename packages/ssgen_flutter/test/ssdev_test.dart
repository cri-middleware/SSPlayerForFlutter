import 'package:flutter_test/flutter_test.dart';
import 'package:ssgen_flutter/ssdev.dart';

void main() {
  group('SsDevOptions.parse', () {
    test('forwards unknown args to flutter, defaults elsewhere', () {
      final o = SsDevOptions.parse(['-d', 'emulator-5554', '--verbose']);
      expect(o.flutterArgs, ['-d', 'emulator-5554', '--verbose']);
      expect(o.projectRoot, isNull);
      expect(o.sourceDir, isNull);
      expect(o.debounceMs, 250);
      expect(o.noWatch, isFalse);
    });

    test('peels off --ss-* options', () {
      final o = SsDevOptions.parse([
        '--ss-project-root=/tmp/app',
        '--ss-source=/tmp/src',
        '--ss-debounce=500',
        '--ss-no-watch',
        '-d',
        'macos',
      ]);
      expect(o.projectRoot, '/tmp/app');
      expect(o.sourceDir, '/tmp/src');
      expect(o.debounceMs, 500);
      expect(o.noWatch, isTrue);
      expect(o.flutterArgs, ['-d', 'macos']);
    });

    test('a bad --ss-debounce keeps the default', () {
      expect(SsDevOptions.parse(['--ss-debounce=nope']).debounceMs, 250);
    });
  });

  group('withLiveReloadDefine', () {
    test('appends the define when absent', () {
      expect(withLiveReloadDefine(['-d', 'macos']), [
        '-d',
        'macos',
        '--dart-define=$ssLiveReloadDefine=true',
      ]);
    });

    test('leaves an existing define untouched (any value)', () {
      final args = ['--dart-define=$ssLiveReloadDefine=false', '-d', 'macos'];
      expect(withLiveReloadDefine(args), same(args));
    });
  });

  group('DaemonMessage.decode', () {
    test('parses an event with params', () {
      final m = DaemonMessage.decode(
        '[{"event":"app.start","params":{"appId":"abc"}}]',
      );
      expect(m, isNotNull);
      expect(m!.isEvent, isTrue);
      expect(m.isResponse, isFalse);
      expect(m.event, 'app.start');
      expect(m.params!['appId'], 'abc');
    });

    test('parses a response with a result code', () {
      final m = DaemonMessage.decode('[{"id":3,"result":{"code":0}}]');
      expect(m!.isResponse, isTrue);
      expect(m.id, 3);
      expect((m.result as Map)['code'], 0);
    });

    test('returns null on non-protocol / malformed lines', () {
      expect(DaemonMessage.decode('Launching lib/main.dart...'), isNull);
      expect(DaemonMessage.decode(''), isNull);
      expect(DaemonMessage.decode('[not json'), isNull);
      expect(DaemonMessage.decode('{"event":"x"}'), isNull); // not array-wrapped
    });
  });

  group('encodeDaemonRequest', () {
    test('round-trips through decode (id + params)', () {
      final line = encodeDaemonRequest(7, 'app.restart', {
        'appId': 'abc',
        'fullRestart': false,
      });
      final m = DaemonMessage.decode(line);
      expect(m!.id, 7);
      expect(m.params!['appId'], 'abc');
      expect(m.params!['fullRestart'], false);
    });
  });

  group('ChangeRunner', () {
    test('coalesces a burst into a single run', () async {
      var runs = 0;
      final runner = ChangeRunner(
        debounce: const Duration(milliseconds: 10),
        onChange: () async {
          runs++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
      );
      runner
        ..bump()
        ..bump()
        ..bump();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runs, 1);
      runner.dispose();
    });
  });
}
