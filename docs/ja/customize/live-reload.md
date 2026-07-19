# ライブリロード

ライブリロードは編集→実機のループを閉じます。**SpriteStudio 7 で `.sspj` を保存すると、実行中の
アプリが更新されます** —— 変更したプロジェクトだけが再変換され、プレイヤーは再生状態（現在の
アニメとフレーム）を保ったまま再生を続けます。Flutter の開発ワークフローに相乗りするので、アニメ
編集がコードのホットリロードと同じ手数で反映されます。

!!! note "🚧 開発中 —— opt-in・未リリース"
    これは開発時専用ツールで、活発に開発中です。**既定でオフ**で、リリースビルドには一切影響しません。
    コマンドやフラグは最初のリリース前に変わる可能性があります。

## これは何

- [`ssgen_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_flutter)
  開発ツールが提供します（[変換](conversion.md)を駆動する `ssgen_dart` の上に構築）。
- プレイヤーのランタイム（`ssplayer_flutter`）は **converter を積みません** —— アプリに余分なものは
  一切載りません。コンバータは開発ツールの中だけに存在します。

## 仕組み

1. アプリ実行中、ホストの watcher が `SpriteStudio_Source/` ディレクトリを監視します。
2. 保存すると、変更されたプロジェクトが `.ssab` に再変換されます（mtime で stale 判定 —— 変わったものだけ）。
3. 新しいパックが実行中のアプリへ **VM Service 経由で直接 push** されます（キー操作不要・IDE
   デバッガと両立。デスクトップ／デバイスで同じ仕組み）。
    - **デスクトップ** —— 再変換した `.ssab` をアプリがその場で読み込みます。
    - **デバイス（iOS / Android）** —— テクスチャ内包の embedded `.ssab` をバイトで送ります
      （端末はホストのパスを読めないため）。
4. プレイヤーが `reload()` を呼び、再生状態を保ったままリソースを差し替えます。

## 有効化（レシピ）

1. アプリの `pubspec.yaml` に `ssgen_flutter` を追加。
2. `State` に `SsLiveReload` を mix-in し、プレイヤーと現在のパックを指定します（mixin は
   プレイヤーを push チャネルに登録するだけです）。

    ```dart
    class _MyPageState extends State<MyPage>
        with SingleTickerProviderStateMixin, SsLiveReload<MyPage> {
      @override SpriteStudioPlayer get ssPlayer => _player;
      @override String get ssAssetDir => 'assets/spritestudio/overall'; // 現パックの出力dir
      @override String get ssPack => _pack;                             // 現パック（.ssab stem）
      @override void ssOnLiveReloaded() => setState(() {});             // 任意（UI更新）
    }
    ```

3. `sswatch` を実行します。ツールも機構（VM Service push）も一つで、**起動の仕方だけ**選びます
   （`SS_LIVE_RELOAD` define で opt-in。define なしの素の `flutter run` はアートを再変換しません）。

    ```bash
    # 1コマンド（flutter run を内包し、define も自動注入）
    dart run ssgen_flutter:sswatch --run -d macos                 # デスクトップ
    dart run ssgen_flutter:sswatch --run -d <emulator> --device   # デバイス（embedded push）

    # IDE で起動する場合（デバッガを維持したまま attach）——
    #   起動側に --dart-define=SS_LIVE_RELOAD=true --vmservice-out-file=/tmp/ss.uri を付け、
    dart run ssgen_flutter:sswatch --vmservice-uri-file=/tmp/ss.uri   # デバイスは末尾に --device
    ```

    デバイスは端末で変換できないため、ホストで動く `sswatch` が embedded `.ssab` をバイトで送ります。

ソースプロジェクトは `SpriteStudio_Source/<project>/` に置きます。実際の編集を保存してください
（`touch` は同一バイトで見た目が変わらない上、watcher が拾わないこともあります）。

## プラットフォーム状況

| プラットフォーム | 経路 | 状況 |
|---|---|---|
| macOS デスクトップ | VM Service push（file） | end-to-end 検証済み |
| Android | VM Service push（embedded） | end-to-end 検証済み（emulator） |
| iOS | VM Service push（embedded） | 見込みあり・未検証 |
| Windows / Linux デスクトップ | VM Service push（file） | 見込みあり（OS 非依存）・未検証 |

単発の手動変換なら [アセットの準備](conversion.md) を参照してください。
