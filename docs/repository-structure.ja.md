# リポジトリ構成 / アーキテクチャ

> [README](../README.md) から退避した構成図です。全体設計は
> [architecture.ja.md](./architecture.ja.md)、実装者向けの規約・要注意点は
> [AGENTS.md](../AGENTS.md) を参照してください。

## アーキテクチャ（Brain / Body）

```
Layer 4  SpriteStudioView (RenderBox) / Flame / CustomPaint   ← 描画アダプタ
Layer 3  SpriteStudioPlayer (ChangeNotifier + Ticker)         ← ユーザー向け制御
Layer 2  SpriteStudioInternalPlayer (Resource/Context, SoA→Vertices, paint)  ← 描画特化エンジン(Pure Dart)
Layer 1  SsRuntimeBindings (dart:ffi) + SsRuntime (loader)    ← C-API バインディング
--------------------------------------------------------------------------
Brain    libssruntime (Rust, no_std, SIMD)                    ← 計算・DrawBatch 生成
```

- **Brain（Rust）** … 時間管理・補間・属性計算・サブフレーム管理・`DrawBatch` プラン生成。ステートレスな計算機。
- **Body（Flutter）** … 本リポジトリ。`.ssab` メタデータの FlatBuffers パース、リソース検証、
  テクスチャ／音声ロード、ワールド座標変換（`M·v` ベイク）、描画実行、イベント処理。

## リポジトリ構成

```
SSPlayerForFlutter/
├── SpriteStudio-SDK/                     # [submodule] Brain (libssruntime / libssconverter / .fbs)
├── scripts/
│   ├── SDK_VERSION.txt                   # download-sdk が参照するリリースタグ
│   ├── build-runtime.{sh,ps1}            # Rust をソースビルド → 各パッケージの native/libs へ配置
│   ├── generate-ffigen-code.{sh,ps1}     # ffigen（Dart FFI）。build-runtime/download-sdk が自動実行
│   ├── generate-fbs-code.{sh,ps1}        # flatc（.ssab/FrameData の Dart アクセサ）。.fbs 変更時のみ
│   ├── download-sdk.{sh,ps1}             # GitHub Releases のプリビルドを DL/展開（SDK_VERSION.txt 準拠）
│   └── prepare-example-assets.sh         # overall.sspj → .ssab（Dart ssconvert 経由・Rust 不要）
├── packages/ssplayer_flutter/            # 【ランタイム描画】配布 pub パッケージ（FFI plugin・全プラットフォーム）
│   ├── lib/
│   │   ├── ssplayer_flutter.dart         # 公開 API
│   │   └── src/
│   │       ├── bindings/                 # Layer 1（ffigen 生成 *.g.dart=gitignore + 手書きローダ）
│   │       ├── ssab/*.g.dart             # [flatc 生成] .ssab / FrameData / EffectDrawPlan
│   │       ├── internal_player.dart      # Layer 2（描画エンジン・SoA ベイク・paint）
│   │       ├── texture_registry.dart     # Layer 2（hash→Image・blend マッピング）
│   │       ├── texture_loader.dart       # reference/embedded テクスチャ読込（§16C）
│   │       ├── ssab_info.dart            # アニメ／セルマップ名の列挙
│   │       ├── player.dart               # Layer 3
│   │       └── render/sprite_studio_view.dart  # Layer 4
│   ├── test/                             # スモーク＋実描画テスト（要 SSRUNTIME_LIBRARY_PATH）
│   ├── native/                           # [生成物] include/ssruntime.h + libs/<platform>/<arch>/（gitignore）
│   ├── macos/Frameworks/                 # [生成物] native/libs/macos/libssruntime.framework へのシンボリックリンク（gitignore）
│   ├── {android,ios,macos,linux,windows}/  # 各プラットフォームのビルド接続
│   ├── ffigen.yaml
│   └── pubspec.yaml
├── packages/ssconverter_dart/            # 【変換ツール】ホスト用 .sspj→.ssab（純 Dart・desktop 専用）
│   ├── lib/ssconverter_dart.dart         # 公開 API（SsConverter / SsConverterLibrary）
│   ├── lib/src/                          # converter.dart・ローダ・ffigen 生成物（gitignore）
│   ├── bin/ssconvert.dart                # dart run ssconverter_dart:ssconvert
│   ├── native/                           # [生成物] include/ssconverter.h + libs/<platform>/（gitignore）
│   ├── ffigen.yaml
│   └── pubspec.yaml
└── example/                              # overall.ssab 検証用の Flutter アプリ
```

## ネイティブ同梱の要点（macOS）

macOS では動的ライブラリを `vendored_libraries` で渡してもアプリに埋め込まれません。Brain は
versioned な **`libssruntime.framework`**（`@rpath` id）で配布します。framework の生成は SDK の共有
スクリプト `scripts/make-macos-framework.sh`（Unity の `make-macos-bundle.sh` に相当する single
source of truth）が担い、リリース（universal）では `release-macos.sh` がそれを呼んで生成 →
`build-runtime.sh` が `native/libs/macos/` へコピー、ホスト（debug）では `build-runtime.sh` が同じ
helper を呼んで cargo の dylib をラップします。framework の実体は `native/libs/macos/` の 1 つだけです。

CocoaPods は podspec ディレクトリ配下の vendored framework しか *埋め込まない*（`../native/...` を
指定しても記録はされるが `.app` には同梱されない）ため、`build-runtime.sh` は
`macos/Frameworks/libssruntime.framework` を `../../native/libs/macos/...` への **シンボリックリンク**
として張り、podspec は `Frameworks/libssruntime.framework` を `vendored_frameworks` で埋め込み＋署名
します（`install_framework` が embed 時にリンクを解決）。実行時は
`DynamicLibrary.open('libssruntime.framework/libssruntime')` が `@rpath` で解決します。

ホストツール `libssconverter` は別パッケージ `ssconverter_dart` の `native/libs/<platform>/` に
配置されます（アプリには同梱しない bare dylib。詳細は [AGENTS.md](../AGENTS.md)）。
