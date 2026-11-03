# 🦀 ネイティブランタイム

Rust ランタイム（`libssruntime`、"Brain"）は Dart の **Native Assets** でアプリに届きます。
[`ssruntime_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssruntime_dart)
のビルドフック（`hook/build.dart`）が dylib をコードアセットとして同梱し、`@Native` バインディングがアセット ID で解決します。CocoaPods プラグインも vendored framework も `DynamicLibrary` のパスも不要 —— ほとんどのアプリでは完全に自動なので、このページは通常読む必要はありません。

## ライブラリの解決順

`hook/build.dart` は次の優先順でネイティブライブラリを選びます。

1. **利用者オーバーライド** —— アプリの `pubspec.yaml` の
   `hooks.user_defines.ssruntime_dart.libssruntime`。最優先。自前 dylib を持ち込めます。
2. **ローカルチェックアウト** —— `packages/ssruntime_dart/native/libs/<platform>/[<arch>]`（`scripts/build-runtime.*` が配置。ソースビルド用）。
3. **ダウンロード** —— ピン留めした SDK リリースのアセットをローカルにキャッシュ。Rust ツールチェーンのない利用者向けのゼロ設定パスです。

`ssconverter_dart` はホストの `libssconverter` を同じ仕組みで同梱します（デスクトップ専用）。

## 自前ビルドを差し込む

パッチ済みランタイム、デバッグビルド、未公開スライスなどを使う場合は、**アプリの** `pubspec.yaml`
にオーバーライドを追加します。

```yaml
hooks:
  user_defines:
    ssruntime_dart:
      libssruntime: /abs/path/to/libssruntime.dylib
```

再ビルドするとフックがダウンロードより自前ファイルを優先します。これはアプリ単位の設定で、リポジトリ全体を変えるものではありません。

## プラットフォーム同梱

同じフックがすべてのネイティブターゲットを賄います —— platform/arch ごとに呼ばれ、一致するライブラリを選びます。web にはフックが無く、Brain は wasm アセットとして読み込まれます（[ビルドガイド](build.md)）。

| プラットフォーム | フックが解決するもの |
|---|---|
| macOS | dylib 1 つ。Flutter が `.app` 内で `ssruntime.framework` に再ラップ |
| iOS | スライスごとの素の dylib（デバイス `iphoneos` / シミュレータ `iphonesimulator`）。xcframework では**ない** |
| Android | NDK ABI ごとの素の `.so`（`arm64-v8a`・`armeabi-v7a`・`x86_64`） |
| Windows / Linux | アーキテクチャごとの `.dll` / `.so` 1 つ（x86_64、arm64 / aarch64） |

`pod install` のプラグイン統合も、スライスの手作業も不要 —— Flutter が選ばれたライブラリを自動で埋め込み・署名します。

## 純 Dart から使う（ヘッドレス）

`ssruntime_dart` は **純 Dart** パッケージ（Flutter 非依存）なので、Layer 1 の FFI バインディングをヘッドレスで使えます —— CLI ツール、テスト、独自の描画（独自の `flutter_gpu` パイプラインや canvas）など。
Flutter の描画スタック（L2–L4: SoA → `ui.Vertices` bake、`paint`、ウィジェット）は `ssplayer_flutter`
にあり、ランタイムとその FlatBuffers フレームデータはそれに依存しません。

レイヤ構成は[プレイヤーの構成](architecture.md)を参照してください。
