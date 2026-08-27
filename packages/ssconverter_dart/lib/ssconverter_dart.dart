/// Host-side SpriteStudio converter for the Flutter ecosystem.
///
/// A pure-Dart `dart:ffi` wrapper (+ `ssconvert` CLI) over the SpriteStudio-SDK
/// `libssconverter`, turning `.sspj` projects into optimized `.ssab` binaries.
/// **Desktop only** (Windows / macOS / Linux) — the converter is a host tool:
/// convert on the host, push the `.ssab` to devices, and reload it via the
/// `ssplayer_flutter` runtime. `embedded` produces a single self-contained
/// `.ssab` (recommended for device / OTA distribution).
library;

export 'src/converter.dart'
    show SsConverter, SsConverterException, CConverterError;
