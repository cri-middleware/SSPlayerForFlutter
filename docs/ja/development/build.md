# 🛠️ ビルドガイド

コア（Rust ランタイム / Player 本体）を開発する人向けです。**アプリ利用者・カスタマイズ勢には不要**
—— ネイティブライブラリは自動ダウンロードされます（[ネイティブランタイム](native-runtime.md)）。

## 前提

| ツール | いつ |
|---|---|
| Rust（`rustup`） | ネイティブをソースからビルドするとき |
| Flutter / Dart | 常時。下限は[インストール](../guide/install.md)にあります（古いと `flutter pub get` が落ちます） |
| `wasm-pack` ＋ `wasm32-unknown-unknown` ターゲット | web ランタイムを**ビルド**するときだけ（`cargo install wasm-pack`；`rustup target add wasm32-unknown-unknown`） |
| libclang | ffigen バインディングを再生成するときだけ（ffigen が読み込みます） |
| クロスターゲットごとの `rustup target add`。Android は `cargo install cargo-ndk` と NDK も | クロスビルドのときだけ（ターゲットは `ci.yml` の `Install targets and tools` の手順に一覧） |
| `flatc` | `.fbs` スキーマを再生成するときだけ |
| cbindgen | 手動導入不要 —— SDK の `build.rs` の build-dependency |

サブモジュール込みでクローンします（Brain のソースである SDK（[プレイヤーの構成](architecture.md)）が git サブモジュール）:

```bash
git submodule update --init --recursive
```

## ソースからビルド

```bash
# ネイティブをビルド + C ヘッダを各バインディングパッケージの native/include/ へコピー
scripts/build-runtime.sh              # 例: build-runtime.sh platform=macos build=release

# overall を起動（アセットとプラットフォームのランナーが無ければ生成）
scripts/run-macos.sh                  # [ssplayer] OK ＋ 画面にアニメーションが出れば成功
```

`run-linux.sh`・`run-ios.sh`・`run-android.sh`・`run-web.sh` も同じことを各ターゲットで行い、`example=<name>`・`--gpu`・`--watch`（後ろの 2 つは `overall` だけ）と `flutter run` の引数を受け付けます（一覧は `scripts/run-example.sh` のヘッダー）。
Windows は各スクリプトの `.ps1` を使います（起動は `run-windows.ps1`）。android・ios・universal の macOS（`arch=universal`）は `SpriteStudio-SDK/scripts/release-*` に委譲し、ホストターゲットと web の wasm は `build-runtime` 自身がビルドします。

## Web（開発者プレビュー）

web ターゲットは **`dart:ffi` も Native Assets も無い**ため、Brain を dylib として同梱できません。代わりに SDK の wasm-bindgen `web` ビルド（`.wasm` ＋ JS グルー）を作り、素の Flutter **アセット**として同梱し、Dart から `dart:js_interop` で駆動します。

**セットアップ — wasm ランタイムを用意**（ビルドするなら `wasm-pack` ＋ `wasm32-unknown-unknown` ターゲットが必要。固定リリースをダウンロードするなら Rust も `wasm-pack` も不要）:

```bash
scripts/build-runtime.sh platform=web        # 既定は build=debug（build=release も指定できます）
scripts/download-web-runtime.sh              # または固定リリース。Rust 不要
# → packages/ssplayer_flutter/assets/runtime-web/
#     {ssruntime.js, ssruntime_bg.wasm, ssruntime_bg.nosimd.wasm}
```

同じソースから wasm を 2 つビルドします: `ssruntime_bg.wasm`（SIMD・高速パス）と
`ssruntime_bg.nosimd.wasm`（安定 SIMD が無い WASM エンジン向けフォールバック、例: RPG ツクール MZ の
NW.js）。両者は **1 つ**の wasm-bindgen JS グルー（`ssruntime.js`）を共有し、`loadSsRuntime` が実行時に
`WebAssembly.validate` の SIMD プローブで適切なバイナリを選びます。

ネイティブ dylib と同様、wasm は **git-ignore** されます —— 各開発者が一度ビルドまたはダウンロードし、`git clean` で消えます。

**実行:**

```bash
scripts/run-web.sh             # 既定 CanvasKit レンダラ
scripts/run-web.sh --wasm      # Skwasm レンダラ（WebAssembly ビルドモード）
```

