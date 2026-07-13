// Host-side reconvert runner for DEVICE (iOS/Android) dev live-reload.
//
//   dart run ssgen_flutter:ssreconvert     # run from the app dir
//
// A device can't run the host libssconverter, so run this on the host after
// editing in SpriteStudio, then press `r` in `flutter run -d <device>` —
// Flutter DevFS-syncs the fresh `.ssab` to the device and the app's
// reassemble() reloads it. On desktop the app reconverts in-process (the
// SsLiveReload mixin), so this runner is only needed for device targets.
//
// It reconverts only the STALE projects under the current dir's
// `SpriteStudio_Source/` (or a `spritestudio.yaml` override), via the same
// SsProjectSync the mixin uses.
import 'dart:io';

import 'package:ssgen_dart/ssgen_dart.dart';

Future<void> main() async {
  final report = await const SsProjectSync().reconvert(
    projectRoot: Directory.current.path,
  );
  if (report.converted.isEmpty) {
    stdout.writeln(
      'ssreconvert: up to date (${report.upToDate.length} project(s)).',
    );
  } else {
    report.converted.forEach(
      (sspj, out) => stdout.writeln('ssreconvert: $sspj -> $out'),
    );
  }
}
