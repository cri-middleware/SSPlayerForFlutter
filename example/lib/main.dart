import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ssplayer_flutter example',
      theme: ThemeData.dark(useMaterial3: true),
      home: const PlayerPage(),
    );
  }
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player;
  String _status = 'loading…';

  // The Phase-1 validation target from the SDK roadmap: play overall.sspj's
  // Basic pack and compare against the editor.
  static const _assetDir = 'assets/overall';
  static const _ssabAsset = '$_assetDir/Basic.ssab';

  @override
  void initState() {
    super.initState();
    _player = SpriteStudioPlayer(vsync: this);
    _load();
  }

  Future<void> _load() async {
    try {
      final ByteData data = await rootBundle.load(_ssabAsset);
      final Uint8List bytes = data.buffer.asUint8List();
      // Pick the first animation in the pack (name comes from the .ssab).
      final animName = SsAnimeInfo(bytes).animationNames.first;
      // overall.ssab uses REFERENCE textures (sibling PNGs) → pass baseAssetDir.
      await _player.load(
        bytes,
        animationName: animName,
        baseAssetDir: _assetDir,
      );
      _player
        ..loop = -1
        ..play();
      final missing = _player.lastTextureReport?.unresolved ?? const [];
      final msg = missing.isEmpty
          ? 'playing "$animName"'
          : 'playing "$animName" (missing textures: ${missing.join(", ")})';
      // ignore: avoid_print
      print('[ssplayer] OK — $msg (frame=${_player.frameNo})');
      setState(() => _status = msg);
    } catch (e, st) {
      // ignore: avoid_print
      print('[ssplayer] FAILED: $e\n$st');
      setState(() => _status = 'failed: $e');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ssplayer_flutter')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 400,
              height: 400,
              color: Colors.black26,
              child: SpriteStudioView(
                player: _player,
                width: 400,
                height: 400,
              ),
            ),
            const SizedBox(height: 16),
            Text(_status),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () =>
            _player.isPlaying ? _player.pause() : _player.play(),
        child: const Icon(Icons.play_arrow),
      ),
    );
  }
}
