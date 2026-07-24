// `ssconvert` — a host CLI that converts a SpriteStudio 7 project (.sspj) to an
// optimized binary (.ssab) via libssconverter over dart:ffi.
//
//   dart run ssconverter_dart:ssconvert [options] <sspj_file>
//
// Single-mode only (mirrors the SDK ssconverter-cli single mode): exactly one
// .sspj at a time; no batch, no watch. libssconverter is delivered via native
// assets (this package's hook/build.dart resolves the prebuilt dylib: a local
// scripts/build-runtime.sh build, else an auto-download of the pinned SDK release).
import 'dart:io';

import 'package:args/args.dart';
import 'package:ssconverter_dart/ssconverter_dart.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addFlag('embedded',
        abbr: 'e',
        negatable: false,
        help: 'Embed assets into a self-contained .ssab.')
    ..addOption('out_dir',
        abbr: 'o',
        valueHelp: 'dir',
        help: 'Output directory (default: sibling <stem>/, <stem>_emb/ when -e).')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('ssconvert: ${e.message}');
    stderr.writeln(_usage(parser));
    exitCode = 2;
    return;
  }

  if (args.flag('help')) {
    stdout.writeln(_usage(parser));
    return;
  }
  if (args.rest.isEmpty) {
    stderr.writeln('ssconvert: missing <sspj_file>.');
    stderr.writeln(_usage(parser));
    exitCode = 2;
    return;
  }
  if (args.rest.length > 1) {
    stderr.writeln('ssconvert: single mode takes exactly one <sspj_file> '
        '(got ${args.rest.length}); batch mode is not supported.');
    exitCode = 2;
    return;
  }

  final sspj = args.rest.single;
  if (!File(sspj).existsSync()) {
    stderr.writeln('ssconvert: no such file: $sspj');
    exitCode = 1;
    return;
  }

  final embedded = args.flag('embedded');
  final outDir = args.option('out_dir') ??
      SsConverter.defaultOutputDir(sspj, embedded: embedded);

  // libssconverter is delivered via native assets (hook/build.dart); the
  // @Native bindings resolve it — no path / SSCONVERTER_LIBRARY_PATH needed.
  const conv = SsConverter();

  stdout.writeln(
      'ssconvert ${conv.version} (ssab schema v${conv.ssabSchemaVersion})');
  stdout.writeln('  $sspj -> $outDir${embedded ? '  [embedded]' : ''}');
  try {
    final out = await conv.convert(sspj, outputDir: outDir, embedded: embedded);
    stdout.writeln('done: $out');
  } on SsConverterException catch (e) {
    stderr.writeln('ssconvert: conversion failed: $e');
    exitCode = 1;
  } catch (e) {
    // Anything else — UnsupportedError (run off-desktop), StateError (the native
    // context could not be created) — surfaces the CLI's clean one-line message
    // and exit 1, not an uncaught stack trace and exit 255.
    stderr.writeln('ssconvert: $e');
    exitCode = 1;
  }
}

String _usage(ArgParser parser) => '''
Convert a SpriteStudio 7 project (.sspj) to an optimized binary (.ssab).

Usage: dart run ssconverter_dart:ssconvert [options] <sspj_file>

${parser.usage}''';
