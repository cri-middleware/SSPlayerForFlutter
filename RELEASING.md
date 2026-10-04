# Releasing SSPlayerForFlutter

Maintainers only. Contributors do not run any of this — see [CONTRIBUTING.md](./CONTRIBUTING.md).

## Cutting a release

Anyone with the Write role on this repository can cut a release: it is one run of the **Release** workflow on `main`, so nothing depends on whose machine starts it. You need `gh` (run `gh auth login` once), and the repository needs the `RELEASE_PAT` secret: the tags have to be pushed by a token other than `GITHUB_TOKEN`, or they start no workflow.

The packages are versioned independently, and a release names the versions it sets, as `<package>@<version>` pairs where `<package>` is the directory under `packages/`. `scripts/set-versions.dart` writes each version, raises the `^` constraint the other packages have on it, and gives its `CHANGELOG.md` a heading that links the package's Release. The workflow then checks everything with `scripts/build-release.sh`, commits the versions to `main`, and gives every package it released a `<package>-v<version>` tag and a draft GitHub Release. Each tag starts `publish.yml`, which publishes the package to pub.dev — unless it still carries `publish_to: none`, in which case it is released on GitHub alone. A pull request carries no version and no release note — both are decided here.

### 1. Decide the versions

Look at what each package gained since its previous tag. A package gets a new version only when it is named: one that depends on a package being released keeps its own version, with its constraint raised for its next release. The SDK the packages fetch is `_sdkVersion` in `packages/*/hook/build.dart`, and both hooks must name the same release: point them at it first, in an ordinary pull request into `main`.

```bash
git log --oneline ssruntime_dart-v7.0.0-beta.1..origin/main -- packages/ssruntime_dart
```

### 2. Look at it first

A dry run sets the versions and checks everything, and commits, tags and releases nothing. The per-package archives and dry-run reports stay on the run (`release-dist`).

```bash
gh workflow run release.yml --ref main -f versions="ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2" -f dry_run=true
gh run watch                                      # the run takes a few seconds to appear
gh run download <run-id> -n release-dist -D qa    # <run-id>: the one gh run watch shows
```

### 3. Run the release

```bash
gh workflow run release.yml --ref main -f versions="ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2"
gh run watch
```

The run sets the versions, checks every package with `scripts/build-release.sh` — analyze, a dry-run publish, the SDK release and the web Brain — and only then commits the versions to `main`, pushes the tags and drafts the Releases, with notes generated from the pull requests since each package's previous tag. A failure before the commit leaves `main` untouched, and so does a `main` that moved during the run, which rejects the push.

With `versions` left empty, nothing is set, and every current version that has no Release yet goes out: the first release, and the retry after a run that failed.

### 4. Publish the drafts

