import 'render_backend.dart';

/// Web stub: flutter_gpu needs dart:ffi / Impeller, neither of which exists on
/// the Web. Never reached (the capability probe is false on Web, so the gpu
/// backend is never selected); present only so the Web compile does not pull in
/// `package:flutter_gpu`.
RenderBackend createFlutterGpuBackend() =>
    throw UnsupportedError('flutter_gpu is not available on this platform');
