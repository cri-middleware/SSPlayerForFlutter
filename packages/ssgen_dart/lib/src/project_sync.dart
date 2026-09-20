import 'dart:io';

import 'package:ssconverter_dart/ssconverter_dart.dart';
import 'package:yaml/yaml.dart';

/// Where a [SsProjectSync] reads `.sspj` sources and writes `.ssab`, resolved
/// from a project root by convention (or a `spritestudio.yaml` override there).
///
/// Defaults (convention over configuration, RenPy-style):
///   * source   = `<projectRoot>/SpriteStudio_Source`
///   * output   = `<projectRoot>/assets/spritestudio`   (per project: `<stem>/`)
///   * embedded = false (reference textures, like the example's asset tree)
///
/// Override by dropping `<projectRoot>/spritestudio.yaml`:
/// ```yaml
/// source: art/spritestudio     # relative to projectRoot (or absolute)
/// output: assets/anim
/// embedded: true
/// ```
class SsProjectSyncConfig {
  /// Source directory holding the `.sspj` project(s) (absolute).
  final String sourceDir;

  /// Output base; each project lands in `<outputDir>/<sspj stem>/` (absolute).
  final String outputDir;

  /// Whether to emit self-contained (texture-inlined) `.ssab`.
  final bool embedded;

  const SsProjectSyncConfig({
    required this.sourceDir,
    required this.outputDir,
    this.embedded = false,
  });

  static const defaultSourceSubdir = 'SpriteStudio_Source';
  static const defaultOutputSubdir = 'assets/spritestudio';
  static const configFileName = 'spritestudio.yaml';

  /// Resolves the config for [projectRoot]: reads `spritestudio.yaml` there if
  /// present, else the conventional defaults. Relative paths (defaults or in the
  /// file) are resolved against [projectRoot].
  factory SsProjectSyncConfig.resolve(String projectRoot) {
    String join(String rel) => _isAbsolute(rel) ? rel : '$projectRoot/$rel';

    final file = File('$projectRoot/$configFileName');
    var source = defaultSourceSubdir;
    var output = defaultOutputSubdir;
    var embedded = false;
    if (file.existsSync()) {
      final doc = loadYaml(file.readAsStringSync());
      if (doc is YamlMap) {
        source = (doc['source'] as String?) ?? source;
        output = (doc['output'] as String?) ?? output;
        embedded = (doc['embedded'] as bool?) ?? embedded;
      }
    }
    return SsProjectSyncConfig(
      sourceDir: join(source),
      outputDir: join(output),
      embedded: embedded,
    );
  }
}

/// One [SsProjectSync.reconvert] pass result.
class SsReconvertReport {
  /// `.sspj` paths (re)converted this pass → their output directories.
  final Map<String, String> converted;

  /// `.sspj` paths skipped because their output was already up to date.
  final List<String> upToDate;

  const SsReconvertReport({required this.converted, required this.upToDate});

  bool get didConvert => converted.isNotEmpty;
}

/// Host-side "reconvert only the stale projects in a directory" — the library
/// primitive behind a **consumer-owned** reconvert trigger. The caller decides
/// when to call [reconvert] (`ssgen_flutter`'s `sswatch` runner does it on a
/// source save), then feeds the changed `.ssab` back through
/// `SpriteStudioPlayer.reload`.
///
/// It is NOT a daemon and NOT a CLI — no watching, no auto-anything, no state.
/// **Desktop only** (it drives [SsConverter] / the host `libssconverter`).
class SsProjectSync {
  const SsProjectSync();

  /// (Re)converts only the STALE `.sspj` projects under the resolved source
  /// directory into `<output>/<stem>/`, and returns what it touched.
  ///
  /// "Stale" = the newest mtime anywhere under a project's own directory is
  /// newer than the oldest `.ssab` already emitted for it — so editing a
  /// referenced `.ssae`/`.png` (not just the `.sspj`) rebuilds too — or there is
  /// no output yet. Mirrors RenPy's "compare the source dir, on demand".
  ///
  /// Paths come from [SsProjectSyncConfig.resolve] on [projectRoot] (default:
  /// the current directory), so a plain `SsProjectSync().reconvert()` follows
  /// the `SpriteStudio_Source → assets/spritestudio` convention (or a
  /// `spritestudio.yaml` override). [sourceDir]/[outputDir]/[embedded] override
  /// the resolved values when given.
  Future<SsReconvertReport> reconvert({
    String? projectRoot,
    String? sourceDir,
    String? outputDir,
    bool? embedded,
    SsConverter converter = const SsConverter(),
  }) async {
    final cfg =
        SsProjectSyncConfig.resolve(projectRoot ?? Directory.current.path);
    final srcDir = sourceDir ?? cfg.sourceDir;
    final outBase = outputDir ?? cfg.outputDir;
    final emb = embedded ?? cfg.embedded;

    final src = Directory(srcDir);
    if (!src.existsSync()) {
      throw ArgumentError.value(srcDir, 'sourceDir', 'no such directory');
    }

    final converted = <String, String>{};
    final upToDate = <String>[];
    for (final sspj in _findSspj(src)) {
      final outDir = '$outBase/${_stem(sspj.path)}';
      if (_isStale(sspj, outDir)) {
        await converter.convert(sspj.path, outputDir: outDir, embedded: emb);
        converted[sspj.path] = outDir;
      } else {
        upToDate.add(sspj.path);
      }
    }
    return SsReconvertReport(converted: converted, upToDate: upToDate);
  }

  List<File> _findSspj(Directory dir) => dir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.sspj'))
      .toList();

  bool _isStale(File sspj, String outDir) {
    final out = Directory(outDir);
    if (!out.existsSync()) return true;
    final ssabs = out
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.ssab'))
        .toList();
    if (ssabs.isEmpty) return true;
    final oldestOut = ssabs
        .map((f) => f.statSync().modified)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    // Newest mtime over the project's OWN directory subtree (one project per
    // dir, the RenPy source layout) — catches `.ssae`/`.png` edits, not just
    // the `.sspj`.
    final newestSrc = sspj.parent
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .map((f) => f.statSync().modified)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    // `!isBefore` (>=), not `isAfter` (>): treat an equal mtime as stale so an
    // edit landing in the same coarse filesystem tick as the last convert (2s
    // granularity on exFAT/FAT32/some network mounts) still triggers a reconvert.
    return !newestSrc.isBefore(oldestOut);
  }

  String _stem(String path) {
    final bslash = path.lastIndexOf('\\');
    final slash = path.lastIndexOf('/');
    final cut = bslash > slash ? bslash : slash;
    final base = cut >= 0 ? path.substring(cut + 1) : path;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }
}

bool _isAbsolute(String p) =>
    p.startsWith('/') ||
    (Platform.isWindows && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(p));
