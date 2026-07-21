import 'backend_kind.dart';
// Native default; Web swaps to the stub. flutter_gpu needs dart:ffi/Impeller,
// so the native impl (which imports package:flutter_gpu) must never be compiled
// into a Web build — the conditional import guarantees that at compile time.
import 'gpu_capability_native.dart'
    if (dart.library.js_interop) 'gpu_capability_web.dart' as impl;

/// Whether the flutter_gpu (Impeller) backend can be used on this platform/run.
///
/// Cached after the first probe. Always false on Web and wherever Impeller is
/// unavailable (Impeller disabled, or a device without a supported GPU backend).
bool isFlutterGpuAvailable() => impl.isFlutterGpuAvailable();

/// Resolves a requested [SpriteStudioBackend] to the concrete backend to use.
///
/// [SpriteStudioBackend.auto] and [SpriteStudioBackend.gpu] both resolve to
/// [SpriteStudioBackend.gpu] only when [isFlutterGpuAvailable]; otherwise they
/// fall back to [SpriteStudioBackend.canvas]. A forced-`gpu` app therefore still
/// renders (on Canvas) on unsupported targets rather than throwing.
SpriteStudioBackend resolveBackend(SpriteStudioBackend requested) {
  switch (requested) {
    case SpriteStudioBackend.canvas:
      return SpriteStudioBackend.canvas;
    case SpriteStudioBackend.gpu:
    case SpriteStudioBackend.auto:
      return isFlutterGpuAvailable()
          ? SpriteStudioBackend.gpu
          : SpriteStudioBackend.canvas;
  }
}