!!! warning "開発者プレビュー"
    web の**ランタイムバックエンド**の継ぎ目はランタイムの API で、`dart:ffi` のバックエンドと `dart:js_interop` のバックエンドを条件付き export で切り替えるため、Layer 2 は `dart:ffi` 無しでコンパイルできます。`flutter build web` / `flutter run -d chrome` はビルド・描画まで通り、全描画
    kind（Normal / Shape / Mesh / Effect / Instance）、シェーダ経路（PartColor / マスク）、framebuffer
    ブレンド、タイムラインイベントのコールバック（UserData / Signal / Audio）を CanvasKit 上で確認済みです。
    web では常に **Canvas（`drawVertices`）バックエンド**で描画し（`flutter_gpu` は web では使えません）、
    SIMD / nosimd の wasm はロード時に自動選択されます。Native Assets の build hook は web で正しく no-op
    します（設定不要）。

!!! note "初回の macOS ランナー"
    `examples/overall/macos/` が無ければ `scripts/run-macos.sh` が生成します。手で作るなら `bash examples/overall/scripts/setup-macos.sh` を使ってください。`flutter create` に加えて、example に必要な entitlement（ドラッグ＆ドロップと、ライブリロードの push のためのデバッグ限定のサンドボックス解除）を足します。素の `flutter create --platforms=macos .` には含まれません。

## コード生成（コミット済み・変更時に再生成）

生成コードは**コミット済み**なので、通常のチェックアウトも、パッケージに依存するアプリも、ffigen / flatc なしでビルドできます。対応する変更をしたら再生成してコミットします:

- **ffigen バインディング**（`lib/src/*_bindings.g.dart`）—— C-API を変えたら、先に `scripts/build-runtime.sh` を実行し（SDK のヘッダーを各バインディングパッケージの `native/include/` へコピーします。ffigen はこれを読みます）、そのあと `scripts/generate-ffigen-code.sh` を実行してコミット。生成は**スタンドアロン**で `build-runtime` は実行せず、ヘッダーが古いとエラーなしに古い C-API で再生成されます。
- **FlatBuffers**（`lib/src/ssab/*.g.dart` アセット形式・`ssruntime_dart` のランタイム fbs）——
  `.fbs` を変えたら `scripts/generate-fbs-code.sh`。flatc は reader ごとに必ずシリアライザも吐くので、スクリプトがその `*Builder` / `*ObjectBuilder` を `lib/` から追い出します（`lib/` 側でバッファを書く箇所は無く、`.ssab` は SpriteStudio ツールの出力、ランタイム fbs は dart:ffi 越しに読むだけ）。移動先はテストの補助コードで、フィクスチャの合成に使います。これで flatc 出力の約 2/3 が公開パッケージから外れます。

## 検証

```bash
# packages/ssplayer_flutter/ で
flutter analyze lib test
flutter test          # Brain は ssruntime_dart のビルドフック（Native Assets）が同梱。env 変数も framework も不要
```

アニメーションを再生するテストは `scripts/deploy-examples.sh` が書き出すパックを読み（`run-*` スクリプトも書き出します）、無いと skipped と報告するため、緑の結果が示すものは見かけより少なくなります。

ほかのパッケージと example も、それぞれのディレクトリで自分のテストを実行します。使うコマンドは下の表のとおりです。

| チェック | 場所 |
|---|---|
| Analyze + ユニット/描画テスト | `packages/ssplayer_flutter/` |
| L1 バインディング smoke | `packages/ssruntime_dart/`（`dart test`） |
| コンバータ smoke + CLI | `packages/ssconverter_dart/`（`dart test`） |
| Flame アダプタ | `packages/ssplayer_flame/`（`flutter test`） |
| 差分再変換 | `packages/ssgen_dart/`（`dart test`） |
| ライブリロード | `packages/ssgen_flutter/`（監視側、`flutter test`）。アプリ側は `packages/ssplayer_flutter/` |
| サンプルアプリ | `examples/overall/`・`examples/flame/`・`examples/part_following/`（`flutter test`） |
| macOS 埋め込み確認 | `examples/overall/` → `flutter build macos` → `*.app/Contents/Frameworks/` に `ssruntime.framework` |

## 変更したプレイヤーを使う

アプリの依存はリリース版を使うときと同じ書き方のまま、アプリが届くこの repo のパッケージ（import するものと、その下の `ssruntime_dart`）をすべてチェックアウトに上書きします。

```yaml
dependencies:
  ssplayer_flutter: ^7.0.0-beta.1
  ssplayer_flame: ^7.0.0-beta.1          # Flame を使うときだけ

dependency_overrides:
  ssplayer_flutter:
    path: <checkout>/packages/ssplayer_flutter
  ssplayer_flame:
    path: <checkout>/packages/ssplayer_flame
  ssruntime_dart:
    path: <checkout>/packages/ssruntime_dart
```

