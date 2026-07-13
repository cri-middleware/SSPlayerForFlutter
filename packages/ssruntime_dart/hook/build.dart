import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

/// Native-assets build hook: resolves the prebuilt `libssruntime` and registers
/// it as a **code asset** so the `@Native` bindings load it without a
/// `DynamicLibrary.open` and without any Rust toolchain on the consumer side.
///
/// The asset id is `package:ssruntime_dart/ssruntime` (package + name); the
/// generated `@ffi.Native` bindings' `DefaultAsset` must match.
///
/// The library is resolved in this order ([_resolveLibrary]):
///   1. `userDefines['libssruntime']` — a consumer-supplied local dylib (bring
///      your own build); set in the app's `pubspec.yaml`:
///      ```yaml
///      hooks:
///        user_defines:
///          ssruntime_dart:
///            libssruntime: path/to/libssruntime.dylib
///      ```
///   2. `native/libs/<platform>/[<arch>]/…` inside the package — a source
///      checkout populated by scripts/build-runtime.sh (build the Brain from the
///      SpriteStudio-SDK submodule).
///   3. Download the SDK release's `spritestudio-sdk-dynamic-libs.zip`, verify it
///      against the release's `SHA256SUMS`, and extract this target's library
///      (macOS/iOS come as a `.framework`/`.xcframework`, so the Mach-O is pulled
///      out and its install id rewritten) — the path for a pub.dev consumer who
///      never touches Rust. Everything is cached under `outputDirectoryShared`.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final target = _targetFor(input.config.code);
    final file = await _resolveLibrary(input, output, target);
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'ssruntime',
        linkMode: DynamicLoadingBundled(),
        file: file,
      ),
    );
    // Rebuild the code asset when the resolved library changes.
    output.dependencies.add(file);
  });
}

/// How the current build target's `libssruntime` is obtained.
class _Target {
  /// Path inside the package (branch 2: source checkout / build-runtime.sh).
  final String rel;

  /// The entry to pull out of `spritestudio-sdk-dynamic-libs.zip` (branch 3),
  /// matched by suffix so the zip's leading directory doesn't have to be known.
  final String zipEntrySuffix;

  /// Bare output file name (drives the extension the code asset needs).
  final String outName;

  /// Post-extraction processing for Apple Mach-Os.
  final _Extract extract;

  /// For [_Extract.lipoThin]: the arch to thin the fat Mach-O down to.
  final String? lipoArch;

  const _Target(
    this.rel,
    this.zipEntrySuffix,
    this.outName,
    this.extract, {
    this.lipoArch,
  });
}

/// - [copy]: the zip already holds a bare `.so`/`.dylib`/`.dll`; copy it out.
/// - [machoId]: the zip holds a `.framework`; copy its (thin or universal)
///   Mach-O out and set the install id to `@rpath/<outName>` (macOS, iOS device).
/// - [lipoThin]: like [machoId] but the Mach-O is fat, so thin it to [lipoArch]
///   first (iOS simulator = arm64 + x86_64).
enum _Extract { copy, machoId, lipoThin }

