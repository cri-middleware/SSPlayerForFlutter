# ♻️ ライブリロード

ライブリロードは編集→実機のループを閉じます。**SpriteStudio で `.sspj` を保存すると、実行中のアプリが更新されます** —— 変更したプロジェクトだけが再変換され、プレイヤーは再生状態（現在のアニメとフレーム）を保ったまま再生を続けます。Flutter の開発ワークフローに相乗りするので、アニメ編集がコードのホットリロードと同じ手数で反映されます。

## これは何

- 監視するのは [`ssgen_flutter`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssgen_flutter) 開発ツールの `sswatch` です（[変換](conversion.md)を駆動する `ssgen_dart` の上に構築）。**dev dependency** で、アプリのコードからは import しません。
- プレイヤーのランタイム（`ssplayer_flutter`）は **converter を積みません**。コンバータは `sswatch` の中だけにあり、アプリが持つのは push を受け取る側だけです。
- **デバッグビルド専用で、既定はオフ**です。受け取る側は `SS_LIVE_RELOAD` define（後述）を付けて起動したデバッグビルドでだけ動き、それ以外のビルド（リリースビルドを含む）からはコンパイル時に消えます。

## 仕組み

1. アプリ実行中、ホストの watcher が `SpriteStudio_Source/` ディレクトリを監視します。
2. 保存すると、変更されたプロジェクトが `.ssab` に再変換されます（mtime で stale 判定 —— 変わったものだけ）。
3. 新しいパックが実行中のアプリへ **VM Service 経由で直接 push** されます（キー操作不要・IDE
   デバッガと両立。デスクトップ／デバイス／Web で同じ仕組み）。
    - **デスクトップ** —— 再変換した `.ssab` をアプリがディスクから読み込みます。
    - **デバイス（iOS / Android）** —— テクスチャ内包の embedded `.ssab` をバイトで送ります（端末はホストのパスを読めないため）。どのパックを送るかは規約で決まります ——
      **パックのアセットキーの末尾のフォルダ**（`assets/spritestudio/Ringo/Ringo.ssab` なら `Ringo`）が、変換元の `<stem>.sspj` を指します。食い違うと `sswatch` が stderr で指摘し、一致するまで何も push されません。
    - **Web（`flutter run -d chrome`・デバッグ）** —— デバイスと同じくテクスチャ内包の embedded
      `.ssab` をバイトで送ります（VM Service 拡張は DWDS が中継）。デバッグビルドのみです。`--wasm` のビルドは VM Service を持たないので、`sswatch --run` は `--wasm` を起動前に断ります。
4. プレイヤーが `reload()` を呼び、再生状態を保ったままリソースを差し替えます。失敗した場合は、アプリ側の例外を `sswatch` が stderr に出します。
5. `--device` では push のあとに `assets/` も再変換します。バイト push は実行中の isolate にしか届かないため、これが無いと次の hot restart で起動時に同梱した絵まで巻き戻ります。保存ごとに変換が 1 回増えますが、デスクトップは再変換先が `assets/` なので不要です。

## 有効化（レシピ）

1. アプリの `dev_dependencies` に `ssgen_flutter` を追加します: `flutter pub add --dev ssgen_flutter`（[インストール](install.md)）。
2. アプリ側には何も書きません。アセットキーでパックを読み込んだプレイヤー —— すべての `SpriteStudioAnimation` と、`loadAsset` した `SpriteStudioPlayer` —— は自分で push を受け取ります。
3. `sswatch` を実行します。ツールも機構（VM Service push）も一つで、**起動の仕方だけ**選びます（`SS_LIVE_RELOAD` define で opt-in。define なしの素の `flutter run` はアートを再変換しません）。

    ```bash
    # 1 コマンド（flutter run を内包し、define も自動注入）
    dart run ssgen_flutter:sswatch --run -d macos                 # デスクトップ（macOS は先にデバッグの App Sandbox を切る。下の警告を参照）
    dart run ssgen_flutter:sswatch --run -d <emulator> --device   # デバイス（embedded push）
    dart run ssgen_flutter:sswatch --run -d chrome --device       # Web（embedded push・デバッグ DDC）

    # IDE で起動する場合（デバッガを維持したまま attach）——
    #   起動側に --dart-define=SS_LIVE_RELOAD=true --vmservice-out-file=/tmp/ss.uri を付け、
    dart run ssgen_flutter:sswatch --vmservice-uri-file=/tmp/ss.uri   # デバイスは末尾に --device
    ```

    デバイスは端末で変換できないため、ホストで動く `sswatch` が embedded `.ssab` をバイトで送ります。
    `--run` は端末をそのまま `flutter run` に渡すので、`r`・`R`・`q` もいつもどおり使えます。

