# SpriteStudioPlayer for Flutter

**OPTPiX SpriteStudio 7** のラスター（スプライト）アニメーション（`.ssab`）を Flutter でそのまま再生
します。アーティストが専用エディタでリグを組み、Flutter の `Canvas` に直接描画 —— 手書きの
アニメーションコードは不要です。

!!! tip "SpriteStudio を初めて使う方へ"
    [OPTPiX SpriteStudio 7](https://www.webtech.co.jp/spritestudio/) はプロ向けの 2D **ラスター**
    アニメーションエディタです。スプライト素材にボーン・メッシュ変形・パーティクルを載せて、
    モーションを視覚的に作れます。アーティストが動きを作り、このプレイヤーが完成ファイルを再生
    します。ベクター系のツールとは用途が異なり、`.gif` や `.mp4` を同梱するより軽量です。

## あなたはどの読者？

目的のところまで読めば OK です。タブは上から並んでいて、アプリ開発者が Rust/SDK の話に触れる必要は
ありません。

| あなたは… | 目的 | ここから |
|---|---|---|
| **Flutter アプリ開発者** | アプリでアニメを再生するだけ | [**利用者 → インストール**](guide/install.md) |
| **カスタマイズ／自動化** | 自分の `.sspj` を変換・ランタイム差し替え・ライブリロード | [**カスタマイズと自動化**](customize/index.md) |
| **Player / SDK 開発者** | Rust ランタイム / Player を拡張・貢献 | [**Player / SDK 開発者向け**](contributing/architecture.md) |

## ハイライト

- **アニメーションコードはゼロ** —— キャラクター・**UI・シーン全体**を SpriteStudio 7 で作り、`play()` を呼ぶだけ。
- **ネイティブ描画** —— `dart:ffi` で Rust ランタイムを駆動し `Canvas.drawVertices` で描画。WebView でも動画デコードでもありません。
- **ウィジェットツリーに、[Flame](guide/flame.md) にも合成** —— `SpriteStudioView` は普通の `RenderBox`。
- **サブフレーム補間** —— ディスプレイのリフレッシュレートに追従する滑らかなモーション（固定 fps ではありません）。
公開パッケージは [パッケージ](packages.md)、生成 API ドキュメントは [API リファレンス](api.md) を参照してください。
