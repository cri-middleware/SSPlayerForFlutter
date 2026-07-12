import 'dart:ffi' as ffi;
import 'dart:io' show File, Platform;
import 'dart:isolate' show Isolate;

import 'ssconverter_bindings.g.dart';

/// Loads the SpriteStudio converter (`libssconverter`) as a [ffi.DynamicLibrary]
/// and exposes it as [SsConverterBindings].
///
/// The converter is a **host / desktop tool** (it is not embedded in a mobile
/// app): convert on the host, push the resulting `.ssab` to devices, and reload
/// it via the runtime. Per-platform file name:
///
///   * Windows → `ssconverter.dll`
///   * macOS   → `libssconverter.dylib`  (a bare dylib, not a framework)
///   * Linux   → `libssconverter.so`
///
/// Resolution order for [open]: an explicit `libraryPath`, else the
/// `SSCONVERTER_LIBRARY_PATH` env var, else the platform default name (the OS
/// loader must be able to find it). For a CLI where the dylib lives under the
/// package's `native/libs/…` (built by `scripts/build-runtime.sh` or fetched by
/// `scripts/download-sdk.sh`) and is not on the loader path, use [openForHost],
/// which additionally resolves that location via the package URI.
class SsConverterLibrary {
  final ffi.DynamicLibrary dynamicLibrary;
  final SsConverterBindings bindings;

  SsConverterLibrary._(this.dynamicLibrary)
      : bindings = SsConverterBindings(dynamicLibrary);

  /// The unversioned platform file name for the converter shared library.
  static String get defaultLibraryName {
    if (Platform.isWindows) return 'ssconverter.dll';
    if (Platform.isMacOS) return 'libssconverter.dylib';
    return 'libssconverter.so'; // Linux (host/desktop tool)
  }

  static String? get _envPath {
    final v = Platform.environment['SSCONVERTER_LIBRARY_PATH'];
    return (v != null && v.isNotEmpty) ? v : null;
  }

  /// Opens by explicit [libraryPath] / `SSCONVERTER_LIBRARY_PATH` / OS default.
  factory SsConverterLibrary.open({String? libraryPath}) {
    final path = libraryPath ?? _envPath ?? defaultLibraryName;
    return SsConverterLibrary._(ffi.DynamicLibrary.open(path));
  }

  /// Wraps an already-open [ffi.DynamicLibrary] (advanced / testing).
  factory SsConverterLibrary.fromDynamicLibrary(ffi.DynamicLibrary library) =>
      SsConverterLibrary._(library);

  /// Opens the host converter for a CLI / desktop tool: an explicit
  /// [libraryPath] / `SSCONVERTER_LIBRARY_PATH`, else the dylib under the
  /// package's `native/libs/<platform>/` (resolved via the package URI), else
  /// the OS default name.
  static Future<SsConverterLibrary> openForHost({String? libraryPath}) async {
    final explicit = libraryPath ?? _envPath;
    if (explicit != null) {
      return SsConverterLibrary._(ffi.DynamicLibrary.open(explicit));
    }
    final resolved = await _resolvePackageHostLibrary();
    return SsConverterLibrary._(
        ffi.DynamicLibrary.open(resolved ?? defaultLibraryName));
  }

  /// Best-effort path to the package's bundled host dylib, in the layout
  /// `scripts/build-runtime.sh` produces. Returns null when it can't be found.
  static Future<String?> _resolvePackageHostLibrary() async {
    final libUri = await Isolate.resolvePackageUri(
        Uri.parse('package:ssconverter_dart/ssconverter_dart.dart'));
    if (libUri == null || libUri.scheme != 'file') return null;
    // …/packages/ssconverter_dart/lib/ssconverter_dart.dart → package root.
    final pkgRoot = File.fromUri(libUri).parent.parent.path;
    final name = defaultLibraryName;
    final libs = '$pkgRoot/native/libs';
    final candidates = <String>[];
    if (Platform.isMacOS) {
      candidates.add('$libs/macos/$name'); // no arch subdir on macOS
    } else if (Platform.isLinux) {
      candidates.add('$libs/linux/x86_64/$name');
      candidates.add('$libs/linux/aarch64/$name');
    } else if (Platform.isWindows) {
      candidates.add('$libs/windows/x86_64/$name');
      candidates.add('$libs/windows/arm64/$name');
    }
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }
}
