// Set the version of one or more packages -- the decision a release makes by hand.
//
//   dart scripts/set-versions.dart ssruntime_dart@7.0.0-beta.2
//   dart scripts/set-versions.dart ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2
//
// Each argument is <directory under packages/>@<version>. For each, this writes
// the `version:` of that package, raises the `^` constraint every other package
// under packages/ has on it (the examples depend by path), and turns the
// `## [Unreleased]` notes in its CHANGELOG.md into `## [<version>] - <date>` under
// a fresh, empty `## [Unreleased]`: the changelog is where the notes are, and
// `dart pub publish` warns about one that does not mention the version, and a
// warning fails it. Nothing else moves, so a dependent gets a new version only
// when it is named too. release.yml runs this with its `versions` input; run it
// locally to see what a release would check, and `git checkout -- packages` to
// put the tree back.
//
// Every argument is checked, and every edit made in memory, before anything is
// written. A version may not go backwards: pub.dev keeps every version it is
// given, for good. A version the changelog already has a heading for is
// released, and nothing under `## [Unreleased]` leaves a release with no notes.
// Naming the version a package already has cuts its first release.

import 'dart:io';

final root = File(Platform.script.toFilePath()).parent.parent;

class Version {
  Version(this.core, this.pre);
  final List<int> core;
  final List<String> pre;

  static Version? parse(String text) {
    final m = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(text);
    if (m == null) return null;
    return Version([
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
    ], m[4] == null ? [] : m[4]!.split('.'));
  }

  // SemVer precedence: the core numerically, then a version with a prerelease
  // part below the same version without one, then the identifiers in turn.
  int compareTo(Version other) {
    for (var i = 0; i < 3; i++) {
      if (core[i] != other.core[i]) return core[i] < other.core[i] ? -1 : 1;
    }
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.length == other.pre.length ? 0 : (pre.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < pre.length || i < other.pre.length; i++) {
      if (i >= pre.length) return -1;
      if (i >= other.pre.length) return 1;
      final x = pre[i];
      final y = other.pre[i];
      final xn = int.tryParse(x);
      final yn = int.tryParse(y);
      if (xn != null && yn != null) {
        if (xn != yn) return xn < yn ? -1 : 1;
      } else if ((xn == null) != (yn == null)) {
        return xn != null ? -1 : 1;
      } else if (x != y) {
        return x.compareTo(y) < 0 ? -1 : 1;
      }
    }
    return 0;
  }
}

String? field(String pubspec, String name) =>
    RegExp('^$name:\\s*(\\S+)', multiLine: true).firstMatch(pubspec)?[1];

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'set-versions: name at least one <package>@<version>, e.g. ssruntime_dart@7.0.0-beta.2',
    );
    exit(2);
  }

  final pubspecs = {
    for (final d in Directory(
      '${root.path}/packages',
    ).listSync()..sort((a, b) => a.path.compareTo(b.path)))
      if (File('${d.path}/pubspec.yaml').existsSync())
        d.path.split(Platform.pathSeparator).last: File(
          '${d.path}/pubspec.yaml',
        ),
  };
  // Every edit lands here first, keyed by file, and is written only at the end.
  final pending = <String, String>{};
  String read(File f) => pending[f.path] ?? f.readAsStringSync();

  final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
  final summary = <String>[];
  final errors = <String>[];
  final seen = <String>{};
  for (final arg in args) {
    final at = arg.lastIndexOf('@');
    final name = at > 0 ? arg.substring(0, at) : '';
    final version = at > 0 ? arg.substring(at + 1) : '';
    final want = Version.parse(version);
    if (name.isEmpty || want == null) {
      errors.add(
        '$arg: expected <directory under packages/>@<x.y.z[-prerelease]>',
      );
      continue;
    }
    if (!seen.add(name)) {
      errors.add('$name: named twice');
      continue;
    }
    final pubspec = pubspecs[name];
    if (pubspec == null || field(read(pubspec), 'name') != name) {
      errors.add('$name: there is no package by that name under packages/');
      continue;
    }
    final current = field(read(pubspec), 'version') ?? '';
    final have = Version.parse(current);
    if (have == null) {
      errors.add(
        "$name: its current version '$current' is not one this script can compare",
      );
      continue;
    }
    final order = want.compareTo(have);
    if (order < 0) {
      errors.add('$name: $version is lower than its current $current');
      continue;
    }

    final changelog = File('${pubspec.parent.path}/CHANGELOG.md');
    if (!changelog.existsSync()) {
      errors.add('$name: there is no CHANGELOG.md beside its pubspec');
      continue;
    }
    final lines = read(changelog).split('\n');
    if (lines.any((l) => l.startsWith('## [$version]'))) {
      errors.add(
        '$name: $version is already released -- its CHANGELOG.md has a heading for it',
      );
      continue;
    }
    final top = lines.indexWhere((l) => l.trimRight() == '## [Unreleased]');
    if (top < 0) {
      errors.add("$name: its CHANGELOG.md has no '## [Unreleased]' heading");
      continue;
    }
    var end = lines.indexWhere((l) => l.startsWith('## '), top + 1);
    if (end < 0) end = lines.length;
    if (!lines
        .sublist(top + 1, end)
        .any((l) => l.trim().isNotEmpty && !l.startsWith('#'))) {
      errors.add(
        "$name: nothing under '## [Unreleased]' in its CHANGELOG.md -- write what $version gains first",
      );
      continue;
    }

    final raised = <String>[];
    if (order > 0) {
      final own = RegExp(
        '^version:[ \\t]*${RegExp.escape(current)}[ \\t]*\$',
        multiLine: true,
      );
      final text = read(pubspec);
      if (own.allMatches(text).length != 1) {
        errors.add(
          '$name: its pubspec does not say `version: $current` exactly once -- set it by hand',
        );
        continue;
      }
      pending[pubspec.path] = text.replaceFirst(own, 'version: $version');

      final constraint = RegExp(
        '^([ \\t]+$name:[ \\t]*)\\^${RegExp.escape(current)}[ \\t]*\$',
        multiLine: true,
      );
      for (final e in pubspecs.entries) {
        final other = read(e.value);
        if (constraint.hasMatch(other)) {
          pending[e.value.path] = other.replaceAllMapped(
            constraint,
            (m) => '${m[1]}^$version',
          );
          raised.add(e.key);
        }
      }
    }

    lines.replaceRange(top, top + 1, [
      '## [Unreleased]',
      '',
      '## [$version] - $today',
    ]);
    pending[changelog.path] = lines.join('\n');

    summary.add(
      order > 0
          ? '$name: $current -> $version${raised.isEmpty ? '' : ' (constraint raised in ${raised.join(', ')})'}'
          : '$name: $version',
    );
  }

  if (errors.isNotEmpty) {
    for (final e in errors) {
      stderr.writeln('set-versions: $e');
    }
    stderr.writeln('set-versions: nothing was written');
    exit(1);
  }
  pending.forEach((path, text) => File(path).writeAsStringSync(text));
  summary.forEach(stdout.writeln);
}
