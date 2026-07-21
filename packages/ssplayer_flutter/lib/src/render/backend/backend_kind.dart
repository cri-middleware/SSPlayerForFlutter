/// Selects which L2 render backend a [SpriteStudioView] drives.
///
/// The dart:ui Canvas path ([canvas]) is always available and is the only Web
/// path; [gpu] uses the optional flutter_gpu (Impeller) backend. [auto] probes
/// for flutter_gpu and uses it where available, otherwise falls back to Canvas.
///
/// Resolution to a concrete backend goes through `resolveBackend` in
/// `gpu_capability.dart` (which consults the capability probe). This enum is
/// kept dependency-free so it is importable on every platform, including Web.
enum SpriteStudioBackend {
  /// Use flutter_gpu when the capability probe reports it available, else Canvas.
  auto,

  /// Force the dart:ui Canvas backend (`Canvas.drawVertices`). Always available.
  canvas,

  /// Prefer the flutter_gpu backend; falls back to Canvas (never throws) when
  /// flutter_gpu is unavailable on this platform/run.
  gpu,
}
