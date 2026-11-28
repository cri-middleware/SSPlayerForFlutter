# 📱 SpriteStudio Player for Flutter

**SpriteStudio** のアニメーション（`.ssab`）を Flutter でそのまま再生します。アーティストが専用エディタでリグを組み、Flutter 自身のレンダラで描画 —— 手書きのアニメーションコードは不要です。再生処理は
[SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) が提供する `libssruntime`
を介して行います。

!!! tip "SpriteStudio を初めて使う方へ"
    [SpriteStudio](https://www.webtech.co.jp/spritestudio/) はプロ向けの 2D アニメーションエディタです。手描きの**ラスター**（PNG）素材にボーン・メッシュ変形・パーティクルを載せて、モーションを視覚的に作れます。アーティストが動きを作り、このプレイヤーが完成ファイルを再生します。`.gif` や `.mp4` を同梱するより軽量です。手元にデータが無くても始められます —— [公式のサンプルデータ](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/)
    （[Ringo](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#ringo) /
    [パーティクル](https://www.webtech.co.jp/help/ja/spritestudio7/download/sample/#Perticle_sample)）がそのまま使えます。自分のアニメーションを作るには SpriteStudio 本体を使います（[製品サイト](https://www.webtech.co.jp/spritestudio/)）。

!!! example "ブラウザで試す"
    [**Web デモ**](https://cri-middleware.github.io/SSPlayerForFlutter/demo/) はこのドキュメントの隣に 2 つ公開しています。`ssplayer_flutter`
    のウィジェットを動かす `examples/overall` と、`ssplayer_flame` を動かす `examples/flame`
    です。いずれも Web 向けにビルドしています。
    Web ターゲットは developer preview です（[制約と適用範囲](limitations.md) を参照）。

## 目次

- **セットアップ**
    - [インストール](guide/install.md)
- **ワークフロー**
    - [クイックスタート](guide/quickstart.md)
    - [再生制御とイベント](guide/playback.md)
    - [モーションブレンド](guide/motion-blending.md)
    - [パーツトラッキング](guide/part-following.md)
    - [パーツオーバーライド](guide/part-overrides.md)
    - [ボタンと UI の状態](guide/buttons.md)
    - [テクスチャ差し替え](guide/textures.md)
    - [Flame との連携](guide/flame.md)
    - [アセットの準備（`.sspj` → `.ssab`）](guide/conversion.md)
    - [ライブリロード](guide/live-reload.md)
- [**API リファレンス**](api.md)
- [**制約と適用範囲**](limitations.md)
- **Player・SDK 開発者向けガイド**
    - [ビルドガイド](development/build.md)
    - [プレイヤーの構成](development/architecture.md)
    - [ネイティブランタイム](development/native-runtime.md)
- [**パッケージ**](packages.md)

## 主な機能 (Key Features)

- **キャラクターも、画面全体も“生きる”。** 呼吸・まばたき、なびく髪や衣装、斬撃・魔法のエフェクト、さらに動く HUD やスプラッシュ画面まで——動きは専用エディタ（SpriteStudio）でビジュアルに作り込み、`SpriteStudioAnimation` はそれを再生するだけ。ボーン・メッシュ変形・パーティクルにも対応し、アニメーションのコードは書かずに済みます。
- **ラスター素材を、ネイティブ描画で——ベクターでも動画でもない選択。** **ラスター**（PNG 等のビットマップ）のスプライト素材を動かすので、描き込んだイラストやリッチな質感が描いたとおりに動きます（ベクター系のアニメーションツールとは得意分野が異なります）。`.gif` や `.mp4` と違って自由に拡大縮小でき、シームレスにループし、アプリの操作にも反応します。描画は `dart:ffi` と native assets を通じて Flutter 自身のレンダラが行い、WebView も動画のデコードも手動のリンク作業も使いません。
- **普通のウィジェットとして——[Flame](guide/flame.md) でも。** 他のウィジェットと同じように配置・サイズ指定・変形・クリップできます。アーティストがタイムラインに置いたユーザーデータ・シグナル・オーディオキューはコールバックで届き（[再生制御とイベント](guide/playback.md)）、パーツ単位のオーバーライド（[パーツオーバーライド](guide/part-overrides.md)）や [`setCellmapTexture()`](guide/textures.md) で実行時に色変え・非表示・着せ替えもできます。ゲームを作るなら、`ssplayer_flame` で同じアニメーションを `FlameGame` に載せられます。
- **フレームの間も、アニメーションの間も滑らかに。** **サブフレーム補間**により、実際の表示タイミングちょうどの位置でフレームを生成します。作成時のフレームレートではなく、ディスプレイのリフレッシュレートや再生速度に追従した滑らかな表示が得られます。`transition` を指定すれば `animation` を変えたときに[クロスフェード](guide/motion-blending.md)し、トラックを重ねれば再生中の動きにまばたきや照準を重ねられます。
- **エディタから実行画面まで、シームレスな更新。** [ライブリロード](guide/live-reload.md)がアプリ実行中に `SpriteStudio_Source/` を監視します。SpriteStudio で保存するだけで、変更のあったプロジェクトだけが再変換され、実行中のアプリに反映されます。書き出しの手作業は要りません。

## 対応バージョン

- **Flutter / Dart**: 下限は[インストール](./guide/install.md)にあります。古いと `flutter pub get` が失敗します。
- **プラットフォーム**: macOS・Windows・Linux・iOS・Android・Web（開発者プレビュー）。

## サンプル

リポジトリの `examples/` フォルダにサンプルアプリがあります。チェックアウトから動かす方法は[ビルドガイド](development/build.md#チェックアウトから動かす)にあります。

- [overall](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/overall) — 総合的な検証アプリ。
- [flame](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/flame) — `ssplayer_flame` 経由でアニメーションを再生する `FlameGame`。
- [part_following](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/part_following) — `SpriteStudioPartAnchor` でウィジェットをパーツに追従させるサンプル。

## 関連リポジトリ

- [SpriteStudio Docs](https://cri-middleware.github.io/SpriteStudio-Docs/ja/) — SDK と公式 Player のドキュメントポータル。
- [SpriteStudio-SDK](https://github.com/cri-middleware/SpriteStudio-SDK) — `libssruntime` / `libssconverter` を提供する SDK 本体。
- [SSConverterGUI](https://github.com/cri-middleware/SSConverterGUI) — Player を介さず `.sspj` を変換するデスクトップ GUI。

## ライセンス

全文と参考訳は[ライセンス](license/index.md)を、同梱するライブラリ（FlatBuffers、SpriteStudio-SDK の依存クレートなど）のライセンスは[サードパーティ通知](license/third-party.md)を参照してください。
