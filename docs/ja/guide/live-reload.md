# ♻️ ライブリロード

ライブリロードは編集→実機のループを閉じます。**SpriteStudio で `.sspj` を保存すると、実行中の
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
   デバッガと両立。デスクトップ／デバイス／Web で同じ仕組み）。
    - **デスクトップ** —— 再変換した `.ssab` をアプリがその場で読み込みます。
    - **デバイス（iOS / Android）** —— テクスチャ内包の embedded `.ssab` をバイトで送ります
      （端末はホストのパスを読めないため）。どのパックを送るかは規約で決まります ——
      アプリの **`ssAssetDir` の末尾セグメント**が、変換元の `<stem>.sspj` を指します。
      食い違うと `sswatch` が stderr で指摘し、一致するまで何も push されません。
    - **Web（`flutter run -d chrome`・デバッグ）** —— デバイスと同じくテクスチャ内包の embedded
      `.ssab` をバイトで送ります（VM Service 拡張は DWDS が中継）。デバッグの DDC のみ
      （`--wasm` や `flutter build web` は不可）。
4. プレイヤーが `reload()` を呼び、再生状態を保ったままリソースを差し替えます。
5. `--device` では push のあとに `assets/` も再変換します。バイト push は実行中の isolate に
   しか届かないため、これが無いと次の hot restart で起動時に同梱した絵まで巻き戻ります。
   保存ごとに変換が 1 回増えますが、デスクトップは再変換先が `assets/` なので不要です。

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
    dart run ssgen_flutter:sswatch --run -d chrome --device       # Web（embedded push・デバッグDDC）

    # IDE で起動する場合（デバッガを維持したまま attach）——
    #   起動側に --dart-define=SS_LIVE_RELOAD=true --vmservice-out-file=/tmp/ss.uri を付け、
    dart run ssgen_flutter:sswatch --vmservice-uri-file=/tmp/ss.uri   # デバイスは末尾に --device
    ```

    デバイスは端末で変換できないため、ホストで動く `sswatch` が embedded `.ssab` をバイトで送ります。

ソースプロジェクトは `SpriteStudio_Source/<project>/` に置きます。実際の編集を保存してください
（`touch` は同一バイトで見た目が変わらない上、watcher が拾わないこともあります）。

!!! warning "macOS デスクトップ: App Sandbox が file push を止めます"
    `file` push はコンテナ外のホストパスをアプリに渡すため、サンドボックス有効のデバッグ
    ビルドでは読めず、エラーも出ないまま `reloaded 0 player(s)` になります。
    `macos/Runner/DebugProfile.entitlements` の `com.apple.security.app-sandbox` を
    `false` にしてください（デバッグのみ。Release はサンドボックス有効のまま）。
    `--device` はバイトを VM Service で送るので影響ありません。

## プラットフォーム状況

| プラットフォーム | 経路 | 状況 |
|---|---|---|
| macOS デスクトップ | VM Service push（file） | end-to-end 検証済み |
| Android | VM Service push（embedded） | end-to-end 検証済み（emulator） |
| iOS | VM Service push（embedded） | 見込みあり・未検証 |
| Windows / Linux デスクトップ | VM Service push（file） | 見込みあり（OS 非依存）・未検証 |
| Web（`-d chrome`・デバッグ） | VM Service push（embedded・DWDS 中継） | デバッグ DDC のみ（`--wasm`/`build web` 不可） |

`--device` はターゲットの選択ではなく**ペイロードの選択**です。ホストのパスではなくバイトを送るだけ
なので、どのターゲットでも受け取れます。つまり `sswatch --run -d macos --device` を実行すれば、
デバイスを繋がずに embedded 経路まるごと —— ルーティング・転送・`reload()` —— を動かせます。実際
その方法で検証済みです（再生位置が保たれる: frame 1.68 → 2 回目の保存で 6.70、編集したプロジェクト
だけが再変換され、push と同時に `assets/` も更新される）。したがって未検証のままの行で未確認なのは
**そのターゲットの接続**であって push 自体ではありません。どれかが無反応なときは、まずそこを疑って
ください。

試すときは**実際の編集**を保存してください。`touch` は watcher に確実には届きません（macOS で確認:
イベントが 1 つも出ませんでした）。これはファイル監視側の性質で、リロードの問題ではありません。

単発の手動変換なら [アセットの準備](conversion.md) を参照してください。
