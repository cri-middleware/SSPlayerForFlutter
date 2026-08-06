// The separator fold, end to end: the REAL player and Brain over REAL converter
// output whose cellmap path carries a Windows separator.
//
// `asset_path_test.dart` pins the rule on synthetic packs; this pins that the
// rule actually reaches `loadAsset`. The pack is rewritten by a same-length byte
// patch (`common.png` → `cm\mon.png`), so every FlatBuffers offset still holds
// and the loader sees precisely what a Windows-authored project hands it —
// ssconverter builds such a reference itself, with `Path::join`, whose separator
// follows the *converting* host (SDK `ssconverter/src/model_t/font.rs`).
//
// The bundle mimics `rootBundle` on purpose: a fixed set of forward-slash keys,
// matched exactly. That is the real failure surface. A `dart:io`-backed bundle
// would hide the bug entirely, since Windows opens `cm\mon.png` quite happily —
// which is exactly how this can pass a desktop dev loop and fail once bundled.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show ByteData, CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/ssplayer_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a cellmap authored with a Windows separator resolves through loadAsset',
      () async {
    final src = _firstExisting([
      'examples/overall/assets/spritestudio/overall',
      '../../examples/overall/assets/spritestudio/overall',
    ]);
    if (src == null) {
      markTestSkipped('overall assets missing — run scripts/deploy-examples');
      return;
    }

    final tmp = Directory.systemTemp.createTempSync('ss_asset_path');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final root = tmp.path.replaceAll('\\', '/');

    // Deploy a copy, then push the atlas one folder down so the pack has to
    // reach it *through a subdirectory* — what a bare filename never exercises.
    for (final f in Directory(src).listSync().whereType<File>()) {
      f.copySync('$root/${f.path.split(RegExp(r'[/\\]')).last}');
    }
    Directory('$root/cm').createSync();
    File('$root/common.png').renameSync('$root/cm/mon.png');

    final pack = File('$root/Basic.ssab');
    final bytes = pack.readAsBytesSync();
    expect(_patch(bytes, 'common.png', r'cm\mon.png'), 1,
        reason: 'the fixture must rewrite exactly the one cellmap reference');
    pack.writeAsBytesSync(bytes);

    final bundle = _ManifestBundle(root);
    final player = SpriteStudioPlayer();
    addTearDown(player.dispose);

    await player.loadAsset('$root/Basic.ssab', bundle: bundle);

    // Unfolded, the key would be `$root/cm\mon.png`: absent from the manifest,
    // so the cellmap lands in the report and its parts silently stop drawing.
    expect(player.lastTextureReport?.unresolved, isEmpty);
    expect(bundle.requested, contains('$root/cm/mon.png'));
  });
}

/// In-place same-length byte substitution; returns how many it made. Equal
/// lengths are what keep the surrounding FlatBuffers offsets valid.
int _patch(Uint8List bytes, String from, String to) {
  final f = from.codeUnits, t = to.codeUnits;
  if (f.length != t.length) throw ArgumentError('lengths differ');
  var count = 0;
  for (var i = 0; i + f.length <= bytes.length; i++) {
    var hit = true;
    for (var j = 0; j < f.length; j++) {
      if (bytes[i + j] != f[j]) {
        hit = false;
        break;
      }
    }
    if (!hit) continue;
    bytes.setRange(i, i + f.length, t);
    count++;
  }
  return count;
}

/// `rootBundle` semantics: a fixed key set matched exactly — no path resolution
/// and no separator tolerance, keys forward-slash as `AssetManifest` always is.
class _ManifestBundle extends CachingAssetBundle {
  _ManifestBundle(String root) {
    for (final f
        in Directory(root).listSync(recursive: true).whereType<File>()) {
      _keys.add(f.path.replaceAll('\\', '/'));
    }
  }

  final Set<String> _keys = <String>{};
  final List<String> requested = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    if (!_keys.contains(key)) throw Exception('no asset for key: $key');
    return ByteData.sublistView(File(key).readAsBytesSync());
  }
}

String? _firstExisting(List<String> paths) {
  for (final p in paths) {
    if (Directory(p).existsSync()) return p;
  }
  return null;
}
