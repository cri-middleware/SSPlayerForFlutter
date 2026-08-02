# API リファレンス

クラスレベルの API リファレンスは、Dart のドキュメントコメントから
[`dart doc`](https://dart.dev/tools/dart-doc) が生成します。パッケージが pub.dev に公開されると、
各パッケージの API は `pub.dev/documentation/<package>` で自動的にホストされます。

!!! note "🚧 最初のリリース前"
    ホスト版の API リンクは pub.dev 公開とともに有効になります。それまではローカルで生成してください。

## ローカルで生成する

```bash
# packages/ssplayer_flutter/（または任意のパッケージ）で
dart doc
# 出力: doc/api/index.html
```

## 主なエントリポイント

- **`SpriteStudioPlayer`**（L3）—— トランスポート / イベント。[再生とイベント](guide/playback.md) を参照。
- **`SpriteStudioView`**（L4）—— `RenderBox` ウィジェット。[クイックスタート](guide/quickstart.md) を参照。
- **`SpriteStudioComponent`**（`ssplayer_flame`）—— Flame アダプタ。[Flame 連携](guide/flame.md) を参照。
- **`SpriteStudioPartAnchor` / `SpriteStudioAnchorHidden` / `SpriteStudioAnchorMirror`**（L4）——
  パーツにウィジェットを追従させる。[パーツトラッキング](guide/part-following.md) を参照。
- **`SsRootTransform`** —— プレイヤー単位の反転 / オフセット（`flipX` / `flipY` / `offset`）。
  [再生とイベント](guide/playback.md) を参照。
- **`SsBlendOp` / `SsOverridePriority` / `PartNameTable`** —— パーツオーバーライド。
  [パーツオーバーライド](guide/part-overrides.md) を参照。
- **`SsAnimeInfo`** —— `.ssab` バイト列からアニメーション / セルマップ / セル名を列挙。
- **`SsConverter` / `ssconvert`**（`ssconverter_dart`）—— [アセット準備](guide/conversion.md) を参照。
