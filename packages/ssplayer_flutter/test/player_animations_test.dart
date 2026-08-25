// Verifies SpriteStudioPlayer.animationNames enumerates the loaded pack's
// animation names (the list the example's animation dropdown is built from).
// The native Brain is bundled by ssruntime_dart's native-assets hook.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  final ssabPath = _firstExisting([
    'examples/overall/assets/spritestudio/overall/Basic.ssab',
    '../../examples/overall/assets/spritestudio/overall/Basic.ssab',
  ]);

  testWidgets('getAnimations lists the loaded pack animations',
      (tester) async {
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());

    // WidgetTester is a TickerProvider, so it can back the player's Ticker.
    final player = SpriteStudioPlayer(vsync: tester);
    addTearDown(player.dispose);

    // Empty before the first load.
    expect(player.animationNames, isEmpty);

    // loadTextures: false — no AssetBundle in a unit test.
    await player.load(bytes, loadTextures: false);

    final anims = player.animationNames;
    expect(anims, isNotEmpty);
    // Matches the metadata parsed straight from the bytes…
    expect(anims, SsAnimeInfo(bytes).animationNames);
    // …and every enumerated name is accepted by setAnimation.
    expect(player.setAnimation(anims.first), isTrue);
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
