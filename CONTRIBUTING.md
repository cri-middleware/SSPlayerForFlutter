# Contributing to SSPlayerForFlutter

> [!IMPORTANT]
> We are not accepting pull requests until a Contributor License Agreement (CLA) is in place. Issues remain open for bug reports and requests.

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
- **Respect the layer boundaries:** Keep **L2** (`SpriteStudioInternalPlayer`) Widget-free so it stays reusable headless / from Flame / behind the `flutter_gpu` backend. L1 FFI bindings live in the sibling `ssruntime_dart` package. Do not leak Widget dependencies downward.
- **Performance in the hot path:** Avoid per-frame heap allocations during playback. Consume the runtime's SoA buffers and `DrawBatch` plans directly. Remember that `FrameData` and SoA pointers are **borrows valid only until the next `update`** — consume them within the frame, and release `Context` / `Resource` handles in `dispose`.
- **SDK separation:** The core animation logic lives in the `SpriteStudio-SDK` submodule (Rust `libssruntime`). Changes to the core/algorithm belong in the SDK repository; Flutter-specific rendering belongs in `packages/`.
- **Generated code is never hand-edited:** The ffigen `@Native` bindings (`lib/src/*_bindings.g.dart`) and the flatc accessors (`lib/src/ssab/*.g.dart`, `ssruntime_dart` fbs) are committed. Regenerate them with the provided scripts and commit the result. The flatc write side (`*Builder` / `*ObjectBuilder`) is deliberately kept out of `lib/` and generated into `packages/ssplayer_flutter/test/support/*_builders.g.dart` instead — import those shims when a test needs to synthesise a fixture buffer.

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
   [Conventional Commits](https://www.conventionalcommits.org/) (e.g. `feat(ssruntime_dart): …`).

## Development Environment

### Prerequisites
- Flutter / Dart — the floor is on [Installation](docs/en/guide/install.md) and enforced by `ssplayer_flutter`'s `environment:`, so `flutter pub get` is what tells you if yours is older.
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
Every other package and example has a suite of its own, run in its directory: `dart test` in `ssruntime_dart`, `ssconverter_dart` and `ssgen_dart`; `flutter test` in `ssplayer_flame`, `ssgen_flutter`, `examples/overall`, `examples/flame` and `examples/part_following`. Run the ones for what you touched. The tests that play an animation — most of `ssplayer_flutter`'s, and those in `ssplayer_flame`, `examples/flame` and `examples/part_following` — read the packs `scripts/deploy-examples.sh` writes, and report skipped without them.

### Documentation
Pages live as both `docs/en/<path>` and `docs/ja/<path>`; there is no fallback locale, so a page missing from one side is a nav entry pointing at nothing. If you edit one, build both locales before you finish: nothing builds the docs on a pull request, so that local build is the only gate.

```bash
scripts/prepare-docs.sh    # once: .venv + the pins in docs/requirements.txt
scripts/build-docs.sh      # English then Japanese, both --strict
```

Both locales, English first: it clears `site/`, which contains `site/ja`, so an English-only build
leaves no Japanese site at all. `mkdocs.base.yml`
sets `strict: true`; `zensical serve` validates nothing, `--strict` or not. `.ps1` twins on Windows,
`key=value` options and `--help` on both.

`scripts/build-pages.sh` builds the published tree: those two locales, then both web demos —
`examples/overall` at `site/demo/flutter/`, `examples/flame` at `site/demo/flame/`, with a chooser
at `site/demo/`. `pages.yml`'s build job **is** this script, so CI builds exactly
what a local run with the same options builds.

```bash
scripts/build-pages.sh serve=yes          # -> http://localhost:8000/SSPlayerForFlutter/
scripts/build-pages.sh sdk=build          # ... with the Brain compiled from the submodule
scripts/build-pages.sh demo=skip          # documentation only
scripts/build-pages.sh base=/ zip=yes     # the Cloudflare Pages upload: SSPlayerForFlutter-site.zip
```

*   **The demos are built here, never downloaded** — a Release carries no asset, so there is nothing
    to fetch. `sdk=` is the separate question of where the
    Brain comes from: `download`, the default and what CI uses, needs no Rust toolchain anywhere.
*   **`base=` is baked in** by `flutter build web --base-href`, so a demo built for one path 404s on
    another. `serve=yes` hangs `site/` off `.pages-preview/<repo>` and serves that, which is the
    only way to open the demo at the address it was built for.
*   **The examples' `web/` runners are git-ignored**, so the script runs `flutter create
    --platforms=web .` when one is missing — and puts `.metadata` back, because `flutter create`
    replaces its platform list rather than appending to it.
*   **`deploy-examples.sh` runs every time**: the `.ssab` both demos play are generated and
    git-ignored, and a stale pack is what nobody notices in a published demo.
*   **A second copy goes up by hand to Cloudflare Pages**, which serves a project at its own root —
    hence `base=/`. `zip=yes` packs `site/` with its contents at the archive root and refuses a tree
    built for a subpath. GitHub Pages stays canonical: the absolute URLs in the READMEs point there,
    and every demo link inside `docs/` is relative, which is what lets one build serve both hosts.

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

> [!IMPORTANT]
> コントリビューターライセンス契約（CLA）の準備が整うまで、プルリクエストは受け付けていません。バグ報告や要望は引き続き Issue で受け付けています。

SSPlayerForFlutter にご関心をお寄せいただき、ありがとうございます！ バグ報告、機能提案、ドキュメントの改善、コードの提供など、あらゆる形での貢献を歓迎します。

## 目次
- [行動規範](#行動規範)
- [貢献する方法](#貢献する方法)
- [開発環境のセットアップ](#開発環境のセットアップ)
- [コーディング規約](#コーディング規約)

## 行動規範
[CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) を参照してください。

## 貢献する方法

### 技術的制約と設計原則
本プレイヤーは、SpriteStudio-SDK の「Brain」に対する厳密な 4 層構成の「Body」です。高速性と移植性を保つため、以下の原則に従ってください。

- **Flutter/Dart のパラダイムを優先:** Flutter の描画（`RenderBox`、`Canvas.drawVertices`）、null 安全、`dispose` の徹底を活用してください。編集するファイルの既存 Dart スタイルに合わせてください。
- **レイヤー境界を尊重:** **L2**（`SpriteStudioInternalPlayer`）は Widget 非依存に保ち、headless / Flame / `flutter_gpu` バックエンドから再利用できるようにしてください。L1 の FFI バインディングは兄弟パッケージ `ssruntime_dart` にあります。下位層へ Widget 依存を漏らさないでください。
- **再生パスのパフォーマンス:** 再生中の毎フレームのヒープ確保は避けてください。ランタイムの SoA バッファと `DrawBatch` プランを直接消費します。`FrameData` と SoA ポインタは**次の `update` までのみ有効な借用**なので、フレーム内で消費し、`Context` / `Resource` ハンドルは `dispose` で解放してください。
- **SDK の分離:** コアのアニメーション計算ロジックは `SpriteStudio-SDK` サブモジュール（Rust `libssruntime`）にあります。コア / アルゴリズムの修正は SDK 側リポジトリへ、Flutter 固有の描画は `packages/` へ行ってください。
- **生成コードは手編集しない:** ffigen の `@Native` バインディング（`lib/src/*_bindings.g.dart`）と flatc アクセサ（`lib/src/ssab/*.g.dart`、`ssruntime_dart` の fbs）はコミット済みです。提供スクリプトで再生成してコミットしてください。flatc の書き込み側（`*Builder` / `*ObjectBuilder`）は意図的に `lib/` から外し、`packages/ssplayer_flutter/test/support/*_builders.g.dart` に生成しています。テストでフィクスチャのバッファを組むときはそちらを import してください。

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
   [Conventional Commits](https://www.conventionalcommits.org/)（例: `feat(ssruntime_dart): …`）を使用してください。

## 開発環境のセットアップ

### 前提条件
- Flutter / Dart —— 下限は[インストール](docs/ja/guide/install.md)にあり、`ssplayer_flutter` の `environment:` が強制します（古いと `flutter pub get` が落ちます）。
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
ほかのパッケージと example もそれぞれ自分のテストを持っており、各ディレクトリで実行します。`ssruntime_dart`・`ssconverter_dart`・`ssgen_dart` は `dart test`、`ssplayer_flame`・`ssgen_flutter`・`examples/overall`・`examples/flame`・`examples/part_following` は `flutter test` です。触ったものに対応するテストを実行してください。アニメーションを再生するテスト（`ssplayer_flutter` の大半と、`ssplayer_flame`・`examples/flame`・`examples/part_following` のもの）は `scripts/deploy-examples.sh` が書き出すパックを読むため、パックが無いと skipped として報告します。

### ドキュメント
ページは `docs/en/<path>` と `docs/ja/<path>` の両方に存在します。フォールバックロケールは無いため、片方に欠けたページは行き先の無い nav エントリになります。編集したら、仕上げる前に両ロケールをビルドしてください。プルリクエストでは docs はビルドされないため、手元のビルドが唯一のゲートです。

```bash
scripts/prepare-docs.sh    # 一度だけ: .venv と docs/requirements.txt のピン
scripts/build-docs.sh      # 英語 → 日本語の順に、どちらも --strict
```

必ず両ロケールを、英語を先に。英語ビルドは `site/`（その中に `site/ja` がある）を消すため、英語だけ建てると日本語サイトは残らず消えます。`mkdocs.base.yml` が `strict: true` を設定します。`zensical serve` は `--strict` を付けても何も検証しません。Windows は `.ps1` 双子、どちらも
`key=value` オプションと `--help` を取ります。

`scripts/build-pages.sh` が公開ツリーです。上記 2 ロケールに続けて Web デモ 2 本 — `examples/overall`
を `site/demo/flutter/`、`examples/flame` を `site/demo/flame/`、選択ページを `site/demo/` に — を建てます。`pages.yml` のビルドジョブはこのスクリプトなので、CI が建てるものは、同じオプションで手元で建てたものと一致します。

```bash
scripts/build-pages.sh serve=yes          # -> http://localhost:8000/SSPlayerForFlutter/
scripts/build-pages.sh sdk=build          # ... Brain を submodule からビルドする
scripts/build-pages.sh demo=skip          # ドキュメントのみ
scripts/build-pages.sh base=/ zip=yes     # Cloudflare Pages 用: SSPlayerForFlutter-site.zip
```

*   **デモはここでビルドします。ダウンロードではありません。** Release は asset を持たないため、取得できるものがありません。`sdk=` は Brain の入手元という別の話で、既定かつ CI が使う `download` なら Rust ツールチェーンは一切不要です。
*   **`base=` はビルド時に焼き込まれます**（`flutter build web --base-href`）。あるパス用に建てたデモは別のパスでは 404 します。`serve=yes` が `site/` を `.pages-preview/<repo>` に吊るして配信するのは、建てたときのアドレスでデモを開く唯一の方法だからです。
*   **examples の `web/` ランナーは git 管理外**なので、無ければスクリプトが `flutter create
    --platforms=web .` を実行し、そのあと `.metadata` を戻します（`flutter create` はプラットフォーム一覧を追記ではなく置き換えるため）。
*   **`deploy-examples.sh` は毎回走ります。** デモが再生する `.ssab` は生成物で git 管理外です。古い
    pack は公開デモで誰も気づかない類の事故です。
*   **もう 1 部を手作業で Cloudflare Pages に上げます。** あちらはプロジェクトを自身のルートで配信するので `base=/` が要ります。`zip=yes` は `site/` の中身をアーカイブのルートに置いて固め、サブパス用に建てたツリーなら拒否します。正典は GitHub Pages 側です（README の絶対 URL はそちらを指し、`docs/`
    内のデモリンクはすべて相対なので、1 回のビルドが両方のホストで正しく動きます）。

## コーディング規約

### Dart のガイドライン
- [Effective Dart](https://dart.dev/effective-dart) と、編集するファイルの既存スタイル（命名・null 安全・`dispose` の徹底）に従ってください。
- `flutter analyze` をクリーンに保ってください。
- FFI オブジェクトを安全に扱ってください（`Context` / `Resource` を解放し、借用した `FrameData` / SoA ポインタはフレーム内で消費する。`NativeFinalizer` はあくまで保険です）。
- 生成コード（`*.g.dart`）は手編集せず、スクリプトで再生成してコミットしてください。

---
本プロジェクトに貢献することで、あなたの貢献がプロジェクトの [LICENSE.md](./LICENSE.md) の下でライセンスされることに同意したものとみなされます。
