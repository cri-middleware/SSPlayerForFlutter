import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';

/// Native-assets build hook: compiles the Flutter GPU shader bundle for the
/// optional flutter_gpu render backend.
///
/// This is a REGULAR-dependency hook (see pubspec.yaml): it runs at *consumer*
/// build time and pulls the shader sources referenced by
/// `ssplayer.shaderbundle.json` through `impellerc` into
/// `build/shaderbundles/ssplayer.shaderbundle`.
///
/// Delivery uses the **legacy** mode: the generated `.shaderbundle` is listed
/// under `flutter: assets:` in pubspec.yaml, so it bundles as a normal asset and
/// loads at runtime with
/// `gpu.ShaderLibrary.fromAsset('packages/ssplayer_flutter/'
/// 'build/shaderbundles/ssplayer.shaderbundle')`.
///
/// This is a *separate* hook from `ssruntime_dart`'s code-asset hook (which
/// delivers `libssruntime`); each package runs its own `hook/build.dart` and
/// they do not interfere. This one contributes no code asset.
///
/// The bundle is only ever *used* on Impeller (mobile/desktop) behind the
/// capability probe; web tree-shakes the backend out. Building the bundle on the
/// host is harmless there (`dataAssetsIfAvailable` falls back to a plain file
/// output when data assets are not requested).
void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'ssplayer.shaderbundle.json',
      includeDirectories: [input.packageRoot.resolve('shaders/gpu/')],
      assetMode: ShaderBundleAssetMode.legacyOnly,
    );
  });
}
