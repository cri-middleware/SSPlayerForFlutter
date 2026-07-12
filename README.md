# SpriteStudioPlayer for Flutter

**OPTPiX SpriteStudio 7 のアニメーション（`.ssab`）を Flutter でそのまま再生。**

[SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) の Rust ランタイム
（**Brain** = `libssruntime`）を `dart:ffi` で駆動し、`.ssab` を読み込んで `Canvas.drawVertices`
で描画する **Body**（`ssplayer_flutter`）を提供します。ボーン・メッシュ変形・エフェクトを専用
エディタで作り、完成アニメを Flutter アプリに載せるだけ。

## ✨ Why SpriteStudio × Flutter?

- **絵を動かす。** 呼吸・まばたき、髪や服の揺れ、派手な斬撃・魔法エフェクト — モーションは専用
  エディタ（SpriteStudio 7）で視覚的に作り、プレイヤーは再生するだけ。手書きのアニメーション不要。
- **動画より軽い代替。** 固定 fps の `.webm`/`.mp4` に頼る場面を、実行時に自由スケール・シームレス
  ループ・ゲームに反応する軽量ネイティブ再生で置き換えます。
- **フレームレート非依存の滑らかさ。** サブフレーム補間で表示タイミングちょうどに各フレームを描画。
- **Widget として自然に合成。** `SpriteStudioView` は普通の `RenderBox` ウィジェット。

## 📚 ドキュメント

- [アーキテクチャ設計（`docs/architecture.ja.md`）](./docs/architecture.ja.md) — 設計意図の一次情報
- [リポジトリ構成・アーキテクチャ図（`docs/repository-structure.ja.md`）](./docs/repository-structure.ja.md)
- [実装ロードマップ・現状（`docs/status.ja.md`）](./docs/status.ja.md)
- [実装者向け規約・要注意点（`AGENTS.md`）](./AGENTS.md) — FFI 寿命 / macOS framework 同梱 / UV ピクセル座標 / `updateFlag` の罠 ほか

### 目的別ガイド（読む範囲は目的まででOK）

| あなたは… | 目的 | 読む範囲 |
|---|---|---|
| **利用者** | アプリでアニメを動かすだけ | 下の **1. Quick Start** |
| **カスタマー** | 自分の環境でビルド／アセットを差し替え | **1 + 2** 章 |
| **SDK / Player 開発者** | コア（Rust ランタイム / Player）を拡張・貢献 | 全章 + [AGENTS.md](./AGENTS.md) + [docs/](./docs/) |

## 📦 パッケージ

このリポジトリは 2 つのパッケージを含みます。

| 目的 | パッケージ | 種別 |
|---|---|---|
| アニメ再生（ランタイム描画） | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter プラグイン（全プラットフォーム） |
| `.sspj` → `.ssab` 変換（CLI / ライブラリ） | [`ssconverter_dart`](./packages/ssconverter_dart) | 純 Dart（デスクトップ専用のホストツール） |

---

## 🚀 1. Quick Start（利用者）

アプリに組み込むときの最小コードです。`.ssab` は事前に用意します（[2 章](#-2-リポジトリで試すカスタマー)の `ssconvert` で生成）。

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

> ⚠️ FFI プラグインのため、ネイティブ Brain（`libssruntime`）が必要です。当面はこのリポジトリを
> git 依存で参照し、`scripts/download-sdk.*`（Rust 不要）または `scripts/build-runtime.*` で
> ネイティブを配置してください（[2 章](#-2-リポジトリで試すカスタマー)）。pub.dev 公開は今後。

## 🛠 2. リポジトリで試す（カスタマー）

サンプル起動と、自分の `.sspj` の変換まで。**Rust ツールチェーンは不要**（プリビルドを取得）。

```bash
# クローン + サブモジュール
git clone https://github.com/cri-middleware/SSPlayerForFlutter.git
cd SSPlayerForFlutter
git submodule update --init --recursive

# ネイティブ Brain / Converter を取得（プリビルド。Rust 不要）
scripts/download-sdk.sh              # ※ソースからビルドする場合は 3 章の build-runtime.sh

# example 用アセット（.ssab）を Dart の ssconvert で生成（Rust 不要）
scripts/prepare-example-assets.sh

# example を起動
cd example && flutter run
```

Windows は各スクリプトの `.ps1` を使います。

### 自分の `.sspj` を変換する

`ssconverter_dart` の CLI で `.sspj` → `.ssab`（`-e` で自己完結の embedded 出力。配布向け）。

```bash
dart run ssconverter_dart:ssconvert    -o out/     path/to/project.sspj  # 参照テクスチャ形式
dart run ssconverter_dart:ssconvert -e -o out_emb/ path/to/project.sspj  # embedded（配布向け）
```

## ⚙️ 3. フル開発環境（SDK / Player 開発者）

コア（Rust ランタイム / Player）を開発する場合。

**前提**: Rust（`rustup`）、Flutter 3.19+ / Dart 3、CocoaPods（macOS/iOS。`brew install cocoapods`）。
`flatc` は `.fbs` を再生成するときだけ。cbindgen は SDK の `build.rs` が build-dependency として使うため個別導入不要。

```bash
git submodule update --init --recursive

# ネイティブをソースからビルド（C ヘッダのコピー＋ffigen 生成まで自動）
scripts/build-runtime.sh             # 例: build-runtime.sh platform=macos build=release

# アセット生成 → example 起動
scripts/prepare-example-assets.sh
cd example && flutter run
#   （初回の macOS ランナー生成: cd example && flutter create --platforms=macos . ）
```

- **コード生成**: `build-runtime` / `download-sdk` の末尾で ffigen（`generate-ffigen-code.*`）が
  `packages/*/ffigen*.yaml` を走査して自動実行。`.fbs` スキーマを変えたときだけ
  `generate-fbs-code.*`（flatc）を手動実行。クロスビルド（android/ios/web）は
  `SpriteStudio-SDK/scripts/release-*` に委譲します。
- **テスト**（`packages/ssplayer_flutter/`）:
  ```bash
  SSRUNTIME_LIBRARY_PATH="$PWD/native/libs/macos/libssruntime.framework/libssruntime" flutter test
  ```
  `ssconverter_dart` は `dart test`（`SsConverter.openForHost()` がパッケージ内の dylib を解決）。
- **規約・設計**: [AGENTS.md](./AGENTS.md)（実装規約・要注意点） /
  [docs/architecture.ja.md](./docs/architecture.ja.md)（設計） /
  [docs/repository-structure.ja.md](./docs/repository-structure.ja.md)（構成図・macOS 同梱の要点） /
  [docs/status.ja.md](./docs/status.ja.md)（進捗）。

## 🔗 関連リポジトリ

- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — Rust ランタイム / コンバータ / `.fbs` スキーマ（Brain）
- 兄弟プレイヤー: [Godot](https://github.com/cri-middleware/SSPlayerForGodot) ／
  [Unity](https://github.com/cri-middleware/SSPlayerForUnity) ／
  [Web](https://github.com/cri-middleware/SSPlayerForWeb) ／
  [Ren'Py](https://github.com/cri-middleware/SSPlayerForRenPy)

## 📄 ライセンス

`SpriteStudio-SDK` のライセンスに従います（[`SpriteStudio-SDK/LICENSE.md`](./SpriteStudio-SDK/LICENSE.md)）。
