/// Web stub for the flutter_gpu capability probe.
///
/// flutter_gpu needs dart:ffi / Impeller, neither of which exists on the Web, so
/// the backend is never available there and the Canvas path is always used. This
/// file is selected by the `dart.library.js_interop` conditional import in
/// `gpu_capability.dart`, keeping `package:flutter_gpu` out of Web builds.
bool isFlutterGpuAvailable() => false;
