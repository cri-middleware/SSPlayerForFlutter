# Releasing SSPlayerForFlutter

Maintainers only. Contributors do not run any of this — see [CONTRIBUTING.md](./CONTRIBUTING.md).

## Cutting a release

Anyone with the Write role on this repository can cut a release: it is one run of the **Release** workflow on `main`, so nothing depends on whose machine starts it. You need `git` and `gh` 2.87 or later (run `gh auth login` once), and for step 3, the Flutter toolchain [CONTRIBUTING.md](./CONTRIBUTING.md) sets up. The repository needs the `RELEASE_PAT` secret: the tags have to be pushed by a token other than `GITHUB_TOKEN`, or they start no workflow. It also needs GitHub Pages enabled with GitHub Actions as its source, and a `*-v*` tag rule on its `github-pages` environment, or publishing a Release deploys nothing; both are settings a repository admin makes. The commands are bash: in zsh, run `setopt interactive_comments` first, so that the `#` comments are not taken as arguments; on Windows, use Git Bash.

The packages are versioned independently, and a release names the versions it sets, as `<package>@<version>` pairs where `<package>` is the directory under `packages/`. `scripts/set-versions.dart` writes each version, raises the `^` constraint the other packages have on it, and turns the package's `## [Unreleased]` notes into that version's section of its `CHANGELOG.md`. The workflow then checks everything with `scripts/build-release.sh`, commits the versions to `main`, and gives every package it released a `<package>-v<version>` tag and a draft GitHub Release. Each tag starts `publish.yml`, which publishes the package to pub.dev — unless it still carries `publish_to: none`, in which case it is released on GitHub alone. What each version gained is written in its package's `CHANGELOG.md` and nowhere else: a Release carries a link to that changelog. A contributor's pull request carries no version and no changelog entry — both are written here. There is no release branch: what `main` holds is what goes out, so `main` holds only what can ship.

