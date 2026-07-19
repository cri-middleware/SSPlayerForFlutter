# Contributing to SSPlayerForFlutter

Thank you for your interest in contributing to SSPlayerForFlutter! We welcome all kinds of contributions, including bug reports, feature requests, documentation improvements, and code contributions.

## Table of Contents
- [Code of Conduct](#code-of-conduct)
- [How Can I Contribute?](#how-can-i-contribute)
- [Development Environment](#development-environment)
- [Coding Standards](#coding-standards)

## Code of Conduct
Please refer to [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

## How Can I Contribute?

### Technical Constraints & Guiding Principles
This player is a strict 4-layer "Body" over the SpriteStudio-SDK "Brain". To keep it fast and portable, please follow these principles:

- **Flutter/Dart idioms first:** Use Flutter's rendering (`RenderBox`, `Canvas.drawVertices`), null-safety, and `dispose` discipline. Match the existing Dart style in the files you touch.
- **Respect the layer boundaries:** Keep **L2** (`SpriteStudioInternalPlayer`) Widget-free so it stays reusable headless / from Flame / a future `flutter_gpu` backend. L1 FFI bindings live in the sibling `ssruntime_dart` package. Do not leak Widget dependencies downward.
- **Performance in the hot path:** Avoid per-frame heap allocations during playback. Consume the runtime's SoA buffers and `DrawBatch` plans directly. Remember that `FrameData` and SoA pointers are **borrows valid only until the next `update`** — consume them within the frame, and release `Context` / `Resource` handles in `dispose`.
- **SDK separation:** The core animation logic lives in the `SpriteStudio-SDK` submodule (Rust `libssruntime`). Changes to the core/algorithm belong in the SDK repository; Flutter-specific rendering belongs in `packages/`.
- **Generated code is never hand-edited:** The ffigen `@Native` bindings (`lib/src/*_bindings.g.dart`) and the flatc accessors (`lib/src/ssab/*.g.dart`, `ssruntime_dart` fbs) are committed. Regenerate them with the provided scripts and commit the result.

### Reporting Bugs
If you find a bug, please open a GitHub Issue and include:
- A clear, descriptive title.
- Steps to reproduce.
- Your Flutter / Dart version (`flutter --version`) and OS / target platform.
- Expected vs. actual behavior.

*Note: If you need to send proprietary `.sspj` projects to reproduce the bug, please do not attach them to public issues. See [SUPPORT.md](./SUPPORT.md) for how to contact us privately.*

### Pull Requests
1. Fork the repository and create your branch from `main`.
2. Ensure your code follows the existing Dart style and the layer boundaries above.
3. Run `flutter analyze` and the tests locally (see below).
4. Submit a Pull Request targeting `main` with a clear description of the changes. Use
   [Conventional Commits](https://www.conventionalcommits.org/) (e.g. `feat(ssruntime_dart): …`) — the
   release tooling derives version bumps from them.

## Development Environment

### Prerequisites
- Flutter 3.38+ / Dart 3.10+ (native assets is stable and default-on).
- A Rust toolchain (`rustup`) — required to build `libssruntime` / `libssconverter` from source.
- `flatc` — only when regenerating a `.fbs` schema. (cbindgen is a build-dependency of the SDK's `build.rs`; no separate install.)
- The `SpriteStudio-SDK` submodule: `git submodule update --init --recursive`.

For the complete build guide, see [docs/en/contributing/build.md](./docs/en/contributing/build.md).

### Build from source
```bash
# 1. Build the native libraries + copy the C headers (Requires Rust)
scripts/build-runtime.sh

# 2. Generate example assets, then run the example
scripts/deploy-examples.sh
cd examples/overall && flutter run    # expect [ssplayer] OK
```
Windows uses the `.ps1` variant of each script. After a C-API change, regenerate the bindings with `scripts/generate-ffigen-code.sh` and commit; after a `.fbs` change, run `scripts/generate-fbs-code.sh`.

### Test
```bash
# in packages/ssplayer_flutter/
flutter analyze lib test
flutter test          # native assets bundles the Brain via hook/build.dart — no env vars
```
`ssruntime_dart` and `ssconverter_dart` each run `dart test` in their own package.

## Coding Standards

### Dart Guidelines
- Follow [Effective Dart](https://dart.dev/effective-dart) and the existing style in the files you touch (naming, null-safety, `dispose` discipline).
- Keep `flutter analyze` clean.
- Handle FFI objects safely: dispose `Context` / `Resource`, and consume borrowed `FrameData` / SoA pointers within the frame (a `NativeFinalizer` is only a backstop).
- Do not hand-edit generated code (`*.g.dart`); regenerate via the scripts and commit.

---
By contributing to this project, you agree that your contributions will be licensed under the project's [LICENSE.md](./LICENSE.md).

<br>
<br>

---

# SSPlayerForFlutter への貢献について

SSPlayerForFlutter にご関心をお寄せいただき、ありがとうございます！ バグ報告、機能提案、ドキュメントの改善、コードの提供など、あらゆる形での貢献を歓迎します。

## 目次
- [行動規範](#行動規範)
- [貢献する方法](#貢献する方法-1)
- [開発環境のセットアップ](#開発環境のセットアップ)
- [コーディング規約](#コーディング規約)

## 行動規範
[CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) を参照してください。

## 貢献する方法

### 技術的制約と設計原則
本プレイヤーは、SpriteStudio-SDK の「Brain」に対する厳密な 4 層構成の「Body」です。高速性と移植性を保つため、以下の原則に従ってください。

- **Flutter/Dart のパラダイムを優先:** Flutter の描画（`RenderBox`、`Canvas.drawVertices`）、null 安全、`dispose` の徹底を活用してください。編集するファイルの既存 Dart スタイルに合わせてください。
- **レイヤー境界を尊重:** **L2**（`SpriteStudioInternalPlayer`）は Widget 非依存に保ち、headless / Flame / 将来の `flutter_gpu` バックエンドから再利用できるようにしてください。L1 の FFI バインディングは兄弟パッケージ `ssruntime_dart` にあります。下位層へ Widget 依存を漏らさないでください。
- **再生パスのパフォーマンス:** 再生中の毎フレームのヒープ確保は避けてください。ランタイムの SoA バッファと `DrawBatch` プランを直接消費します。`FrameData` と SoA ポインタは**次の `update` までのみ有効な借用**なので、フレーム内で消費し、`Context` / `Resource` ハンドルは `dispose` で解放してください。
- **SDK の分離:** コアのアニメーション計算ロジックは `SpriteStudio-SDK` サブモジュール（Rust `libssruntime`）にあります。コア / アルゴリズムの修正は SDK 側リポジトリへ、Flutter 固有の描画は `packages/` へ行ってください。
- **生成コードは手編集しない:** ffigen の `@Native` バインディング（`lib/src/*_bindings.g.dart`）と flatc アクセサ（`lib/src/ssab/*.g.dart`、`ssruntime_dart` の fbs）はコミット済みです。提供スクリプトで再生成してコミットしてください。

### バグの報告
バグを発見した場合は、GitHub Issue に以下の情報を含めてください。
- 簡潔で分かりやすいタイトル
- 再現手順
- 利用している Flutter / Dart のバージョン（`flutter --version`）と OS / 対象プラットフォーム
- 期待される動作と実際の動作

*注: バグ再現のために非公開の `.sspj` プロジェクトデータ等を提供いただける場合は、公開 Issue には添付せず、[SUPPORT.md](./SUPPORT.md) に記載のヘルプセンターをご利用ください。*

### プルリクエスト
1. リポジトリをフォークし、`main` ブランチから作業用ブランチを作成してください。
2. 既存の Dart スタイルと上記のレイヤー境界に従ってコードを記述してください。
3. ローカルで `flutter analyze` とテストを実行してください（下記参照）。
4. `main` ブランチに向けて、変更内容を明確に記載したプルリクエストを送信してください。コミットは
   [Conventional Commits](https://www.conventionalcommits.org/)（例: `feat(ssruntime_dart): …`）を使用してください —— リリースツールがこれをもとにバージョンを決定します。

## 開発環境のセットアップ

### 前提条件
- Flutter 3.38+ / Dart 3.10+（Native Assets が標準・既定で有効）。
- Rust ツールチェイン（`rustup`）—— `libssruntime` / `libssconverter` をソースからビルドする場合に必要です。
- `flatc` —— `.fbs` スキーマを再生成するときのみ。（cbindgen は SDK の `build.rs` の build-dependency なので個別導入は不要です。）
- `SpriteStudio-SDK` サブモジュール: `git submodule update --init --recursive`。

完全なビルド手順については、[docs/ja/contributing/build.md](./docs/ja/contributing/build.md) を参照してください。

### ソースからのビルド
```bash
# 1. ネイティブライブラリのビルド + C ヘッダのコピー（Rust 環境が必要です）
scripts/build-runtime.sh

# 2. アセット生成 → example 起動
scripts/deploy-examples.sh
cd examples/overall && flutter run    # [ssplayer] OK を確認
```
Windows は各スクリプトの `.ps1` を使います。C-API を変えたら `scripts/generate-ffigen-code.sh` でバインディングを再生成してコミット、`.fbs` を変えたら `scripts/generate-fbs-code.sh` を実行してください。

### テスト
```bash
# packages/ssplayer_flutter/ で
flutter analyze lib test
flutter test          # Native Assets が hook/build.dart 経由で Brain を同梱。env 変数は不要
```
`ssruntime_dart` / `ssconverter_dart` は各パッケージで `dart test` を実行します。

## コーディング規約

### Dart のガイドライン
- [Effective Dart](https://dart.dev/effective-dart) と、編集するファイルの既存スタイル（命名・null 安全・`dispose` の徹底）に従ってください。
- `flutter analyze` をクリーンに保ってください。
- FFI オブジェクトを安全に扱ってください（`Context` / `Resource` を解放し、借用した `FrameData` / SoA ポインタはフレーム内で消費する。`NativeFinalizer` はあくまで保険です）。
- 生成コード（`*.g.dart`）は手編集せず、スクリプトで再生成してコミットしてください。

---
本プロジェクトへの貢献は、プロジェクトの [LICENSE.md](./LICENSE.md) に同意したものとみなされます。
