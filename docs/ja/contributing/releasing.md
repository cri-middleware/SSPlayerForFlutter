# 🚢 リリース

このモノレポは単一の `main` ブランチから複数パッケージを、**パッケージごとに独立した** SemVer で公開します。3 層それぞれに役割が 1 つずつあります:

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
`ssruntime_dart` の `feat!` は `ssruntime_dart` だけを major に上げ、依存側は自動 patch + 制約更新になります。

## リリースを切る（定常運用）

1. Conventional Commit のメッセージで PR を `main` にマージ。
2. **Actions → Release → Run workflow**（まず *dry-run* で算出バージョンをプレビュー）。
3. Melos が変更のあった公開パッケージを bump し、CHANGELOG を書き、`chore(release): …` をコミットして
   `<package>-v<version>` タグを push。
4. 各タグが `publish.yml` を起動し、そのパッケージだけを OIDC で pub.dev に公開。

## 注意点

- **`publish_to: none` が on/off スイッチ。** `release.yml` は `melos version --no-private` を実行するので、この行がある間はリリース対象から完全に外れます。公開準備ができたときだけ外し、初回のみ依存順に手動公開します。
- **Native Assets はソースのみ公開。** プリビルドの `libssruntime` / `libssconverter` は利用者のビルド時に各パッケージの `hook/build.dart` が取得します。`native/` は gitignore で公開アーカイブに含まれず、リリース時にやることはありません。
- **Melos はピン留めした workspace dev-dependency**（`^8.9.0`）。ffigen がまだ `cli_util ^0.4.2` に固定しているため、ルートの `pubspec.yaml` の `dependency_overrides` で `cli_util: ^0.6.0` に上書きし、同じ解決に同居させています。`dart run melos …` で起動します。
- **CI のツールチェーンはピン留め**（`release.yml` で Flutter 3.47.1 / Dart 3.13.1）。ほとんどのパッケージの `environment:` はそれよりずっと低い対応**下限**（`sdk: >=3.10.0`、Flutter `>=3.38.0`）のみを宣言し、利用者を CI と同一バージョンに縛りません。例外は `ssplayer_flutter` の Flutter
  `>=3.47.0` です —— flutter_gpu は SDK 同梱でバージョンを持たず、3.47 の API はソース互換を壊すため、
  GPU バックエンドはそれ未満ではコンパイルできません。ローカルのツールチェーン更新に合わせて
  `release.yml` のピンを上げます（宣言した下限を下回らせないこと）。