_Target _targetFor(CodeConfig code) {
  final os = code.targetOS;
  // build-runtime.sh spells the linux arch dir aarch64 (else x86_64) and arm64
  // elsewhere; map the code_assets Architecture to that.
  final arch = switch (code.targetArchitecture) {
    Architecture.x64 => 'x86_64',
    Architecture.arm64 => os == OS.linux ? 'aarch64' : 'arm64',
    final a => a.name,
  };
  switch (os) {
    case OS.macOS:
      // The release ships libssruntime as a versioned .framework — no bare dylib
      // ("no longer shipped"). Pull the universal Mach-O out of it.
      return const _Target(
        'native/libs/macos/libssruntime.dylib',
        'macos/libssruntime.framework/Versions/A/libssruntime',
        'libssruntime.dylib',
        _Extract.machoId,
      );
    case OS.linux:
      return _Target(
        'native/libs/linux/$arch/libssruntime.so',
        'libs/linux/$arch/libssruntime.so',
        'libssruntime.so',
        _Extract.copy,
      );
    case OS.windows:
      return _Target(
        'native/libs/windows/$arch/ssruntime.dll',
        'libs/windows/$arch/ssruntime.dll',
        'ssruntime.dll',
        _Extract.copy,
      );
    case OS.android:
      final abi = switch (code.targetArchitecture) {
        Architecture.arm64 => 'arm64-v8a',
        Architecture.arm => 'armeabi-v7a',
        Architecture.x64 => 'x86_64',
        final a => throw UnsupportedError(
          'ssruntime_dart: no prebuilt libssruntime for Android $a '
          '(built ABIs: arm64-v8a, armeabi-v7a, x86_64)',
        ),
      };
      return _Target(
        'native/libs/android/$abi/libssruntime.so',
        'libs/android/$abi/libssruntime.so',
        'libssruntime.so',
        _Extract.copy,
      );
    case OS.iOS:
      // The release ships an .xcframework: device = thin arm64,
      // simulator = fat (arm64 + x86_64). Device/simulator arm64 are distinct
      // Mach-O targets that can't share a slice — select by targetSdk.
      final device = code.iOS.targetSdk == IOSSdk.iPhoneOS;
      final dir = device ? 'iphoneos' : 'iphonesimulator';
      final slice = device ? 'ios-arm64' : 'ios-arm64_x86_64-simulator';
      return _Target(
        'native/libs/ios/$dir/$arch/libssruntime.dylib',
        'libssruntime.xcframework/$slice/libssruntime.framework/libssruntime',
        'libssruntime.dylib',
        device ? _Extract.machoId : _Extract.lipoThin,
        lipoArch: device ? null : arch,
      );
    default:
      throw UnsupportedError(
        'ssruntime_dart: no prebuilt libssruntime for target OS $os',
      );
  }
}

/// The SpriteStudio-SDK release the download branch fetches from — the single
/// source of truth for the pinned version. MUST stay in lockstep with the
/// committed ffigen bindings' ABI: bump this whenever you regenerate the bindings
/// against a newer SDK, or the downloaded binary and the Dart bindings disagree.
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
  final override = input.userDefines.path('libssruntime');
  if (override != null) {
    if (!File.fromUri(override).existsSync()) {
      throw ArgumentError(
        'ssruntime_dart: hooks.user_defines.ssruntime_dart.libssruntime points '
        'to a missing file: ${override.toFilePath()}',
      );
    }
    // Declare the dependency so the build cache invalidates if the file changes.
    output.dependencies.add(override);
    return override;
  }

  // 2) Prebuilt library shipped in the package (source checkout / build-runtime).
  final local = input.packageRoot.resolve(target.rel);
  if (File.fromUri(local).existsSync()) {
    return local;
  }

  // 3) Download the release zip and extract this target (pub.dev consumer).
  return _download(input, target);
}

