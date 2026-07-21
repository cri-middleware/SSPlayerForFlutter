import 'render_backend.dart';
// Native default (imports package:flutter_gpu); Web swaps to a stub that never
// touches flutter_gpu. The conditional keeps dart:ffi out of Web builds.
import 'flutter_gpu_backend.dart'
    if (dart.library.js_interop) 'gpu_backend_unsupported.dart' as impl;

/// Constructs the flutter_gpu render backend.
///
/// Only ever called when `resolveBackend` selected `gpu`, which requires the
/// capability probe to pass — and the probe is always false on Web — so the Web
/// stub's `UnsupportedError` is unreachable in practice; it exists only to keep
/// `package:flutter_gpu` (and its `dart:ffi`) out of the Web compile.
RenderBackend createFlutterGpuBackend() => impl.createFlutterGpuBackend();
