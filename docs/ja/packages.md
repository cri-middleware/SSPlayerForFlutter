# 📦 パッケージ

このモノレポは以下のパッケージを公開予定です 🚧（まだ pub.dev には未公開 —— [インストール](guide/install.md)
参照）。多くのアプリが依存するのは `ssplayer_flutter` で、残りは推移的に取り込まれるか、特定の用途で
使います。

どちらのプレイヤーもブラウザで動くデモがあります —— ウィジェット版は
[demo/flutter/](../demo/flutter/)、Flame 版は [demo/flame/](../demo/flame/) です。

| 目的 | パッケージ | 種別 |
|---|---|---|
| アニメ再生（ランタイム描画） | [`ssplayer_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flutter) | Flutter パッケージ（全プラットフォーム・`ssruntime_dart` に依存） |
| [Flame](https://flame-engine.org/) ゲームエンジンアダプタ | [`ssplayer_flame`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flame) | Flutter パッケージ（`SpriteStudioComponent`） |
| ランタイム FFI バインディング（Layer 1） | [`ssruntime_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssruntime_dart) | 純 Dart（renderer 非依存コア） |
| `.sspj` → `.ssab` 変換（CLI / ライブラリ） | [`ssconverter_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssconverter_dart) | 純 Dart（デスクトップ専用のホストツール） |
| stale なものだけ再変換するホストライブラリ（`ssgen_flutter` の土台） | [`ssgen_dart`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_dart) | 純 Dart（デスクトップ用ホストライブラリ・`ssconverter_dart` の上） |
| 編集→実機ループのライブリロード | [`ssgen_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_flutter) | Flutter 開発ツール（`ssgen_dart` の上） |

これらが描画レイヤーにどう対応するかは [アーキテクチャ](contributing/architecture.md) を参照してください。
