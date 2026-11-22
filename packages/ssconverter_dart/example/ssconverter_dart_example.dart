// Converts a SpriteStudio project into one self-contained .ssab, as
// `dart run ssconverter_dart:ssconvert -e -o <output dir> <project.sspj>` does.
//
//   dart run example/ssconverter_dart_example.dart <project.sspj> <output dir>

import 'dart:io';

import 'package:ssconverter_dart/ssconverter_dart.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run example/ssconverter_dart_example.dart '
      '<project.sspj> <output dir>',
    );
    exitCode = 64;
    return;
  }

  try {
    final out = await const SsConverter().convert(
      args[0],
      outputDir: args[1],
      embedded: true,
    );
    print('converted into $out');
  } on SsConverterException catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  }
}
