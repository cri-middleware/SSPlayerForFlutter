# 📥 インストール

Flutter アプリに SpriteStudioPlayer for Flutter を追加する手順です。ネイティブランタイム（`libssruntime`）は Dart の **Native Assets** で自動的に届くので、CocoaPods・framework・
`DynamicLibrary` のパス設定は不要で、Rust ツールチェーンも要りません。

## 対応環境

| 項目 | 内容 |
|---|---|
| Flutter / Dart | **Flutter 3.47+ / Dart 3.13+**（Native Assets は 3.38 から既定で有効。下限 3.47 は flutter_gpu バックエンドの要件）。この下限を書き下ろしているのはこのページで、実際に強制するのは `ssplayer_flutter` の `environment:` です（古いと `flutter pub get` が落ちます） |
| 動作確認済み | macOS · iOS · Android |
| その他 | Windows / Linux はソースからビルド、Web は開発者プレビュー |
| ネイティブツールチェーン | 不要 —— Brain は `ssruntime_dart` のビルドフックがプリビルドを取得 |

## インストール方法

パッケージを追加する方法は 2 通りあります。最初の pub.dev 公開までは、**GitHub Releases のバンドル**（方法 1）を使ってください。

### 方法 1 — GitHub Releases のバンドル（推奨・現在利用可能）

1. [**GitHub Releases**](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest) から最新バンドルをダウンロードします。
2. プロジェクト内（例: `vendor/`）に展開します。
3. アプリの `pubspec.yaml` に `path:` 依存として記述します。

```yaml
dependencies:
  ssplayer_flutter:
    # 展開したバンドルは packages/ レイアウトを保つので、推移依存の
    # ssruntime_dart も自動で解決されます。
    path: vendor/SSPlayerForFlutter/packages/ssplayer_flutter
```

4. `flutter pub get` を実行します。

[Flame](https://flame-engine.org/) でゲームを作る場合は、同じバンドルの `ssplayer_flame` も追加します（[Flame 連携](flame.md)）。

### 方法 2 — pub.dev から

公開後は、`vendor/` の手順なしで 1 行のホスト依存として記述できます。

```yaml
dependencies:
  ssplayer_flutter: ^x.y.z
```

!!! warning "🚧 工事中"
    パッケージはまだ pub.dev に公開されていないため、この方法は利用できません。当面は **方法 1** を使ってください。最初のリリース公開後に、実際のバージョンとともにこの節を記載します。

!!! tip "コアを開発する場合"
    `libssruntime` を Rust ソースからビルドしたり Player 本体に手を入れる作業は、
    [ビルドガイド](../contributing/build.md) にまとめてあります —— アプリ利用者には不要です。

## 動作確認

同梱の example を起動するか、アプリで `ssplayer_flutter` を import して `flutter pub get` が解決しビルドが通ることを確認します。ネイティブライブラリは初回ビルド時に取得・埋め込みされ、追加設定は不要です。

## 次のステップ

- **まだ `.ssab` が無い** → [アセットの準備（`.sspj` → `.ssab`）](conversion.md) で SpriteStudio
  プロジェクトから生成します。
- **`.ssab` がある** → [クイックスタート](quickstart.md) でウィジェットに読み込んで再生します。
