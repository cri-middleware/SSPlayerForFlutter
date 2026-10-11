# 📥 インストール

Flutter アプリに SpriteStudio Player for Flutter を追加する手順です。ネイティブランタイム（`libssruntime`）は Dart の **Native Assets** で自動的に届くので、CocoaPods・framework・
`DynamicLibrary` のパス設定は不要で、Rust ツールチェーンも要りません。

## 対応環境

| 項目 | 内容 |
|---|---|
| Flutter / Dart | **Flutter 3.47+ / Dart 3.13+**（Native Assets は 3.38 から既定で有効。下限 3.47 は flutter_gpu バックエンドの要件）。この下限を書き下ろしているのはこのページで、実際に強制するのは `ssplayer_flutter` の `environment:` です（古いと `flutter pub get` が落ちます） |
| 動作確認済み | macOS · iOS · Android |
| その他 | Windows / Linux はソースからビルド、Web は開発者プレビュー |
| ネイティブツールチェーン | 不要 —— Brain は `ssruntime_dart` のビルドフックがプリビルドを取得 |

## 依存を追加する

パッケージは、リリースのタグを指す git 依存として追加します。リリースはパッケージごとに `<package>-v<version>` のタグを付けます。パッケージの [**Releases**](https://github.com/cri-middleware/SSPlayerForFlutter/releases?q=ssplayer_flutter&expanded=true) からバージョンを選び、すべての `ref` の `<version>` をそれに置き換えます。

```yaml
dependencies:
  ssplayer_flutter:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssplayer_flutter-v<version>
      path: packages/ssplayer_flutter

dependency_overrides:
  ssruntime_dart:
    git:
      url: https://github.com/cri-middleware/SSPlayerForFlutter.git
      ref: ssplayer_flutter-v<version>
      path: packages/ssruntime_dart
```

続けて `flutter pub get` を実行します。

パッケージどうしはバージョンで依存し合っているので、依存したパッケージが引き込むこのリポジトリのパッケージは、すべて同じ形で `dependency_overrides` に書きます。どれも**同じ 1 つのタグ**から取ってください。タグには、リリースが一緒に検査したときのままの全パッケージが入っています。

| 依存するパッケージ | `dependency_overrides` に足すもの |
|---|---|
| `ssplayer_flutter` | `ssruntime_dart` |
| `ssplayer_flame` —— [Flame 連携](flame.md) | `ssplayer_flutter`、`ssruntime_dart` |
| `ssconverter_dart`（dev）—— `ssconvert` CLI、[アセットの準備](conversion.md) | —— |
| `ssgen_flutter`（dev）—— [ライブリロード](live-reload.md) | `ssplayer_flutter`、`ssgen_dart`、`ssconverter_dart`、`ssruntime_dart` |

!!! note "Web ターゲット"
    Web のランタイム（`packages/ssplayer_flutter/assets/runtime-web/`）はビルド生成物でリポジトリに含まれないため、git 依存には入っておらず、`loadSsRuntime()` が読み込むものがありません。Web 向けにビルドするときは、タグをクローンしてその中で `scripts/download-web-runtime.sh`（Windows では `.ps1`）を 1 回実行し、そのパッケージを `path:` で依存してください。`dependency_overrides` も `path:` で書きます。

!!! tip "コアを開発する場合"
    `libssruntime` を Rust ソースからビルドしたり Player 本体に手を入れる作業は、
    [ビルドガイド](../contributing/build.md) にまとめてあります —— アプリ利用者には不要です。

## 動作確認

同梱の example を起動するか、アプリで `ssplayer_flutter` を import して `flutter pub get` が解決しビルドが通ることを確認します。ネイティブライブラリは初回ビルド時に取得・埋め込みされ、追加設定は不要です。

## 次のステップ

- **まだ `.ssab` が無い** → [アセットの準備（`.sspj` → `.ssab`）](conversion.md) で SpriteStudio
  プロジェクトから生成します。
- **`.ssab` がある** → [クイックスタート](quickstart.md) でウィジェットに読み込んで再生します。
