# インストール

Flutter アプリに SpriteStudioPlayer for Flutter を追加する手順です。ネイティブランタイム
（`libssruntime`）は Dart の **Native Assets** で自動的に届くので、CocoaPods・framework・
`DynamicLibrary` のパス設定は不要で、Rust ツールチェーンも要りません。

## 対応環境

| 項目 | 内容 |
|---|---|
| Flutter / Dart | **Flutter 3.38+ / Dart 3.10+**（Native Assets が標準・既定で有効） |
| 動作確認済み | macOS · iOS · Android |
| その他 | Windows / Linux はソースからビルド、Web はロードマップ上 |
| ネイティブツールチェーン | 不要 —— Brain は `ssruntime_dart` のビルドフックがプリビルドを取得 |

## GitHub Releases のバンドルから導入（推奨）

pub.dev 公開までは、リリースバンドルから導入します。

1. [**GitHub Releases**](https://github.com/cri-middleware/SSPlayerForFlutter/releases/latest) から
   最新バンドルをダウンロードします。
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

!!! note "🚧 最初のリリース前"
    Releases からのダウンロードは最初のリリース公開後に有効になります。pub.dev 公開後は、
    `vendor/` の手順なしで通常の `ssplayer_flutter: ^x.y.z` に置き換わります。

[Flame](https://flame-engine.org/) でゲームを作る場合は、同じバンドルの `ssplayer_flame` も追加します
（[Flame 連携](flame.md)）。

!!! tip "コアを開発する場合"
    `libssruntime` を Rust ソースからビルドしたり Player 本体に手を入れる作業は、
    [ビルドガイド](../contributing/build.md) にまとめてあります —— アプリ利用者には不要です。

## 動作確認

同梱の example を起動するか、アプリで `ssplayer_flutter` を import して `flutter pub get` が解決し
ビルドが通ることを確認します。ネイティブライブラリは初回ビルド時に取得・埋め込みされ、追加設定は
不要です。

## 次のステップ

- **まだ `.ssab` が無い** → [CLI 変換（`.sspj` → `.ssab`）](../customize/conversion.md) で SpriteStudio
  プロジェクトから生成します。
- **`.ssab` がある** → [クイックスタート](quickstart.md) でウィジェットに読み込んで再生します。
