<!--
Thanks for contributing! See CONTRIBUTING.md for the constraints this project works under
(Widget-free L2, no per-frame allocation, generated code regenerated rather than edited).
CONTRIBUTING.md に本プロジェクトの制約が記載されています。日本語でも英語でも構いません。
-->

## What does this change? / 変更内容

<!-- What it does and why. Link any related issue: Fixes #123 -->

## How was it verified? / 検証方法

<!--
Which checks ran, and on what. If you could not run them, say so —
that is useful information, not a problem.
実行した確認と環境。実行できなかった場合はその旨をお書きください。
-->

- [ ] `flutter analyze lib test` and `flutter test` in `packages/ssplayer_flutter/`
- [ ] The other packages' suites (`dart test` / `flutter test` in each) — the Ringo tests report skipped without `scripts/deploy-examples.sh`
- [ ] `cd examples/overall && flutter run` — `[ssplayer] OK`
- [ ] Not run — see notes below / 未実行（理由は下記）

**Environment / 環境:** `flutter --version`, OS, target platform, backend (Canvas or `SS_BACKEND=gpu`)

## Checklist

- [ ] Scoped to one thing. Unrelated fixes are easier to review as their own PR.
- [ ] Follows the style of the files it touches.
- [ ] Docs updated if behaviour changed.
- [ ] Anything that exists twice changed twice — a page and its translation, a `.sh` and its `.ps1`.
- [ ] L2 (`SpriteStudioInternalPlayer`) stays Widget-free; no Widget dependency leaks downward.
- [ ] No per-frame allocations, and every `Context` / `Resource` is disposed.
- [ ] Generated `*.g.dart` regenerated with the scripts and committed, never hand-edited.
- [ ] Commit messages follow Conventional Commits; the release tooling derives version bumps from them.

## Anything reviewers should know? / レビュー時の注意点

<!-- Trade-offs you made, alternatives you rejected, parts you are unsure about. -->
