import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Native-assets build hook: bundles the prebuilt `libssruntime` (placed under
/// `native/libs/` by scripts/build-runtime.sh — or, later, fetched by
/// download-sdk) as a **code asset** so `@Native` bindings resolve it without a
/// `DynamicLibrary.open` and without any Rust toolchain on the consumer side.
///
/// The asset id is `package:ssruntime_dart/ssruntime` (package + name); the
/// generated `@ffi.Native` bindings' `DefaultAsset` must match.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final os = code.targetOS;
    // build-runtime.sh spells the arch dir as x86_64 / aarch64 (linux) and
    // x86_64 / arm64 (windows); map the code_assets Architecture to that.
    final arch = switch (code.targetArchitecture) {
      Architecture.x64 => 'x86_64',
      Architecture.arm64 => os == OS.linux ? 'aarch64' : 'arm64',
      final a => a.name,
    };
    final rel = switch (os) {
      OS.macOS => 'native/libs/macos/libssruntime.dylib',
      OS.linux => 'native/libs/linux/$arch/libssruntime.so',
      OS.windows => 'native/libs/windows/$arch/ssruntime.dll',
      _ => throw UnsupportedError(
          'ssruntime_dart: no prebuilt libssruntime for $os '
          '(iOS/Android native-assets embedding is a follow-up)'),
    };

    final file = input.packageRoot.resolve(rel);
    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: 'ssruntime',
      linkMode: DynamicLoadingBundled(),
      file: file,
    ));
    // Rebuild the code asset when the prebuilt library changes.
    output.dependencies.add(file);
  });
}
