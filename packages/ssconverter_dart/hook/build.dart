import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

/// Native-assets build hook: resolves the prebuilt `libssconverter` and registers
/// it as a **code asset** so the `@Native` bindings load it without a
/// `DynamicLibrary.open`. Desktop only (the converter is a host tool).
///
/// The asset id is `package:ssconverter_dart/ssconverter`; the generated
/// `@ffi.Native` bindings' `DefaultAsset` must match.
///
/// The library is resolved in this order ([_resolveLibrary]) — the same scheme
/// as ssruntime_dart:
///   1. `userDefines['libssconverter']` — a consumer-supplied local dylib, set in
///      the app's `pubspec.yaml`:
///      ```yaml
///      hooks:
///        user_defines:
///          ssconverter_dart:
///            libssconverter: path/to/libssconverter.dylib
///      ```
///   2. `native/libs/<platform>/[<arch>]/…` inside the package — a source
///      checkout populated by scripts/build-runtime.sh.
///   3. Download the SDK release's `spritestudio-sdk-dynamic-libs.zip`, verify it
///      against the release's `SHA256SUMS`, and extract this platform's converter
///      library — the path for a consumer with no Rust toolchain. The converter
///      ships as a bare dylib/.so/.dll on every desktop OS (no framework), so
///      extraction is a plain copy. Cached under `outputDirectoryShared`.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final target = _targetFor(input.config.code);
    final file = await _resolveLibrary(input, output, target);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'ssconverter',
        linkMode: DynamicLoadingBundled(),
        file: file,
      ),
    );
    output.dependencies.add(file);
  });
}

/// How the current build target's `libssconverter` is obtained. The converter is
/// desktop-only and ships as a bare library on every OS, so — unlike the runtime
/// — there is no framework/xcframework to unwrap: [macOsId] just rewrites the
/// macOS dylib's install id, everything else is a plain copy.
class _Target {
  /// Path inside the package (branch 2: source checkout / build-runtime.sh).
  final String rel;

  /// Entry to pull out of `spritestudio-sdk-dynamic-libs.zip` (branch 3), matched
  /// by suffix so the zip's leading directory doesn't have to be known.
  final String zipEntrySuffix;

  /// Bare output file name (drives the extension the code asset needs).
  final String outName;

  /// Whether to set the macOS dylib's install id to `@rpath/<outName>`.
  final bool macOsId;

  const _Target(
    this.rel,
    this.zipEntrySuffix,
    this.outName, {
    this.macOsId = false,
  });
}

_Target _targetFor(CodeConfig code) {
  final os = code.targetOS;
  final arch = switch (code.targetArchitecture) {
    Architecture.x64 => 'x86_64',
    Architecture.arm64 => os == OS.linux ? 'aarch64' : 'arm64',
    final a => a.name,
  };
  return switch (os) {
    OS.macOS => const _Target(
      'native/libs/macos/libssconverter.dylib',
      'macos/libssconverter.dylib',
      'libssconverter.dylib',
      macOsId: true,
    ),
    OS.linux => _Target(
      'native/libs/linux/$arch/libssconverter.so',
      'libs/linux/$arch/libssconverter.so',
      'libssconverter.so',
    ),
    OS.windows => _Target(
      'native/libs/windows/$arch/ssconverter.dll',
      'libs/windows/$arch/ssconverter.dll',
      'ssconverter.dll',
    ),
    _ => throw UnsupportedError(
      'ssconverter_dart is desktop-only (Windows/macOS/Linux); got $os',
    ),
  };
}

/// The SpriteStudio-SDK release the download branch fetches from — the single
/// source of truth for the pinned version. MUST stay in lockstep with the
/// committed ffigen bindings' ABI.
const _sdkVersion = 'v7.0.0-alpha.1';

/// GitHub Releases base for the SpriteStudio-SDK.
const _releaseBase =
    'https://github.com/cri-middleware/SpriteStudio-SDK/releases/download';

/// The all-platform dynamic-libraries archive published on each release.
const _dynamicLibsZip = 'spritestudio-sdk-dynamic-libs.zip';

Future<Uri> _resolveLibrary(
  BuildInput input,
  BuildOutputBuilder output,
  _Target target,
) async {
  // 1) Consumer override — an explicit local dylib wins over everything.
  final override = input.userDefines.path('libssconverter');
  if (override != null) {
    if (!File.fromUri(override).existsSync()) {
      throw ArgumentError(
        'ssconverter_dart: hooks.user_defines.ssconverter_dart.libssconverter '
        'points to a missing file: ${override.toFilePath()}',
      );
    }
    output.dependencies.add(override);
    return override;
  }

  // 2) Prebuilt library shipped in the package (source checkout / build-runtime).
  final local = input.packageRoot.resolve(target.rel);
  if (File.fromUri(local).existsSync()) {
    return local;
  }

  // 3) Download the release zip and extract this target (consumer).
  return _download(input, target);
}

