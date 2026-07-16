// Verifies SpriteStudioPlayer.reload() live-swaps the resource while preserving
// transport — the selected animation and the playhead — unlike load() which
// rewinds to frame 0. This is the primitive behind dev-time live reload
// ("save in the editor → the preview updates in place").
// The native Brain is bundled by ssruntime_dart's native-assets hook.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  final ssabPath = _firstExisting([
    'example/assets/spritestudio/overall/Basic.ssab',
    '../../example/assets/spritestudio/overall/Basic.ssab',
  ]);

  testWidgets('reload preserves the animation and playhead', (tester) async {
    if (ssabPath == null) {
      markTestSkipped('Basic.ssab missing — run deploy-examples.sh');
      return;
    }
    final bytes = Uint8List.fromList(File(ssabPath).readAsBytesSync());

    final player = SpriteStudioPlayer(vsync: tester);
    addTearDown(player.dispose);

    await player.load(bytes, loadTextures: false);
    final anim = player.getAnimations().first;
    player.setupAnimation(anim);
    expect(player.currentAnimation, anim);

    // Move off frame 0 so the "preserve playhead" behaviour is observable.
    player.seek(3);
    expect(player.frameNo, closeTo(3, 1e-6));

    // Re-load the SAME bytes (an editor re-export in practice) via reload().
    await player.reload(bytes, loadTextures: false);

    // Selection + playhead survive the resource swap...
    expect(player.currentAnimation, anim);
    expect(player.frameNo, closeTo(3, 1e-6));

    // ...whereas plain load() rewinds to frame 0 (the contrast reload avoids).
    await player.load(bytes, animationName: anim, loadTextures: false);
    expect(player.frameNo, closeTo(0, 1e-6));
  });
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
