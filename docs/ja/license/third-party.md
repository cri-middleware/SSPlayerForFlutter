# サードパーティ通知

本プロジェクトはサードパーティのオープンソースコンポーネントを利用しています。正式な一覧は
リポジトリ直下の
[`THIRD_PARTY_NOTICES.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/THIRD_PARTY_NOTICES.md)
で、以下を含みます。

- **SpriteStudio-SDK** のネイティブライブラリ（`libssruntime` / `libssconverter`）とその Rust
  クレート依存（BSD-3-Clause）。
- **FlatBuffers**（Apache-2.0）—— `.ssab` アセット形式とランタイムの `FrameData` バッファに使用。
- **Dart / Flutter パッケージ依存** —— pub.dev 経由で各自のライセンスのもとに配布。

プリビルドのネイティブライブラリは、ソースビルドまたはダウンロード後に、対応するクレートの
ライセンス通知を同梱します。

- `packages/ssruntime_dart/native/libs/THIRD-PARTY-LICENSES.ssruntime.md`
- `packages/ssconverter_dart/native/libs/THIRD-PARTY-LICENSES.ssconverter.md`

これらのネイティブライブラリを埋め込んだアプリを再頒布する場合は、対応する通知を頒布物に
同梱してください。プロジェクトおよび SDK 本体のライセンスは [ライセンス](index.md) を参照してください。
