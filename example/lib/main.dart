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

  static const _assetDir = 'assets/overall';

  // overall.sspj packs, switchable from the dropdown to eyeball each feature
  // against the SS7 editor. PartsColor (§10, roadmap step 2) is the default so a
  // bare `flutter run` lands on the current verification target.
  static const _packs = <String>[
    'PartsColor',
    'Basic',
    'BlendMode',
    'Interpolation',
  ];
  String _pack = 'PartsColor';

  @override
  void initState() {
    super.initState();
    _player = SpriteStudioPlayer(vsync: this);
    _load(_pack);
  }

  Future<void> _load(String pack) async {
    setState(() {
      _pack = pack;
      _status = 'loading "$pack"…';
    });
    try {
      final asset = '$_assetDir/$pack.ssab';
      final ByteData data = await rootBundle.load(asset);
      final Uint8List bytes = data.buffer.asUint8List();
      // Pick the first animation in the pack (name comes from the .ssab).
      final animName = SsAnimeInfo(bytes).animationNames.first;
      // overall.ssab uses REFERENCE textures (sibling PNGs) → pass baseAssetDir.
      await _player.load(
        bytes,
        animationName: animName,
        baseAssetDir: _assetDir,
      );
      // Guard against a newer selection winning the race while we awaited.
      if (!mounted || _pack != pack) return;
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
      if (mounted) setState(() => _status = 'failed: $e');
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
      appBar: AppBar(
        title: const Text('ssplayer_flutter'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButton<String>(
              value: _pack,
              onChanged: (v) {
                if (v != null && v != _pack) _load(v);
              },
              items: [
                for (final p in _packs)
                  DropdownMenuItem<String>(value: p, child: Text(p)),
              ],
            ),
          ),
        ],
      ),
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
