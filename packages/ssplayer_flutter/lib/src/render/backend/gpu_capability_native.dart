import 'package:flutter_gpu/gpu.dart' as gpu;

bool? _cached;

/// Probes once whether a usable flutter_gpu (Impeller) context exists.
///
/// There is no boolean capability API. [gpu.gpuContext] is a lazy top-level that
/// runs `GpuContext._createDefault()` on first access and throws when there is
/// no Impeller context, so a try/catch around a trivial allocation is the only
/// reliable gate. The result is cached — the context does not appear/disappear
/// within a run.
bool isFlutterGpuAvailable() => _cached ??= _probe();

bool _probe() {
  try {
    final ctx = gpu.gpuContext;
    // A trivial allocation confirms the context is actually usable, not merely
    // constructed. Sixteen bytes: a HostBuffer would set aside 4 MB.
    ctx.createDeviceBuffer(gpu.StorageMode.hostVisible, 16);
    return true;
  } catch (_) {
    return false;
  }
}
