[**English**](./README.md) | [**日本語**](./README.ja.md)

# SpriteStudio Player for Flutter

**エディタで作り込んだ 2D ラスターアニメーションを、あなたの Flutter アプリへ。アーティストがリグを組み、あなたはウィジェット 1 個で再生。アニメーションコードは一切不要です。**

▶️ **[サンプルアプリを試す](./examples/overall/)** — 同梱の SpriteStudio アニメを Flutter の Canvas に直接描画します。🚧 プリビルドのネイティブは最初の SDK リリース公開後に自動ダウンロードされます。

**[OPTPiX SpriteStudio 7](https://www.webtech.co.jp/spritestudio/)** のアニメーション（`.ssab`）を [Flutter](https://flutter.dev/) でそのまま再生するプレイヤーです。SpriteStudio 7 はプロ向けの 2D **ラスター**（スプライト）アニメーションエディタ —— スプライト素材にボーン・メッシュ変形・パーティクルを載せてモーションを作れます。アーティストが動きを視覚的に作り、プレイヤーは完成ファイルを再生するだけ。Flutter の `Canvas` にネイティブ描画するので、手書きの `AnimationController` も、スプライトシートの切り出しも、動画のデコードも要りません。

## ✨ なぜ SpriteStudio Player？

- **絵を、そしてシーン全体を動かす —— アニメーションコードはゼロ。** 呼吸・まばたき、髪や服の揺れ、派手な斬撃・魔法エフェクト。`AnimationController` / `Tween` / `AnimatedBuilder` を手配線したり、スプライトシートを手で切り出したりする代わりに、モーションは専用エディタ（SpriteStudio 7）で視覚的に作り、プレイヤーは再生するだけ —— ボーン・メッシュ変形・パーティクル込みで。しかも 1 体のキャラクターに留まりません —— **UI・HUD・シーン全体**をエディタ上で丸ごと組み上げ、そのまま 1 つとして描画できます（狭いアイコンアニメ用途のツールでは届かない領域です）。
- **ラスター（スプライト）アニメを、ネイティブ描画。ベクターでも動画でもない。** **ラスターのスプライト素材**にリグと変形を効かせるので、手描きのキャラクターやゲームスプライトが作ったまま動きます —— ベクター系のアニメーションツールとは用途が異なり、`.gif` や `.mp4` を同梱するより軽量です。再生は `dart:ffi` 経由で Rust ランタイムを駆動し、`Canvas.drawVertices` で描画します —— WebView でも動画デコードでもありません。実行時に自由スケール、シームレスループ、しかもアプリに反応します。
- **ウィジェットツリーに —— そして Flame にも自然に合成。** `SpriteStudioView` は普通の `RenderBox` ウィジェットなので、位置・変形・クリップを他のウィジェットと同じように扱えます。ゲームを作るなら、別パッケージの [`ssplayer_flame`](./packages/ssplayer_flame) アダプタで、同じアニメを `FlameGame` の `PositionComponent` として載せられます。
- **フレームレートに縛られない滑らかさ。** **サブフレーム補間**が各フレームを表示タイミングちょうどに描画するので、モーションはディスプレイのリフレッシュレートと再生速度に追従します —— 固定 fps のパラパラ漫画やベイク済み動画より滑らかです。
- **編集から実機までシームレス。** ライブリロードが `flutter run` 中に `.sspj` を監視。SpriteStudio 7 で保存 → ホットリロードすると、変更したプロジェクトだけが再変換されてアプリに即反映されます —— 手動エクスポート不要。
## 📚 ドキュメント

インストール、アセットパイプライン、API リファレンスは MkDocs ドキュメントサイトを参照してください。

- [**ドキュメントサイト（ホスト版）**](https://cri-middleware.github.io/SSPlayerForFlutter/) — 🚧 最初のリリース後に公開
- [**Documentation (English)**](./docs/en/index.md)
- [**ドキュメント (日本語)**](./docs/ja/index.md)

### クイックリンク
- [インストール](docs/ja/guide/install.md)
- [クイックスタート](docs/ja/guide/quickstart.md)
- [Flame 連携](docs/ja/guide/flame.md)
- [CLI 変換（`.sspj` → `.ssab`）](docs/ja/guide/conversion.md)

## 📦 パッケージ

このモノレポは以下のパッケージを pub.dev に公開予定です 🚧（まだ未公開 —— 上のクイックスタート参照）。

| 目的 | パッケージ | 種別 |
|---|---|---|
| アニメ再生（ランタイム描画） | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter パッケージ（全プラットフォーム・`ssruntime_dart` に依存） |
| [Flame](https://flame-engine.org/) ゲームエンジンアダプタ | [`ssplayer_flame`](./packages/ssplayer_flame) | Flutter パッケージ（`SpriteStudioComponent`） |
| ランタイム FFI バインディング（Layer 1） | [`ssruntime_dart`](./packages/ssruntime_dart) | 純 Dart（renderer 非依存コア） |
| `.sspj` → `.ssab` 変換（CLI / ライブラリ） | [`ssconverter_dart`](./packages/ssconverter_dart) | 純 Dart（デスクトップ専用のホストツール） |
| stale なものだけ再変換するホストライブラリ（`ssgen_flutter` の土台） | [`ssgen_dart`](./packages/ssgen_dart) | 純 Dart（デスクトップ用ホストライブラリ） |
| 編集→実機ループのライブリロード | [`ssgen_flutter`](./packages/ssgen_flutter) | Flutter 開発ツール（`ssgen_dart` の上） |

---

## 🚀 1. クイックスタート（利用者）

アプリに `.ssab` アニメを組み込む最小コードです。（`.ssab` は事前に用意します —— [2 章](#-2-リポジトリで試す--自分のsspjを変換カスタマー)の `ssconvert` で `.sspj` から生成できます。）

依存を追加します。**pub.dev 公開までは**、[GitHub Releases](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest) から最新バンドルをダウンロードし、プロジェクト内（例: `vendor/`）に展開して、path 依存で参照してください。

```yaml
# pubspec.yaml
dependencies:
  ssplayer_flutter:
    # GitHub Releases のバンドルをプロジェクトに展開したもの。packages/ レイアウトを保つので、
    # 推移依存の ssruntime_dart も自動で解決されます。
    path: vendor/SSPlayerForFlutter/packages/ssplayer_flutter
```

> 🚧 Releases からのダウンロードは最初のリリース公開後に有効になります。pub.dev 公開後は、
> 通常の `ssplayer_flutter: ^x.y.z` に置き換わります。

```dart
class _MyState extends State<MyWidget> with SingleTickerProviderStateMixin {
  late final SpriteStudioPlayer _player = SpriteStudioPlayer(vsync: this);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // loadAsset がバイト列を読み、reference テクスチャ（同じフォルダの PNG）を
    // キー自身のフォルダから解決します。baseAssetDir は不要（embedded も同じ）。
    await _player.loadAsset('assets/overall/Basic.ssab');
    _player
      ..setupAnimation(_player.getAnimations().first)
      ..loop = -1
      ..play();
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
> Rust ツールチェーンは不要です（ソースからビルドする場合のみ `scripts/build-runtime.*`）。

## 🛠 2. リポジトリで試す ＋ 自分の`.sspj`を変換（カスタマー）

サンプル起動と、自分の `.sspj` の変換まで。**Rust ツールチェーンは不要** —— ネイティブ
（`libssruntime` / `libssconverter`）は各パッケージの `hook/build.dart` が、ピン留めした
SDK リリースからプリビルドを自動ダウンロードして同梱します。

```bash
git clone https://github.com/cri-middleware/SSPlayerForFlutter.git
cd SSPlayerForFlutter
git submodule update --init --recursive

# example 用アセット（.ssab）を Dart の ssconvert で生成（libssconverter は自動DL・Rust 不要）
scripts/deploy-examples.sh

# example を起動（libssruntime は hook/build.dart が自動DL）
cd examples/overall && flutter run
```

Windows は各スクリプトの `.ps1` を使います。自前ビルドの dylib を差し込む場合は、アプリの
`pubspec.yaml` の `hooks.user_defines.<pkg>.lib<name>` で指定します。

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
scripts/deploy-examples.sh
cd examples/overall && flutter run
```

実装規約・要注意点・Native Assets 同梱は [AGENTS.md](./AGENTS.md)、設計・リポジトリ構成・kind × 横断機能の
整合性は [docs/architecture.ja.md](./docs/architecture.ja.md)、今後の作業は [ROADMAP.md](./ROADMAP.md) を参照してください。

## 🔗 関連リポジトリ

- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — Rust ランタイム / コンバータ / `.fbs` スキーマ（Brain）
- 兄弟プレイヤー: [Godot](https://github.com/cri-middleware/SSPlayerForGodot) ·
  [Unity](https://github.com/cri-middleware/SSPlayerForUnity) ·
  [Web](https://github.com/cri-middleware/SSPlayerForWeb) ·
  [Ren'Py](https://github.com/cri-middleware/SSPlayerForRenPy)

## 📄 ライセンス

本プロジェクトは `SpriteStudio-SDK` のライセンスに従います
（[`SpriteStudio-SDK/LICENSE.md`](./SpriteStudio-SDK/LICENSE.md)）。同梱するネイティブランタイムや
その他のサードパーティコンポーネントのライセンスは、各パッケージの `native/libs/` 配下の
`THIRD-PARTY-LICENSES.*.md` を参照してください。
