import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:ssplayer_flame/ssplayer_flame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On the web the Brain is a wasm module fetched at runtime; await it before the
  // game is created. A no-op on native (the native asset resolves eagerly).
  //
  // Without this the web build is not an error, it is a blank screen: the .ssab
  // still loads, the component still mounts, and nothing ever draws.
  await loadSsRuntime();
  runApp(const FlameExampleApp());
}

class FlameExampleApp extends StatefulWidget {
  const FlameExampleApp({super.key});

  @override
  State<FlameExampleApp> createState() => _FlameExampleAppState();
}

class _FlameExampleAppState extends State<FlameExampleApp> {
  // Built once and held, NOT constructed in `build`: a game made there is
  // replaced on every rebuild (and every hot reload), and the one it replaces
  // keeps its native Brain and decoded textures alive.
  late final SpriteStudioGame game = SpriteStudioGame();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ssplayer_flame example',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('ssplayer_flame — Ringo')),
        // Flame owns the game loop; the SpriteStudioComponent's `update`/`render`
        // ride it. A plain GestureDetector in the Flutter layer toggles playback
        // (keeps this demo free of Flame input-mixin version churn).
        body: GestureDetector(
          onTap: game.toggle,
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              GameWidget(game: game),
              const Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('tap to play / pause'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A minimal [FlameGame] whose single content is a [SpriteStudioComponent]
/// playing the bundled Ringo animation, kept placed as the window resizes.
class SpriteStudioGame extends FlameGame {
  SpriteStudioComponent? _ringo;

  /// Where Ringo's world origin sits, as a fraction of the viewport height.
  /// Ringo's origin is near its lower body, so a dead-centre (0.5) placement
  /// pushes the head off the top — nudge it below centre so the whole body
  /// shows. Tune this to reframe.
  static const _originYFraction = 1.0;

  Vector2 _placement(Vector2 size) =>
      Vector2(size.x / 2, size.y * _originYFraction);

  @override
  Future<void> onLoad() async {
    _ringo = SpriteStudioComponent.asset(
      // Ringo uses REFERENCE textures (sibling Ringo.png); the asset ctor
      // resolves them from the key's own folder, so no baseAssetDir is needed.
      'assets/spritestudio/Ringo/Ringo.ssab',
      // anchor.center ⇒ `position` IS the animation's world origin on screen
      // (SpriteStudio origins are centered).
      anchor: Anchor.center,
      position: _placement(size),
    );
    await add(_ringo!);
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _ringo?.position = _placement(size);
  }

  /// Toggle play/pause from the Flutter tap handler (the player is null until
  /// the component finishes loading).
  void toggle() => _ringo?.player?.togglePlayPause();

  /// Tearing down a `GameWidget` calls this but does **not** walk the component
  /// tree, so without `dispose()` the SpriteStudioComponent's `onRemove` never
  /// runs and its Brain + textures leak. Every game hosting a
  /// SpriteStudioComponent wants this.
  @override
  void onDispose() {
    dispose(); // removeAll(children) → onRemove on each
    super.onDispose();
  }
}