repo の中では、パッケージは pub workspace でお互いを見つけます。外からは、それぞれがほかのパッケージを版で指定しているので、`ssplayer_flutter` だけを `path:` で依存しても、pub は `ssruntime_dart` を（`ssplayer_flame` なら `ssplayer_flutter` を）版で探すため、pub は pub.dev のリリース版を取り、アプリは手元の変更をそのリリース版の上で、気づかないまま動かします。ネイティブライブラリは、`build-runtime` でチェックアウトの `packages/ssruntime_dart/native/libs/` を作ってあればそこから、無ければ指定の SDK リリースから取ります（[ネイティブランタイム](native-runtime.md)）。リリース版のプレイヤーのまま手を入れたランタイムを使うなら、アプリを自分の dylib に向けてください（[自前ビルドを差し込む](native-runtime.md#自前ビルドを差し込む)）。

## 実際のホストで確かめる

上のスイートでは見えないものと、その確かめ方です。

- **`flutter test` のエンドツーエンドの描画は、シェーダーの経路を通りません。** `flutter test` では `ui.FragmentProgram.fromAsset` がパッケージローカルのキーしか見つけられず、Canvas バックエンドは `packages/…` のキーを使うので、一度失敗するとそのままになります。剥がした PartColor・マスクのカバレッジのパス・`ss_*` のエフェクトは描かれません。`player.paint` → `toImage` のテストが緑でも、確かめているのはバッチのジオメトリだけです。残りはヘルパーの単体テストで押さえ、アプリを動かして見ます。
- **`ui.Image` や `ui.ImageShader` の寿命に触る変更は、`dart:io` を使わないテストを `flutter test --platform chrome <ファイル>` でも回します**（そのテストの冒頭のコメントがコマンドを示します）。 CanvasKit の `ImageShader.dispose` は画像まで dispose し、ネイティブと Skwasm は借りるだけです。VM のテストも CI も CanvasKit を通りません。
- **`flutter test --enable-impeller` でブレンドのエンドツーエンドのテストの `Sub` のケースが落ちるのは、エンジンの問題です。** framebuffer fetch の無い flutter_tester の Impeller は、先行する描画に重なる advanced blend を、その範囲の対角線に継ぎ目を付けて描きます。素の `dart:ui` の `drawRect` 3 つで再現し、macOS のアプリはきれいに描きます。CI は `--enable-impeller` を付けません。
- **`.frag` は読んで判断せず、Flutter のキャッシュにある `impellerc` で確かめます。** ランタイムエフェクトは何も言わずに失敗するためです。`--reflection-json` で各 uniform の `location`（Dart 側の `setFloat` を呼ぶ順）が分かり、`--sksl --json` で Web の経路が見えます。ローカルの `#include` は効き、宣言だけで使っていない uniform もスロットを持ち続けます。
- **GPU バックエンドは `flutter clean` の後で見ます。** clean ビルドでしか出ない不具合を、インクリメンタルビルドが隠したことがあります。`examples/overall` の integration test が実機で Canvas と比べ、前提はその冒頭にあります。GPU の経路のメモリは確保量ではなく RSS で言います。書き込んでいないページは常駐しないためです。
- **ちらつくフレームをヘッドレスで見つけます。** `SpriteStudioInternalPlayer` を直接動かし（`load` のあと、プレイヤーが描くときと同じ順で `updateMs`・`frameNo`・`getFrameData`）、毎 tick、`meshVertexOffsets()` / `meshVerticesX()` / `meshVerticesY()` からパーツのワールドのバウンディングボックスを記録して、前後の tick から飛び離れる tick を探します。
- **実機なしでライブリロードを確かめます。** `examples/overall`（`ssgen_flutter` と `SpriteStudio_Source/` を持つ唯一の example）で `dart run ssgen_flutter:sswatch --run -d chrome --device --web-browser-flag=--headless=new` を実行します。runner は `flutter create --platforms=<すでにあるすべてのプラットフォーム>` で作ってください。このコマンドは `.metadata` の一覧を置き換えるためで、`.metadata` は後で戻します。保存の代わりに `.sspj` の末尾に改行を足します（`touch` は監視に届きません）。`r` / `R` / `q` を送るには、`script` を通して渡します。`flutter run` が待つ端末を `script` が用意します。

4 つのレイヤーとそれぞれが持つものは[プレイヤーの構成](architecture.md)、ネイティブライブラリの解決と同梱は [ネイティブランタイム](native-runtime.md) にあります。
