# Releasing SSPlayerForFlutter

Maintainers only. Contributors do not run any of this — see [CONTRIBUTING.md](./CONTRIBUTING.md).

## Cutting a release

Anyone with the Write role on this repository can cut a release: it is one run of the **Release** workflow on `main`, so nothing depends on whose machine starts it. You need `git` and `gh` 2.87 or later (run `gh auth login` once), and for step 3, the toolchain [CONTRIBUTING.md](./CONTRIBUTING.md) sets up, `flatc` included. The repository needs the `RELEASE_PAT` secret: the tags have to be pushed by a token other than `GITHUB_TOKEN`, or they start no workflow. It also needs GitHub Pages enabled with GitHub Actions as its source, and a `*-v*` tag rule on its `github-pages` environment, or publishing a Release deploys nothing; both are settings a repository admin makes. The commands are bash: in zsh, run `setopt interactive_comments` first, so that the `#` comments are not taken as arguments; on Windows, use Git Bash.

The packages are versioned independently, and a release names the versions it sets, as `<package>@<version>` pairs where `<package>` is the directory under `packages/`. `scripts/set-versions.dart` writes each version, raises the `^` constraint the other packages have on it, and turns the package's `## [Unreleased]` notes into that version's section of its `CHANGELOG.md`. The workflow then checks everything with `scripts/build-release.sh`, commits the versions to `main`, and gives every package it released a `<package>-v<version>` tag and a draft GitHub Release. Each tag starts `publish.yml`, which publishes the package to pub.dev — unless it still carries `publish_to: none`, in which case it is released on GitHub alone. What each version gained is written in its package's `CHANGELOG.md` and nowhere else: a Release carries a link to that changelog. A contributor's pull request carries no version and no changelog entry — both are written here. There is no release branch: what `main` holds is what goes out, so `main` holds only what can ship.

