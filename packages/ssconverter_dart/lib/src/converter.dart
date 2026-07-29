import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'ssconverter_bindings.g.dart';

/// The converter result code (mirrors the C `CConverterError`).
export 'ssconverter_bindings.g.dart' show CConverterError;

/// Thrown when a `.sspj → .ssab` conversion fails. [code] is the Brain's result
/// code and [message] the converter's error string (may be null).
class SsConverterException implements Exception {
  final CConverterError code;
  final String? message;
  final String sspjPath;

  SsConverterException(this.code, this.message, this.sspjPath);

  @override
  String toString() => 'SsConverterException(${code.name}'
      '${message != null ? ': $message' : ''}) for $sspjPath';
}

/// High-level, async wrapper over `libssconverter` — a **host / desktop tool**.
///
/// Converts a SpriteStudio 7 `.sspj` project into optimized `.ssab` binary(ies).
/// The native library is delivered via **native assets** — `hook/build.dart`
/// bundles the prebuilt `libssconverter` as a code asset and the `@Native`
/// bindings resolve it, so there is no `DynamicLibrary.open` /
/// `SSCONVERTER_LIBRARY_PATH`. Desktop only (Windows / macOS / Linux).
///
/// Lifetime: each [convert] owns its native `Context` for the duration of the
/// call (create → convert → poll `is_finished` → get_result → destroy); no
/// borrowed pointers escape the call (architecture §16B).
class SsConverter {
  const SsConverter();

  /// The converter version string (e.g. `7.0.0-beta.1+<sha>`).
  String get version {
    final p = ss_converter_version();
    if (p == ffi.nullptr) return 'unknown';
    try {
      return p.cast<Utf8>().toDartString();
    } finally {
      ss_converter_version_free(p);
    }
  }

  /// The `.ssab` schema version this converter emits.
  int get ssabSchemaVersion => ss_converter_ssab_schema_version();

  /// The default output directory for [sspjPath]: a sibling folder named after
  /// the project stem — `<stem>` normally, `<stem>_emb` when [embedded] — which
  /// mirrors the SDK `ssconverter-cli` single-mode default.
  static String defaultOutputDir(String sspjPath, {bool embedded = false}) {
    final slash = sspjPath.lastIndexOf('/');
    final bslash = Platform.isWindows ? sspjPath.lastIndexOf('\\') : -1;
    final sep = slash > bslash ? slash : bslash;
    final dir = sep >= 0 ? sspjPath.substring(0, sep) : '';
    final base = sep >= 0 ? sspjPath.substring(sep + 1) : sspjPath;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    final name = embedded ? '${stem}_emb' : stem;
    return dir.isEmpty ? name : '$dir/$name';
  }

  /// Converts [sspjPath] → `.ssab`, writing into [outputDir] (created by the
  /// converter if needed; defaults to [defaultOutputDir]). [embedded] inlines
  /// textures into a self-contained `.ssab`.
  ///
  /// Returns the output directory. Throws [SsConverterException] on a converter
  /// error, or [StateError] if the native context can't be created.
  ///
  /// The conversion runs on a native worker thread; this polls it every
  /// [pollInterval] without blocking the isolate.
  Future<String> convert(
    String sspjPath, {
    String? outputDir,
    bool embedded = false,
    Duration pollInterval = const Duration(milliseconds: 20),
  }) async {
    // Desktop-only host tool: the mobile-inert build hook bundles no
    // libssconverter on iOS/Android, so fail clearly here rather than with a
    // cryptic native-symbol lookup error. Mobile apps ship pre-converted `.ssab`
    // (convert on the host); the live-reload path reloads, never converts, on
    // device.
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      throw UnsupportedError(
        'ssconverter_dart is desktop-only; conversion cannot run on '
        '${Platform.operatingSystem}. Convert on the host and ship the .ssab.',
      );
    }
    final outDir = outputDir ?? defaultOutputDir(sspjPath, embedded: embedded);

    final ctx = ss_converter_create();
    if (ctx == ffi.nullptr) {
      throw StateError('ss_converter_create returned null');
    }
    // Allocate the UTF-8 argument buffers inside the try so that if the second
    // allocation throws (OOM) the first is still freed and the context destroyed.
    ffi.Pointer<Utf8>? cSspj;
    ffi.Pointer<Utf8>? cOut;
    try {
      cSspj = sspjPath.toNativeUtf8();
      cOut = outDir.toNativeUtf8();
      ss_converter_convert(
        ctx,
        cSspj.cast(),
        cOut.cast(),
        embedded,
        ffi.nullptr, // log callback: none in v1
      );
      // The worker thread is spawned synchronously inside convert(); poll it to
      // completion. is_running goes false-without-finished only when the call
      // never started a worker (e.g. bad args) — break so get_result surfaces it.
      while (!ss_converter_is_finished(ctx)) {
        if (!ss_converter_is_running(ctx)) break;
        await Future<void>.delayed(pollInterval);
      }
      final code = CConverterError.fromValue(ss_converter_get_result(ctx));
      if (code != CConverterError.Success) {
        throw SsConverterException(code, _readError(ctx), sspjPath);
      }
      return outDir;
    } finally {
      if (cSspj != null) malloc.free(cSspj);
      if (cOut != null) malloc.free(cOut);
      ss_converter_destroy(ctx);
    }
  }

  /// Reads the converter's last error string via `ss_converter_get_error`
  /// (populated by the preceding `ss_converter_get_result`). Null when none.
  String? _readError(ffi.Pointer<Context> ctx) {
    final outData = calloc<ffi.Pointer<ffi.Char>>();
    final outLen = calloc<ffi.UintPtr>();
    try {
      ss_converter_get_error(ctx, outData, outLen);
      final ptr = outData.value;
      final len = outLen.value;
      if (ptr == ffi.nullptr || len == 0) return null;
      return ptr.cast<Utf8>().toDartString(length: len);
    } finally {
      calloc.free(outData);
      calloc.free(outLen);
    }
  }
}
