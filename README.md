# SSPlayerForFlutter

OPTPiX **SpriteStudio 7** の Flutter 向けプレイヤー（`ssplayer_flutter`）。

[SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) の Rust ランタイム
（**Brain** = `libssruntime`）を `dart:ffi` 経由で駆動し、`.ssab` を読み込んで
`Canvas.drawVertices` で描画する **Body**（描画・リソース・座標変換）を実装します。
設計は「SpriteStudio-SDK v7 Flutter Player アーキテクチャ設計書」
および SDK 公式の移植ガイド（`SpriteStudio-SDK/libs/ssruntime/docs/`）に準拠します。

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

> 実装者向けの規約・要注意点（FFI 寿命、macOS framework 同梱、UV ピクセル座標、
> `updateFlag` の罠 など）は [AGENTS.md](./AGENTS.md) に集約しています。

## リポジトリ構成

```
SSPlayerForFlutter/
├── SpriteStudio-SDK/                     # [submodule] Brain (libssruntime / libssconverter / .fbs)
├── SDK_VERSION.txt                       # download-sdk が参照するリリースタグ
├── scripts/
│   ├── build-runtime.{sh,ps1}            # Rust をソースビルド → native/libs/<platform>/<arch>/ へ配置
│   ├── generate-runtime-code.{sh,ps1}    # cbindgen(C ヘッダ) + flatc(Dart) + ffigen
│   ├── download-sdk.{sh,ps1}             # GitHub Releases のプリビルドを DL/展開（SDK_VERSION.txt 準拠）
│   └── prepare-example-assets.sh         # overall.sspj → .ssab を example/assets へ
├── packages/ssplayer_flutter/            # 配布する pub パッケージ（FFI plugin）
│   ├── lib/
│   │   ├── ssplayer_flutter.dart         # 公開 API
│   │   └── src/
│   │       ├── bindings/                 # Layer 1（ffigen 生成 + ローダ）
│   │       ├── ssab/*.g.dart             # [flatc 生成] .ssab / FrameData / EffectDrawPlan
│   │       ├── internal_player.dart      # Layer 2（描画エンジン・SoA ベイク・paint）
│   │       ├── texture_registry.dart     # Layer 2（hash→Image・blend マッピング）
│   │       ├── texture_loader.dart       # reference/embedded テクスチャ読込（§16C）
│   │       ├── ssab_info.dart            # アニメ／セルマップ名の列挙
│   │       ├── player.dart               # Layer 3
│   │       └── render/sprite_studio_view.dart  # Layer 4
│   ├── test/                             # スモーク＋実描画テスト（要 SSRUNTIME_LIBRARY_PATH）
│   ├── native/                           # [生成物] include/ + libs/<platform>/<arch>/（gitignore）
│   ├── macos/Frameworks/                 # [生成物] libssruntime.framework（gitignore）
│   ├── {android,ios,macos,linux,windows}/  # 各プラットフォームのビルド接続
│   ├── ffigen.yaml
│   └── pubspec.yaml
└── example/                              # overall.ssab 検証用の Flutter アプリ
```

## セットアップ

前提: Rust ツールチェーン（`rustup`）、`flatc`、`cbindgen`（`cargo install cbindgen`）、
Flutter 3.19+ / Dart 3、CocoaPods（macOS/iOS ビルド時。`brew install cocoapods`）。

```bash
# 1. サブモジュール取得
git submodule update --init --recursive

# 2. ネイティブ Brain をソースビルド（ホスト向け。dylib/so/dll を native/libs へ配置）
scripts/build-runtime.sh                 # 例: build-runtime.sh platform=macos build=release
#    ※ プリビルドを使う場合: scripts/download-sdk.sh

# 3. C ヘッダ + Dart FlatBuffers + ffigen バインディングを生成
scripts/generate-runtime-code.sh

# 4. example 用アセット（.ssab）を用意
scripts/prepare-example-assets.sh

# 5. example を起動
cd example && flutter run
```

`build-runtime` / `generate-runtime-code` / `download-sdk` は Windows では `.ps1` を使います。
クロスビルド（android/ios/web）は `SpriteStudio-SDK/scripts/release-*` に委譲します。

### macOS デスクトップで動かす（検証済み）

```bash
brew install cocoapods                 # macOS/iOS プラグイン統合に必須
scripts/build-runtime.sh               # libssruntime.framework を生成
cd example && flutter create --platforms=macos .   # 初回のみ macOS ランナー生成
flutter run -d macos                   # -> [ssplayer] OK — playing "anime_1"
```

**ネイティブ同梱の要点**: macOS では動的ライブラリを `vendored_libraries` で渡しても
アプリに埋め込まれません。`build-runtime.sh` は `libssruntime.dylib` を **`libssruntime.framework`**
（`@rpath` id・versioned 構造）にラップし、CocoaPods が globできるよう **プラグインの
`macos/Frameworks/` 配下**へ配置します。podspec は `vendored_frameworks` でこれを埋め込み＋署名し、
`DynamicLibrary.open('libssruntime.framework/libssruntime')` が `@rpath` で解決します。