Every block runs as written in a new shell: it works out what it needs from git and GitHub. One value is set by hand, written as a placeholder to fill in: `<versions>`, the pairs from step 1 in quotes, in steps 4 and 5 and their retry under [Undoing a release](#undoing-a-release). A block that acts on a tag or package you chose takes it as `<tag>` or `<package>` the same way. Left as it is, a placeholder stops its line with a syntax error, and a list left unquoted leaves `VERSIONS` unset, which the dispatch refuses: an empty `versions` is the retry of whatever is not yet released.

An agent can run every block. A person sorts the scan's matches in step 4 and decides two steps — the merge in step 2, which puts the notes on `main`, and step 6, which publishes the Releases for good — and step 5 too once a package is on pub.dev, where its tag publishes it for good. A package's first version on pub.dev is a person's to publish (see [Opening a package to pub.dev](#opening-a-package-to-pubdev)).

### 1. Decide the versions

Look at what each package gained since its previous tag. A package gets a new version only when it is named: one that depends on a package being released keeps its own version, with its constraint raised for its next release. The SDK the packages fetch is `_sdkVersion` in `packages/*/hook/build.dart`, and the bindings committed under `packages/` are generated from the `SpriteStudio-SDK` submodule, so both hooks and the submodule must name the same SDK release: point all three at it first, in an ordinary pull request into `main`; `scripts/build-release.sh` says whether the bindings need regenerating. The last two lines below print the release the hooks pin and the tag the submodule is on, and stop when it is on none.

```bash
git fetch origin --tags
for pkg in $(git ls-tree -r --name-only origin/main -- packages | sed -n 's|^packages/\([^/]*\)/pubspec\.yaml$|\1|p'); do
  prev=$(git -c versionsort.suffix=- tag --list "$pkg-v*" --sort=-v:refname | head -n 1)
  echo "== $pkg, last released: ${prev:-never}"
  git log --oneline ${prev:+"$prev.."}origin/main -- "packages/$pkg"
done
git show origin/main:packages/ssruntime_dart/hook/build.dart origin/main:packages/ssconverter_dart/hook/build.dart | grep '^const _sdkVersion'
git -C SpriteStudio-SDK fetch -q --tags && git -C SpriteStudio-SDK describe --tags --exact-match "$(git rev-parse origin/main:SpriteStudio-SDK)"
```

A run releases every package whose current version has no Release yet, named or not. So the first release names every package at the version it already has:

```text
ssruntime_dart@7.0.0-beta.1 ssconverter_dart@7.0.0-beta.1 ssplayer_flutter@7.0.0-beta.1 ssplayer_flame@7.0.0-beta.1 ssgen_dart@7.0.0-beta.1 ssgen_flutter@7.0.0-beta.1
```

Steps 4 and 5 take the decision in place of their `<versions>`, in quotes, as in `"ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2"`.

### 2. Write the changelog

For each package being released, write what it gained under `## [Unreleased]` in `packages/<dir>/CHANGELOG.md`, in Keep a Changelog's sections (`### Added`, `### Changed`, `### Fixed`, `### Removed`), and merge it into `main` with a pull request. If a dependency the packages bundle changed, bring `THIRD_PARTY_NOTICES.md` up to date in the same pull request. The release turns each `## [Unreleased]` into `## [<version>] - <date>`, and stops before building anything when a package it releases has nothing there.

```bash
git switch -c release-notes origin/main
# write under ## [Unreleased] in packages/<dir>/CHANGELOG.md
git add packages/*/CHANGELOG.md THIRD_PARTY_NOTICES.md
git commit -m "docs: changelog for the next release"
git push -u origin release-notes
gh pr create -B main --fill
```

**A person runs the merge**, which puts the notes on `main`: choose **Create a merge commit** on the pull request's page, or run

```bash
gh pr merge release-notes --merge --delete-branch
```

### 3. Check it locally

The tests and the generated code are checked here and nowhere else: `release.yml` runs `scripts/build-release.sh` with `checks=analyze codegen=skip`, and no workflow runs the tests. The site is built here too: `pages.yml` builds it only once a Release is published, from its tag, and a re-run builds that same tag, so a fault in the docs or the demos found then can only be fixed in `main` and deployed from there. `scripts/build-pages.sh` builds what `pages.yml` deploys, in the same order. Run all of it from the `main` the release will be cut from, and fix a failure by a pull request into `main` before step 4.

```bash
git switch main && git pull --ff-only && git submodule update --init --recursive &&
  scripts/build-runtime.sh &&                     # the Brain and its C headers, from the submodule
  scripts/deploy-examples.sh &&                   # the packs the tests play; without them they report skipped
  scripts/build-release.sh &&                     # analyze, tests, generated code, dry-run publish
  scripts/build-pages.sh                          # -> site/, the site pages.yml would deploy
```

A check that cannot run says so and passes, so read the output, not only the exit status. `ffigen SKIPPED` or `flatc SKIPPED` means the generated code went unchecked, and a package still carrying `publish_to: none` reports what would block its publish as `would not publish` without failing the script.

### 4. Look at it first

A dry run sets the versions and checks everything, and commits, tags and releases nothing. The per-package archives and dry-run reports stay on the run (`release-dist`); the block downloads them into `qa/<run ID>`, and fails when the run did. Once a tag is pushed, a package without `publish_to: none` is on pub.dev for good, so this is the last look before that.

```bash
VERSIONS=<versions>                               # the pairs from step 1, in quotes
RUN=$(gh workflow run release.yml --ref main -f versions="${VERSIONS:?}" -f dry_run=true | sed 's|.*/||')
gh run watch "${RUN:?}" --exit-status
gh run download "${RUN:?}" -n release-dist -D "qa/$RUN"
gh run view "${RUN:?}" --exit-status > /dev/null  # the block fails when the run did
```

Scan `main` too, for code copied from others. `provenance.yml` runs SCANOSS, which matches the tracked files against public open-source code by sending their fingerprints rather than the code, and ScanCode, which finds copyright and license notices. It keeps both reports and a summary of what they found on the run (`provenance`); the block downloads them into `qa/<run ID>` and prints the summary. **A person sorts the matches.** A match with the earlier SpriteStudio Players and SDK is our own code. A match with a library this repository bundles must be listed in `THIRD_PARTY_NOTICES.md`. Anything else is rewritten, unless its license, read at its source, is compatible with BSD-3-Clause and the code keeps the notice that license asks for. Fix a match by a pull request into `main` before step 5, and run the block again.

```bash
RUN=$(gh workflow run provenance.yml --ref main | sed 's|.*/||')
gh run watch "${RUN:?}" --exit-status &&
  gh run download "${RUN:?}" -n provenance -D "qa/$RUN" &&
  cat "qa/$RUN/summary.md"
```

### 5. Run the release

```bash
VERSIONS=<versions>                               # the pairs from step 1, in quotes
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

**A person publishes the Releases**: a published Release is permanent. Nothing on a draft needs writing, and a version with a `-` is already marked as a pre-release. Publishing starts `pages.yml`, which deploys the [documentation site](https://cri-middleware.github.io/SSPlayerForFlutter/) and the web demos.

```bash
for tag in $(gh release list --json tagName,isDraft -q '.[] | select(.isDraft) | .tagName'); do
  gh release edit "$tag" --draft=false
done
```

Then watch the deploy. Every Release published starts a run of its own; they queue, and a newer one replaces one still waiting, which then shows as cancelled, so the run to watch is the one for the Release published last. The block finds that Release itself, and waits up to a minute for its run, which appears a few seconds after it.

```bash
tag=$(gh release list --json tagName,publishedAt,isDraft -q '[.[] | select(.isDraft | not)] | sort_by(.publishedAt) | last | .tagName')
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  RUN=$(gh run list -w pages.yml -b "${tag:?}" -L 1 --json databaseId -q '.[0].databaseId')
  [ -n "$RUN" ] && break
  sleep 5
done
gh run watch "${RUN:?}" --exit-status
```

Then open the site. A failed run leaves the site as it was. When the cause was a setting outside the repository, re-run it with `gh run rerun <run-id>`, the run the block watched; a fix in the repository goes into `main` by pull request and deploys with `gh workflow run pages.yml --ref main`.

## Opening a package to pub.dev

A package is published only once its pubspec drops `publish_to: none`. Do that in an ordinary pull request, then release a version of it as above. pub.dev takes an automated publish only for a package it already has, so `publish.yml` fails on that first tag, and **a person publishes the version by hand**: `dart pub publish` signs in with a Google account in a browser and asks before it uploads. Publish from a checkout of the tag, in dependency order — `ssruntime_dart` and `ssconverter_dart`, then `ssplayer_flutter` and `ssgen_dart`, then `ssplayer_flame` and `ssgen_flutter` — and fetch the web Brain before `ssplayer_flutter`, or that version goes out without it for good:

```bash
git switch --detach <tag>
flutter pub get
scripts/download-web-runtime.sh                   # ssplayer_flutter only
cd packages/<package> && dart pub publish
```

Then enable **Automated publishing** in the package's pub.dev Admin tab, with the repository `cri-middleware/SSPlayerForFlutter` and the tag pattern `<package>-v{{version}}`. From then on, a release's tag publishes it.

## Undoing a release

**A version on pub.dev is permanent** — it cannot be withdrawn — so a fault found after a published package's tag went out is fixed by a new version. So is a published Release, whose tag users depend on. Before that:

*   A run that failed before its commit reached `main` is run again with the same versions, once the cause is fixed in `main`. The **Re-run** button would replay the old commit, and its push would be rejected.

    ```bash
    VERSIONS=<versions>                               # the pairs from step 1, in quotes
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

`scripts/build-release.sh` is the check. Step 3 runs it with its defaults, and `release.yml` runs the same script before it commits or tags anything. `checks=skip sdk=skip` builds just the archives, offline, and `packages=<package>` checks one package. To check under the versions a release would set, set them first with `dart scripts/set-versions.dart <package>@<version> …`, which sets them, and dates their changelog sections, the same way the release would; put them back afterwards with `git checkout -- packages`.

*   **A private package is previewed, not skipped.** The script lifts `publish_to: none` for the
    length of the dry run and restores it however it exits, from a backup kept *outside* the package
    — pub publishes untracked files too, so a `pubspec.yaml.bak` beside the original would ship.
*   **`dart pub publish` treats warnings as fatal**, and neither `-f` nor the reusable workflow
    passes `--ignore-warnings`. `LICENSE.md` instead of `LICENSE`, a missing `CHANGELOG.md`, or one
    that does not mention the version, is enough to abort a publish. A version not yet released is
    mentioned only once `set-versions.dart` has dated its section, so check one after setting it.
*   **The pinned SDK release has to exist.** `packages/*/hook/build.dart` download `libssruntime` /
    `libssconverter` from `_sdkVersion`'s release for every consumer without a Rust toolchain, and
    the two hooks must name the *same* release. `sdk=download`, the default, failing while the SDK
    is untagged is correct — there is nothing to publish against.
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

このリポジトリの Write ロールを持つ人なら誰でもリリースできます。リリースは `main` での **Release** ワークフローの実行 1 回なので、誰の手元から始めても結果は変わりません。必要なのは `git` と `gh` 2.87 以降（最初に一度 `gh auth login`）、それに手順 3 のための、[CONTRIBUTING.md](./CONTRIBUTING.md) が用意するツールチェーン（`flatc` を含む）です。リポジトリには `RELEASE_PAT` secret が要ります。タグを `GITHUB_TOKEN` 以外のトークンで push しないと、ワークフローが起動しないためです。さらに、GitHub Pages を有効にしてソースを GitHub Actions にし、`github-pages` environment に `*-v*` のタグのルールを足しておく必要があります。どちらかが欠けると、Release を公開しても何もデプロイされません。どちらもリポジトリの admin が行う設定です。コマンドは bash です。zsh では、`#` のコメントが引数として渡されないよう、先に `setopt interactive_comments` を実行します。Windows では Git Bash を使います。

パッケージは独立にバージョンを持ち、リリースは設定するバージョンを `<package>@<version>` の組で指定します。`<package>` は `packages/` の下のディレクトリ名です。`scripts/set-versions.dart` が各バージョンを書き、他のパッケージがそれに付けている `^` の制約を引き上げ、パッケージの `## [Unreleased]` のノートを、`CHANGELOG.md` のそのバージョンの節に書き換えます。続けてワークフローが `scripts/build-release.sh` ですべてを検査し、バージョンを `main` へコミットし、リリースした各パッケージに `<package>-v<version>` のタグと下書きの GitHub Release を作ります。タグはそれぞれ `publish.yml` を起動し、パッケージを pub.dev へ publish します。ただし `publish_to: none` が残っているパッケージは GitHub だけでリリースされます。各バージョンで何が変わったかは、そのパッケージの `CHANGELOG.md` にだけ書きます。Release が持つのは、その changelog へのリンクだけです。コントリビューターのプルリクエストはバージョンも changelog の項目も持ちません。どちらもここで書きます。release ブランチはありません。`main` にあるものがそのまま出るので、`main` には出せるものだけを置きます。

どのブロックも、新しいシェルで書かれたとおりに実行できます。必要なものは git と GitHub から求めます。手で設定する値は 1 つで、埋めるプレースホルダとして書いてあります。手順 4・5 と「リリースの取り消し」にあるその再実行の `<versions>` で、手順 1 で決めた組を引用符で囲んで入れます。選んだタグやパッケージに対して操作するブロックも、それを `<tag>` や `<package>` で受け取ります。埋めずに実行すると、その行は構文エラーで止まります。組を引用符で囲み忘れると `VERSIONS` は設定されず、dispatch はそれを拒否します。空の `versions` は、まだリリースしていないものすべての再実行になるためです。

どのブロックもエージェントに実行させられます。手順 4 の照合の一致は人が仕分けます。2 つの手順は人が判断します。ノートを `main` に入れる手順 2 のマージと、取り消せない公開を行う手順 6 です。pub.dev に出したパッケージがあれば、手順 5 のタグがそれを取り消せない形で publish するので、手順 5 も人が判断します。パッケージの pub.dev への最初のバージョンも人が publish します（「パッケージを pub.dev に開く」を参照）。

### 1. バージョンを決める

各パッケージが前回のタグから何を得たかを見ます。新しいバージョンになるのは指定したパッケージだけです。リリースするパッケージに依存するパッケージは自分のバージョンを保ち、次のリリースに向けて制約だけが引き上げられます。パッケージが取得する SDK は `packages/*/hook/build.dart` の `_sdkVersion` で、`packages/` にコミットしてあるバインディングは `SpriteStudio-SDK` submodule から生成しています。そのため 2 つの hook と submodule は同じ SDK リリースを指す必要があります。先に、通常のプルリクエストで `main` の 3 つをそのリリースに合わせます。バインディングの再生成が要るかどうかは `scripts/build-release.sh` が示します。下のブロックの最後の 2 行は、hook が指すリリースと submodule が載っているタグを出し、submodule がどのタグにも載っていなければ止まります。

```bash
git fetch origin --tags
for pkg in $(git ls-tree -r --name-only origin/main -- packages | sed -n 's|^packages/\([^/]*\)/pubspec\.yaml$|\1|p'); do
  prev=$(git -c versionsort.suffix=- tag --list "$pkg-v*" --sort=-v:refname | head -n 1)
  echo "== $pkg, last released: ${prev:-never}"
  git log --oneline ${prev:+"$prev.."}origin/main -- "packages/$pkg"
done
git show origin/main:packages/ssruntime_dart/hook/build.dart origin/main:packages/ssconverter_dart/hook/build.dart | grep '^const _sdkVersion'
git -C SpriteStudio-SDK fetch -q --tags && git -C SpriteStudio-SDK describe --tags --exact-match "$(git rev-parse origin/main:SpriteStudio-SDK)"
```

run は、指定したかどうかに関わらず、現在のバージョンにまだ Release が無いパッケージをすべて出します。そのため初回のリリースでは、全パッケージをいま持っているバージョンのまま指定します。

```text
ssruntime_dart@7.0.0-beta.1 ssconverter_dart@7.0.0-beta.1 ssplayer_flutter@7.0.0-beta.1 ssplayer_flame@7.0.0-beta.1 ssgen_dart@7.0.0-beta.1 ssgen_flutter@7.0.0-beta.1
```

手順 4・5 は、決めた組を引用符で囲んで `<versions>` の位置に受け取ります（`"ssruntime_dart@7.0.0-beta.2 ssplayer_flutter@7.0.0-beta.2"` など）。

### 2. changelog を書く

リリースするパッケージごとに、得たものを `packages/<dir>/CHANGELOG.md` の `## [Unreleased]` の下に、Keep a Changelog の節（`### Added`・`### Changed`・`### Fixed`・`### Removed`）で書き、プルリクエストで `main` にマージします。パッケージが同梱する依存が変わっていれば、同じプルリクエストで `THIRD_PARTY_NOTICES.md` も更新します。リリースは各 `## [Unreleased]` を `## [<version>] - <date>` に書き換えます。リリースするパッケージの `## [Unreleased]` が空なら、何もビルドせずに止まります。

```bash
git switch -c release-notes origin/main
# packages/<dir>/CHANGELOG.md の ## [Unreleased] の下に書く
git add packages/*/CHANGELOG.md THIRD_PARTY_NOTICES.md
git commit -m "docs: changelog for the next release"
git push -u origin release-notes
gh pr create -B main --fill
```

**マージは人が行います。** ノートが `main` に入るためです。プルリクエストのページで **Create a merge commit** を選ぶか、次を実行します。

```bash
gh pr merge release-notes --merge --delete-branch
```

### 3. 手元で検査する

テストと生成コードを検査するのはここだけです。`release.yml` は `scripts/build-release.sh` を `checks=analyze codegen=skip` で実行し、テストを実行するワークフローはありません。サイトもここでビルドします。`pages.yml` がサイトをビルドするのは Release を公開したときだけで、そのタグから作ります。再実行しても同じタグをビルドするだけなので、そこで docs やデモの不具合が見つかると、`main` で直してそこからデプロイするしかありません。`scripts/build-pages.sh` は、`pages.yml` がデプロイするものを同じ順にビルドします。どれもリリースを切る `main` から実行し、失敗したら、手順 4 の前にプルリクエストで `main` を直します。

```bash
git switch main && git pull --ff-only && git submodule update --init --recursive &&
  scripts/build-runtime.sh &&                     # submodule から Brain と C ヘッダーを作る
  scripts/deploy-examples.sh &&                   # テストが再生する pack。無いとテストは skipped になる
  scripts/build-release.sh &&                     # analyze、テスト、生成コード、dry-run publish
  scripts/build-pages.sh                          # -> site/。pages.yml がデプロイするサイト
```

実行できない検査は、そう表示したうえで通過します。終了コードだけでなく出力を読みます。`ffigen SKIPPED` か `flatc SKIPPED` が出たら、生成コードは検査されていません。`publish_to: none` が残っているパッケージは、publish を妨げるものを `would not publish` として報告しますが、スクリプトは失敗しません。

### 4. 先に確かめる

dry run はバージョンを設定してすべてを検査し、コミットもタグも Release も作りません。パッケージごとのアーカイブと dry-run の報告は run に残ります（`release-dist`）。ブロックはそれを `qa/<run ID>` にダウンロードし、run が失敗していればブロックも失敗します。タグを push すると、`publish_to: none` の無いパッケージは pub.dev に出て取り消せないので、これがその前の最後の確認です。

```bash
VERSIONS=<versions>                               # 手順 1 の組を引用符で囲む
RUN=$(gh workflow run release.yml --ref main -f versions="${VERSIONS:?}" -f dry_run=true | sed 's|.*/||')
gh run watch "${RUN:?}" --exit-status
gh run download "${RUN:?}" -n release-dist -D "qa/$RUN"
gh run view "${RUN:?}" --exit-status > /dev/null  # run が失敗していればブロックも失敗する
```

`main` で、他者のコードを写した箇所が無いかも照合します。`provenance.yml` は SCANOSS と ScanCode を実行します。SCANOSS は、追跡しているファイルを公開されているオープンソースのコードと照合します。送るのはコードではなく指紋です。ScanCode は、著作権表示とライセンスの記述を見つけます。2 つの報告と、見つかったものの一覧は run に残ります（`provenance`）。ブロックはそれを `qa/<run ID>` にダウンロードし、一覧を表示します。**一致は人が仕分けます。** 以前の SpriteStudio の Player・SDK との一致は、自社のコードです。このリポジトリが同梱するライブラリとの一致は、`THIRD_PARTY_NOTICES.md` に載っていなければなりません。それ以外は書き直します。残せるのは、出所で確かめたライセンスが BSD-3-Clause と両立し、そのライセンスが求める表示をコードに残すときだけです。一致を直すときは、手順 5 の前にプルリクエストで `main` を直し、このブロックをもう一度実行します。

```bash
RUN=$(gh workflow run provenance.yml --ref main | sed 's|.*/||')
gh run watch "${RUN:?}" --exit-status &&
  gh run download "${RUN:?}" -n provenance -D "qa/$RUN" &&
  cat "qa/$RUN/summary.md"
```

### 5. リリースを実行する

```bash
VERSIONS=<versions>                               # 手順 1 の組を引用符で囲む
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

**Release の公開は人が行います。** 公開した Release は取り消せないためです。下書きに書き足すものはありません。`-` を含むバージョンは、すでに pre-release になっています。公開すると `pages.yml` が動き、[ドキュメントサイト](https://cri-middleware.github.io/SSPlayerForFlutter/) と Web デモをデプロイします。

```bash
for tag in $(gh release list --json tagName,isDraft -q '.[] | select(.isDraft) | .tagName'); do
  gh release edit "$tag" --draft=false
done
```

続けてデプロイを見届けます。Release を 1 つ公開するごとに run が 1 つ始まります。run は順に並び、待っている run は新しい run に置き換えられて cancelled と表示されるので、見届けるのは最後に公開した Release の run です。ブロックはその Release を自分で探し、run が一覧に出るまで最大 1 分待ちます。run は Release の公開から数秒遅れて出るためです。

```bash
tag=$(gh release list --json tagName,publishedAt,isDraft -q '[.[] | select(.isDraft | not)] | sort_by(.publishedAt) | last | .tagName')
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  RUN=$(gh run list -w pages.yml -b "${tag:?}" -L 1 --json databaseId -q '.[0].databaseId')
  [ -n "$RUN" ] && break
  sleep 5
done
gh run watch "${RUN:?}" --exit-status
```

終わったら、サイトを開いて確かめます。run が失敗してもサイトは元のまま残ります。原因がリポジトリの外の設定にあったなら、ブロックが見届けた run を `gh run rerun <run-id>` で再実行します。リポジトリ内の修正は、プルリクエストで `main` に入れてから `gh workflow run pages.yml --ref main` でデプロイします。

## パッケージを pub.dev に開く

パッケージが publish されるのは、その pubspec から `publish_to: none` を外してからです。通常のプルリクエストで外し、上の手順でそのパッケージのバージョンをリリースします。pub.dev が自動の publish を受け付けるのはすでにあるパッケージだけなので、その最初のタグでは `publish.yml` が失敗します。そのバージョンは**人が手で publish します**。`dart pub publish` はブラウザで Google アカウントにサインインさせ、アップロードの前に確認を求めます。タグをチェックアウトし、依存の順に publish します（`ssruntime_dart` と `ssconverter_dart`、続けて `ssplayer_flutter` と `ssgen_dart`、最後に `ssplayer_flame` と `ssgen_flutter`）。`ssplayer_flutter` の前には Web の Brain を取得します。取得しないと、そのバージョンは Web の Brain を持たないまま恒久的に残ります。

```bash
git switch --detach <tag>
flutter pub get
scripts/download-web-runtime.sh                   # ssplayer_flutter のときだけ
cd packages/<package> && dart pub publish
```

そのうえで pub.dev のパッケージの Admin タブで **Automated publishing** を有効にし、リポジトリを `cri-middleware/SSPlayerForFlutter`、タグのパターンを `<package>-v{{version}}` にします。以後はリリースのタグで publish されます。

## リリースの取り消し

**pub.dev のバージョンは恒久的です。** 取り下げられないので、publish されたパッケージのタグが出た後に見つかった不具合は、新しいバージョンで直します。公開した Release も同じで、利用者はそのタグに依存しています。それより前なら、次のようにします。

*   コミットが `main` に届く前に失敗した run は、原因を `main` で直してから、同じバージョンで実行し直します。**Re-run** ボタンは古いコミットを再生するので、その push は拒否されます。

    ```bash
    VERSIONS=<versions>                               # 手順 1 の組を引用符で囲む
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

`scripts/build-release.sh` が検査そのものです。手順 3 が既定のオプションで実行し、`release.yml` もコミットやタグの前に同じスクリプトを実行します。`checks=skip sdk=skip` を付けるとアーカイブだけをオフラインで作り、`packages=<package>` を付けると 1 つのパッケージだけを検査します。リリースが設定するバージョンで検査するなら、先に `dart scripts/set-versions.dart <package>@<version> …` で、リリースと同じ方法でバージョンを設定して changelog の節に日付を入れ、終わったら `git checkout -- packages` で元に戻します。

*   **private なパッケージはスキップせずプレビューします。** dry run の間だけ `publish_to: none` を外し、スクリプトがどう終了しても復元します。バックアップはパッケージの**外**に置きます（pub は未追跡ファイルも publish するため、隣に置いた `pubspec.yaml.bak` はアーカイブに入ってしまいます）。
*   **`dart pub publish` は警告を致命エラーとして扱います。** `--ignore-warnings` を渡すのは `-f` でも再利用ワークフローでもありません。`LICENSE` ではなく `LICENSE.md` である、`CHANGELOG.md` が無い、またはそのバージョンに触れていない、だけで publish は中断します。まだリリースしていないバージョンは、`set-versions.dart` が節に日付を入れて初めて changelog に現れるので、設定してから検査します。
*   **ピンした SDK リリースが存在している必要があります。** `packages/*/hook/build.dart` が `_sdkVersion` のリリースから、Rust ツールチェインを持たないすべての利用者向けに `libssruntime` / `libssconverter` を取得します。2 つの hook は**同じ**リリースを指す必要があります。SDK が未タグのうち `sdk=download`（既定）が失敗するのは正しい挙動です。
*   **Web の Brain は git 管理外のビルド生成物ですが、publish に含める必要があります。** `assets/runtime-web/{ssruntime.js,ssruntime_bg.wasm,ssruntime_bg.nosimd.wasm}` は `ssruntime_dart` の `web_runtime.dart` が名前で読み込むファイルで、pub は git が無視するものを publish しません。そのための `assets/runtime-web/.pubignore` で、pub はそのディレクトリの `.gitignore` の**代わりに**これを読みます。dart-lang の再利用ワークフローは checkout と `dart pub publish` の間に何も挟めないため、`publish.yml` の **`ssplayer_flutter` ジョブだけは手書き**です（同じ手順に `scripts/download-web-runtime.sh` を dry run の前に挿入）。この取得手順が消えた場合は `build-release.sh` の verify が指摘します。空の `assets/runtime-web/` を抱えた一見完全なアーカイブが pub.dev に上がるのを防ぐためです。
*   **ツールチェーンは固定しています。** `release.yml`・`publish.yml`・`pages.yml` の 3 か所で Flutter 3.47.1 にしているので、検査も publish もデモも同じものが行います。3 つは一緒に動かし、パッケージが宣言する下限を下回らないようにしてください。多くのパッケージはピンよりかなり低い下限を宣言していますが、`ssplayer_flutter` は使っている flutter_gpu が SDK に同梱されるため Flutter `>=3.47.0` です。