ソースプロジェクトは `SpriteStudio_Source/<project>/` に置きます。`sswatch` は、実行したディレクトリ（アプリのルート）を基準に動き、`SpriteStudio_Source/` を監視して `assets/spritestudio/<project>/` に書き出します。別のフォルダを使うときは、そこに `spritestudio.yaml`（`source:`・`output:`・`embedded:`）を置くか、`--project-root=<dir>` で別のルートを指定します。実際の編集を保存してください（`touch` は同一バイトで見た目が変わらない上、watcher が拾わないこともあります）。

> [!TIP] バイト列から読み込んだプレイヤーや、リロードに反応したい画面
> ダウンロードや実行時に選んだファイルなど、バイト列から読み込んだプレイヤーには、見つけてもらうためのアセットキーがありません。所有する `State` に `SsLiveReload` を mix-in して、パックを指定してください。同じ mixin で、リロードに合わせて画面を更新したり、`sswatch` の管理外のものを表示している間は止めたりもできます。自分で登録したプレイヤーと同じものを指定した場合は、mixin のほうが使われます。
>
> ```dart
> class _MyPageState extends State<MyPage>
>     with SingleTickerProviderStateMixin, SsLiveReload<MyPage> {
>   @override SpriteStudioPlayer get ssPlayer => _player;
>   @override String get ssAssetDir => 'assets/spritestudio/overall'; // 現パックの出力 dir
>   @override String get ssPack => _pack;                             // 現パック（.ssab stem）
>   @override void ssOnLiveReloaded() => setState(() {});             // 任意（UI 更新）
> }
> ```

> [!WARNING] macOS デスクトップ: App Sandbox が file push を止めます
> `file` push はコンテナ外のホストパスをアプリに渡すため、サンドボックス有効のデバッグビルドでは読めず、エラーも出ないまま `reloaded 0 player(s)` になります。
> `macos/Runner/DebugProfile.entitlements` の `com.apple.security.app-sandbox` を
> `false` にしてください（デバッグのみ。Release はサンドボックス有効のまま）。
> `--device` はバイトを VM Service で送るので影響ありません。

## プラットフォーム状況

| プラットフォーム | 経路 | 状況 |
|---|---|---|
| macOS デスクトップ | VM Service push（file） | 対応 |
| Android | VM Service push（embedded） | 対応 |
| iOS | VM Service push（embedded） | 対応 |
| Web（`-d chrome`・デバッグ） | VM Service push（embedded・DWDS 中継） | 対応 |
| `--wasm`・`--release`・`--profile` | — | 不可。前の 2 つは VM Service が無く、profile ビルドには push チャネルがありません。`sswatch --run` は起動前に断ります |

`--device` はターゲットの選択ではなく**ペイロードの選択**です。ホストのパスではなくバイトを送るだけなので、どのターゲットでも受け取れます。つまり `sswatch --run -d macos --device` を実行すれば、デバイスを繋がずに embedded 経路まるごと —— ルーティング・転送・`reload()` —— を動かせます。
push が壊れているのか、単にターゲットが繋がっていないだけなのかを切り分けるのに使えます。

試すときは**実際の編集**を保存してください。`touch` は watcher に確実には届きません（イベントが 1 つも出ないことがあります）。これはファイル監視側の性質で、リロードの問題ではありません。

単発の手動変換なら [アセットの準備](conversion.md) を参照してください。
