# Releasing SSPlayerForFlutter

Maintainers only. Contributors do not run any of this — see [CONTRIBUTING.md](./CONTRIBUTING.md).

## Building the documentation site

```bash
scripts/prepare-docs.sh    # once: .venv + the pins in docs/requirements.txt
scripts/build-docs.sh      # English then Japanese, both --strict
```

Both locales, English first: it clears `site/`, which contains `site/ja`, so an English-only build
leaves a stale Japanese site behind and a page you just broke still looks fine. `mkdocs.base.yml`
sets `strict: true`; `zensical serve` validates nothing, `--strict` or not. `.ps1` twins on Windows,
`key=value` options and `--help` on both.

`scripts/build-pages.sh` builds the published tree: those two locales, then both web demos —
`examples/overall` at `site/demo/flutter/`, `examples/flame` at `site/demo/flame/`, with a chooser
at `site/demo/`. `pages.yml`'s build job **is** this script with every option spelled out, so CI and
a local run cannot drift.

```bash
scripts/build-pages.sh serve=yes          # -> http://localhost:8000/SSPlayerForFlutter/
scripts/build-pages.sh sdk=build          # ... with the Brain compiled from the submodule
scripts/build-pages.sh demo=skip          # documentation only
scripts/build-pages.sh base=/ zip=yes     # the Cloudflare Pages upload: SSPlayerForFlutter-site.zip
```

*   **The demos are built here, never downloaded** — `release.yml` publishes to pub.dev and creates
    no GitHub Release, so there is no asset to fetch. `sdk=` is the separate question of where the
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

## Cutting a release

How versions are computed, and the steady-state run, are on
[Releasing](./docs/en/contributing/releasing.md) / [ja](./docs/ja/contributing/releasing.md).
The release *is* six pub.dev publishes; there is no GitHub Release and no asset.

Run the preflight before cutting versions. `melos version` pushes the `<package>-v<version>` tags
**before** pub.dev ever sees a package, and a version there is permanent — a package pub rejects at
publish time has already cost a version number and a CHANGELOG commit.

```bash
scripts/build-release.sh                        # every package: analyze + tests + dry-run publish
scripts/build-release.sh checks=skip sdk=skip   # just the archives, offline
scripts/build-release.sh packages=ssruntime_dart
```

`release.yml`'s first job is that script with every option spelled out.

*   **A private package is previewed, not skipped.** The script lifts `publish_to: none` for the
    length of the dry run and restores it however it exits, from a backup kept *outside* the package
    — pub publishes untracked files too, so a `pubspec.yaml.bak` beside the original would ship.
*   **`dart pub publish` treats warnings as fatal**, and neither `-f` nor the reusable workflow
    passes `--ignore-warnings`. `LICENSE.md` instead of `LICENSE`, or a missing `CHANGELOG.md`, is
    enough to abort a publish.
*   **The pinned SDK release has to exist.** `packages/*/hook/build.dart` download `libssruntime` /
    `libssconverter` from `_sdkVersion`'s release for every consumer without a Rust toolchain, and
    the two hooks must name the *same* release. `sdk=check` failing while the SDK is untagged is
    correct — there is nothing to publish against.
*   **The web Brain is git-ignored build output that has to ship.**
    `assets/runtime-web/{ssruntime.js,ssruntime_bg.wasm,ssruntime_bg.nosimd.wasm}` are what
    `ssruntime_dart`'s `web_runtime.dart` loads by name, and pub publishes nothing git ignores —
    hence `assets/runtime-web/.pubignore`, which pub reads *instead of* the `.gitignore` there.
    dart-lang's reusable publish workflow has no step between checkout and `dart pub publish`, so
    `publish.yml`'s **`ssplayer_flutter` job is hand-rolled**: that workflow's steps verbatim, with
    `scripts/download-web-runtime.sh` inserted before the dry run. If that step ever disappears,
    `build-release.sh verify` says so rather than letting a complete-looking archive hide an empty
    `assets/runtime-web/` on pub.dev.

<br>

---

# SSPlayerForFlutter のリリース手順

維持者向けです。コントリビューターがこの手順を実行することはありません（[CONTRIBUTING.md](./CONTRIBUTING.md) を参照してください）。

## ドキュメントサイトのビルド

```bash
scripts/prepare-docs.sh    # 一度だけ: .venv と docs/requirements.txt のピン
scripts/build-docs.sh      # 英語 → 日本語の順に、どちらも --strict
```

必ず両ロケールを、英語を先に。英語ビルドは `site/`（その中に `site/ja` がある）を消すため、英語だけ
建てると古い日本語サイトが残り、壊したページが無傷に見えます。`mkdocs.base.yml` が `strict: true` を
設定します。`zensical serve` は `--strict` を付けても何も検証しません。Windows は `.ps1` 双子、どちらも
`key=value` オプションと `--help` を取ります。

