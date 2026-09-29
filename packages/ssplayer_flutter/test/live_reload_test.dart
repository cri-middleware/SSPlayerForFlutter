// The in-app end of live reload: which players a push reaches.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

const _key = 'assets/spritestudio/overall/Basic.ssab';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final dir = _firstExisting(const [
    'examples/overall/assets/spritestudio/overall',
    '../../examples/overall/assets/spritestudio/overall',
  ]);
  final channel = SsDevChannel.instance;

  /// A player on Basic.ssab, loaded by asset key and joined to the channel the
  /// way `loadAsset` joins it in a build launched for live reload.
  Future<SpriteStudioPlayer> joined() async {
    final player = SpriteStudioPlayer();
    addTearDown(() {
      channel.unregisterAsset(player);
      player.dispose();
    });
    await player.loadAsset(_key, bundle: _DirBundle(dir!), loadTextures: false);
    channel.registerAsset(player, _key);
    return player;
  }

  group('a file push', () {
    test('reloads a player that joined by its asset key', () async {
      if (dir == null) return markTestSkipped('overall assets missing');
      final player = await joined();
      final before = player.internal;

      final result = await channel.handleReload({'dir': File(dir).absolute.path});
      expect(result['ok'], isTrue);
      expect(result['reloaded'], 1);
      expect(player.internal, isNot(same(before)), reason: 'a new resource');
      expect(player.currentAnimation, 'anime_1');
    });

    test('leaves a player alone when the dir does not hold its pack', () async {
      if (dir == null) return markTestSkipped('overall assets missing');
      await joined();
      final empty = Directory.systemTemp.createTempSync('ss_push');
      addTearDown(() => empty.deleteSync(recursive: true));

      final result = await channel.handleReload({'dir': empty.path});
      expect(result['reloaded'], 0);
    });

    test('a target naming the same player is the one used', () async {
      if (dir == null) return markTestSkipped('overall assets missing');
      final player = await joined();
      final target = _Target(player);
      channel.register(target);
      addTearDown(() => channel.unregister(target));

      final result = await channel.handleReload({'dir': File(dir).absolute.path});
      expect(result['reloaded'], 1, reason: 'once, not once per registration');
      expect(target.reloaded, 1, reason: "the target's callback ran");
    });

    test('a disabled target stands its player down', () async {
      if (dir == null) return markTestSkipped('overall assets missing');
      final player = await joined();
      final target = _Target(player)..enabled = false;
      channel.register(target);
      addTearDown(() => channel.unregister(target));

      final result = await channel.handleReload({'dir': File(dir).absolute.path});
      expect(result['reloaded'], 0,
          reason: "the player's own registration does not go around it");
    });
  });

  test('a byte push goes only to the pack it names', () async {
    if (dir == null) return markTestSkipped('overall assets missing');
    await joined();
    final result = await channel.handleReload({
      'source': 'bytes',
      'pack': 'NotBasic',
      'bytes': 'AAAA',
    });
    expect(result['reloaded'], 0);
    expect(result['errors'], isNull);
  });
}

class _Target implements SsLiveReloadTarget {
  _Target(this.ssPlayer);

  @override
  final SpriteStudioPlayer ssPlayer;
  bool enabled = true;
  int reloaded = 0;

  @override
  String get ssAssetDir => 'assets/spritestudio/overall';
  @override
  String get ssPack => 'Basic';
  @override
  bool get ssLiveReloadEnabled => enabled;
  @override
  void ssOnLiveReloaded() => reloaded++;
  @override
  void ssOnLiveReloadError(Object error) {}
}

/// Serves any key by its basename out of a directory read into memory up front.
class _DirBundle extends CachingAssetBundle {
  _DirBundle(String dir) {
    for (final f in Directory(dir).listSync().whereType<File>()) {
      _files[f.uri.pathSegments.last] = f.readAsBytesSync();
    }
  }
  final Map<String, Uint8List> _files = {};

  @override
  Future<ByteData> load(String key) async {
    final bytes = _files[key.split('/').last];
    if (bytes == null) throw FlutterError('not in bundle: $key');
    return ByteData.sublistView(bytes);
  }
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (Directory(p).existsSync()) return p;
  }
  return null;
}
