// Plays one SpriteStudio animation inside a FlameGame.
//
// The pack is a .ssab converted from a SpriteStudio project
// (`dart run ssconverter_dart:ssconvert`). List its folder in the app's
// pubspec.yaml so the reference textures beside it are bundled too:
//
//   flutter:
//     assets:
//       - assets/spritestudio/Ringo/

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:ssplayer_flame/ssplayer_flame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On the web the runtime is a wasm module loaded here; a no-op on native.
  await loadSsRuntime();
  runApp(GameWidget(game: RingoGame()));
}

class RingoGame extends FlameGame {
  @override
  Future<void> onLoad() async {
    add(
      SpriteStudioComponent.asset(
        'assets/spritestudio/Ringo/Ringo.ssab',
        animation: 'wait1',
        position: size / 2,
        anchor: Anchor.center,
      ),
    );
  }
}