`scripts/build-pages.sh` が公開ツリーです。上記 2 ロケールに続けて Web デモ 2 本 — `examples/overall`
を `site/demo/flutter/`、`examples/flame` を `site/demo/flame/`、選択ページを `site/demo/` に — を
建てます。`pages.yml` のビルドジョブはこのスクリプトをすべてのオプションを明示して実行するので、CI と
手元がずれません。

```bash
scripts/build-pages.sh serve=yes          # -> http://localhost:8000/SSPlayerForFlutter/
scripts/build-pages.sh sdk=build          # ... Brain を submodule からビルドする
scripts/build-pages.sh demo=skip          # ドキュメントのみ
scripts/build-pages.sh base=/ zip=yes     # Cloudflare Pages 用: SSPlayerForFlutter-site.zip
```

*   **デモはここでビルドします。ダウンロードではありません。** `release.yml` は pub.dev へ publish
    するだけで GitHub Release を作らないため、取得できる asset がありません。`sdk=` は Brain の入手元
    という別の話で、既定かつ CI が使う `download` なら Rust ツールチェーンは一切不要です。
*   **`base=` はビルド時に焼き込まれます**（`flutter build web --base-href`）。あるパス用に建てたデモは
    別のパスでは 404 します。`serve=yes` が `site/` を `.pages-preview/<repo>` に吊るして配信するのは、
    建てたときのアドレスでデモを開く唯一の方法だからです。
*   **examples の `web/` ランナーは git 管理外**なので、無ければスクリプトが `flutter create
    --platforms=web .` を実行し、そのあと `.metadata` を戻します（`flutter create` はプラットフォーム
    一覧を追記ではなく置き換えるため）。
*   **`deploy-examples.sh` は毎回走ります。** デモが再生する `.ssab` は生成物で git 管理外です。古い
    pack は公開デモで誰も気づかない類の事故です。
*   **もう 1 部を手作業で Cloudflare Pages に上げます。** あちらはプロジェクトを自身のルートで配信する
    ので `base=/` が要ります。`zip=yes` は `site/` の中身をアーカイブのルートに置いて固め、サブパス用に
    建てたツリーなら拒否します。正典は GitHub Pages 側です（README の絶対 URL はそちらを指し、`docs/`
    内のデモリンクはすべて相対なので、1 回のビルドが両方のホストで正しく動きます）。

## リリースの手順

バージョンの決まり方と通常運転の流れは
[リリース](./docs/ja/contributing/releasing.md) / [en](./docs/en/contributing/releasing.md) にあります。
リリースの実体は pub.dev への 6 パッケージの publish で、GitHub Release も asset もありません。

バージョンを切る前に必ずプリフライトを実行してください。`melos version` は **pub.dev がパッケージを
見るより先に** `<package>-v<version>` タグを push し、pub.dev のバージョンは永久に取り消せません。
publish 時に pub に弾かれたパッケージは、その時点でバージョン番号と CHANGELOG のコミットを消費済みです。

```bash
scripts/build-release.sh                        # 全パッケージ: analyze + テスト + dry-run publish
scripts/build-release.sh checks=skip sdk=skip   # アーカイブだけ、オフライン
scripts/build-release.sh packages=ssruntime_dart
```

`release.yml` の最初のジョブがこのスクリプト（オプションはすべて明示）です。

*   **private なパッケージはスキップせずプレビューします。** dry run の間だけ `publish_to: none` を
    外し、スクリプトがどう終了しても復元します。バックアップはパッケージの**外**に置きます（pub は
    未追跡ファイルも publish するため、隣に置いた `pubspec.yaml.bak` はアーカイブに入ってしまいます）。
*   **`dart pub publish` は警告を致命エラーとして扱います。** `--ignore-warnings` を渡すのは `-f` でも
    再利用ワークフローでもありません。`LICENSE` ではなく `LICENSE.md` である、`CHANGELOG.md` が無い、
    だけで publish は中断します。
*   **ピンした SDK リリースが存在している必要があります。** `packages/*/hook/build.dart` が
    `_sdkVersion` のリリースから `libssruntime` / `libssconverter` を取得します。2 つの hook は**同じ**
    リリースを指す必要があります。SDK が未タグのうち `sdk=check` が失敗するのは正しい挙動です。
*   **Web の Brain は git 管理外のビルド生成物ですが、publish に含める必要があります。**
    `assets/runtime-web/{ssruntime.js,ssruntime_bg.wasm,ssruntime_bg.nosimd.wasm}` は
    `ssruntime_dart` の `web_runtime.dart` が名前で読み込むファイルで、pub は git が無視するものを
    publish しません。そのための `assets/runtime-web/.pubignore` で、pub はそのディレクトリの
    `.gitignore` の**代わりに**これを読みます。dart-lang の再利用ワークフローは checkout と
    `dart pub publish` の間に何も挟めないため、`publish.yml` の **`ssplayer_flutter` ジョブだけは
    手書き**です（同じ手順に `scripts/download-web-runtime.sh` を dry run の前に挿入）。この取得手順が
    消えた場合は `build-release.sh` の verify が指摘します。空の `assets/runtime-web/` を抱えた
    一見完全なアーカイブが pub.dev に上がるのを防ぐためです。
