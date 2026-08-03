// Splits the write-side out of a `flatc --dart` generated file, in place.
//
// The Dart FlatBuffers generator always emits a serializer alongside every
// reader — `<Type>Builder` (the low-level, offset-threading builder) and
// `<Type>ObjectBuilder` (the object API) — and there is no flatc flag to
// suppress it. SSPlayer only ever READS FlatBuffers: the `.ssab` / `.ssqb`
// assets are produced by the SpriteStudio tooling, and `FrameData` /
// `EffectDrawPlan` are produced by the native runtime and read back over
// dart:ffi. That makes ~2/3 of the generated source dead weight in the
// published packages, so `scripts/generate-fbs-code.{sh,ps1}` pipes every
// freshly generated file through here.
//
// The one place the write side is genuinely used is the test suite, which
// synthesises fixture buffers rather than shipping binary assets for every
// case. `--builders-out` keeps those classes alive outside `lib/`: the emitted
// file re-exports the reader library, so a test only swaps its import URI and
// keeps its prefix. Without the flag the write side is simply discarded.
//
// Usage:
//   dart scripts/strip_fbs_builders.dart <generated.dart>...
//   dart scripts/strip_fbs_builders.dart --builders-out=<path> \
//       --reader-library=<uri> <generated.dart>
//
// The split is deliberately conservative and self-checking: a class is only
// moved when it carries the generator's own write-side signature, and the
// stripped file is verified to contain no dangling reference to anything
// removed. Any surprise (a flatc output shape this does not recognise) is a
// hard error rather than a silently broken file — the generated accessors are
// committed, so a bad rewrite would not be caught until build time otherwise.

import 'dart:io';

/// Marks an already-processed file, so re-running this is a no-op.
const _marker = 'scripts/strip_fbs_builders.dart';

/// Start of any top-level declaration in flatc's Dart output.
final _declStart = RegExp(r'^(?:abstract )?(?:class|enum|mixin|extension) (\w+)');

/// `class FooObjectBuilder extends fb.ObjectBuilder {` — the object API.
final _objectBuilder = RegExp(r'^class \w+ObjectBuilder extends fb\.ObjectBuilder \{$');

/// `class FooBuilder {` — only write-side when it holds the builder handle
/// below, so a schema type that happens to end in `Builder` is left alone.
final _builder = RegExp(r'^class \w+Builder \{$');
const _builderField = 'final fb.Builder fbBuilder;';

/// `import 'dart:typed_data' show Uint8List;` — the shown names are used by
/// `toBytes()`, which lives on the object builders, so the import follows them
/// out of the reader file.
final _showImport = RegExp(r"^import '([^']+)' show ([^;]+);$");

/// Write-side runtime symbols that must be gone from the reader file once the
/// classes are.
const _writeSideSymbols = [
  'fb.Builder',
  'fb.ObjectBuilder',
  'fb.StructBuilder',
  'fb.Packable',
];

void main(List<String> args) {
  String? buildersOut;
  String? readerLibrary;
  final paths = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--builders-out=')) {
      buildersOut = arg.substring('--builders-out='.length);
    } else if (arg.startsWith('--reader-library=')) {
      readerLibrary = arg.substring('--reader-library='.length);
    } else {
      paths.add(arg);
    }
  }
  if (paths.isEmpty || (buildersOut != null) != (readerLibrary != null)) {
    stderr.writeln(
      'usage: dart scripts/strip_fbs_builders.dart '
      '[--builders-out=<path> --reader-library=<uri>] <generated.dart>...',
    );
    exit(64);
  }
  if (buildersOut != null && paths.length > 1) {
    stderr.writeln('strip_fbs_builders: --builders-out takes a single input file');
    exit(64);
  }

  var failed = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('strip_fbs_builders: no such file: $path');
      failed = true;
      continue;
    }
    final before = file.readAsStringSync();
    try {
      final result = strip(before);
      if (result.reader != before) file.writeAsStringSync(result.reader);
      final kept = '\n'.allMatches(result.reader).length;
      final dropped = '\n'.allMatches(before).length - kept;
      stdout.writeln(
        '   split off ${result.removed.length} write-side classes '
        '(-$dropped lines, $kept left) from $path',
      );
      if (buildersOut != null && result.removed.isNotEmpty) {
        final out = File(buildersOut);
        out.parent.createSync(recursive: true);
        out.writeAsStringSync(result.buildersFile(readerLibrary!));
        stdout.writeln('   -> $buildersOut');
      }
    } on FormatException catch (e) {
      stderr.writeln('strip_fbs_builders: $path: ${e.message}');
      failed = true;
    }
  }
  if (failed) exit(1);
}

class StripResult {
  StripResult(this.reader, this.removed, this._writeSide, this._eol);

  /// The input with its write-side classes removed.
  final String reader;

  /// Names of the classes that were removed.
  final List<String> removed;

  final List<String> _writeSide;
  final String _eol;

