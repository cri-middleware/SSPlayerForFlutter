# 📥 インストール

Flutter アプリに SpriteStudio Player for Flutter を追加する手順です。ネイティブランタイム（`libssruntime`）は Dart の **Native Assets** で自動的に届くので、CocoaPods・framework・
`DynamicLibrary` のパス設定は不要で、Rust ツールチェーンも要りません。

## 対応環境

| 項目 | 内容 |
|---|---|
| Flutter / Dart | **Flutter 3.47+ / Dart 3.13+**（Native Assets は 3.38 から既定で有効。下限 3.47 は flutter_gpu バックエンドの要件）。強制するのは `ssplayer_flutter` の `environment:` です（古いと `flutter pub get` が落ちます） |
| プラットフォーム | macOS · Windows · Linux · iOS · Android。Web は開発者プレビュー |
| SpriteStudio | 7.6 以上で作成したプロジェクト |
| ネイティブツールチェーン | 不要 —— ネイティブランタイムは `ssruntime_dart` のビルドフックがプリビルドを取得 |

## 依存を追加する

[pub.dev](https://pub.dev/packages/ssplayer_flutter) から `ssplayer_flutter` を、dev 依存としてコンバータを追加します。

```bash
flutter pub add ssplayer_flutter
flutter pub add --dev ssconverter_dart
```

その下のランタイムバインディング `ssruntime_dart` も一緒に入ります。

ほかに追加するものは、使う機能によって決まります。

| 用途 | 追加するもの |
|---|---|
| [Flame 連携](flame.md) | `flutter pub add flame ssplayer_flame` |
| [ライブリロード](live-reload.md) | `flutter pub add --dev ssgen_flutter` |

> [!NOTE] Web ターゲット
> Web のランタイムは `ssplayer_flutter` に同梱されています。`runApp` の前に一度 `await loadSsRuntime()` を呼んでください。ほかのプラットフォームでは何もしません。

> [!TIP] コアを開発する場合
> `libssruntime` を Rust ソースからビルドしたり Player 本体に手を入れる作業は、
> [ビルドガイド](../development/build.md) にまとめてあります —— アプリ利用者には不要です。

## 動作確認

アプリで `ssplayer_flutter` を import して `flutter pub get` が解決しビルドが通ることを確認します。ネイティブライブラリは初回ビルド時に取得・埋め込みされ、追加設定は不要です。

## 次のステップ

- **まだ `.ssab` が無い** → [アセットの準備（`.sspj` → `.ssab`）](conversion.md) で SpriteStudio
  プロジェクトから生成します。
- **`.ssab` がある** → [クイックスタート](quickstart.md) でウィジェットに読み込んで再生します。
