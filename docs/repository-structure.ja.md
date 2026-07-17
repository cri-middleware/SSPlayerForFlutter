# リポジトリ構成 / アーキテクチャ

> [README](../README.md) から退避した構成図です。全体設計は
> [architecture.ja.md](./architecture.ja.md)、実装者向けの規約・要注意点は
> [AGENTS.md](../AGENTS.md) を参照してください。

## アーキテクチャ（Brain / Body）

```
Layer 4  SpriteStudioView (RenderBox) / Flame / CustomPaint   ← 描画アダプタ
Layer 3  SpriteStudioPlayer (ChangeNotifier + Ticker)         ← ユーザー向け制御
Layer 2  SpriteStudioInternalPlayer (Resource/Context, SoA→Vertices, paint)  ← 描画特化エンジン(Pure Dart)
Layer 1  @Native C-API バインディング (dart:ffi, Native Assets)  ← ローダ無し
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
│   ├── build-runtime.{sh,ps1}            # Rust をソースビルド → 各パッケージの native/libs へ配置
│   ├── generate-ffigen-code.{sh,ps1}     # ffigen（Dart FFI）。C-API 変更時に手動実行 → commit
│   ├── generate-fbs-code.{sh,ps1}        # flatc（.ssab/FrameData の Dart アクセサ）。.fbs 変更時のみ
│   └── deploy-examples.sh         # overall.sspj → .ssab（Dart ssconvert 経由・Rust 不要）
├── packages/ssplayer_flutter/            # 【L2–4 描画】Flutter パッケージ（全プラットフォーム・ssruntime_dart 依存）
│   ├── lib/
│   │   ├── ssplayer_flutter.dart         # 公開 API（L2–4。L1 は ssruntime_dart から直接 import）
│   │   └── src/
│   │       ├── ssab/*.g.dart             # [flatc 生成・コミット] .ssab / .ssqb アセット形式アクセサ
│   │       ├── internal_player.dart      # Layer 2（描画エンジン・SoA ベイク・paint）
│   │       ├── texture_registry.dart     # Layer 2（hash→Image・blend マッピング）
│   │       ├── texture_loader.dart       # reference/embedded テクスチャ読込（§16C）
│   │       ├── ssab_info.dart            # アニメ／セルマップ名の列挙
│   │       ├── player.dart               # Layer 3
│   │       └── render/sprite_studio_view.dart  # Layer 4
│   ├── test/                             # スモーク＋実描画テスト（Native Assets 経由・env 変数不要）
│   └── pubspec.yaml                       # ※プラグインではない（native は ssruntime_dart が同梱）
├── packages/ssruntime_dart/              # 【Layer 1】ランタイム FFI バインディング（純 Dart・renderer 非依存）
│   ├── lib/ssruntime_dart.dart           # 公開 API（@Native トップレベル C-API 関数・ローダ無し）
│   ├── lib/framedata.dart                # ランタイム出力 FrameData の公開ライブラリ
│   ├── lib/src/ssruntime_bindings.g.dart # [ffigen 生成・@Native] 全 C-API（gitignore）
│   ├── lib/src/fbs/*.g.dart              # [flatc 生成・コミット] framedata / effect_draw_plan
│   ├── hook/build.dart                   # Native Assets: 素の dylib を CodeAsset として同梱
│   ├── native/                           # [生成物] include/ssruntime.h + libs/<platform>/（gitignore）
│   ├── ffigen.yaml
│   └── pubspec.yaml
├── packages/ssconverter_dart/            # 【変換ツール】ホスト用 .sspj→.ssab（純 Dart・desktop 専用）
│   ├── lib/ssconverter_dart.dart         # 公開 API（SsConverter）
│   ├── lib/src/                          # converter.dart・ffigen 生成物（gitignore）
│   ├── bin/ssconvert.dart                # dart run ssconverter_dart:ssconvert
│   ├── hook/build.dart                   # Native Assets: libssconverter を CodeAsset として同梱
│   ├── native/                           # [生成物] include/ssconverter.h + libs/<platform>/（gitignore）
│   ├── ffigen.yaml
│   └── pubspec.yaml
└── examples/overall/                     # overall.ssab 検証用の Flutter アプリ
```

## ネイティブ同梱の要点（Native Assets）

Flutter 側は **Native Assets（build hooks）** に一本化しました（Flutter 3.38 / Dart 3.10 以降で標準・
デフォルト有効）。`ssruntime_dart/hook/build.dart` が `native/libs/<platform>/<arch>/` の**素の dylib**を
`CodeAsset(package: 'ssruntime_dart', name: 'ssruntime', linkMode: DynamicLoadingBundled())` として登録し、
ffigen 生成バインディングの `@ffi.DefaultAsset('package:ssruntime_dart/ssruntime')` がそれを解決します。
`dart` / `flutter test` と `flutter build` が hook を自動実行するため、`DynamicLibrary.open` も
`SSRUNTIME_LIBRARY_PATH` も要りません。

macOS では `flutter build` が同梱 dylib を `Contents/Frameworks/ssruntime.framework` に再ラップし、
`flutter_assets/NativeAssetsManifest.json` に `package:ssruntime_dart/ssruntime` → `ssruntime.framework/ssruntime`
の写像を記録します（`flutter build macos` で `.app` への埋め込みを確認済み）。podspec の `vendored_frameworks`
や `macos/Frameworks/` シンボリックリンクは廃止し、`ssplayer_flutter` はプラグインではなくなりました。

なお SDK は universal リリースおよび他プレイヤー（Godot / Unity / RenPy）向けに、共有スクリプト
`scripts/make-macos-framework.sh` で versioned な `libssruntime.framework` を引き続き生成します——
**Flutter の「消費」だけ** Native Assets へ移行した形です。

ホストツール `libssconverter` は別パッケージ `ssconverter_dart` が同じ仕組み（`hook/build.dart`）で
同梱します（desktop 専用。詳細は [AGENTS.md](../AGENTS.md)）。
