// Event decode (§6C). Pure — no host Brain: a synthetic `.ssab` is built with
// the generated ObjectBuilders, wrapped in SsAnimeInfo, and decoded. This pins
// the FlatBuffers → plain-Dart mapping (including the Signal param union and the
// "inactive signal is dropped" rule) independently of the runtime.
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
// ignore: implementation_imports
// Re-exports the .ssab readers and adds back the flatc write-side classes,
// which live outside lib/ (see scripts/strip_fbs_builders.dart).
import 'support/ssab_builders.g.dart' as ssab;

/// A pack with one animation `anime_1` whose `events()` list has two entries:
///   [0] one UserData marker (all four payload kinds) on part 3.
///   [1] one active Signal (int param) + one inactive Signal (dropped) on part
///       2, and one Audio trigger on part 4.
Uint8List _buildSsab() {
  final anime = ssab.SsAnimeBinaryObjectBuilder(
    name: 'pack',
    animations: [
      ssab.AnimationDataObjectBuilder(
        name: 'anime_1',
        events: [
          ssab.EventsPerFrameObjectBuilder(
            frameIndex: 5,
            users: [
              ssab.EventUserDataObjectBuilder(
                partIndex: 3,
                value: ssab.PartAttributeUserDataObjectBuilder(
                  integer: ssab.IntValueEntryObjectBuilder(value: 42),
                  rect: ssab.BoundsObjectBuilder(left: 1, top: 2, right: 3, bottom: 4),
                  point: ssab.Vec2ObjectBuilder(v1: 7, v2: 8),
                  str: 'hello',
                ),
              ),
            ],
          ),
          ssab.EventsPerFrameObjectBuilder(
            frameIndex: 9,
            signals: [
              ssab.EventSignalObjectBuilder(
                partIndex: 2,
                value: ssab.PartAttributeSignalObjectBuilder(
                  active: true,
                  commandId: 'jump',
                  params: [
                    ssab.SignalCommandParamObjectBuilder(
                      paramId: 'power',
                      type: ssab.SignalCommandParamType.Integer,
                      valueType: ssab.SignalCommandParamValueTypeId.Integer,
                      value: ssab.IntValueEntryObjectBuilder(value: 99),
                    ),
                  ],
                ),
              ),
              ssab.EventSignalObjectBuilder(
                partIndex: 2,
                value: ssab.PartAttributeSignalObjectBuilder(
                  active: false,
                  commandId: 'ignored',
                ),
              ),
            ],
            audios: [
              ssab.EventAudioObjectBuilder(
                partIndex: 4,
                value: ssab.PartAttributeAudioObjectBuilder(
                  soundName: 'boom',
                  soundNameHash: 123,
                  soundListNameHash: 456,
                  loopNum: 2,
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  return anime.toBytes();
}

void main() {
  late SsAnimeInfo info;
  setUp(() => info = SsAnimeInfo(_buildSsab()));

  test('decodes a UserData marker with all four payload kinds', () {
    final decoded = info.decodePassedEvents('anime_1', [0]);
    expect(decoded.signals, isEmpty);
    expect(decoded.audios, isEmpty);
    expect(decoded.userData, hasLength(1));

    final u = decoded.userData.single;
    expect(u.partIndex, 3);
    expect(u.integer, 42);
    expect(u.rect, const Rect.fromLTRB(1, 2, 3, 4));
    expect(u.point, const Offset(7, 8));
    expect(u.string, 'hello');
  });

  test('decodes an active Signal and drops the inactive one', () {
    final decoded = info.decodePassedEvents('anime_1', [1]);
    expect(decoded.signals, hasLength(1), reason: 'inactive signal dropped');

    final s = decoded.signals.single;
    expect(s.partIndex, 2);
    expect(s.commandId, 'jump');
    expect(s.params, hasLength(1));
    expect(s.params.single.paramId, 'power');
    expect(s.params.single.value, 99);
  });

  test('decodes an Audio trigger (name + hashes + loop)', () {
    final decoded = info.decodePassedEvents('anime_1', [1]);
    expect(decoded.audios, hasLength(1));

    final a = decoded.audios.single;
    expect(a.partIndex, 4);
    expect(a.soundName, 'boom');
    expect(a.soundNameHash, 123);
    expect(a.soundListNameHash, 456);
    expect(a.loopNum, 2);
  });

  test('multiple indices accumulate into one flat set of lists', () {
    final decoded = info.decodePassedEvents('anime_1', [0, 1]);
    expect(decoded.userData, hasLength(1));
    expect(decoded.signals, hasLength(1));
    expect(decoded.audios, hasLength(1));
  });

  test('out-of-range indices are ignored', () {
    final decoded = info.decodePassedEvents('anime_1', [99, -1]);
    expect(decoded.userData, isEmpty);
    expect(decoded.signals, isEmpty);
    expect(decoded.audios, isEmpty);
  });

  test('an unknown animation decodes to nothing', () {
    final decoded = info.decodePassedEvents('nope', [0, 1]);
    expect(decoded.userData, isEmpty);
    expect(decoded.signals, isEmpty);
    expect(decoded.audios, isEmpty);
  });

  test('no indices decodes to nothing without touching the pack', () {
    final decoded = info.decodePassedEvents('anime_1', const []);
    expect(decoded.userData, isEmpty);
    expect(decoded.signals, isEmpty);
    expect(decoded.audios, isEmpty);
  });
}
