// ssconverter stores a `.sspj`/`.ssce` file reference in the `.ssab` exactly as
// authored — no separator normalization (SDK `docs/30_core/10_initialization.md`
// §3.0) — so a Windows-authored project reaches the Body as `image\body.png`,
// while a Flutter asset key is forward-slash on every platform. Folding that is
// the Body's job, and getting it wrong is invisible: an unresolved cellmap is
// only collected into a report, never thrown, and the part quietly stops
// drawing. These tests pin the fold, the two things that must NOT be folded (a
// host-path base, an embedded pack's pre-computed hash) and the pre-existing
// forward-slash behaviour they had to leave intact.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show ByteData, CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssplayer_flutter/src/asset_path.dart';
import 'package:ssplayer_flutter/src/texture_loader.dart';
import 'package:ssplayer_flutter/src/texture_registry.dart';
// Re-exports the .ssab readers and adds back the flatc write-side classes,
// which live outside lib/ (see scripts/strip_fbs_builders.dart).
import 'support/ssab_builders.g.dart' as ssab;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('joinAssetPath', () {
    test('folds the separators of a pack-authored path', () {
      expect(joinAssetPath('assets/x', r'image\body.png'),
          'assets/x/image/body.png');
      expect(joinAssetPath('assets/x', r'a\b\c\body.png'),
          'assets/x/a/b/c/body.png');
      // Leading separator stripped in either spelling.
      expect(joinAssetPath('assets/x', r'\body.png'), 'assets/x/body.png');
      expect(joinAssetPath('', r'\body.png'), 'body.png');
    });

    test('leaves the forward-slash cases exactly as they were', () {
      expect(joinAssetPath('assets/x', 'body.png'), 'assets/x/body.png');
      expect(joinAssetPath('assets/x/', 'body.png'), 'assets/x/body.png');
      expect(joinAssetPath('assets/x', '/body.png'), 'assets/x/body.png');
      // A root-level `.ssab` derives an empty base: the join is a no-op, and in
      // particular must not prepend a stray leading '/'.
      expect(joinAssetPath('', 'body.png'), 'body.png');
    });

    test('never folds the base, which may be a host path', () {
      // A dropped folder / dev file push hands us a real Windows path. `dart:io`
      // takes the mixed result; a folded UNC prefix would stop being a UNC path.
      expect(joinAssetPath(r'U:\art\overall', r'image\body.png'),
          r'U:\art\overall/image/body.png');
      expect(joinAssetPath(r'\\host\share', 'body.png'),
          r'\\host\share/body.png');
    });
  });

  group('assetDirOf', () {
    test('derives the parent folder of an asset key', () {
      expect(assetDirOf('a/b/c.ssab'), 'a/b');
      expect(assetDirOf('c.ssab'), '');
      expect(assetDirOf('/c.ssab'), '');
    });

    test('derives it from a native path too, separator preserved', () {
      // A file picker hands back an all-backslash path; resolving it against a
      // `dart:io`-backed bundle used to fall back to the bundle root, sending
      // every sibling texture lookup somewhere else entirely.
      expect(assetDirOf(r'U:\art\overall\Ringo.ssab'), r'U:\art\overall');
      // Mixed, which is what a caller joining a host dir with '/' produces.
      expect(assetDirOf(r'U:\art\overall/Ringo.ssab'), r'U:\art\overall');
      expect(assetDirOf(r'\Ringo.ssab'), '');
    });
  });

  group('SsTextureLoader', () {
    late Uint8List png;

    setUpAll(() async => png = await _tinyPng());

    test('resolves a reference cellmap authored with Windows separators',
        () async {
      final bundle = _RecordingBundle({'assets/x/image/body.png': png});
      final registry = TextureRegistry();
      addTearDown(registry.dispose);

      final report = await SsTextureLoader.load(
        registry,
        _syntheticSsab(nameHash: 0xABCD, imagePath: r'image\body.png'),
        bundle: bundle,
        baseAssetDir: 'assets/x',
      );

      expect(report.isComplete, isTrue,
          reason: 'a backslash-authored image_path must still resolve');
      expect(registry.contains(0xABCD), isTrue);
      expect(bundle.requested, contains('assets/x/image/body.png'));
    });

    test('reports the folded key when the asset is genuinely missing',
        () async {
      final bundle = _RecordingBundle(const {});
      final registry = TextureRegistry();
      addTearDown(registry.dispose);

      final report = await SsTextureLoader.load(
        registry,
        _syntheticSsab(nameHash: 0xABCD, imagePath: r'image\body.png'),
        bundle: bundle,
        baseAssetDir: 'assets/x',
      );

      expect(report.unresolved, ['assets/x/image/body.png']);
    });

    test('embedded assets keep matching on the Brain\'s raw-text hash',
        () async {
      // The guard on the fold: `image_path_hash` is FNV-1a over the UNFOLDED
      // text, computed by ssconverter. Fold before that lookup (or re-hash on
      // the Dart side at all) and every embedded pack stops resolving.
      final bundle = _RecordingBundle(const {});
      final registry = TextureRegistry();
      addTearDown(registry.dispose);

      final report = await SsTextureLoader.load(
        registry,
        _syntheticSsab(
          nameHash: 0xABCD,
          imagePath: r'image\body.png',
          imagePathHash: 0x5151,
          embedded: png,
        ),
        bundle: bundle,
        baseAssetDir: 'assets/x',
      );

      expect(report.isComplete, isTrue);
      expect(registry.contains(0xABCD), isTrue);
      expect(bundle.requested, isEmpty,
          reason: 'embedded bytes win outright — no bundle access at all');
    });
  });
}

/// A minimal `.ssab` carrying one cellmap (and optionally its embedded bytes).
/// [SsTextureLoader] reads nothing else, so this needs no Brain and no FFI.
Uint8List _syntheticSsab({
  required int nameHash,
  required String imagePath,
  int imagePathHash = 0,
  Uint8List? embedded,
}) =>
    ssab.SsAnimeBinaryObjectBuilder(
      version: 1,
      name: 'synthetic',
      nameHash: 1,
      cellmaps: <ssab.CellMapObjectBuilder>[
        ssab.CellMapObjectBuilder(
          nameHash: nameHash,
          name: 'cellmap',
          imagePath: imagePath,
          imagePathHash: imagePathHash,
        ),
      ],
      embeddedAssets: embedded == null
          ? null
          : <ssab.EmbeddedAssetObjectBuilder>[
              ssab.EmbeddedAssetObjectBuilder(
                nameHash: imagePathHash,
                name: imagePath,
                data: embedded,
              ),
            ],
    ).toBytes();

/// A 1×1 PNG, so the loader has something real to hand `instantiateImageCodec`
/// without the test depending on deployed example assets.
Future<Uint8List> _tinyPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 1, 1),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// Serves a fixed key→bytes map and records every key asked for, so the derived
/// asset key is observable rather than inferred from success alone.
class _RecordingBundle extends CachingAssetBundle {
  _RecordingBundle(this._files);

  final Map<String, Uint8List> _files;
  final List<String> requested = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requested.add(key);
    final bytes = _files[key];
    if (bytes == null) throw Exception('no such asset: $key');
    return ByteData.sublistView(bytes);
  }
}