Open each draft on the [Releases](https://github.com/cri-middleware/SSPlayerForFlutter/releases) page: edit its notes down to what that package gained — they list every pull request since its previous tag, the other packages' included — choose **Set as a pre-release** or **Set as the latest release**, and **Publish release**. Publishing starts `pages.yml`, which deploys the [documentation site](https://cri-middleware.github.io/SSPlayerForFlutter/) and the web demos. Watch the run through, then open the site: a failed run leaves the site as it was. Once the cause is fixed, re-run it.

```bash
gh run watch                                      # pages.yml; the run takes a few seconds to appear
```

## Opening a package to pub.dev

A package is published only once its pubspec drops `publish_to: none`. Do that in an ordinary pull request, publish its first version by hand from a checkout of its tag — in dependency order, `ssruntime_dart` and `ssconverter_dart` before the packages that depend on them — and enable **Automated publishing** in the package's pub.dev Admin tab with the tag pattern `<package>-v{{version}}`. From then on, a release's tag publishes it.

## Undoing a release

**A version on pub.dev is permanent** — it cannot be withdrawn — so a fault found after a published package's tag went out is fixed by a new version. A run that failed partway is run again with `versions` empty: it releases what `main` now carries, reusing any tag it had pushed. A package that went to GitHub alone can be undone until its Release is published: delete the draft, run `git push origin ":refs/tags/$TAG" && git tag -d "$TAG"`, merge the fix into `main`, and run the workflow again with `versions` empty.

## Building the release locally

`scripts/build-release.sh` is the check, and `release.yml` runs exactly this script before it commits or tags anything. Run it before a release; `scripts/set-versions.dart` sets the versions the same way the release would, and `git checkout -- packages` puts them back.

```bash
dart scripts/set-versions.dart ssruntime_dart@7.0.0-beta.2   # optional: the versions a release would set
scripts/build-release.sh                        # every package: analyze + tests + dry-run publish
scripts/build-release.sh checks=skip sdk=skip   # just the archives, offline
scripts/build-release.sh packages=ssruntime_dart
```

*   **A private package is previewed, not skipped.** The script lifts `publish_to: none` for the
    length of the dry run and restores it however it exits, from a backup kept *outside* the package
    — pub publishes untracked files too, so a `pubspec.yaml.bak` beside the original would ship.
*   **`dart pub publish` treats warnings as fatal**, and neither `-f` nor the reusable workflow
    passes `--ignore-warnings`. `LICENSE.md` instead of `LICENSE`, a missing `CHANGELOG.md`, or one
    that does not mention the version, is enough to abort a publish.
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
*   **The toolchain is pinned** — Flutter 3.47.1 in `release.yml`, `publish.yml` and `pages.yml`, so
    a release is checked, published and demoed by the same one. Move the three together, and never
    below a package's declared floor: most declare one well below the pin, `ssplayer_flutter` sits at
    Flutter `>=3.47.0` because the flutter_gpu it uses ships inside the SDK.

<br>

---

# SSPlayerForFlutter のリリース手順

維持者向けです。コントリビューターがこの手順を実行することはありません（[CONTRIBUTING.md](./CONTRIBUTING.md) を参照してください）。

## リリースの手順

このリポジトリの Write ロールを持つ人なら誰でもリリースできます。リリースは `main` での **Release** ワークフローの実行 1 回なので、誰の手元から始めても結果は変わりません。必要なのは `gh`（最初に一度 `gh auth login`）で、リポジトリには `RELEASE_PAT` secret が要ります。タグを `GITHUB_TOKEN` 以外のトークンで push しないと、ワークフローが起動しないためです。

パッケージは独立にバージョンを持ち、リリースは設定するバージョンを `<package>@<version>` の組で指定します。`<package>` は `packages/` の下のディレクトリ名です。`scripts/set-versions.dart` が各バージョンを書き、他のパッケージがそれに付けている `^` の制約を引き上げ、`CHANGELOG.md` にそのパッケージの Release へリンクする見出しを足します。続けてワークフローが `scripts/build-release.sh` ですべてを検査し、バージョンを `main` へコミットし、リリースした各パッケージに `<package>-v<version>` のタグと下書きの GitHub Release を作ります。タグはそれぞれ `publish.yml` を起動し、パッケージを pub.dev へ publish します。ただし `publish_to: none` が残っているパッケージは GitHub だけでリリースされます。プルリクエストはバージョンもリリースノートも持ちません。どちらもここで決めます。

### 1. バージョンを決める

各パッケージが前回のタグから何を得たかを見ます。新しいバージョンになるのは指定したパッケージだけです。リリースするパッケージに依存するパッケージは自分のバージョンを保ち、次のリリースに向けて制約だけが引き上げられます。パッケージが取得する SDK は `packages/*/hook/build.dart` の `_sdkVersion` で、2 つの hook は同じリリースを指す必要があります。先に、通常のプルリクエストで `main` のそれを合わせておきます。

```bash
git log --oneline ssruntime_dart-v7.0.0-beta.1..origin/main -- packages/ssruntime_dart
```

### 2. 先に確かめる

dry run はバージョンを設定してすべてを検査し、コミットもタグも Release も作りません。パッケージごとのアーカイブと dry-run の報告は run に残ります（`release-dist`）。

```bash
gh workflow run release.yml --ref main -f versions="ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2" -f dry_run=true
gh run watch                                      # run が一覧に出るまで数秒かかる
gh run download <run-id> -n release-dist -D qa    # <run-id>: gh run watch に出るもの
```

### 3. リリースを実行する

```bash
gh workflow run release.yml --ref main -f versions="ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2"
gh run watch
```

run はバージョンを設定し、`scripts/build-release.sh` で全パッケージを検査します（analyze、dry-run publish、SDK リリース、Web の Brain）。そのあとで初めてバージョンを `main` へコミットし、タグを push し、各パッケージの前回のタグ以降のプルリクエストから生成したノート付きで Release の下書きを作ります。コミットより前に失敗すれば `main` は変わりません。run の途中で `main` が進んでいた場合も、push が拒否されるので同じです。

`versions` を空にすると何も設定せず、Release がまだ無い現在のバージョンをすべて出します。初回のリリースと、失敗した run のやり直しがこれです。

### 4. 下書きを公開する

[Releases](https://github.com/cri-middleware/SSPlayerForFlutter/releases) ページで下書きを 1 つずつ開きます。ノートにはそのパッケージの前回のタグ以降のプルリクエストが、他のパッケージのものも含めてすべて並ぶので、このパッケージが得たものだけに絞ります。**Set as a pre-release** か **Set as the latest release** を選んで、**Publish release** を押します。公開すると `pages.yml` が動き、[ドキュメントサイト](https://cri-middleware.github.io/SSPlayerForFlutter/) と Web デモをデプロイします。run を最後まで見届けてから、サイトを開いて確かめます。run が失敗してもサイトは元のまま残ります。原因を直したら run を再実行します。

```bash
gh run watch                                      # pages.yml。run が一覧に出るまで数秒かかる
```

## パッケージを pub.dev に開く

パッケージが publish されるのは、その pubspec から `publish_to: none` を外してからです。通常のプルリクエストで外し、最初のバージョンだけはタグをチェックアウトして手で publish します（依存の順に。`ssruntime_dart` と `ssconverter_dart` を、それに依存するパッケージより先に）。そのうえで pub.dev のパッケージの Admin タブで **Automated publishing** を有効にし、タグのパターンを `<package>-v{{version}}` にします。以後はリリースのタグで publish されます。

## リリースの取り消し

**pub.dev のバージョンは恒久的です。** 取り下げられないので、publish されたパッケージのタグが出た後に見つかった不具合は、新しいバージョンで直します。途中で失敗した run は `versions` を空にして実行し直します。`main` が今持っているものを出し、push 済みのタグはそのまま使います。GitHub だけでリリースしたパッケージは、Release を公開するまでは取り消せます。下書きを消し、`git push origin ":refs/tags/$TAG" && git tag -d "$TAG"` を実行し、修正を `main` へマージしてから、`versions` を空にしてワークフローを実行し直します。

## リリースのローカルビルド

`scripts/build-release.sh` が検査そのもので、`release.yml` はコミットやタグの前にこのスクリプトを実行しているだけです。リリースの前に実行してください。`scripts/set-versions.dart` はリリースと同じ方法でバージョンを設定し、`git checkout -- packages` で元に戻せます。

```bash
dart scripts/set-versions.dart ssruntime_dart@7.0.0-beta.2   # 任意: リリースが設定するバージョン
scripts/build-release.sh                        # 全パッケージ: analyze + テスト + dry-run publish
scripts/build-release.sh checks=skip sdk=skip   # アーカイブだけ、オフライン
scripts/build-release.sh packages=ssruntime_dart
```

*   **private なパッケージはスキップせずプレビューします。** dry run の間だけ `publish_to: none` を外し、スクリプトがどう終了しても復元します。バックアップはパッケージの**外**に置きます（pub は未追跡ファイルも publish するため、隣に置いた `pubspec.yaml.bak` はアーカイブに入ってしまいます）。
*   **`dart pub publish` は警告を致命エラーとして扱います。** `--ignore-warnings` を渡すのは `-f` でも再利用ワークフローでもありません。`LICENSE` ではなく `LICENSE.md` である、`CHANGELOG.md` が無い、またはそのバージョンに触れていない、だけで publish は中断します。
*   **ピンした SDK リリースが存在している必要があります。** `packages/*/hook/build.dart` が `_sdkVersion` のリリースから、Rust ツールチェインを持たないすべての利用者向けに `libssruntime` / `libssconverter` を取得します。2 つの hook は**同じ**リリースを指す必要があります。SDK が未タグのうち `sdk=check` が失敗するのは正しい挙動です。
*   **Web の Brain は git 管理外のビルド生成物ですが、publish に含める必要があります。** `assets/runtime-web/{ssruntime.js,ssruntime_bg.wasm,ssruntime_bg.nosimd.wasm}` は `ssruntime_dart` の `web_runtime.dart` が名前で読み込むファイルで、pub は git が無視するものを publish しません。そのための `assets/runtime-web/.pubignore` で、pub はそのディレクトリの `.gitignore` の**代わりに**これを読みます。dart-lang の再利用ワークフローは checkout と `dart pub publish` の間に何も挟めないため、`publish.yml` の **`ssplayer_flutter` ジョブだけは手書き**です（同じ手順に `scripts/download-web-runtime.sh` を dry run の前に挿入）。この取得手順が消えた場合は `build-release.sh` の verify が指摘します。空の `assets/runtime-web/` を抱えた一見完全なアーカイブが pub.dev に上がるのを防ぐためです。
*   **ツールチェーンは固定しています。** `release.yml`・`publish.yml`・`pages.yml` の 3 か所で Flutter 3.47.1 にしているので、検査も publish もデモも同じものが行います。3 つは一緒に動かし、パッケージが宣言する下限を下回らないようにしてください。多くのパッケージはピンよりかなり低い下限を宣言していますが、`ssplayer_flutter` は使っている flutter_gpu が SDK に同梱されるため Flutter `>=3.47.0` です。
