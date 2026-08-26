# 🛠️ ビルドガイド

コア（Rust ランタイム / Player 本体）を開発する人向けです。**アプリ利用者・カスタマイズ勢には不要**
—— ネイティブライブラリは自動ダウンロードされます（[ネイティブランタイム](native-runtime.md)）。

## 前提

| ツール | いつ |
|---|---|
| Rust（`rustup`） | ネイティブをソースからビルドするとき |
| Flutter 3.47+ / Dart 3.13+ | 常時（Native Assets は 3.38 から既定で有効。下限 3.47 は flutter_gpu バックエンドの要件） |
| `wasm-pack` ＋ `wasm32-unknown-unknown` ターゲット | **web** ターゲットのときだけ（`cargo install wasm-pack`；`rustup target add wasm32-unknown-unknown`） |
| `flatc` | `.fbs` スキーマを再生成するときだけ |
| cbindgen | 手動導入不要 —— SDK の `build.rs` の build-dependency |

サブモジュール込みでクローンします（Brain のソースである SDK が git サブモジュール）:

```bash
git submodule update --init --recursive
```

## ソースからビルド

```bash
# ネイティブをビルド + C ヘッダを各バインディングパッケージの native/include/ へコピー
scripts/build-runtime.sh              # 例: build-runtime.sh platform=macos build=release

# アセット生成 → example 起動
scripts/deploy-examples.sh
cd examples/overall && flutter run    # [ssplayer] OK ＋ 画面にアニメーションが出れば成功
```

Windows は各スクリプトの `.ps1` を使います。android / ios のクロスビルドは
`SpriteStudio-SDK/scripts/release-*` に委譲します（`build-runtime` 自体はホストターゲットを直接ビルド）。

## Web（開発者プレビュー）

web ターゲットは **`dart:ffi` も Native Assets も無い**ため、Brain を dylib として同梱できません。
代わりに SDK の wasm-bindgen `web` ビルド（`.wasm` ＋ JS グルー）を作り、素の Flutter **アセット**として
同梱し、Dart から `dart:js_interop` で駆動します。

**セットアップ — wasm ランタイムをビルド**（`wasm-pack` ＋ `wasm32-unknown-unknown` ターゲットが必要）:

```bash
scripts/build-runtime.sh platform=web        # ＋ build=release（既定）| debug
# → packages/ssplayer_flutter/assets/runtime-web/
#     {ssruntime.js, ssruntime_bg.wasm, ssruntime_bg.nosimd.wasm}
```

同じソースから wasm を2つビルドします: `ssruntime_bg.wasm`（SIMD・高速パス）と
`ssruntime_bg.nosimd.wasm`（安定 SIMD が無い WASM エンジン向けフォールバック、例: RPG ツクール MZ の
NW.js）。両者は **1つ**の wasm-bindgen JS グルー（`ssruntime.js`）を共有し、`loadSsRuntime` が実行時に
`WebAssembly.validate` の SIMD プローブで適切なバイナリを選びます。

ネイティブ dylib と同様、ビルド済み wasm は **git-ignore** されます —— 各開発者が上記で（再）ビルドし、
`git clean` で消えます。

**実行:**

```bash
cd examples/overall
flutter run -d chrome          # 既定 CanvasKit レンダラ
flutter run -d chrome --wasm   # Skwasm レンダラ（WebAssembly ビルドモード）
```

!!! warning "🚧 開発者プレビュー"
    web の**ランタイムバックエンド**は配線済みです。継ぎ目は `lib/src/runtime_api.dart` で、`dart:ffi`
    バックエンド（`native_runtime.dart`）と `dart:js_interop` バックエンド（`web_runtime.dart`）を
    条件付き export で切り替えるため、Layer 2（`internal_player.dart` ほか）は `dart:ffi` 無しで
    コンパイルできます。`flutter build web` / `flutter run -d chrome` はビルド・描画まで通り、全描画
    kind（Normal / Shape / Mesh / Effect / Instance）、シェーダ経路（PartColor / マスク）、framebuffer
    ブレンド、タイムラインイベントのコールバック（UserData / Signal / Audio）を CanvasKit 上で確認済みです。
    web は **デバッグ用途の `drawVertices` 経路**の位置づけ（`flutter_gpu` へ向かうのは mobile / desktop）で、
    SIMD / nosimd の wasm はロード時に自動選択されます。Native Assets の build hook は web で正しく no-op
    します（設定不要）。

!!! note "初回の macOS ランナー"
    `examples/overall/macos/` が無ければ一度だけ生成:
    `cd examples/overall && flutter create --platforms=macos .`

## コード生成（コミット済み・変更時に再生成）

生成コードは**コミット済み**なので、通常のチェックアウトや pub.dev 利用者は ffigen / flatc なしで
ビルドできます。対応する変更をしたら再生成してコミットします:

- **ffigen バインディング**（`lib/src/*_bindings.g.dart`）—— C-API を変えたら
  `scripts/generate-ffigen-code.sh` を実行してコミット。**スタンドアロン**で、`build-runtime` は実行
  しません。
- **FlatBuffers**（`lib/src/ssab/*.g.dart` アセット形式・`ssruntime_dart` のランタイム fbs）——
  `.fbs` を変えたら `scripts/generate-fbs-code.sh`。flatc は
  reader ごとに必ずシリアライザも吐くので、`scripts/strip_fbs_builders.dart` がその
  `*Builder` / `*ObjectBuilder` を `lib/` から追い出します（`lib/` 側でバッファを書く箇所は無く、
  `.ssab` は SpriteStudio ツールの出力、ランタイム fbs は dart:ffi 越しに読むだけ）。移動先は
  `packages/ssplayer_flutter/test/support/*_builders.g.dart` で、テストのフィクスチャ合成に使います。
  これで flatc 出力の約 2/3 が公開パッケージから外れます。

## 検証

```bash
# packages/ssplayer_flutter/ で
flutter analyze lib test
flutter test          # Native Assets が hook/build.dart 経由で Brain を同梱。env 変数も framework も不要
```

`ssruntime_dart` / `ssconverter_dart` は各パッケージで `dart test`。

| チェック | 場所 |
|---|---|
| Analyze + ユニット/描画テスト | `packages/ssplayer_flutter/` |
| L1 バインディング smoke | `packages/ssruntime_dart/`（`dart test`） |
| コンバータ smoke + CLI | `packages/ssconverter_dart/`（`dart test`） |
| macOS 埋め込み確認 | `examples/overall/` → `flutter build macos` → `*.app/Contents/Frameworks/` に `ssruntime.framework` |

FFI ポインタ寿命・`updateFlag` の罠・UV ピクセル座標・Native Assets 同梱など、実装規約と要注意点は
[`AGENTS.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/AGENTS.md) を参照してください。