Only steps 4 and 5 and their retry under [Undoing a release](#undoing-a-release) read a value set by hand, `VERSIONS`, and they refuse one that is empty. Every other block works out what it needs from git and GitHub, so each can run in a new shell; the one block that acts on a Release you chose takes it as a `<tag>` placeholder, which stops with a syntax error when left as it is.

### 1. Decide the versions

Look at what each package gained since its previous tag. A package gets a new version only when it is named: one that depends on a package being released keeps its own version, with its constraint raised for its next release. The SDK the packages fetch is `_sdkVersion` in `packages/*/hook/build.dart`, and both hooks must name the same release: point them at it first, in an ordinary pull request into `main`.

```bash
git fetch origin --tags
for pkg in $(git ls-tree -r --name-only origin/main -- packages | sed -n 's|^packages/\([^/]*\)/pubspec\.yaml$|\1|p'); do
  prev=$(git -c versionsort.suffix=- tag --list "$pkg-v*" --sort=-v:refname | head -n 1)
  echo "== $pkg, last released: ${prev:-never}"
  git log --oneline ${prev:+"$prev.."}origin/main -- "packages/$pkg"
done
```

A run releases every package whose current version has no Release yet, named or not. So the first release names every package at the version it already has:

```text
ssruntime_dart@7.0.0-beta.1 ssconverter_dart@7.0.0-beta.1 ssplayer_flutter@7.0.0-beta.1 ssplayer_flame@7.0.0-beta.1 ssgen_dart@7.0.0-beta.1 ssgen_flutter@7.0.0-beta.1
```

Write the decision down for steps 4 and 5:

```bash
VERSIONS="ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2"
```

### 2. Write the changelog

For each package being released, write what it gained under `## [Unreleased]` in `packages/<dir>/CHANGELOG.md`, in Keep a Changelog's sections (`### Added`, `### Changed`, `### Fixed`, `### Removed`), and merge it into `main` with a pull request. If a dependency the packages bundle changed, bring `THIRD_PARTY_NOTICES.md` up to date in the same pull request. The release turns each `## [Unreleased]` into `## [<version>] - <date>`, and stops before building anything when a package it releases has nothing there.

```bash
git switch -c release-notes origin/main
# write under ## [Unreleased] in packages/<dir>/CHANGELOG.md
git add packages/*/CHANGELOG.md THIRD_PARTY_NOTICES.md
git commit -m "docs: changelog for the next release"
git push -u origin release-notes
gh pr create -B main --fill
gh pr merge release-notes --merge --delete-branch
```

### 3. Build the site

`pages.yml` builds the site only once a Release is published, from its tag, and a re-run builds that same tag: a fault in the docs or the demos found then can only be fixed in `main` and deployed from there. So build the site now, from the `main` the release will be cut from. `scripts/build-pages.sh` builds what `pages.yml` deploys, in the same order. A failure is fixed by a pull request into `main` before step 4.

```bash
git switch main && git pull --ff-only
scripts/build-pages.sh                            # -> site/, the site pages.yml would deploy
```

### 4. Look at it first

A dry run sets the versions and checks everything, and commits, tags and releases nothing. The per-package archives and dry-run reports stay on the run (`release-dist`). Once a tag is pushed, a package without `publish_to: none` is on pub.dev for good, so this is the last look before that.

```bash
RUN=$(gh workflow run release.yml --ref main -f versions="${VERSIONS:?}" -f dry_run=true | sed 's|.*/||')
gh run watch "${RUN:?}" --exit-status
gh run download "${RUN:?}" -n release-dist -D qa
```

### 5. Run the release

```bash
RUN=$(gh workflow run release.yml --ref main -f versions="${VERSIONS:?}" | sed 's|.*/||')
gh run watch "${RUN:?}" --exit-status
```

The run sets the versions and dates their changelog sections, checks every package with `scripts/build-release.sh` — analyze, a dry-run publish, the SDK release and the web Brain — and only then commits the versions to `main`, pushes the tags and drafts the Releases. Each tag starts `publish.yml`. A failure before the commit leaves `main` untouched, and so does a `main` that moved during the run, which rejects the push. Then see what it made:

```bash
git fetch origin --tags
git log --oneline -1 origin/main                  # chore(release): <the versions>
gh release list --json tagName,isDraft -q '.[] | select(.isDraft) | .tagName'   # its drafts
gh run list -w publish.yml -L 6                   # one run per tag; a package without publish_to: none went to pub.dev
```

### 6. Publish the Releases

Nothing on a draft needs writing, and a version with a `-` is already marked as a pre-release. Publishing starts `pages.yml`, which deploys the [documentation site](https://cri-middleware.github.io/SSPlayerForFlutter/) and the web demos. Every Release published starts a run of its own; they queue, and a newer one replaces one still waiting, which then shows as cancelled, so the run to watch is the last Release's.

```bash
tag=
for tag in $(gh release list --json tagName,isDraft -q '.[] | select(.isDraft) | .tagName'); do
  gh release edit "$tag" --draft=false
done
RUN=$(gh run list -w pages.yml -b "${tag:?}" -L 1 --json databaseId -q '.[0].databaseId')
gh run watch "${RUN:?}" --exit-status             # RUN is empty for the few seconds before the run appears
```

Then open the site. A failed run leaves the site as it was. When the cause was a setting outside the repository, re-run it with `gh run rerun "$RUN"`; a fix in the repository goes into `main` by pull request and deploys with `gh workflow run pages.yml --ref main`.

## Opening a package to pub.dev

A package is published only once its pubspec drops `publish_to: none`. Do that in an ordinary pull request, publish its first version by hand from a checkout of its tag — in dependency order, `ssruntime_dart` and `ssconverter_dart` before the packages that depend on them — and enable **Automated publishing** in the package's pub.dev Admin tab with the tag pattern `<package>-v{{version}}`. From then on, a release's tag publishes it.

## Undoing a release

**A version on pub.dev is permanent** — it cannot be withdrawn — so a fault found after a published package's tag went out is fixed by a new version. So is a published Release, whose tag users depend on. Before that:

*   A run that failed before its commit reached `main` is run again with the same versions, once the cause is fixed in `main`. The **Re-run** button would replay the old commit, and its push would be rejected.

    ```bash
    RUN=$(gh workflow run release.yml --ref main -f versions="${VERSIONS:?}" | sed 's|.*/||')
    gh run watch "${RUN:?}" --exit-status
    ```

*   A run that failed after its commit reached `main` is run again with `versions` empty, before anything else is merged into `main`: the retry checks `main` as it then is, reuses any tag it had pushed, and drafts the Releases still missing.

    ```bash
    RUN=$(gh workflow run release.yml --ref main | sed 's|.*/||')
    gh run watch "${RUN:?}" --exit-status
    ```

*   A package that went to GitHub alone can be undone until its Release is published: delete its draft and tag, merge the fix into `main` — correcting the version's changelog section if it needs it — and run again with `versions` empty, which tags the same version on the fixed `main`. `<tag>` is that draft's tag; the block deletes nothing unless it is a draft's.

    ```bash
    TAG=<tag>
    [ "$(gh release view "${TAG:?}" --json isDraft -q .isDraft)" = true ] &&
      gh release delete "$TAG" --cleanup-tag --yes  # deletes the tag too, here and on GitHub
    ```

## Building the release locally

`scripts/build-release.sh` is the check, and `release.yml` runs exactly this script before it commits or tags anything. Run it before a release:

```bash
scripts/build-release.sh                        # every package: analyze + tests + dry-run publish
```

`checks=skip sdk=skip` builds just the archives, offline, and `packages=<package>` checks one package. To check under the versions a release would set, set them first with `dart scripts/set-versions.dart <package>@<version> …`, which sets them, and dates their changelog sections, the same way the release would; put them back afterwards with `git checkout -- packages`.

*   **A private package is previewed, not skipped.** The script lifts `publish_to: none` for the
    length of the dry run and restores it however it exits, from a backup kept *outside* the package
    — pub publishes untracked files too, so a `pubspec.yaml.bak` beside the original would ship.
*   **`dart pub publish` treats warnings as fatal**, and neither `-f` nor the reusable workflow
    passes `--ignore-warnings`. `LICENSE.md` instead of `LICENSE`, a missing `CHANGELOG.md`, or one
    that does not mention the version, is enough to abort a publish. A version not yet released is
    mentioned only once `set-versions.dart` has dated its section, so check one after setting it.
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

このリポジトリの Write ロールを持つ人なら誰でもリリースできます。リリースは `main` での **Release** ワークフローの実行 1 回なので、誰の手元から始めても結果は変わりません。必要なのは `git` と `gh` 2.87 以降（最初に一度 `gh auth login`）、それに手順 3 のための、[CONTRIBUTING.md](./CONTRIBUTING.md) が用意する Flutter のツールチェーンです。リポジトリには `RELEASE_PAT` secret が要ります。タグを `GITHUB_TOKEN` 以外のトークンで push しないと、ワークフローが起動しないためです。さらに、GitHub Pages を有効にしてソースを GitHub Actions にし、`github-pages` environment に `*-v*` のタグのルールを足しておく必要があります。どちらかが欠けると、Release を公開しても何もデプロイされません。どちらもリポジトリの admin が行う設定です。コマンドは bash です。zsh では、`#` のコメントが引数として渡されないよう、先に `setopt interactive_comments` を実行します。Windows では Git Bash を使います。

パッケージは独立にバージョンを持ち、リリースは設定するバージョンを `<package>@<version>` の組で指定します。`<package>` は `packages/` の下のディレクトリ名です。`scripts/set-versions.dart` が各バージョンを書き、他のパッケージがそれに付けている `^` の制約を引き上げ、パッケージの `## [Unreleased]` のノートを、`CHANGELOG.md` のそのバージョンの節に書き換えます。続けてワークフローが `scripts/build-release.sh` ですべてを検査し、バージョンを `main` へコミットし、リリースした各パッケージに `<package>-v<version>` のタグと下書きの GitHub Release を作ります。タグはそれぞれ `publish.yml` を起動し、パッケージを pub.dev へ publish します。ただし `publish_to: none` が残っているパッケージは GitHub だけでリリースされます。各バージョンで何が変わったかは、そのパッケージの `CHANGELOG.md` にだけ書きます。Release が持つのは、その changelog へのリンクだけです。コントリビューターのプルリクエストはバージョンも changelog の項目も持ちません。どちらもここで書きます。release ブランチはありません。`main` にあるものがそのまま出るので、`main` には出せるものだけを置きます。

手で設定する値 `VERSIONS` を読むのは、手順 4・5 と「リリースの取り消し」にあるその再実行だけで、空なら実行を拒否します。ほかのブロックは必要なものを git と GitHub から求めるので、どれも新しいシェルで実行できます。選んだ Release に対して操作するブロックは 1 つだけで、その Release を `<tag>` のプレースホルダで受け取ります。埋めずに実行すると、その行は構文エラーで止まります。

### 1. バージョンを決める

各パッケージが前回のタグから何を得たかを見ます。新しいバージョンになるのは指定したパッケージだけです。リリースするパッケージに依存するパッケージは自分のバージョンを保ち、次のリリースに向けて制約だけが引き上げられます。パッケージが取得する SDK は `packages/*/hook/build.dart` の `_sdkVersion` で、2 つの hook は同じリリースを指す必要があります。先に、通常のプルリクエストで `main` のそれを合わせておきます。

```bash
git fetch origin --tags
for pkg in $(git ls-tree -r --name-only origin/main -- packages | sed -n 's|^packages/\([^/]*\)/pubspec\.yaml$|\1|p'); do
  prev=$(git -c versionsort.suffix=- tag --list "$pkg-v*" --sort=-v:refname | head -n 1)
  echo "== $pkg, last released: ${prev:-never}"
  git log --oneline ${prev:+"$prev.."}origin/main -- "packages/$pkg"
done
```

run は、指定したかどうかに関わらず、現在のバージョンにまだ Release が無いパッケージをすべて出します。そのため初回のリリースでは、全パッケージをいま持っているバージョンのまま指定します。

```text
ssruntime_dart@7.0.0-beta.1 ssconverter_dart@7.0.0-beta.1 ssplayer_flutter@7.0.0-beta.1 ssplayer_flame@7.0.0-beta.1 ssgen_dart@7.0.0-beta.1 ssgen_flutter@7.0.0-beta.1
```

決めたものを手順 4・5 のために書き留めます。

```bash
VERSIONS="ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2"
```

### 2. changelog を書く

リリースするパッケージごとに、得たものを `packages/<dir>/CHANGELOG.md` の `## [Unreleased]` の下に、Keep a Changelog の節（`### Added`・`### Changed`・`### Fixed`・`### Removed`）で書き、プルリクエストで `main` にマージします。パッケージが同梱する依存が変わっていれば、同じプルリクエストで `THIRD_PARTY_NOTICES.md` も更新します。リリースは各 `## [Unreleased]` を `## [<version>] - <date>` に書き換えます。リリースするパッケージの `## [Unreleased]` が空なら、何もビルドせずに止まります。

```bash
git switch -c release-notes origin/main
# packages/<dir>/CHANGELOG.md の ## [Unreleased] の下に書く
git add packages/*/CHANGELOG.md THIRD_PARTY_NOTICES.md
git commit -m "docs: changelog for the next release"
git push -u origin release-notes
gh pr create -B main --fill
gh pr merge release-notes --merge --delete-branch
```

### 3. サイトをビルドする

`pages.yml` がサイトをビルドするのは Release を公開したときだけで、そのタグから作ります。再実行しても同じタグをビルドするだけなので、そこで docs やデモの不具合が見つかると、`main` で直してそこからデプロイするしかありません。そこで、リリースを切る `main` から、先にサイトをビルドしておきます。`scripts/build-pages.sh` は、`pages.yml` がデプロイするものを同じ順にビルドします。失敗したら、手順 4 の前にプルリクエストで `main` を直します。

```bash
git switch main && git pull --ff-only
scripts/build-pages.sh                            # -> site/。pages.yml がデプロイするサイト
```

### 4. 先に確かめる

dry run はバージョンを設定してすべてを検査し、コミットもタグも Release も作りません。パッケージごとのアーカイブと dry-run の報告は run に残ります（`release-dist`）。タグを push すると、`publish_to: none` の無いパッケージは pub.dev に出て取り消せないので、これがその前の最後の確認です。

```bash
RUN=$(gh workflow run release.yml --ref main -f versions="${VERSIONS:?}" -f dry_run=true | sed 's|.*/||')
gh run watch "${RUN:?}" --exit-status
gh run download "${RUN:?}" -n release-dist -D qa
```

### 5. リリースを実行する

```bash
RUN=$(gh workflow run release.yml --ref main -f versions="${VERSIONS:?}" | sed 's|.*/||')
gh run watch "${RUN:?}" --exit-status
```

run はバージョンを設定して changelog の節に日付を入れ、`scripts/build-release.sh` で全パッケージを検査します（analyze、dry-run publish、SDK リリース、Web の Brain）。そのあとで初めてバージョンを `main` へコミットし、タグを push し、Release の下書きを作ります。タグはそれぞれ `publish.yml` を起動します。コミットより前に失敗すれば `main` は変わりません。run の途中で `main` が進んでいた場合も、push が拒否されるので同じです。終わったら、できたものを確かめます。

```bash
git fetch origin --tags
git log --oneline -1 origin/main                  # chore(release): <指定したバージョン>
gh release list --json tagName,isDraft -q '.[] | select(.isDraft) | .tagName'   # できた下書き
gh run list -w publish.yml -L 6                   # タグごとに 1 つ。publish_to: none の無いパッケージは pub.dev に出た
```

### 6. Release を公開する

下書きに書き足すものはありません。`-` を含むバージョンは、すでに pre-release になっています。公開すると `pages.yml` が動き、[ドキュメントサイト](https://cri-middleware.github.io/SSPlayerForFlutter/) と Web デモをデプロイします。Release を 1 つ公開するごとに run が 1 つ始まります。run は順に並び、待っている run は新しい run に置き換えられて cancelled と表示されるので、見届けるのは最後に公開した Release の run です。

```bash
tag=
for tag in $(gh release list --json tagName,isDraft -q '.[] | select(.isDraft) | .tagName'); do
  gh release edit "$tag" --draft=false
done
RUN=$(gh run list -w pages.yml -b "${tag:?}" -L 1 --json databaseId -q '.[0].databaseId')
gh run watch "${RUN:?}" --exit-status             # run が一覧に出るまでの数秒間は RUN が空になる
```

終わったら、サイトを開いて確かめます。run が失敗してもサイトは元のまま残ります。原因がリポジトリの外の設定にあったなら、`gh run rerun "$RUN"` で再実行します。リポジトリ内の修正は、プルリクエストで `main` に入れてから `gh workflow run pages.yml --ref main` でデプロイします。

## パッケージを pub.dev に開く

パッケージが publish されるのは、その pubspec から `publish_to: none` を外してからです。通常のプルリクエストで外し、最初のバージョンだけはタグをチェックアウトして手で publish します（依存の順に。`ssruntime_dart` と `ssconverter_dart` を、それに依存するパッケージより先に）。そのうえで pub.dev のパッケージの Admin タブで **Automated publishing** を有効にし、タグのパターンを `<package>-v{{version}}` にします。以後はリリースのタグで publish されます。

## リリースの取り消し

**pub.dev のバージョンは恒久的です。** 取り下げられないので、publish されたパッケージのタグが出た後に見つかった不具合は、新しいバージョンで直します。公開した Release も同じで、利用者はそのタグに依存しています。それより前なら、次のようにします。

*   コミットが `main` に届く前に失敗した run は、原因を `main` で直してから、同じバージョンで実行し直します。**Re-run** ボタンは古いコミットを再生するので、その push は拒否されます。

    ```bash
    RUN=$(gh workflow run release.yml --ref main -f versions="${VERSIONS:?}" | sed 's|.*/||')
    gh run watch "${RUN:?}" --exit-status
    ```

*   コミットが `main` に届いた後に失敗した run は、ほかの変更が `main` にマージされる前に、`versions` を空にして実行し直します。やり直しはその時点の `main` を検査し、push 済みのタグはそのまま使い、まだ無い Release の下書きを作ります。

    ```bash
    RUN=$(gh workflow run release.yml --ref main | sed 's|.*/||')
    gh run watch "${RUN:?}" --exit-status
    ```

*   GitHub だけでリリースしたパッケージは、Release を公開するまでは取り消せます。下書きとそのタグを消し、修正を `main` へマージして（必要ならそのバージョンの changelog の節も直して）、`versions` を空にして実行し直します。直した `main` に同じバージョンのタグが打たれます。`<tag>` はその下書きのタグです。下書きのものでなければ、ブロックは何も消しません。

    ```bash
    TAG=<tag>
    [ "$(gh release view "${TAG:?}" --json isDraft -q .isDraft)" = true ] &&
      gh release delete "$TAG" --cleanup-tag --yes  # タグも手元と GitHub の両方から消える
    ```

## リリースのローカルビルド

`scripts/build-release.sh` が検査そのもので、`release.yml` はコミットやタグの前にこのスクリプトを実行しているだけです。リリースの前に実行してください。

```bash
scripts/build-release.sh                        # 全パッケージ: analyze + テスト + dry-run publish
```

`checks=skip sdk=skip` を付けるとアーカイブだけをオフラインで作り、`packages=<package>` を付けると 1 つのパッケージだけを検査します。リリースが設定するバージョンで検査するなら、先に `dart scripts/set-versions.dart <package>@<version> …` で、リリースと同じ方法でバージョンを設定して changelog の節に日付を入れ、終わったら `git checkout -- packages` で元に戻します。

*   **private なパッケージはスキップせずプレビューします。** dry run の間だけ `publish_to: none` を外し、スクリプトがどう終了しても復元します。バックアップはパッケージの**外**に置きます（pub は未追跡ファイルも publish するため、隣に置いた `pubspec.yaml.bak` はアーカイブに入ってしまいます）。
*   **`dart pub publish` は警告を致命エラーとして扱います。** `--ignore-warnings` を渡すのは `-f` でも再利用ワークフローでもありません。`LICENSE` ではなく `LICENSE.md` である、`CHANGELOG.md` が無い、またはそのバージョンに触れていない、だけで publish は中断します。まだリリースしていないバージョンは、`set-versions.dart` が節に日付を入れて初めて changelog に現れるので、設定してから検査します。
*   **ピンした SDK リリースが存在している必要があります。** `packages/*/hook/build.dart` が `_sdkVersion` のリリースから、Rust ツールチェインを持たないすべての利用者向けに `libssruntime` / `libssconverter` を取得します。2 つの hook は**同じ**リリースを指す必要があります。SDK が未タグのうち `sdk=check` が失敗するのは正しい挙動です。
*   **Web の Brain は git 管理外のビルド生成物ですが、publish に含める必要があります。** `assets/runtime-web/{ssruntime.js,ssruntime_bg.wasm,ssruntime_bg.nosimd.wasm}` は `ssruntime_dart` の `web_runtime.dart` が名前で読み込むファイルで、pub は git が無視するものを publish しません。そのための `assets/runtime-web/.pubignore` で、pub はそのディレクトリの `.gitignore` の**代わりに**これを読みます。dart-lang の再利用ワークフローは checkout と `dart pub publish` の間に何も挟めないため、`publish.yml` の **`ssplayer_flutter` ジョブだけは手書き**です（同じ手順に `scripts/download-web-runtime.sh` を dry run の前に挿入）。この取得手順が消えた場合は `build-release.sh` の verify が指摘します。空の `assets/runtime-web/` を抱えた一見完全なアーカイブが pub.dev に上がるのを防ぐためです。
*   **ツールチェーンは固定しています。** `release.yml`・`publish.yml`・`pages.yml` の 3 か所で Flutter 3.47.1 にしているので、検査も publish もデモも同じものが行います。3 つは一緒に動かし、パッケージが宣言する下限を下回らないようにしてください。多くのパッケージはピンよりかなり低い下限を宣言していますが、`ssplayer_flutter` は使っている flutter_gpu が SDK に同梱されるため Flutter `>=3.47.0` です。