/// Ensures the checksum-verified dynamic-libs zip is cached, then extracts this
/// target's library. Both the zip and each extracted library are cached under
/// `outputDirectoryShared`.
Future<Uri> _download(BuildInput input, _Target target) async {
  final cacheDir = input.outputDirectoryShared.resolve(
    'spritestudio-sdk/$_sdkVersion/',
  );
  final outUri = cacheDir
      .resolve('extracted/')
      .resolve(target.rel.replaceFirst('native/libs/', ''));
  final outFile = File.fromUri(outUri);
  if (outFile.existsSync() && outFile.lengthSync() > 0) {
    return outUri; // cache hit
  }

  // install_name_tool / codesign are macOS-only; assert the host so a violation
  // fails clearly rather than with a cryptic "command not found".
  if (target.macOsId && !Platform.isMacOS) {
    throw StateError(
      'ssconverter_dart: preparing the macOS library requires a macOS host — '
      'install_name_tool / codesign are macOS-only.',
    );
  }

  final zipFile = await _ensureZip(cacheDir);

  final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
  final entry = archive.files.firstWhere(
    (f) => f.isFile && f.name.endsWith(target.zipEntrySuffix),
    orElse: () => throw StateError(
      'ssconverter_dart: "${target.zipEntrySuffix}" not found in $_dynamicLibsZip '
      '($_sdkVersion) — the release layout may have changed.',
    ),
  );

  outFile.parent.createSync(recursive: true);
  final tmp = File.fromUri(
    outFile.parent.uri.resolve('${target.outName}.$pid.part'),
  );
  tmp.writeAsBytesSync(entry.content as List<int>);
  if (target.macOsId) {
    await _run('install_name_tool', [
      '-id',
      '@rpath/${target.outName}',
      tmp.path,
    ]);
    // install_name_tool invalidated the dylib's signature; Apple Silicon won't
    // dlopen an unsigned Mach-O, so re-sign ad-hoc (Flutter re-signs later too).
    await _run('codesign', ['--sign', '-', '--force', tmp.path]);
  }
  tmp.renameSync(outFile.path); // atomic within the same directory
  return outUri;
}

/// Downloads + checksum-verifies `spritestudio-sdk-dynamic-libs.zip` into
/// [cacheDir] (once per version) and returns it.
Future<File> _ensureZip(Uri cacheDir) async {
  await Directory.fromUri(cacheDir).create(recursive: true);
  final zipFile = File.fromUri(cacheDir.resolve(_dynamicLibsZip));
  if (zipFile.existsSync() && zipFile.lengthSync() > 0) {
    return zipFile; // cache hit
  }

  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final sums = await _getText(
      client,
      Uri.parse('$_releaseBase/$_sdkVersion/SHA256SUMS'),
    );
    final want = _sha256For(sums, _dynamicLibsZip);

    final tmp = File.fromUri(cacheDir.resolve('$_dynamicLibsZip.$pid.part'));
    await _streamTo(
      client,
      Uri.parse('$_releaseBase/$_sdkVersion/$_dynamicLibsZip'),
      tmp,
    );

    final got = sha256.convert(tmp.readAsBytesSync()).toString();
    if (got != want) {
      tmp.deleteSync();
      throw StateError(
        'ssconverter_dart: SHA256 mismatch for $_dynamicLibsZip ($_sdkVersion): '
        'expected $want, got $got.',
      );
    }
    tmp.renameSync(zipFile.path); // atomic within the same directory
    return zipFile;
  } finally {
    client.close(force: true);
  }
}

/// Parses `sha256sum` output and returns the hex digest for [filename].
String _sha256For(String sums, String filename) {
  for (final line in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null && m.group(2)!.split('/').last == filename) {
      return m.group(1)!.toLowerCase();
    }
  }
  throw StateError(
    'ssconverter_dart: $filename is not listed in SHA256SUMS ($_sdkVersion).',
  );
}

Future<String> _getText(HttpClient client, Uri url) async {
  final resp = await (await client.getUrl(url)).close();
  if (resp.statusCode != HttpStatus.ok) {
    throw HttpException(
      'ssconverter_dart: HTTP ${resp.statusCode} for $url — is the $_sdkVersion '
      'release published? (else build locally with scripts/build-runtime.sh).',
      uri: url,
    );
  }
  return resp.transform(utf8.decoder).join();
}

Future<void> _streamTo(HttpClient client, Uri url, File dest) async {
  final resp = await (await client.getUrl(url)).close();
  if (resp.statusCode != HttpStatus.ok) {
    throw HttpException(
      'ssconverter_dart: HTTP ${resp.statusCode} for $url.',
      uri: url,
    );
  }
  await resp.pipe(dest.openWrite()); // pipe closes the sink
  if (dest.lengthSync() == 0) {
    dest.deleteSync();
    throw HttpException(
      'ssconverter_dart: downloaded an empty file from $url',
      uri: url,
    );
  }
}

Future<void> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    throw ProcessException(
      exe,
      args,
      '${r.stderr}'.trim().isEmpty
          ? '${r.stdout}'.trim()
          : '${r.stderr}'.trim(),
      r.exitCode,
    );
  }
}