## 使い方（Dart API）

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final bytes = (await rootBundle.load('assets/overall/Basic.ssab'))
        .buffer.asUint8List();
    final animName = SsAnimeInfo(bytes).animationNames.first;
    // reference テクスチャ（兄弟 PNG）は baseAssetDir を渡す。embedded は自動解決。
    await _player.load(bytes, animationName: animName, baseAssetDir: 'assets/overall');
    _player..loop = -1..play();
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) =>
      SpriteStudioView(player: _player, width: 400, height: 400);
}
```

## テスト

ネイティブ Brain を先にビルドし、`SSRUNTIME_LIBRARY_PATH` にホスト dylib を指定します。

```bash
cd packages/ssplayer_flutter
SSRUNTIME_LIBRARY_PATH="$PWD/native/libs/macos/libssruntime.dylib" flutter test
```

- `test/internal_player_smoke_test.dart` — FFI パイプライン（load→update→FrameData→SoA）。
- `test/render_test.dart` — 実描画（テクスチャ付き非空フレームのラスタライズ）。

## 実装ロードマップ（公式検証方針: `tests/overall/overall.sspj` がエディタと一致すれば合格）

- **Phase 1** — Basic（位置/回転/スケール/α の親子継承）→ BlendMode。`SpriteStudioView` で 1 体表示。
- **Phase 2** — PartsColor / Mask / Mesh / Instance / Effect、Flame 対応、配布整備、Web。

## 現状（このコミット時点）

**足場 ＋ Layer 1〜4 ＋ Phase 1 Basic 実描画**（フラグシップ SSPlayerForGodot の
`ss_internal_player.cpp` レシピに準拠）。

| 項目 | 状態 |
|------|------|
| `scripts/*`（build / generate / download / assets）| ✅ 作成・ホスト(macOS)で実行検証済み |
| ネイティブビルド（`libssruntime.dylib` 生成・配置）| ✅ 検証済み |
| C ヘッダ生成（cbindgen）・Dart FlatBuffers 生成（flatc）| ✅ 検証済み |
| Layer 1 `SsRuntimeBindings`（ffigen 生成・全 C-API 111 メソッド）| ✅ |
| Layer 2 `SpriteStudioInternalPlayer`（ライフサイクル / SoA / update）| ✅ |
| **Phase 1 Basic 描画**（Normal バッチ・親子継承・α・テクスチャ・BlendMode）| ✅ 実装（実機検証は下記） |
| Layer 3/4（`SpriteStudioPlayer` / `SpriteStudioView`）| ✅ |
| テクスチャ（reference＝兄弟PNG / embedded 両対応、§16C ルーティング）| ✅ |
| サブフレーム補間（既定 ON）| ✅ |
| **実機検証**（Flutter 3.44 / `flutter analyze` 0 件、`flutter test` 2件 PASS）| ✅ |
| ↳ FFI パイプライン（load→update→FrameData→SoA）スモークテスト | ✅ PASS |
| ↳ 実描画テスト（テクスチャ付き非空フレームをラスタライズ）| ✅ PASS（目視でも overall/Basic がエディタ相当に描画） |
| **macOS デスクトップ example 起動**（`flutter run -d macos`、framework ロード＆再生）| ✅ `[ssplayer] OK — playing "anime_1"` |
| PartColor / Mask / Mesh / Effect / Instance、BoxFit スケール | ⏳ TODO（Phase 1 後半〜2）|

**Phase 1 Basic 描画の実装要点**（Godot flagship 準拠。詳細は `docs/30_core/30_render_loop.ja.md`）:
- RenderMode=Direct（既定）、`coordinate_system=1`（Y-Down）。原点/単位は既定のまま。
- SoA: world(parts×16 列優先)、local_vertices(×10)、**local_uvs(×10・テクスチャピクセル座標)**。
- 頂点ベイク: `x' = m0·x + m4·y + m12`, `y' = m1·x + m5·y + m13`。
- 4 隅クアッド `{0,1,2, 1,3,2}`。UV はピクセルのまま `ImageShader`(identity) へ（Flutterは正規化不要）。
- α: `PartState.alpha` を白×α 頂点カラー＋`drawVertices(v, modulate, paint)` で乗算。
- BlendMode: Mix→srcOver / Add→plus / Mul→multiply / Sub→(近似) / 他→srcOver。
- テクスチャキー = `cellmap.name_hash` = `DrawBatch.texture_hash`（再ハッシュしない）。

> `ssruntime_bindings.g.dart`（Layer 1）は `scripts/generate-runtime-code.sh` の
> ffigen で生成された全 C-API バインディング（111 メソッド）です。C の
> `unsigned char*` / `uintptr_t*` は `Pointer<UnsignedChar>` / `Pointer<UintPtr>`
> になるため、Layer 2 は境界で `.cast()` して受けています。

詳細な API 対応表は設計書と `SpriteStudio-SDK/libs/ssruntime/docs/` を参照してください。

## ライセンス

`SpriteStudio-SDK` のライセンスに従います（`SpriteStudio-SDK/LICENSE.md`）。
