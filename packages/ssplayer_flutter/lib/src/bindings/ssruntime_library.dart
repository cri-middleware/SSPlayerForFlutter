import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'ssruntime_bindings.g.dart';

/// Loads the SpriteStudio Brain (`libssruntime`) as a [ffi.DynamicLibrary] and
/// exposes it as [SsRuntimeBindings] (Layer 1).
///
/// The on-disk name of the native library differs per platform — this loader
/// hides that so callers never hard-code `.dylib`/`.dll`/`.so`:
///
///   * Windows        → `ssruntime.dll`
///   * macOS          → `libssruntime.dylib`
///   * Linux/Android  → `libssruntime.so`
///   * iOS            → symbols in the app image (`DynamicLibrary.process()`),
///                      or `libssruntime.framework/libssruntime` when embedded
///                      as a framework.
///
/// Resolution order:
///  1. An explicit path ([SsRuntime.open]'s `libraryPath`) or the
///     `SSRUNTIME_LIBRARY_PATH` env var — handy for `dart test` and desktop
///     runs that load `native/libs/<platform>/...` directly.
///  2. The platform default name ([defaultLibraryName]), resolved by the OS
///     loader once the Flutter FFI plugin has bundled the library.
///  3. On iOS, `DynamicLibrary.process()` for a statically-linked Brain.
class SsRuntime {
  final ffi.DynamicLibrary dynamicLibrary;
  final SsRuntimeBindings bindings;

  SsRuntime._(this.dynamicLibrary) : bindings = SsRuntimeBindings(dynamicLibrary);

  /// The unversioned platform file name for the Brain shared library.
  static String get defaultLibraryName {
    if (Platform.isWindows) return 'ssruntime.dll';
    // macOS + iOS ship the Brain as an embedded framework; dyld resolves it via
    // @rpath (the app's Frameworks dir).
    if (Platform.isMacOS) return 'libssruntime.framework/libssruntime';
    if (Platform.isIOS) return 'libssruntime.framework/libssruntime';
    // Android + Linux.
    return 'libssruntime.so';
  }

  /// Opens the Brain. Pass [libraryPath] to load a specific file (e.g. the
  /// artifact produced by scripts/build-runtime.sh under `native/libs/`).
  factory SsRuntime.open({String? libraryPath}) {
    final envPath = Platform.environment['SSRUNTIME_LIBRARY_PATH'];
    final override = libraryPath ??
        (envPath != null && envPath.isNotEmpty ? envPath : null);
    if (override != null) {
      return SsRuntime._(ffi.DynamicLibrary.open(override));
    }

    // When the Brain is linked into the app image (typical on iOS), its symbols
    // are already in the process; prefer that before opening by name.
    if (Platform.isIOS) {
      return SsRuntime._(ffi.DynamicLibrary.process());
    }
    return SsRuntime._(ffi.DynamicLibrary.open(defaultLibraryName));
  }

  /// Wraps an already-open [ffi.DynamicLibrary] (advanced / testing).
  factory SsRuntime.fromDynamicLibrary(ffi.DynamicLibrary library) =>
      SsRuntime._(library);
}
