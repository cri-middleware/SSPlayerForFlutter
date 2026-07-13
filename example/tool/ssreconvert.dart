// Host-side reconvert for the example's DEVICE (iOS/Android) live-reload.
//
// On desktop the app reconverts in-process from State.reassemble, but a device
// can't run the host libssconverter. So on the HOST run:
//
//   dart run tool/ssreconvert.dart      # (from example/) reconvert stale projects
//
// then press `r` in `flutter run -d <device>` — Flutter DevFS-syncs the changed
// `.ssab` to the device and evicts its rootBundle cache, and the app's
// reassemble() reloads it in place (converter-free on device).
//
// It rebuilds example/assets/spritestudio/<project>/ from
// example/SpriteStudio_Source/<project>/ (mtime-diff: only stale projects), via
// the same SsProjectSync the desktop path uses.
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
