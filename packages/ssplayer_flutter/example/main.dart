// Plays one SpriteStudio animation in a Flutter app.
//
// The pack is a .ssab converted from a SpriteStudio project
// (`dart run ssconverter_dart:ssconvert`). List its folder in the app's
// pubspec.yaml so the reference textures beside it are bundled too:
//
//   flutter:
//     assets:
//       - assets/spritestudio/Ringo/

import 'package:flutter/widgets.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On the web the runtime is a wasm module loaded here; a no-op on native.
  await loadSsRuntime();
  runApp(
    const Center(
      child: SpriteStudioAnimation.asset(
        'assets/spritestudio/Ringo/Ringo.ssab',
        animation: 'wait1',
        width: 400,
        height: 400,
      ),
    ),
  );
}
