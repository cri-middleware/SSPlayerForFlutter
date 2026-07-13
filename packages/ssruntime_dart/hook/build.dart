import 'dart:io';

import 'package:code_assets/code_assets.dart';
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
///   3. Download the pinned release asset from GitHub and cache it under
///      `outputDirectoryShared` — the path taken by a pub.dev consumer who never
///      touches Rust.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final (rel, assetName) = _targetPaths(input.config.code);
    final file = await _resolveLibrary(input, output, rel, assetName);
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

/// (package-local path, release-asset file name) for the current build target.
/// The hook runs once per (OS, architecture, and — for iOS — SDK), so each
/// invocation resolves exactly one native library.
(String, String) _targetPaths(CodeConfig code) {
  final os = code.targetOS;
  // build-runtime.sh spells the linux arch dir aarch64 (else x86_64) and arm64
  // elsewhere; map the code_assets Architecture to that.
  final arch = switch (code.targetArchitecture) {
    Architecture.x64 => 'x86_64',
    Architecture.arm64 => os == OS.linux ? 'aarch64' : 'arm64',
    final a => a.name,
  };
  return switch (os) {
    OS.macOS => (
      'native/libs/macos/libssruntime.dylib',
      'libssruntime-macos.dylib',
    ),
    OS.linux => (
      'native/libs/linux/$arch/libssruntime.so',
      'libssruntime-linux-$arch.so',
    ),
    OS.windows => (
      'native/libs/windows/$arch/ssruntime.dll',
      'ssruntime-windows-$arch.dll',
    ),
    OS.android => _androidPaths(code.targetArchitecture),
    OS.iOS => _iosPaths(code.iOS.targetSdk, arch),
    _ => throw UnsupportedError(
      'ssruntime_dart: no prebuilt libssruntime for target OS $os',
    ),
  };
}

/// Android ships one bare `.so` per NDK ABI (the SDK builds these three).
(String, String) _androidPaths(Architecture arch) => switch (arch) {
  Architecture.arm64 => (
    'native/libs/android/arm64-v8a/libssruntime.so',
    'libssruntime-android-arm64-v8a.so',
  ),
  Architecture.arm => (
    'native/libs/android/armeabi-v7a/libssruntime.so',
    'libssruntime-android-armeabi-v7a.so',
  ),
  Architecture.x64 => (
    'native/libs/android/x86_64/libssruntime.so',
    'libssruntime-android-x86_64.so',
  ),
  _ => throw UnsupportedError(
    'ssruntime_dart: no prebuilt libssruntime for Android $arch '
    '(built ABIs: arm64-v8a, armeabi-v7a, x86_64)',
  ),
};

/// iOS device (`iphoneos`) and simulator (`iphonesimulator`) are DISTINCT Mach-O
/// targets even at the same arch (`arm64-apple-ios` vs
/// `arm64-apple-ios-simulator`), so they cannot share a slice — select by the
/// SDK this hook invocation targets. Flutter's native-assets embedding wraps the
/// chosen bare dylib into a framework and (re)signs it, as it does on macOS.
(String, String) _iosPaths(IOSSdk sdk, String arch) {
  final dir = sdk == IOSSdk.iPhoneOS ? 'iphoneos' : 'iphonesimulator';
  return (
    'native/libs/ios/$dir/$arch/libssruntime.dylib',
    'libssruntime-ios-$dir-$arch.dylib',
  );
}

/// The SpriteStudio-SDK release the download branch fetches prebuilt libraries
/// from — the single source of truth for the pinned version. MUST stay in
/// lockstep with the committed ffigen bindings' ABI: bump this whenever you
/// regenerate the bindings against a newer SDK, or the downloaded binary and the
/// Dart bindings will disagree.
const _sdkVersion = 'v7.0.0-alpha01';

/// GitHub Releases base for prebuilt `libssruntime` assets (see [_download]).
const _releaseBase =
    'https://github.com/cri-middleware/SpriteStudio-SDK/releases/download';

Future<Uri> _resolveLibrary(
  BuildInput input,
  BuildOutputBuilder output,
  String rel,
  String assetName,
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
  final local = input.packageRoot.resolve(rel);
  if (File.fromUri(local).existsSync()) {
    return local;
  }

  // 3) Download the pinned release asset (pub.dev consumer, no Rust toolchain).
  return _download(input, assetName);
}

/// Downloads [assetName] from the pinned release into a version-keyed subfolder
/// of `outputDirectoryShared` (persisted across builds) and returns its Uri.
/// A prior download for the same version is reused; the write is staged through
/// a temp file + atomic rename so an interrupted build never leaves a truncated
/// dylib in the cache.
Future<Uri> _download(BuildInput input, String assetName) async {
  final cacheDir = input.outputDirectoryShared.resolve(
    'libssruntime/$_sdkVersion/',
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
        'ssruntime_dart: could not download the prebuilt libssruntime for '
        '$_sdkVersion (HTTP ${response.statusCode}). Either the release does '
        'not publish "$assetName" yet, or build the Brain locally with '
        'scripts/build-runtime.sh.',
        uri: url,
      );
    }
    final tmp = File.fromUri(cacheDir.resolve('$assetName.$pid.part'));
    await response.pipe(tmp.openWrite()); // pipe closes the sink
    if (tmp.lengthSync() == 0) {
      tmp.deleteSync();
      throw HttpException(
        'ssruntime_dart: downloaded an empty file from $url',
        uri: url,
      );
    }
    tmp.renameSync(destFile.path); // atomic within the same directory
  } finally {
    client.close(force: true);
  }
  return dest;
}
