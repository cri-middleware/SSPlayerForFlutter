import 'package:flutter_test/flutter_test.dart';
import 'package:ssgen_flutter/sswatch.dart';

void main() {
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
}