/// Ensures the checksum-verified dynamic-libs zip is cached, then extracts and
/// post-processes this target's library. Both the zip and each extracted library
/// are cached under `outputDirectoryShared` so a second build (or a second
/// target) reuses them — one download yields every platform's library.
Future<Uri> _download(BuildInput input, _Target target) async {
  final cacheDir = input.outputDirectoryShared.resolve(
    'spritestudio-sdk/$_sdkVersion/',
  );
  // Mirror the package-local layout under extracted/ so each target is unique.
  final outUri = cacheDir
      .resolve('extracted/')
      .resolve(target.rel.replaceFirst('native/libs/', ''));
  final outFile = File.fromUri(outUri);
  if (outFile.existsSync() && outFile.lengthSync() > 0) {
    return outUri; // cache hit (this target already extracted)
  }

  final zipFile = await _ensureZip(cacheDir);

  final archive = ZipDecoder().decodeBytes(zipFile.readAsBytesSync());
  final entry = archive.files.firstWhere(
    (f) => f.isFile && f.name.endsWith(target.zipEntrySuffix),
    orElse: () => throw StateError(
      'ssruntime_dart: "${target.zipEntrySuffix}" not found in $_dynamicLibsZip '
      '($_sdkVersion) — the release layout may have changed.',
    ),
  );

  outFile.parent.createSync(recursive: true);
  final tmp = File.fromUri(
    outFile.parent.uri.resolve('${target.outName}.$pid.part'),
  );
  tmp.writeAsBytesSync(entry.content as List<int>);

  switch (target.extract) {
    case _Extract.copy:
      break;
    case _Extract.machoId:
      await _run('install_name_tool', [
        '-id',
        '@rpath/${target.outName}',
        tmp.path,
      ]);
      await _sign(tmp.path);
    case _Extract.lipoThin:
      final thin = File.fromUri(
        outFile.parent.uri.resolve('${target.outName}.$pid.thin'),
      );
      await _run('lipo', [
        tmp.path,
        '-thin',
        target.lipoArch!,
        '-output',
        thin.path,
      ]);
      tmp.deleteSync();
      thin.renameSync(tmp.path);
      await _run('install_name_tool', [
        '-id',
        '@rpath/${target.outName}',
        tmp.path,
      ]);
      await _sign(tmp.path);
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
    // 1) The canonical checksum manifest (small text file).
    final sums = await _getText(
      client,
      Uri.parse('$_releaseBase/$_sdkVersion/SHA256SUMS'),
    );
    final want = _sha256For(sums, _dynamicLibsZip);

    // 2) The zip itself, streamed to a temp file.
    final tmp = File.fromUri(cacheDir.resolve('$_dynamicLibsZip.$pid.part'));
    await _streamTo(
      client,
      Uri.parse('$_releaseBase/$_sdkVersion/$_dynamicLibsZip'),
      tmp,
    );

    // 3) Verify before trusting the archive.
    final got = sha256.convert(tmp.readAsBytesSync()).toString();
    if (got != want) {
      tmp.deleteSync();
      throw StateError(
        'ssruntime_dart: SHA256 mismatch for $_dynamicLibsZip ($_sdkVersion): '
        'expected $want, got $got.',
      );
    }
    tmp.renameSync(zipFile.path); // atomic within the same directory
    return zipFile;
  } finally {
    client.close(force: true);
  }
}

/// Parses `sha256sum` output (`<64-hex>  <name>`, name may carry a `*` binary
/// marker or a path prefix) and returns the hex digest for [filename].
String _sha256For(String sums, String filename) {
  for (final line in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null && m.group(2)!.split('/').last == filename) {
      return m.group(1)!.toLowerCase();
    }
  }
  throw StateError(
    'ssruntime_dart: $filename is not listed in SHA256SUMS ($_sdkVersion).',
  );
}

Future<String> _getText(HttpClient client, Uri url) async {
  final resp = await (await client.getUrl(url)).close();
  if (resp.statusCode != HttpStatus.ok) {
    throw HttpException(
      'ssruntime_dart: HTTP ${resp.statusCode} for $url — is the $_sdkVersion '
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
      'ssruntime_dart: HTTP ${resp.statusCode} for $url.',
      uri: url,
    );
  }
  await resp.pipe(dest.openWrite()); // pipe closes the sink
  if (dest.lengthSync() == 0) {
    dest.deleteSync();
    throw HttpException(
      'ssruntime_dart: downloaded an empty file from $url',
      uri: url,
    );
  }
}

/// Ad-hoc re-signs [path]. `install_name_tool` / `lipo` invalidate a Mach-O's
/// code signature, and Apple Silicon refuses to `dlopen` an unsigned dylib
/// (verified). Flutter later re-signs the embedded asset with the app identity;
/// this just keeps the cached file independently loadable.
Future<void> _sign(String path) =>
    _run('codesign', ['--sign', '-', '--force', path]);

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
