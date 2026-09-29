import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetBundle;

/// Web side of the dev push channel: there is no host filesystem, so the `file`
/// source is unavailable — a web push always carries `bytes` (the same path a
/// device uses). Mirrors `dev_channel_io.dart`'s surface so the channel compiles
/// for the web without importing `dart:io`.
const bool supportsFilePush = false;

Future<Uint8List?> readSsabFile(String path) async => null;

AssetBundle filePushBundle() =>
    throw UnsupportedError('a file push is unavailable on the web');
