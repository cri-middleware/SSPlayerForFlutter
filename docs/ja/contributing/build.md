# ビルドガイド

コア（Rust ランタイム / Player 本体）を開発する人向けです。**アプリ利用者・カスタマイズ勢には不要**
—— ネイティブライブラリは自動ダウンロードされます（[ネイティブランタイム](../customize/native-runtime.md)）。

## 前提

| ツール | いつ |
|---|---|
| Rust（`rustup`） | ネイティブをソースからビルドするとき |
| Flutter 3.38+ / Dart 3.10+ | 常時（Native Assets が標準・既定で有効） |
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

Windows は各スクリプトの `.ps1` を使います。android / ios / web のクロスビルドは
`SpriteStudio-SDK/scripts/release-*` に委譲します（`build-runtime` 自体はホストターゲットを直接ビルド）。

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
  `.fbs` を変えたら `scripts/generate-fbs-code.sh`。

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
