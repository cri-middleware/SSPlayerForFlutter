# 実装ロードマップと現状

> [README](../README.md) から退避した進捗です。実装規約は [AGENTS.md](../AGENTS.md)、
> 設計は [architecture.ja.md](./architecture.ja.md) を参照してください。

## 実装ロードマップ

公式検証方針: `SpriteStudio-SDK/tests/overall/overall.sspj` がエディタと一致すれば合格。

- **Phase 1** — Basic（位置/回転/スケール/α の親子継承）→ BlendMode。`SpriteStudioView` で 1 体表示。
- **Phase 2** — PartsColor / Mask / Mesh / Instance / Effect、Flame 対応、配布整備、Web。

## 現状

**足場 ＋ Layer 1〜4 ＋ Phase 1 Basic 実描画 ＋ PartColor（§10）**（フラグシップ
SSPlayerForGodot の `ss_internal_player.cpp` レシピに準拠）。加えて `.sspj → .ssab`
変換パッケージ（`ssconverter_dart`：`SsConverter` API + `ssconvert` CLI + embedded
対応）と、SS7 保存 → プレビュー即更新のライブリロード（`ssgen_dart` / `ssgen_flutter`
＋ `ssdev` ランナー）。

| 項目 | 状態 |
|------|------|
| `scripts/*`（build / generate / assets）| ✅ 作成・ホスト(macOS)で実行検証済み |
| ネイティブビルド（bare dylib 生成・各バインディングパッケージ `native/libs/` へ配置）| ✅ 検証済み |
| ネイティブ同梱（Native Assets: `hook/build.dart` が `CodeAsset` として同梱）| ✅ dart/flutter test・`flutter build macos` で検証済み |
| C ヘッダ生成（SDK build.rs）・Dart FlatBuffers 生成（flatc）| ✅ 検証済み |
| Layer 1 `@Native` バインディング（`ssruntime_dart`・ffigen 生成・トップレベル C-API）| ✅ |
| Layer 2 `SpriteStudioInternalPlayer`（ライフサイクル / SoA / update）| ✅ |
| **Phase 1 Basic 描画**（Normal バッチ・親子継承・α・テクスチャ・BlendMode）| ✅ 実装（実機検証は下記） |
| Layer 3/4（`SpriteStudioPlayer` / `SpriteStudioView`）| ✅ |
| テクスチャ（reference＝兄弟PNG / embedded 両対応、§16C ルーティング）| ✅ |
| サブフレーム補間（既定 ON）| ✅ |
| **PartColor（§10）**（Normal パーツ・`FragmentProgram`・4 隅補間・Mix/Mul/Add/Sub）| ✅ 実装・`test/part_color_test.dart` PASS |
| **Mask（§9）**（カバレッジビットマップ・スコープ/極性/OP・カットアウト閾値）| ✅ 実装・`test/mask_test.dart` PASS・example で Mask.ssab 目視確認済み |
| ↳ Mesh / Shape / Text / Nines を writer とするマスク | ⏳ 各 kind 移植時（現状 Normal / Mask パーツのみ。writer 収集で `quadGeometry` により除外＝誤形状で clipping しない）|
| ↳ Instance 配下へのマスク継承（§3-2-2）| ⏳ Instance kind 移植時 |
| **Mesh（§8）**（ワールド頂点 SoA・CSR スライス・index 再ベース・バッチ描画）| ✅ 実装・`test/mesh_test.dart` PASS |
| ↳ Mesh の PartColor（Whole-only＝`lt` 一律）／ Mesh のマスク対象判定 | ⏳ TODO（シェーダが varying を取れずクアッドアフィンに乗らないため）|
| **`ssconverter_dart`**（`SsConverter` / `ssconvert` CLI / embedded）| ✅ analyze・test・CLI 検証済み |
| **ライブリロード**（`ssgen_dart` / `ssgen_flutter` / `ssdev`・SS7 保存→即反映）| ✅ desktop / mobile 実動 |
| **実機検証**（Flutter / `flutter analyze` 0 件、`flutter test` PASS）| ✅ |
| ↳ FFI パイプライン（load→update→FrameData→SoA）スモークテスト | ✅ PASS |
| ↳ 実描画テスト（テクスチャ付き非空フレームをラスタライズ）| ✅ PASS（目視でも overall/Basic がエディタ相当に描画） |
| **macOS デスクトップ example 起動**（`flutter run -d macos`、Native Assets 同梱＆再生）| ✅ `[ssplayer] OK — playing "anime_1"` |
| ↳ 埋め込み検証（`flutter build macos` → `.app/Contents/Frameworks/ssruntime.framework`）| ✅ NativeAssetsManifest.json 写像確認済み |
| Mesh / Effect / Instance / Shape / Nines、BoxFit スケール | ⏳ TODO（Phase 2）|

## Phase 1 Basic 描画の実装要点

Godot flagship 準拠。詳細は `SpriteStudio-SDK/libs/ssruntime/docs/30_core/30_render_loop.ja.md`。

- RenderMode=Direct（既定）、`coordinate_system=1`（Y-Down）。原点/単位は既定のまま。
- SoA: world(parts×16 列優先)、local_vertices(×10)、**local_uvs(×10・テクスチャピクセル座標)**。
- 頂点ベイク: `x' = m0·x + m4·y + m12`, `y' = m1·x + m5·y + m13`。
- 4 隅クアッド `{0,1,2, 1,3,2}`。UV はピクセルのまま `ImageShader`(identity) へ（Flutter は正規化不要）。
- α: `PartState.alpha` を白×α 頂点カラー＋`drawVertices(v, modulate, paint)` で乗算。
- BlendMode: Mix→srcOver / Add→plus / Mul→multiply / Sub→(近似) / 他→srcOver。
- テクスチャキー = `cellmap.name_hash` = `DrawBatch.texture_hash`（再ハッシュしない）。

> `packages/ssruntime_dart/lib/src/ssruntime_bindings.g.dart`（Layer 1・**コミット済み**）は
> `generate-ffigen-code`（スタンドアロン。`build-runtime` からは呼ばれない）の
> ffigen で生成された全 C-API バインディング（111 メソッド）です。C の
> `unsigned char*` / `uintptr_t*` は `Pointer<UnsignedChar>` / `Pointer<UintPtr>`
> になるため、Layer 2 は境界で `.cast()` して受けています。

詳細な API 対応表は設計書と `SpriteStudio-SDK/libs/ssruntime/docs/` を参照してください。
