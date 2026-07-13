import 'dart:io';

import 'package:code_assets/code_assets.dart';
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
///   3. Download the pinned release asset from GitHub, cached under
///      `outputDirectoryShared` — the path for a consumer with no Rust toolchain.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final os = code.targetOS;
    final arch = switch (code.targetArchitecture) {
      Architecture.x64 => 'x86_64',
      Architecture.arm64 => os == OS.linux ? 'aarch64' : 'arm64',
      final a => a.name,
    };
    // (local path inside the package, release asset file name). macOS ships one
    // universal dylib (no arch dir); linux/windows are per-arch.
    final (String rel, String assetName) = switch (os) {
      OS.macOS => (
        'native/libs/macos/libssconverter.dylib',
        'libssconverter-macos.dylib',
      ),
      OS.linux => (
        'native/libs/linux/$arch/libssconverter.so',
        'libssconverter-linux-$arch.so',
      ),
      OS.windows => (
        'native/libs/windows/$arch/ssconverter.dll',
        'ssconverter-windows-$arch.dll',
      ),
      _ => throw UnsupportedError(
        'ssconverter_dart is desktop-only (Windows/macOS/Linux); got $os',
      ),
    };

    final file = await _resolveLibrary(input, output, rel, assetName);
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

/// The SpriteStudio-SDK release the download branch fetches prebuilt libraries
/// from — the single source of truth for the pinned version. MUST stay in
/// lockstep with the committed ffigen bindings' ABI: bump this whenever you
/// regenerate the bindings against a newer SDK, or the downloaded binary and the
/// Dart bindings will disagree.
const _sdkVersion = 'v7.0.0-alpha.1';

/// GitHub Releases base for prebuilt `libssconverter` assets (see [_download]).
const _releaseBase =
    'https://github.com/cri-middleware/SpriteStudio-SDK/releases/download';

Future<Uri> _resolveLibrary(
  BuildInput input,
  BuildOutputBuilder output,
  String rel,
  String assetName,
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
  final local = input.packageRoot.resolve(rel);
  if (File.fromUri(local).existsSync()) {
    return local;
  }

  // 3) Download the pinned release asset (consumer, no Rust toolchain).
  return _download(input, assetName);
}

/// Downloads [assetName] from the pinned release into a version-keyed subfolder
/// of `outputDirectoryShared` (persisted across builds) and returns its Uri.
/// A prior download for the same version is reused; the write is staged through
/// a temp file + atomic rename so an interrupted build never leaves a truncated
/// dylib in the cache.
Future<Uri> _download(BuildInput input, String assetName) async {
  final cacheDir = input.outputDirectoryShared.resolve(
    'libssconverter/$_sdkVersion/',
  );
  final dest = cacheDir.resolve(assetName);
  final destFile = File.fromUri(dest);
  if (destFile.existsSync() && destFile.lengthSync() > 0) {
    return dest; // cache hit
  }

  final url = Uri.parse('$_releaseBase/$_sdkVersion/$assetName');
  await Directory.fromUri(cacheDir).create(recursive: true);

  final client = HttpClient()
    // Honour HTTP(S)_PROXY / NO_PROXY — the hooks runner passes these through.
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final request = await client.getUrl(url); // follows redirects to the CDN
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'ssconverter_dart: could not download the prebuilt libssconverter for '
        '$_sdkVersion (HTTP ${response.statusCode}). Either the release does '
        'not publish "$assetName" yet, or build it locally with '
        'scripts/build-runtime.sh.',
        uri: url,
      );
    }
    final tmp = File.fromUri(cacheDir.resolve('$assetName.$pid.part'));
    await response.pipe(tmp.openWrite()); // pipe closes the sink
    if (tmp.lengthSync() == 0) {
      tmp.deleteSync();
      throw HttpException(
        'ssconverter_dart: downloaded an empty file from $url',
        uri: url,
      );
    }
    tmp.renameSync(destFile.path); // atomic within the same directory
  } finally {
    client.close(force: true);
  }
  return dest;
}
