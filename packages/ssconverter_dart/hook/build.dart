import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Native-assets build hook: bundles the prebuilt `libssconverter` (placed under
/// `native/libs/` by scripts/build-runtime.sh — or fetched by download-sdk) as a
/// **code asset** so the `@Native` bindings resolve it without a
/// `DynamicLibrary.open`. Desktop only (the converter is a host tool).
///
/// The asset id is `package:ssconverter_dart/ssconverter`; the generated
/// `@ffi.Native` bindings' `DefaultAsset` must match.
void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final os = code.targetOS;
    final arch = switch (code.targetArchitecture) {
      Architecture.x64 => 'x86_64',
      Architecture.arm64 => os == OS.linux ? 'aarch64' : 'arm64',
      final a => a.name,
    };
    final rel = switch (os) {
      OS.macOS => 'native/libs/macos/libssconverter.dylib',
      OS.linux => 'native/libs/linux/$arch/libssconverter.so',
      OS.windows => 'native/libs/windows/$arch/ssconverter.dll',
      _ => throw UnsupportedError(
          'ssconverter_dart is desktop-only (Windows/macOS/Linux); got $os'),
    };

    final file = input.packageRoot.resolve(rel);
    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: 'ssconverter',
      linkMode: DynamicLoadingBundled(),
      file: file,
    ));
    output.dependencies.add(file);
  });
}
