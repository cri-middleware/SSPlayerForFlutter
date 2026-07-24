import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle, CachingAssetBundle;

/// Native (`dart:io`) side of the dev push channel's `file` source: read a
/// reconverted `.ssab` off disk and resolve its sibling textures through a
/// filesystem-keyed [AssetBundle]. The web build swaps in `dev_channel_stub.dart`
/// (there is no host filesystem there — a web push always carries bytes).
const bool supportsFilePush = true;

/// Reads the reconverted `.ssab` at [path], or null if it is absent.
Future<Uint8List?> readSsabFile(String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  return file.readAsBytes();
}

/// A bundle whose keys are absolute filesystem paths, so a pushed `.ssab` and
/// its sibling reference textures load through the same code path as bundled
/// assets.
AssetBundle filePushBundle() => _FileBundle();

class _FileBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}
