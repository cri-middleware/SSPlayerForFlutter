# リリース

このモノレポは単一の `main` ブランチから複数パッケージを、**パッケージごとに独立した** SemVer で公開
します。3 層それぞれに役割が 1 つずつあります:

| 関心事 | ツール |
|---|---|
| ワークスペース解決（共有ロックファイル） | **pub workspaces**（`resolution: workspace`） |
| パッケージごとの bump + CHANGELOG + git タグ | **[Melos](https://melos.invertase.dev/)**（Conventional Commits） |
| タグごとに各パッケージを公開 | **pub.dev automated publishing**（GitHub Actions OIDC） |

リリースのトリガーは**オンデマンド**: PR は通常どおり `main` にマージし、バージョンを切りたいときに
**Release** ワークフローを手動実行します。リリースブランチはありません。

## Conventional Commits で bump を決める

Melos は各パッケージの直近 `<package>-v<version>` タグ以降のコミットメッセージを読みます:

| コミット | bump |
|---|---|
| `fix: …` / `fix(<pkg>): …` | patch |
| `feat: …` / `feat(<pkg>): …` | minor |
| `feat!: …` または `BREAKING CHANGE:` フッタ | major |
| `chore` / `docs` / `refactor` / `test` / `ci` | 単独では bump なし |

スコープにはパッケージ名を使います（`feat(ssruntime_dart): …`）。バージョニングは**完全に独立**で、
`ssruntime_dart` の `feat!` は `ssruntime_dart` だけを major に上げ、依存側は自動 patch + 制約更新に
なります。

## リリースを切る（定常運用）

1. Conventional Commit のメッセージで PR を `main` にマージ。
2. **Actions → Release → Run workflow**（まず *dry-run* で算出バージョンをプレビュー）。
3. Melos が変更のあった公開パッケージを bump し、CHANGELOG を書き、`chore(release): …` をコミットして
   `<package>-v<version>` タグを push。
4. 各タグが `publish.yml` を起動し、そのパッケージだけを OIDC で pub.dev に公開。

## 注意点

- **`publish_to: none` が on/off スイッチ。** `release.yml` は `melos version --no-private` を実行する
  ので、この行がある間はリリース対象から完全に外れます。公開準備ができたときだけ外し、初回のみ依存
  順に手動公開します。
- **Native Assets はソースのみ公開。** プリビルドの `libssruntime` / `libssconverter` は利用者の
  ビルド時に各パッケージの `hook/build.dart` が取得します。`native/` は gitignore で公開アーカイブに
  含まれず、リリース時にやることはありません。
- **Melos はピン留めした workspace dev-dependency**（`>=7.0.0 <7.8.2`。7.8.2 は ffigen のピンと衝突する
  `cli_util` を引き込む）。`dart run melos …` で起動します。
- **CI のツールチェーンはピン留め**（`release.yml` で Flutter 3.44.6 / Dart 3.12.2）。パッケージの
  `environment:` は対応**下限**（`sdk: >=3.10.0`、Flutter `>=3.38.0`）のみを宣言します —— 意図的に
  低くし、利用者を CI と同一バージョンに縛りません。ローカルのツールチェーン更新に合わせて
  `release.yml` のピンを上げます。

一次情報の手順書（パッケージごとの初回セットアップ・`RELEASE_PAT` シークレット含む）は
[`docs/RELEASING.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/docs/RELEASING.md)
です。
