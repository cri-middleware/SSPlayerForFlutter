[**English**](./README.md) | [**日本語**](./README.ja.md)

# SpriteStudio Player for Flutter

**エディタで作り込んだ 2D ラスターアニメーションを、あなたの Flutter アプリへ。アーティストがリグを組み、あなたはウィジェット 1 個で再生。アニメーションコードは一切不要です。**

▶️ **[ライブデモを試す](https://cri-middleware.github.io/SSPlayerForFlutter/demo/)** — Flutter が再生する SpriteStudio アニメをブラウザで見られます。インストールは要りません。

**[SpriteStudio](https://www.webtech.co.jp/spritestudio/)** のアニメーション（`.ssab`）を [Flutter](https://flutter.dev/) でそのまま再生するプレイヤーです。SpriteStudio はプロ向けの 2D **ラスター**（スプライト）アニメーションエディタ —— スプライト素材にボーン・メッシュ変形・パーティクルを載せてモーションを作れます。アーティストが動きを視覚的に作り、プレイヤーは完成ファイルを再生するだけ。Flutter の `Canvas` にネイティブ描画するので、手書きの `AnimationController` も、スプライトシートの切り出しも、動画のデコードも要りません。

## ✨ SpriteStudio を Flutter で使うメリット

- **キャラクターも、画面全体も“生きる”。** 呼吸・まばたき、なびく髪や衣装、斬撃・魔法のエフェクト、さらに動く HUD やスプラッシュ画面まで——動きは専用エディタ（SpriteStudio）でビジュアルに作り込み、`SpriteStudioAnimation` はそれを再生するだけ。ボーン・メッシュ変形・パーティクルにも対応し、アニメーションのコードは書かずに済みます。
- **ラスター素材を、ネイティブ描画で——ベクターでも動画でもない選択。** **ラスター**（PNG 等のビットマップ）のスプライト素材を動かすので、描き込んだイラストやリッチな質感が描いたとおりに動きます（ベクター系のアニメーションツールとは得意分野が異なります）。`.gif` や `.mp4` と違って自由に拡大縮小でき、シームレスにループし、アプリの操作にも反応します。描画は Flutter 自身のレンダラが行い、WebView も動画のデコードも使いません。
- **普通のウィジェットとして——Flame でも。** 他のウィジェットと同じように配置・サイズ指定・変形・クリップできます。アーティストがタイムラインに置いたユーザーデータ・シグナル・オーディオキューはコールバックで届き、パーツ単位のオーバーライドで実行時に色変え・非表示・差し替えもできます。ゲームを作るなら、[`ssplayer_flame`](./packages/ssplayer_flame) で同じアニメーションを `FlameGame` に載せられます。
- **フレームの間も、アニメーションの間も滑らかに。** **サブフレーム補間**により、実際の表示タイミングちょうどの位置でフレームを生成します。作成時のフレームレートではなく、ディスプレイのリフレッシュレートや再生速度に追従した滑らかな表示が得られます。`transition` を指定すれば `animation` を変えたときにクロスフェードし、トラックを重ねれば再生中の動きにまばたきや照準を重ねられます。
- **エディタから実行画面まで、シームレスな更新。** ライブリロードがアプリ実行中に `SpriteStudio_Source/` を監視します。SpriteStudio で保存するだけで、変更のあったプロジェクトだけが再変換され、実行中のアプリに反映されます。書き出しの手作業は要りません。

## 📚 ドキュメント

インストール、アセットパイプライン、API リファレンスは MkDocs ドキュメントサイトを参照してください。

- [**ドキュメントサイト（ホスト版）**](https://cri-middleware.github.io/SSPlayerForFlutter/ja/)
- [**Web デモ**](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — `ssplayer_flutter` と `ssplayer_flame` がブラウザで動きます
- [**Documentation (English)**](./docs/en/index.md)
- [**ドキュメント (日本語)**](./docs/ja/index.md)
- [**AI アシスタント向け**](https://cri-middleware.github.io/SSPlayerForFlutter/ja/llms.txt) — このドキュメントを Markdown で提供します。`llms.txt` はページの目次、`llms-full.txt` は全ページを 1 ファイルにまとめたものです。`ssplayer_flutter` と `ssplayer_flame` は同じページを `doc/` に、Agent Skill として `skills/` にも持っています（[skill の入れ方](https://cri-middleware.github.io/SpriteStudio-Docs/ja/overview/ai-assistants/)）
- [**SpriteStudio Docs（ポータル）**](https://cri-middleware.github.io/SpriteStudio-Docs/ja/) — SDK と全公式 Player の入口

### クイックリンク
- [インストール](docs/ja/guide/install.md)
- [クイックスタート](docs/ja/guide/quickstart.md)
- [Flame 連携](docs/ja/guide/flame.md)
- [アセットの準備（`.sspj` → `.ssab`）](docs/ja/guide/conversion.md)
- [制約と適用範囲](docs/ja/limitations.md)

---

## 🚀 クイックスタート

**アプリで使う場合**はこのまま下へ。依存を追加する → 自分の `.sspj` を変換する → 再生する。その先（イベント、パーツ単位の上書き、ライブリロード）も同じ道の続きで、[ドキュメント](docs/ja/index.md)にあります。
**Player 自体や、その下の Rust ランタイムを変更する場合**は [CONTRIBUTING.md](./CONTRIBUTING.md) と[ビルドガイド](./docs/ja/development/build.md)（変更したプレイヤーをアプリで使う方法と、スイートで見えないものの確かめ方を含む）へ。層とその理由は[プレイヤーの構成](./docs/ja/development/architecture.md)にあります。

**Flutter 3.47 以上 / Dart 3.13 以上**と、**SpriteStudio 7.6 以上**で作成したプロジェクトを用意してください。

1. **導入**: プレイヤーと、dev 依存としてコンバータを追加します。

   ```bash
   flutter pub add ssplayer_flutter
   flutter pub add --dev ssconverter_dart
   ```

   ネイティブランタイムは、最初のビルドでパッケージと一緒にビルド済みのものが入ります。Rust のツールチェーンも、プラットフォームごとの設定も要りません。

2. **変換**: SpriteStudio のプロジェクトをフォルダごとアプリの `SpriteStudio_Source/` に置き、`assets/spritestudio/` へ変換して、そのフォルダを `pubspec.yaml` に登録します。

   ```bash
   dart run ssconverter_dart:ssconvert -o assets/spritestudio/Ringo/ SpriteStudio_Source/Ringo/Ringo.sspj
   ```

   ```yaml
   flutter:
     assets:
       - assets/spritestudio/Ringo/
   ```

   ```
   my_app/
   ├── SpriteStudio_Source/
   │   └── Ringo/                 ← SpriteStudio のプロジェクトをフォルダごと
   │       ├── Ringo.sspj
   │       ├── Ringo.png
   │       └── …
   ├── assets/spritestudio/
   │   └── Ringo/                 ← ssconvert が書き出す
   │       ├── Ringo.ssab
   │       └── Ringo.png
   ├── lib/main.dart
   └── pubspec.yaml               ← assets/spritestudio/Ringo/ を登録
   ```

3. **再生**: ウィジェットを 1 つ、ツリーのどこかに置きます。

   ```dart
   SpriteStudioAnimation.asset(
     'assets/spritestudio/Ringo/Ringo.ssab',
     animation: 'wait1',
     width: 400,
     height: 400,
   )
   ```

   パックとテクスチャを読み込んでアニメをループ再生し、ウィジェットと一緒に破棄されます。

SpriteStudio での保存を、手で変換せずに実行中のアプリへ反映するには [ライブリロード](docs/ja/guide/live-reload.md) を使います。同じ `SpriteStudio_Source/` を監視します。

SpriteStudio のデータが手元に無くても始められます。[公式のサンプルデータ](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/)がそのまま使えます。キャラクターなら [Ringo](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#ringo) が手頃です。

**次に読む:** [クイックスタート（ガイド）](docs/ja/guide/quickstart.md) · [再生とイベント](docs/ja/guide/playback.md) ·
[制約と適用範囲](docs/ja/limitations.md)

## 📦 パッケージ

アプリから直接使うパッケージです。アニメーションを再生するだけなら最初の 1 行で足ります。土台となる FFI バインディングや差分再変換パッケージ（`ssruntime_dart`・`ssgen_dart`）も含めた一覧は[パッケージ](docs/ja/packages.md)と[プレイヤーの構成](docs/ja/development/architecture.md)を参照してください。

| 目的 | パッケージ | 種別 |
|---|---|---|
| アニメ再生（ランタイム描画） | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter パッケージ（全プラットフォーム） |
| [Flame](https://flame-engine.org/) ゲームエンジンアダプタ | [`ssplayer_flame`](./packages/ssplayer_flame) | Flutter パッケージ（`SpriteStudioComponent`） |
| `.sspj` → `.ssab` 変換（CLI / ライブラリ） | [`ssconverter_dart`](./packages/ssconverter_dart) | 純 Dart（デスクトップ専用のホストツール） |
| 編集→実機ループのライブリロード | [`ssgen_flutter`](./packages/ssgen_flutter) | Flutter 開発ツール |

## 🎬 サンプル

[`examples/`](./examples/) にすぐ動かせるアプリがあります。`scripts/run-<platform>.*` を 1 回実行すれば起動します。SDK のテストプロジェクトを各サンプルが読み込む `.ssab` へ変換し、プラットフォームのランナーを生成し、端末を選ぶところまで行います（起動中の端末が無ければエミュレータを起動します）。

```bash
scripts/run-macos.sh                   # overall。run-linux / run-ios / run-android / run-web も同様
scripts/run-android.sh example=flame   # 別のサンプル
scripts\run-windows.ps1                # Windows（run-android.ps1 / run-web.ps1 もあります）
```

- [overall](./examples/overall) — まず開くのはこちら。`tests/overall` を再生し、ドロップダウンでアニメを切り替えられます。
- [flame](./examples/flame) — [`ssplayer_flame`](./packages/ssplayer_flame) アダプタのサンプル。`FlameGame` に `SpriteStudioComponent` を 1 つ載せて Ringo を再生し、タップで再生 / 一時停止を切り替えます。
- [part_following](./examples/part_following) — `SpriteStudioPartAnchor` で通常の Flutter ウィジェットをパーツに貼り付け、位置・回転・スケールを毎フレーム追従させます。

## 🔗 関連リポジトリ

- [SpriteStudio Docs](https://cri-middleware.github.io/SpriteStudio-Docs/ja/) — SDK と全公式 Player のドキュメントポータル
- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — 本 Player が駆動する Rust ランタイム / コンバータ / `.fbs` スキーマ
- [SSConverterGUI](https://github.com/cri-middleware/SSConverterGUI) — Player なしで `.sspj` を変換できるデスクトップ GUI

## 📄 ライセンス

本プロジェクトは BSD-3-Clause ライセンスです（[`LICENSE.md`](./LICENSE.md)、参考訳 [`LICENSE.ja.md`](./LICENSE.ja.md)）。同梱するネイティブランタイムやその他のサードパーティコンポーネントの通知は
[`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md) を参照してください。