  /// The removed classes as a standalone library that re-exports
  /// [readerLibrary], so importers reach both halves under one prefix.
  String buildersFile(String readerLibrary) {
    final header = [
      '// automatically generated by the FlatBuffers compiler, do not modify',
      '// ignore_for_file: unused_import, unused_field, unused_element, unused_local_variable, constant_identifier_names',
      '// Split out by $_marker:',
      '// the write-side classes flatc emits alongside the readers. SSPlayer',
      '// only reads FlatBuffers, so these live outside lib/ — they exist only',
      '// so tests can synthesise fixture buffers. This re-exports the reader',
      '// library, so a test swaps the import URI and keeps its prefix.',
      '// Regenerate with scripts/generate-fbs-code.{sh,ps1}.',
      '',
      "import 'dart:typed_data' show Uint8List;",
      "import 'package:flat_buffers/flat_buffers.dart' as fb;",
      "import '$readerLibrary';",
      '',
      "export '$readerLibrary';",
      '',
    ];
    final text = _tidy([...header, ..._writeSide], _eol);
    return _pruneShowImports(text, _eol);
  }
}

/// Returns [source] split into its reader and write-side halves.
///
/// Throws [FormatException] if the input does not look like flatc `--dart`
/// output, or if the rewrite would leave a dangling reference.
StripResult strip(String source) {
  final eol = source.contains('\r\n') ? '\r\n' : '\n';
  final lines = source.split(RegExp(r'\r?\n'));

  final kept = <String>[];
  final writeSide = <String>[];
  final removed = <String>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final decl = _declStart.firstMatch(line);
    if (decl == null) {
      kept.add(line);
      i++;
      continue;
    }
    // flatc writes every top-level declaration flush-left and closes it with a
    // bare `}` in column 0; nested braces (and the ones inside the generated
    // `toString()` string literals) are always indented.
    var end = i;
    while (end < lines.length && lines[end] != '}') {
      end++;
    }
    if (end == lines.length) {
      throw FormatException('unterminated top-level declaration at line ${i + 1}: $line');
    }
    final block = lines.sublist(i, end + 1);
    if (_isWriteSide(block)) {
      removed.add(decl.group(1)!);
      // The doc comment that belongs to the class travels with it.
      final doc = <String>[];
      while (kept.isNotEmpty && kept.last.trimLeft().startsWith('//')) {
        doc.insert(0, kept.removeLast());
      }
      writeSide.addAll([...doc, ...block, '']);
    } else {
      kept.addAll(block);
    }
    i = end + 1;
  }
  if (removed.isEmpty && !source.contains(_marker)) {
    throw FormatException('no write-side classes found — is this flatc --dart output?');
  }

  var reader = _tidy(kept, eol);
  reader = _pruneShowImports(reader, eol);
  reader = _annotate(reader, eol);

  for (final name in removed) {
    if (RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(reader)) {
      throw FormatException('$name is still referenced after stripping');
    }
  }
  for (final symbol in _writeSideSymbols) {
    if (reader.contains(symbol)) {
      throw FormatException('write-side symbol $symbol survived stripping');
    }
  }
  return StripResult(reader, removed, writeSide, eol);
}

bool _isWriteSide(List<String> block) {
  if (_objectBuilder.hasMatch(block.first)) return true;
  return _builder.hasMatch(block.first) &&
      block.any((line) => line.trim() == _builderField);
}

/// Collapses the blank-line runs left behind by moved classes and ends the file
/// with exactly one newline, so re-running produces an identical file.
String _tidy(List<String> lines, String eol) {
  final out = <String>[];
  for (final line in lines) {
    if (line.trim().isEmpty && (out.isEmpty || out.last.trim().isEmpty)) continue;
    out.add(line);
  }
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  return '${out.join(eol)}$eol';
}

/// Drops `show` imports whose names are no longer referenced.
String _pruneShowImports(String text, String eol) {
  final lines = text.split(RegExp(r'\r?\n'));
  final out = <String>[];
  for (final line in lines) {
    final import = _showImport.firstMatch(line);
    if (import != null) {
      final body = lines.where((other) => other != line).join('\n');
      final names = import
          .group(2)!
          .split(',')
          .map((name) => name.trim())
          .where((name) => RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(body));
      if (names.isEmpty) continue;
      out.add("import '${import.group(1)}' show ${names.join(', ')};");
      continue;
    }
    out.add(line);
  }
  return out.join(eol);
}

/// Notes the rewrite under flatc's own "do not modify" header.
String _annotate(String text, String eol) {
  if (text.contains(_marker)) return text;
  final lines = text.split(RegExp(r'\r?\n'));
  // Sits after flatc's `// ignore_for_file:` line, i.e. after the leading
  // comment block, so the header still reads top-down.
  var at = 0;
  while (at < lines.length && lines[at].startsWith('//')) {
    at++;
  }
  lines.insertAll(at, [
    '// Post-processed by $_marker: the write-side <Type>Builder /',
    '// <Type>ObjectBuilder classes are split out — SSPlayer only reads',
    '// FlatBuffers. Regenerate with scripts/generate-fbs-code.{sh,ps1}.',
  ]);
  return lines.join(eol);
}
