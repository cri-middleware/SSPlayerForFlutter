// Reconverts the SpriteStudio projects under SpriteStudio_Source/ whose
// output went stale, into assets/spritestudio/<project>/, both resolved from
// the current directory. Save it in the app as tool/reconvert.dart and run it
// from the app's root:
//
//   dart run tool/reconvert.dart

import 'package:ssgen_dart/ssgen_dart.dart';

Future<void> main() async {
  final report = await const SsProjectSync().reconvert();
  for (final MapEntry(key: sspj, value: out) in report.converted.entries) {
    print('converted $sspj -> $out');
  }
  print('${report.upToDate.length} already up to date');
}
