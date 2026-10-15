[**English**](./README.md) | [**日本語**](./README.ja.md)

# SpriteStudio Player for Flutter

**エディタで作り込んだ 2D ラスターアニメーションを、あなたの Flutter アプリへ。アーティストがリグを組み、あなたはウィジェット 1 個で再生。アニメーションコードは一切不要です。**

▶️ **[サンプルアプリを試す](./examples/overall/)** — 同梱の SpriteStudio アニメを Flutter の Canvas に直接描画します。プリビルドのネイティブは自動ダウンロードされます。

**[SpriteStudio](https://www.webtech.co.jp/spritestudio/)** のアニメーション（`.ssab`）を [Flutter](https://flutter.dev/) でそのまま再生するプレイヤーです。SpriteStudio はプロ向けの 2D **ラスター**（スプライト）アニメーションエディタ —— スプライト素材にボーン・メッシュ変形・パーティクルを載せてモーションを作れます。アーティストが動きを視覚的に作り、プレイヤーは完成ファイルを再生するだけ。Flutter の `Canvas` にネイティブ描画するので、手書きの `AnimationController` も、スプライトシートの切り出しも、動画のデコードも要りません。

## ✨ SpriteStudio を Flutter で使うメリット

- **キャラクターも、画面全体も“生きる”。** 呼吸・まばたき、なびく髪や衣装、斬撃・魔法のエフェクト、さらに動く HUD やスプラッシュ画面まで——動きは専用エディタ（SpriteStudio）でビジュアルに作り込み、`SpriteStudioView` はそれを再生するだけ。ボーン・メッシュ変形・パーティクルにも対応し、アニメーションのコードは書かずに済みます。
- **手描きの絵を、ネイティブ描画で。** お手持ちのスプライト素材を動かすので、描き込んだキャラクターが描いたとおりに動きます（Lottie のようなベクター系ツールとは得意分野が異なります）。`.gif` や `.mp4` と違って自由に拡大縮小でき、シームレスにループし、アプリの操作にも反応します。描画は Flutter 自身のレンダラが行い、WebView も動画のデコードも使いません。
- **普通のウィジェットとして——Flame でも。** 他のウィジェットと同じように配置・サイズ指定・変形・クリップできます。ゲームを作るなら、[`ssplayer_flame`](./packages/ssplayer_flame) で同じアニメーションを `FlameGame` に載せられます。
- **フレームレートに縛られない滑らかな動き。** **サブフレーム補間**により、実際の表示タイミングちょうどの位置でフレームを生成します。作成時のフレームレートではなく、ディスプレイのリフレッシュレートや再生速度に追従した滑らかな表示が得られます。
- **エディタから実行画面まで、シームレスな更新。** ライブリロードがアプリ実行中に `SpriteStudio_Source/` を監視します。SpriteStudio で保存するだけで、変更のあったプロジェクトだけが再変換され、実行中のアプリに反映されます。書き出しの手作業は要りません。

## 📚 ドキュメント

インストール、アセットパイプライン、API リファレンスは MkDocs ドキュメントサイトを参照してください。

- [**ドキュメントサイト（ホスト版）**](https://cri-middleware.github.io/SSPlayerForFlutter/ja/)
- [**Web デモ**](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) — `ssplayer_flutter` と `ssplayer_flame` がブラウザで動きます
- [**Documentation (English)**](./docs/en/index.md)
- [**ドキュメント (日本語)**](./docs/ja/index.md)
- [**AI アシスタント向け**](https://cri-middleware.github.io/SSPlayerForFlutter/ja/llms.txt) — このドキュメントを Markdown で提供します。`llms.txt` はページの目次、`llms-full.txt` は全ページを 1 ファイルにまとめたものです
- [**SpriteStudio Docs（ポータル）**](https://cri-middleware.github.io/SpriteStudio-Docs/ja/) — SDK と全公式 Player の入口

### クイックリンク
- [インストール](docs/ja/guide/install.md)
- [クイックスタート](docs/ja/guide/quickstart.md)
- [Flame 連携](docs/ja/guide/flame.md)
- [アセットの準備（`.sspj` → `.ssab`）](docs/ja/guide/conversion.md)
- [制約と適用範囲](docs/ja/limitations.md)

---

## 🚀 1. クイックスタート

**アプリで使う場合**はこのまま下へ。依存を追加する → 自分の `.sspj` を変換する → 再生する。その先（イベント、パーツ単位の上書き、ライブリロード）も同じ道の続きで、[ドキュメント](docs/ja/index.md)にあります。
**Player 自体や、その下の Rust ランタイムを変更する場合**は [2 章](#%EF%B8%8F-2-フル開発環境sdk--player-開発者)へ。

### セットアップ

[pub.dev](https://pub.dev/packages/ssplayer_flutter) からパッケージを追加します。

```bash
flutter pub add ssplayer_flutter
```

Flame・コンバータ・ライブリロードは、それぞれパッケージを 1 つ足します（[インストール](docs/ja/guide/install.md)参照）。

`.ssab` アニメを組み込む最小コードです（`.ssab` は事前に用意します —— [自分の `.sspj` を変換する](#自分の-sspj-を変換する)参照）:

```dart
SpriteStudioAnimation.asset(
  'assets/spritestudio/overall/Basic.ssab',
  width: 400,
  height: 400,
)
```

これでバイト列を読み、reference テクスチャ（同じフォルダの PNG）をキー自身のフォルダから解決し（embedded も同じ）、パックの最初のアニメを選んでループ再生し、ウィジェットと一緒にすべて破棄します。別のアニメを選ぶなら `animation:`、最初のフレームが描けるまでの表示は
`placeholder:` です。

プレイヤーを自分で持ちたい場合 —— ステートマシンからアニメを差し替える、イベントを購読する、ウィジェットをパーツに貼り付ける —— は `SpriteStudioPlayer` を作って `SpriteStudioView` に渡してください。→ [クイックスタート](./docs/ja/guide/quickstart.md)

> ⚠️ ネイティブランタイム（`libssruntime`。各公式 Player が共通で使う Rust コア）が必要です。これは依存先 `ssruntime_dart` の
> **Native Assets**（`hook/build.dart`）がアプリに自動同梱します（プラグイン／framework 配線は不要）。
> `hook/build.dart` はピン留めした SDK リリースからプリビルドを**自動ダウンロード**するので
> Rust ツールチェーンは不要です（ソースからビルドする場合のみ 2 章参照）。

### チェックアウトから動かしてみる

> これは上のインストール手順の一部ではなくチェックアウトなので、パッケージを使うだけなら不要です。

同梱のサンプルを起動して動作を確認します。**Rust ツールチェーンは不要** —— 各パッケージの
`hook/build.dart` が、ピン留めした SDK リリースからプリビルド（`libssruntime` / `libssconverter`）を自動ダウンロードして同梱します。

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
`ssconverter_dart` の CLI で変換します（`-e` で自己完結の embedded `.ssab`。配布向け）。**Rust ツールチェーンは不要** —— `libssconverter` は自動ダウンロードされます:

```bash
# SpriteStudio_Source/MyChar/MyChar.sspj  →  assets/spritestudio/MyChar/<pack>.ssab
#   （1 つの .sspj からアニメパックごとに .ssab が出力されます）
dart run ssconverter_dart:ssconvert -e -o assets/spritestudio/MyChar/ SpriteStudio_Source/MyChar/MyChar.sspj
# アプリ側:  loadAsset('assets/spritestudio/MyChar/MyChar.ssab')
```

同じ `SpriteStudio_Source/` レイアウトが**ライブリロード**を駆動します。`flutter run` の隣で `sswatch`
を回すと、SpriteStudio での保存が変更プロジェクトだけを再変換し、実行中アプリへ反映します（[ライブリロード](docs/ja/guide/live-reload.md)参照）。自前ビルドのネイティブライブラリを差し込む場合は、アプリの `pubspec.yaml` の `hooks.user_defines.<pkg>.lib<name>` で指定します。

## ⚙️ 2. フル開発環境（SDK / Player 開発者）

コア（Rust ランタイム / Player）をソースから開発する場合。**前提**: Rust（`rustup`）、
Flutter / Dart は[インストール](docs/ja/guide/install.md)の下限以上（Native Assets が標準。ネイティブランタイム同梱に CocoaPods／vendored
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

チェックアウトからのビルドとテストは [CONTRIBUTING.md](./CONTRIBUTING.md)、ネイティブライブラリの同梱は [ネイティブランタイム](./docs/ja/contributing/native-runtime.md)、今後の作業は [ROADMAP.md](./ROADMAP.md) を参照してください。

## 📦 パッケージ

このモノレポがリリースするものです。アニメーションを再生するだけなら最初の 1 行で足り、残りはその土台と周辺ツールです。

| 目的 | パッケージ | 種別 |
|---|---|---|
| アニメ再生（ランタイム描画） | [`ssplayer_flutter`](./packages/ssplayer_flutter) | Flutter パッケージ（全プラットフォーム・`ssruntime_dart` に依存） |
| [Flame](https://flame-engine.org/) ゲームエンジンアダプタ | [`ssplayer_flame`](./packages/ssplayer_flame) | Flutter パッケージ（`SpriteStudioComponent`） |
| `dart:ffi` 越しのランタイムバインディング | [`ssruntime_dart`](./packages/ssruntime_dart) | 純 Dart（renderer 非依存コア） |
| `.sspj` → `.ssab` 変換（CLI / ライブラリ） | [`ssconverter_dart`](./packages/ssconverter_dart) | 純 Dart（デスクトップ専用のホストツール） |
| 変更されたものだけ再変換するホストライブラリ（`ssgen_flutter` の土台） | [`ssgen_dart`](./packages/ssgen_dart) | 純 Dart（デスクトップ用ホストライブラリ） |
| 編集→実機ループのライブリロード | [`ssgen_flutter`](./packages/ssgen_flutter) | Flutter 開発ツール（`ssgen_dart` の上） |

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
