// `loadAsset` derives `baseAssetDir` from the asset key's parent directory, so a
// bundled `.ssab` and its sibling reference textures resolve with no explicit
// base. These tests drive a bundle that records every requested key and serves
// it by basename from the real `examples/overall` assets — so the derived base
// is observable in the keys the loader asks for, and the root-level (empty-base)
// case proves `joinAssetPath` never prepends a stray leading slash. Separator
// folding is pinned separately, in `asset_path_test.dart`.
import 'dart:io';

import 'package:flutter/services.dart' show ByteData, CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final assetDir = _firstExisting([
    'examples/overall/assets/spritestudio/overall',
    '../../examples/overall/assets/spritestudio/overall',
  ]);

  test('loadAsset derives the texture folder from the key and resolves textures',
      () async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing — run scripts/deploy-examples.sh');
      return;
    }
    final bundle = _RebasingBundle(assetDir);
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);

    await player.loadAsset('assets/x/Basic.ssab', bundle: bundle);

    // Reference textures (sibling PNGs) all resolved: the base was derived.
    expect(player.lastTextureReport, isNotNull);
    expect(player.lastTextureReport!.isComplete, isTrue,
        reason: 'derived baseAssetDir should resolve every reference texture');

    // The `.ssab` and at least one texture were fetched under the key's own
    // folder — proof the base is `assets/x`, not the bundle root.
    expect(bundle.requested, contains('assets/x/Basic.ssab'));
    expect(bundle.requested.where((k) => k.startsWith('assets/x/')).length,
        greaterThan(1),
        reason: 'textures should be requested under the derived folder');
  });

  test('loadAsset with a root-level key resolves textures without a leading slash',
      () async {
    if (assetDir == null) {
      markTestSkipped('overall assets missing — run scripts/deploy-examples.sh');
      return;
    }
    // A bare key and a root-anchored key both derive an empty base, so the join
    // must be a no-op (`common.png`, not `/common.png`).
    for (final key in <String>['Basic.ssab', '/Basic.ssab']) {
      final bundle = _RebasingBundle(assetDir);
      final player = SpriteStudioPlayer();
      addTearDown(player.dispose);

      await player.loadAsset(key, bundle: bundle);

      expect(player.lastTextureReport!.isComplete, isTrue,
          reason: 'empty base must still resolve textures for key "$key"');
      // The ssab key itself may carry the caller's leading slash; the empty-base
      // join must not add one to the *texture* keys derived from it.
      final textureKeys = bundle.requested.where((k) => k != key);
      expect(textureKeys, isNotEmpty,
          reason: 'reference textures should be fetched for key "$key"');
      expect(textureKeys.any((k) => k.startsWith('/')), isFalse,
          reason: 'no texture key should carry a leading slash for "$key"');
    }
  });
}

/// A bundle whose keys are logical asset paths; it serves each by *basename*
/// from [root] (the real assets dir) and records every requested key. Mirrors
/// the example's `_FileBundle`, minus the absolute-path assumption.
class _RebasingBundle extends CachingAssetBundle {
  _RebasingBundle(this.root);

  final String root;
  final List<String> requested = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    final name = key.substring(key.lastIndexOf('/') + 1);
    final bytes = await File('$root/$name').readAsBytes();
    return ByteData.sublistView(bytes);
  }
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (Directory(p).existsSync()) return p;
  }
  return null;
}
