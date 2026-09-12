[**English**](./README.md) | [**日本語**](./README.ja.md)

# SpriteStudio Player for Flutter

**エディタで作り込んだ 2D ラスターアニメーションを、あなたの Flutter アプリへ。アーティストがリグを組み、あなたはウィジェット 1 個で再生。アニメーションコードは一切不要です。**

▶️ **[サンプルアプリを試す](./examples/overall/)** — 同梱の SpriteStudio アニメを Flutter の Canvas に直接描画します。🚧 プリビルドのネイティブは最初の SDK リリース公開後に自動ダウンロードされます。

**[SpriteStudio](https://www.webtech.co.jp/spritestudio/)** のアニメーション（`.ssab`）を [Flutter](https://flutter.dev/) でそのまま再生するプレイヤーです。SpriteStudio はプロ向けの 2D **ラスター**（スプライト）アニメーションエディタ —— スプライト素材にボーン・メッシュ変形・パーティクルを載せてモーションを作れます。アーティストが動きを視覚的に作り、プレイヤーは完成ファイルを再生するだけ。Flutter の `Canvas` にネイティブ描画するので、手書きの `AnimationController` も、スプライトシートの切り出しも、動画のデコードも要りません。

## ✨ なぜ SpriteStudio Player？

- **絵を、そしてシーン全体を動かす —— アニメーションコードはゼロ。** 呼吸・まばたき、髪や服の揺れ、派手な斬撃・魔法エフェクト。`AnimationController` / `Tween` / `AnimatedBuilder` を手配線したり、スプライトシートを手で切り出したりする代わりに、モーションは専用エディタ（SpriteStudio）で視覚的に作り、プレイヤーは再生するだけ —— ボーン・メッシュ変形・パーティクル込みで。しかも 1 体のキャラクターに留まりません —— **UI・HUD・シーン全体**をエディタ上で丸ごと組み上げ、そのまま 1 つとして描画できます（狭いアイコンアニメ用途のツールでは届かない領域です）。
- **ラスター（スプライト）アニメを、ネイティブ描画。ベクターでも動画でもない。** **ラスターのスプライト素材**にリグと変形を効かせるので、手描きのキャラクターやゲームスプライトが作ったまま動きます —— ベクター系のアニメーションツールとは用途が異なり、`.gif` や `.mp4` を同梱するより軽量です。再生は `dart:ffi` 経由で Rust ランタイムを駆動し、Flutter 自身のレンダラで描画します（Impeller では **flutter_gpu** で GPU バッチ描画、それ以外は `Canvas.drawVertices`）—— WebView でも動画デコードでもありません。実行時に自由スケール、シームレスループ、しかもアプリに反応します。
- **ウィジェットツリーに —— そして Flame にも自然に合成。** `SpriteStudioView` は普通の `RenderBox` ウィジェットなので、位置・変形・クリップを他のウィジェットと同じように扱えます。ゲームを作るなら、別パッケージの [`ssplayer_flame`](./packages/ssplayer_flame) アダプタで、同じアニメを `FlameGame` の `PositionComponent` として載せられます。
- **フレームレートに縛られない滑らかさ。** **サブフレーム補間**が各フレームを表示タイミングちょうどに描画するので、モーションはディスプレイのリフレッシュレートと再生速度に追従します —— 固定 fps のパラパラ漫画やベイク済み動画より滑らかです。
- **編集から実機までシームレス。** ライブリロードが `flutter run` 中に `SpriteStudio_Source/` を監視。SpriteStudio で保存 → ホットリロードすると、変更したプロジェクトだけが再変換されてアプリに即反映されます —— 手動エクスポート不要。

## 📚 ドキュメント

インストール、アセットパイプライン、API リファレンスは MkDocs ドキュメントサイトを参照してください。

- [**ドキュメントサイト（ホスト版）**](https://cri-middleware.github.io/SSPlayerForFlutter/ja/) — 🚧 最初のリリース後に公開
- [**Web デモ**](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — `ssplayer_flutter` と `ssplayer_flame` がブラウザで動きます — 🚧 最初のリリース後に公開
- [**Documentation (English)**](./docs/en/index.md)
- [**ドキュメント (日本語)**](./docs/ja/index.md)
- [**SpriteStudio Docs（ポータル）**](https://cri-middleware.github.io/SpriteStudio-Docs/ja/) — SDK と全公式 Player の入口 — 🚧 最初のリリース後に公開

### クイックリンク
- [インストール](docs/ja/guide/install.md)
- [クイックスタート](docs/ja/guide/quickstart.md)
- [Flame 連携](docs/ja/guide/flame.md)
- [アセットの準備（`.sspj` → `.ssab`）](docs/ja/guide/conversion.md)
- [制限事項と対応範囲](docs/ja/limitations.md)

## 📦 パッケージ

このモノレポは以下のパッケージを pub.dev に公開予定です 🚧（まだ未公開 —— 下のクイックスタート参照）。

| 目的 | パッケージ | 種別 |
|---|---|---|
| アニメ再生（ランタイム描画） | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter パッケージ（全プラットフォーム・`ssruntime_dart` に依存） |
| [Flame](https://flame-engine.org/) ゲームエンジンアダプタ | [`ssplayer_flame`](./packages/ssplayer_flame) | Flutter パッケージ（`SpriteStudioComponent`） |
| ランタイム FFI バインディング（Layer 1） | [`ssruntime_dart`](./packages/ssruntime_dart) | 純 Dart（renderer 非依存コア） |
| `.sspj` → `.ssab` 変換（CLI / ライブラリ） | [`ssconverter_dart`](./packages/ssconverter_dart) | 純 Dart（デスクトップ専用のホストツール） |
| stale なものだけ再変換するホストライブラリ（`ssgen_flutter` の土台） | [`ssgen_dart`](./packages/ssgen_dart) | 純 Dart（デスクトップ用ホストライブラリ） |
| 編集→実機ループのライブリロード | [`ssgen_flutter`](./packages/ssgen_flutter) | Flutter 開発ツール（`ssgen_dart` の上） |

---

## 🚀 1. クイックスタート

**アプリで使う場合**はこのまま下へ。依存を追加する → 自分の `.sspj` を変換する → 再生する。
その先（イベント、パーツ単位の上書き、ライブリロード）も同じ道の続きで、[ドキュメント](docs/ja/index.md)にあります。
**Player 自体や、その下の Rust ランタイムを変更する場合**は [2 章](#-2-フル開発環境sdk--player-開発者)へ。

### セットアップ

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

`.ssab` アニメを組み込む最小コードです（`.ssab` は事前に用意します —— [自分の `.sspj` を変換する](#自分の-sspj-を変換する)参照）:

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
    await _player.loadAsset('assets/spritestudio/overall/Basic.ssab');
    _player
      ..setAnimation(_player.animationNames.first)
      ..loopCount = -1
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
> Rust ツールチェーンは不要です（ソースからビルドする場合のみ 2 章参照）。

### チェックアウトから動かしてみる

> 🚧 pub.dev 公開までは、これが動いているところを見る方法です。上のインストール手順の一部では
> なくチェックアウトなので、パッケージを使うだけなら不要です。

同梱のサンプルを起動して動作を確認します。**Rust ツールチェーンは不要** —— 各パッケージの
`hook/build.dart` が、ピン留めした SDK リリースからプリビルド（`libssruntime` / `libssconverter`）を
自動ダウンロードして同梱します。

**macOS / Linux:**
```bash
git clone https://github.com/cri-middleware/SSPlayerForFlutter.git
cd SSPlayerForFlutter
git submodule update --init --recursive
scripts/deploy-examples.sh          # example 用 .ssab を生成（libssconverter は自動DL・Rust 不要）
cd examples/overall && flutter run  # libssruntime は自動DL
```

**Windows:**
```powershell
git clone https://github.com/cri-middleware/SSPlayerForFlutter.git
cd SSPlayerForFlutter
git submodule update --init --recursive
scripts\deploy-examples.ps1
cd examples\overall; flutter run
```

### 自分の `.sspj` を変換する

対応するのは **SpriteStudio 7.5 以上**で作成されたプロジェクトです。`.sspj` + `.ssae` + 画像を **`SpriteStudio_Source/`** フォルダに入れ、
`ssconverter_dart` の CLI で変換します（`-e` で自己完結の embedded `.ssab`。配布向け）。**Rust ツール
チェーンは不要** —— `libssconverter` は自動ダウンロードされます:

```bash
# SpriteStudio_Source/MyChar/MyChar.sspj  →  assets/spritestudio/MyChar/<pack>.ssab
#   （1 つの .sspj からアニメパックごとに .ssab が出力されます）
dart run ssconverter_dart:ssconvert -e -o assets/spritestudio/MyChar/ SpriteStudio_Source/MyChar/MyChar.sspj
# アプリ側:  loadAsset('assets/spritestudio/MyChar/MyChar.ssab')
```

同じ `SpriteStudio_Source/` レイアウトが**ライブリロード**を駆動します。`flutter run` の隣で `sswatch`
を回すと、SpriteStudio での保存が変更プロジェクトだけを再変換し、実行中アプリへ反映します
（[ライブリロード](docs/ja/guide/live-reload.md)参照）。自前ビルドのネイティブライブラリを差し込む場合は、
アプリの `pubspec.yaml` の `hooks.user_defines.<pkg>.lib<name>` で指定します。

## ⚙️ 2. フル開発環境（SDK / Player 開発者）

コア（Rust ランタイム / Player）をソースから開発する場合。**前提**: Rust（`rustup`）、
Flutter / Dart は[インストール](docs/ja/guide/install.md)の下限以上（Native Assets が標準。ネイティブ Brain 同梱に CocoaPods／vendored
framework は不要）。`flatc` は `.fbs` を再生成するときだけ。cbindgen は SDK の `build.rs` が
build-dependency として使うため個別導入不要。

**macOS / Linux:**
```bash
git submodule update --init --recursive
scripts/build-runtime.sh             # 例: build-runtime.sh platform=macos build=release
#   C-API を変えたらバインディング再生成 → commit: scripts/generate-ffigen-code.sh
scripts/deploy-examples.sh
cd examples/overall && flutter run
```

**Windows:**
```powershell
git submodule update --init --recursive
scripts\build-runtime.ps1
scripts\deploy-examples.ps1
cd examples\overall; flutter run
```

実装規約・要注意点・Native Assets 同梱は [AGENTS.md](./AGENTS.md)、今後の作業は [ROADMAP.md](./ROADMAP.md) を参照してください。

## 🎬 サンプル

[`examples/`](./examples/) にすぐ動かせるアプリがあります。先に `scripts/deploy-examples.*` を
一度実行してください（SDK のテストプロジェクトを、各サンプルが読み込む `.ssab` へ変換します）。

- [overall](./examples/overall) — まず開くのはこちら。`tests/overall` を再生し、ドロップダウンでアニメを切り替えられます。
- [flame](./examples/flame) — [`ssplayer_flame`](./packages/ssplayer_flame) アダプタのサンプル。`FlameGame` に `SpriteStudioComponent` を 1 つ載せて Ringo を再生し、タップで再生 / 一時停止を切り替えます。
- [part_following](./examples/part_following) — `SpriteStudioPartAnchor` で通常の Flutter ウィジェットをパーツに貼り付け、位置・回転・スケールを毎フレーム追従させます。

## 🔗 関連リポジトリ

- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — Rust ランタイム / コンバータ / `.fbs` スキーマ（Brain）

## 📄 ライセンス

本プロジェクトは BSD-3-Clause ライセンスです（[`LICENSE.md`](./LICENSE.md)、参考訳 [`LICENSE.ja.md`](./LICENSE.ja.md)）。同梱するネイティブ
ランタイムやその他のサードパーティコンポーネントの通知は
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md) を参照してください。
