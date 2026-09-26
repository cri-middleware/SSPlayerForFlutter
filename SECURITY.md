# Security Policy

## Supported Versions

SpriteStudio Player for Flutter is pre-release: nothing is published yet, and fixes are issued against `main`.
Once there are releases, this becomes "the latest one".

| Version | Supported |
|---|---|
| `main` | ✅ |
| Anything else | ❌ |

## Reporting a Vulnerability

**Please do not open a public GitHub Issue for a security problem.** Report it privately through the
official inquiry form:

👉 [**CRI Middleware Inquiry Form (English)**](https://www.webtech.co.jp/contact/en.html)

The English form has no file upload. If you need to send a reproduction, use the
[Japanese Help Center form](https://www.webtech.co.jp/help/ja/spritestudio7/inquiries/ssplayer_tool/),
which takes a zip of up to 8 MB.

Please include:

- What the impact is — crash, out-of-bounds read, arbitrary code execution, information disclosure.
- Steps to reproduce, ideally with a minimal `.ssab` and the smallest amount of Dart needed.
- The package version or commit, the SpriteStudio SDK version it builds against (`_sdkVersion` in
  `packages/ssruntime_dart/hook/build.dart`), your Flutter and Dart versions, and the platform.
- Whether the input that triggers it comes from a trusted source in your project or from somewhere
  untrusted (downloaded content, user-supplied files).

We will confirm receipt, tell you whether we can reproduce it, and let you know when a fix ships.
Please give us a chance to release that fix before disclosing publicly.

### Which repository to report to

Playback is driven by the runtime shared with the other SpriteStudio players, which lives in
SpriteStudio-SDK. If the same problem reproduces on a different SpriteStudio player, it is most likely
in that shared core. Report it here all the same and say so; we will route it.

## Scope Notes

The player loads binary animation data (`.ssab`) and hands it to the native runtime, or to its
WebAssembly build on the web. Two things are worth knowing before you decide how much to trust a pack.

**Only the file identifier is checked before the runtime sees the bytes.** `assertSsabIdentifier`
rejects a buffer without the `"SSAB"` identifier, and the player's own reads of the pack are
bounds-checked and throw on a corrupt one. The runtime then parses the buffer without verifying its
structure, so a deliberately crafted `.ssab` can still cause out-of-bounds reads in native code.

**`SpriteStudioPlayer.load` takes bytes from anywhere** — an asset bundle, the file system, the network.
Loading `.ssab` from an untrusted source is not a supported configuration: serve downloaded packs over a
channel you control, and treat them as content you vouch for.

Reports about the known gap above are welcome, but it is already known — a report that demonstrates
impact beyond it is more useful.

---

# セキュリティポリシー

## サポート対象バージョン

SpriteStudio Player for Flutter はリリース前です。まだ何も公開されておらず、修正は `main` に対して提供されます。リリースが始まった時点で「最新リリース」に切り替わります。

| バージョン | サポート |
|---|---|
| `main` | ✅ |
| それ以外 | ❌ |

## 脆弱性の報告

**セキュリティに関する問題は、公開の GitHub Issue に投稿しないでください。** 再現データ（8 MB までの zip ファイル）の添付も可能なヘルプセンターより、非公開でご報告ください。

👉 [**ヘルプセンター（お問い合わせフォーム）**](https://www.webtech.co.jp/help/ja/spritestudio7/inquiries/ssplayer_tool/)

ご報告には以下を含めてください。

- 影響の内容（クラッシュ、境界外読み取り、任意コード実行、情報漏洩など）
- 再現手順。可能であれば最小限の `.ssab` と、必要最小限の Dart コード
- パッケージのバージョンまたはコミット、ビルドに使う SpriteStudio SDK のバージョン（`packages/ssruntime_dart/hook/build.dart` の `_sdkVersion`）、Flutter と Dart のバージョン、対象プラットフォーム
- 引き金となる入力が、プロジェクト内の信頼できるデータか、信頼できない経路（ダウンロードコンテンツ、ユーザーが用意したファイル）由来か

受領の確認、再現可否、修正版の公開時期についてご連絡します。修正を公開するまでの間、公表をお待ちいただけますようお願いします。

### 報告先リポジトリの判断

再生処理は、他の SpriteStudio Player と共通のランタイムが担っており、SpriteStudio-SDK で開発されています。他の SpriteStudio Player でも同じ問題が再現する場合、共通コア側の問題である可能性が高いため、その旨を添えて本リポジトリへご報告ください。こちらで振り分けます。

## 既知の注意点

本プレイヤーはバイナリのアニメーションデータ（`.ssab`）を読み込み、ネイティブランタイム（Web では WebAssembly 版）へ渡します。パックをどこまで信頼するかを判断する前に、2 点を把握してください。

**ランタイムに渡す前に確認するのはファイル識別子だけです。** `assertSsabIdentifier` は `"SSAB"` 識別子の無いバッファを拒否し、プレイヤー自身によるパックの読み取りは境界チェック付きで、破損していれば例外を投げます。その後ランタイムは構造を検証せずにバッファを解析するため、意図的に細工された `.ssab` はネイティブコードで境界外読み取りを引き起こす可能性があります。

**`SpriteStudioPlayer.load` はどこから来たバイト列でも受け付けます**（アセットバンドル、ファイルシステム、ネットワーク）。信頼できない入手元の `.ssab` の読み込みはサポート対象外です。ダウンロードするパックは自社管理の経路で配信し、内容を保証できるコンテンツとして扱ってください。

上記の既知の課題に関するご報告も歓迎しますが、すでに把握している内容です。これを超える影響を示すご報告のほうが有用です。
