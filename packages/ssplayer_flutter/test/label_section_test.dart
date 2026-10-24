// A playback section, by frame and named by labels.
//
// The label table is read from the pack, not the Brain, so its two halves are
// tested apart: the table itself on a synthetic `.ssab` (no runtime), and the
// section it sets on `Signal.ssab`, whose `anime_1` runs 0..30 and labels
// frames 10 (`Start`) and 20 (`End`).
//
//   flutter test test/label_section_test.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';
import 'package:ssplayer_flutter/src/ssab_info.dart' show labelTableOf;

import 'support/ssab_builders.g.dart' as ssab;

Uint8List _packWithLabels() => ssab.SsAnimeBinaryObjectBuilder(
      name: 'pack',
      animations: [
        ssab.AnimationDataObjectBuilder(
          name: 'button',
          startFrame: 0,
          endFrame: 59,
          // Out of frame order, as the converter writes them (by name hash).
          labels: [
            ssab.LabelObjectBuilder(nameHash: 3, name: 'pressed', time: 40),
            ssab.LabelObjectBuilder(nameHash: 1, name: 'normal', time: 0),
            ssab.LabelObjectBuilder(nameHash: 2, name: 'hover', time: 20),
          ],
        ),
        ssab.AnimationDataObjectBuilder(name: 'plain', endFrame: 9),
      ],
    ).toBytes();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('label table', () {
    final info = SsAnimeInfo(_packWithLabels());

    test('lists the labels in frame order', () {
      final table = labelTableOf(info, 'button')!;
      expect(table.labels.map((l) => l.name), ['normal', 'hover', 'pressed']);
      expect(table.labels.map((l) => l.frame), [0, 20, 40]);
    });

    test('resolves a label, and _start / _end to the animation range', () {
      final table = labelTableOf(info, 'button')!;
      expect(table.frameOf('hover'), 20);
      expect(table.frameOf('_start'), 0);
      expect(table.frameOf('_end'), 59);
      expect(table.frameOf('Hover'), isNull, reason: 'names match exactly');
    });

    test('an animation without labels still has _start and _end', () {
      final table = labelTableOf(info, 'plain')!;
      expect(table.labels, isEmpty);
      expect(table.frameOf('_end'), 9);
    });

    test('an unknown animation has no table', () {
      expect(labelTableOf(info, 'nope'), isNull);
    });
  });

  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Signal.ssab',
    '../../examples/overall/assets/spritestudio/overall/Signal.ssab',
  ]);

  Future<SpriteStudioPlayer?> loaded() async {
    if (ssabPath == null) return null;
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);
    await player.load(File(ssabPath).readAsBytesSync(),
        animationName: 'anime_1', loadTextures: false);
    return player;
  }

  List<String> captureLog() {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    return lines;
  }

  group('setAnimationSection', () {
    test('does nothing before load', () {
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      final lines = captureLog();
      expect(player.setAnimationSection(20, 10), isFalse);
      expect(lines, isEmpty);
    });

    test('a section can start on the last frame, and holds it', () async {
      final player = await loaded();
      if (player == null) {
        markTestSkipped('Signal.ssab missing — run scripts/deploy-examples.sh');
        return;
      }
      expect((player.startFrame, player.endFrame), (0, 30));

      expect(player.setAnimationSection(30, 30), isTrue);
      expect((player.startFrame, player.endFrame), (30, 30));
      expect(player.frameNo, 30);

      expect(player.setAnimationSection(0, 10), isTrue);
      // An end out of range is the animation's edge: the last frame again.
      expect(player.setAnimationSection(30, -1), isTrue);
      expect((player.startFrame, player.endFrame), (30, 30));
    });

    test('an end before the start is refused, keeps the section, and reports '
        'once', () async {
      final player = await loaded();
      if (player == null) {
        markTestSkipped('Signal.ssab missing — run scripts/deploy-examples.sh');
        return;
      }
      expect(player.setAnimationSection(10, 20), isTrue);
      player
        ..play()
        ..advance(const Duration(milliseconds: 100));
      final playhead = player.frameNo;
      expect(playhead, greaterThan(10));
      final lines = captureLog();

      expect(player.setAnimationSection(20, 10), isFalse);
      expect(player.setAnimationSection(20, 10), isFalse);
      expect((player.startFrame, player.endFrame), (10, 20));
      expect(player.frameNo, playhead, reason: 'the playhead stays too');

      final said =
          lines.where((l) => l.contains('setAnimationSection')).toList();
      expect(said, hasLength(1), reason: lines.join('\n'));
      expect(said.single, contains('(20, 10)'));

      // Keyed on the pair: a different one has its own line.
      expect(player.setAnimationSection(25, 5), isFalse);
      expect(lines.where((l) => l.contains('(25, 5)')), hasLength(1));
    });
  });

  group('setAnimationSectionByLabel', () {
    test('does nothing before load', () {
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);
      expect(player.setAnimationSectionByLabel('Start', 'End'), isFalse);
    });

    test('runs from one label to the other, offsets added', () async {
      final player = await loaded();
      if (player == null) {
        markTestSkipped('Signal.ssab missing — run scripts/deploy-examples.sh');
        return;
      }
      expect(player.setAnimationSectionByLabel('Start', 'End'), isTrue);
      expect((player.startFrame, player.endFrame), (10, 20));
      expect(player.frameNo, 10, reason: 'the playhead moves to the start');

      expect(
          player.setAnimationSectionByLabel('Start', 'End',
              startOffset: 2, endOffset: -1),
          isTrue);
      expect((player.startFrame, player.endFrame), (12, 19));
    });

    test('_start and _end are the ends of the animation', () async {
      final player = await loaded();
      if (player == null) {
        markTestSkipped('Signal.ssab missing — run scripts/deploy-examples.sh');
        return;
      }
      final first = player.startFrame, last = player.endFrame;
      expect(player.setAnimationSectionByLabel('End', '_end'), isTrue);
      expect((player.startFrame, player.endFrame), (20, last));
      // `_start` reads the animation, not the section just set.
      expect(player.setAnimationSectionByLabel('_start', 'Start'), isTrue);
      expect((player.startFrame, player.endFrame), (first, 10));
    });

    test('an end before the start is pulled up to it', () async {
      final player = await loaded();
      if (player == null) {
        markTestSkipped('Signal.ssab missing — run scripts/deploy-examples.sh');
        return;
      }
      expect(player.setAnimationSectionByLabel('End', 'Start'), isTrue);
      expect((player.startFrame, player.endFrame), (20, 20));
    });

    test('a missing label fails, keeps the section, and reports once',
        () async {
      final player = await loaded();
      if (player == null) {
        markTestSkipped('Signal.ssab missing — run scripts/deploy-examples.sh');
        return;
      }
      player.setAnimationSectionByLabel('Start', 'End');
      final lines = captureLog();

      expect(player.setAnimationSectionByLabel('Start', 'Ned'), isFalse);
      expect(player.setAnimationSectionByLabel('Start', 'Ned'), isFalse);
      expect((player.startFrame, player.endFrame), (10, 20));

      final said = lines.where((l) => l.contains('"Ned"')).toList();
      expect(said, hasLength(1), reason: lines.join('\n'));
      expect(said.single, contains('animation "anime_1"'));
      expect(said.single, isNot(contains('"Start"')),
          reason: 'only the label that is missing is named');
    });
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
