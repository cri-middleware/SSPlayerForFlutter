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
- [実装者向け規約・要注意点（`AGENTS.md`）](./AGENTS.md) — FFI 寿命 / ネイティブ同梱（Native Assets）/ UV ピクセル座標 / `updateFlag` の罠 ほか

### 目的別ガイド（読む範囲は目的まででOK）

| あなたは… | 目的 | 読む範囲 |
|---|---|---|
| **利用者** | アプリでアニメを動かすだけ | 下の **1. Quick Start** |
| **カスタマー** | 自分の環境でビルド／アセットを差し替え | **1 + 2** 章 |
| **SDK / Player 開発者** | コア（Rust ランタイム / Player）を拡張・貢献 | 全章 + [AGENTS.md](./AGENTS.md) + [docs/](./docs/) |

## 📦 パッケージ

このリポジトリは 3 つのパッケージを含みます。

| 目的 | パッケージ | 種別 |
|---|---|---|
| アニメ再生（ランタイム描画） | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter パッケージ（全プラットフォーム・`ssruntime_dart` に依存） |
| ランタイム FFI バインディング（Layer 1） | [`ssruntime_dart`](./packages/ssruntime_dart) | 純 Dart（renderer 非依存コア） |
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

> ⚠️ ネイティブ Brain（`libssruntime`）が必要です。これは依存先 `ssruntime_dart` の
> **Native Assets**（`hook/build.dart`）がアプリに自動同梱します（プラグイン／framework 配線は不要）。
> `hook/build.dart` はピン留めした SDK リリースからプリビルドを**自動ダウンロード**するので
> Rust ツールチェーンは不要です（ソースからビルドする場合のみ `scripts/build-runtime.*`）。当面は
> このリポジトリを git 依存で参照してください（[2 章](#-2-リポジトリで試すカスタマー)）。pub.dev 公開は今後。

## 🛠 2. リポジトリで試す（カスタマー）

サンプル起動と、自分の `.sspj` の変換まで。**Rust ツールチェーンは不要** — ネイティブ
（`libssruntime` / `libssconverter`）は各パッケージの `hook/build.dart` が、ピン留めした
SDK リリースからプリビルドを自動ダウンロードして同梱します（手動の取得手順はありません）。

```bash
# クローン + サブモジュール
git clone https://github.com/cri-middleware/SSPlayerForFlutter.git
cd SSPlayerForFlutter
git submodule update --init --recursive

# example 用アセット（.ssab）を Dart の ssconvert で生成
#   （libssconverter は hook/build.dart が自動DL。Rust 不要）
scripts/prepare-example-assets.sh

# example を起動（libssruntime は hook/build.dart が自動DL）
cd example && flutter run
```

> ℹ️ プリビルドの自動DLは、SDK リリースが Flutter 向けアセット（`lib{ssruntime,ssconverter}-<os>[-<arch>]`）
> を公開してから有効になります。それまでは 3 章の `scripts/build-runtime.*`（Rust 必要）で
> ネイティブを用意してください。自前ビルドの dylib を差し込む場合は各アプリの `pubspec.yaml` の
> `hooks.user_defines.<pkg>.lib<name>` で指定できます。

Windows は各スクリプトの `.ps1` を使います。

### 自分の `.sspj` を変換する

`ssconverter_dart` の CLI で `.sspj` → `.ssab`（`-e` で自己完結の embedded 出力。配布向け）。

```bash
dart run ssconverter_dart:ssconvert    -o out/     path/to/project.sspj  # 参照テクスチャ形式
dart run ssconverter_dart:ssconvert -e -o out_emb/ path/to/project.sspj  # embedded（配布向け）
```

## ⚙️ 3. フル開発環境（SDK / Player 開発者）

コア（Rust ランタイム / Player）を開発する場合。

**前提**: Rust（`rustup`）、Flutter 3.38+ / Dart 3.10+（Native Assets が標準。ネイティブ Brain 同梱に
CocoaPods／vendored framework は不要）。`flatc` は `.fbs` を再生成するときだけ。cbindgen は SDK の
`build.rs` が build-dependency として使うため個別導入不要。

```bash
git submodule update --init --recursive

# ネイティブをソースからビルド（C ヘッダのコピーまで。ffigen は別ステップ）
scripts/build-runtime.sh             # 例: build-runtime.sh platform=macos build=release
#   C-API を変えたらバインディング再生成 → commit: scripts/generate-ffigen-code.sh

# アセット生成 → example 起動
scripts/prepare-example-assets.sh
cd example && flutter run
#   （初回の macOS ランナー生成: cd example && flutter create --platforms=macos . ）
```

- **コード生成**: ffigen バインディング（`lib/src/*_bindings.g.dart`）は**コミット済み**。
  C-API を変えたら `generate-ffigen-code.*` を実行して再生成 → commit（`build-runtime` は
  もう自動実行しません）。`.fbs` スキーマを変えたときは `generate-fbs-code.*`（flatc）。
  クロスビルド（android/ios/web）は `SpriteStudio-SDK/scripts/release-*` に委譲します。
- **テスト**（`packages/ssplayer_flutter/`）:
  ```bash
  flutter test   # Native Assets が hook/build.dart 経由で Brain を自動同梱。env 変数は不要
  ```
  `ssruntime_dart` / `ssconverter_dart` は各パッケージで `dart test`（同じく hook がネイティブを解決）。
- **規約・設計**: [AGENTS.md](./AGENTS.md)（実装規約・要注意点） /
  [docs/architecture.ja.md](./docs/architecture.ja.md)（設計） /
  [docs/repository-structure.ja.md](./docs/repository-structure.ja.md)（構成図・Native Assets 同梱の要点） /
  [docs/status.ja.md](./docs/status.ja.md)（進捗）。

## 🔗 関連リポジトリ

- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — Rust ランタイム / コンバータ / `.fbs` スキーマ（Brain）
- 兄弟プレイヤー: [Godot](https://github.com/cri-middleware/SSPlayerForGodot) ／
  [Unity](https://github.com/cri-middleware/SSPlayerForUnity) ／
  [Web](https://github.com/cri-middleware/SSPlayerForWeb) ／
  [Ren'Py](https://github.com/cri-middleware/SSPlayerForRenPy)

## 📄 ライセンス

`SpriteStudio-SDK` のライセンスに従います（[`SpriteStudio-SDK/LICENSE.md`](./SpriteStudio-SDK/LICENSE.md)）。
