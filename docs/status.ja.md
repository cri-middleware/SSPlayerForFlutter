# 実装ロードマップと現状

> [README](../README.md) から退避した進捗です。実装規約は [AGENTS.md](../AGENTS.md)、
> 設計は [architecture.ja.md](./architecture.ja.md) を参照してください。

## 実装ロードマップ

公式検証方針: `SpriteStudio-SDK/tests/overall/overall.sspj` がエディタと一致すれば合格。

- **Phase 1** — Basic（位置/回転/スケール/α の親子継承）→ BlendMode。`SpriteStudioView` で 1 体表示。
- **Phase 2** — PartsColor / Mask / Mesh / Instance / Effect、Flame 対応、配布整備、Web。

## 現状

**足場 ＋ Layer 1〜4 ＋ Phase 1 Basic 実描画**（フラグシップ SSPlayerForGodot の
`ss_internal_player.cpp` レシピに準拠）。加えて `.sspj → .ssab` 変換パッケージ
（`ssconverter_dart`：`SsConverter` API + `ssconvert` CLI + embedded 対応）。

| 項目 | 状態 |
|------|------|
| `scripts/*`（build / generate / download / assets）| ✅ 作成・ホスト(macOS)で実行検証済み |
| ネイティブビルド（`libssruntime.framework` 生成・配置）| ✅ 検証済み |
| C ヘッダ生成（SDK build.rs / cbindgen）・Dart FlatBuffers 生成（flatc）| ✅ 検証済み |
| Layer 1 `SsRuntimeBindings`（ffigen 生成・全 C-API 111 メソッド）| ✅ |
| Layer 2 `SpriteStudioInternalPlayer`（ライフサイクル / SoA / update）| ✅ |
| **Phase 1 Basic 描画**（Normal バッチ・親子継承・α・テクスチャ・BlendMode）| ✅ 実装（実機検証は下記） |
| Layer 3/4（`SpriteStudioPlayer` / `SpriteStudioView`）| ✅ |
| テクスチャ（reference＝兄弟PNG / embedded 両対応、§16C ルーティング）| ✅ |
| サブフレーム補間（既定 ON）| ✅ |
| **`ssconverter_dart`**（`SsConverter` / `ssconvert` CLI / embedded）| ✅ analyze・test・CLI 検証済み |
| **実機検証**（Flutter / `flutter analyze` 0 件、`flutter test` PASS）| ✅ |
| ↳ FFI パイプライン（load→update→FrameData→SoA）スモークテスト | ✅ PASS |
| ↳ 実描画テスト（テクスチャ付き非空フレームをラスタライズ）| ✅ PASS（目視でも overall/Basic がエディタ相当に描画） |
| **macOS デスクトップ example 起動**（`flutter run -d macos`、framework ロード＆再生）| ✅ `[ssplayer] OK — playing "anime_1"` |
| PartColor / Mask / Mesh / Effect / Instance、BoxFit スケール | ⏳ TODO（Phase 1 後半〜2）|

## Phase 1 Basic 描画の実装要点

Godot flagship 準拠。詳細は `SpriteStudio-SDK/libs/ssruntime/docs/30_core/30_render_loop.ja.md`。

- RenderMode=Direct（既定）、`coordinate_system=1`（Y-Down）。原点/単位は既定のまま。
- SoA: world(parts×16 列優先)、local_vertices(×10)、**local_uvs(×10・テクスチャピクセル座標)**。
- 頂点ベイク: `x' = m0·x + m4·y + m12`, `y' = m1·x + m5·y + m13`。
- 4 隅クアッド `{0,1,2, 1,3,2}`。UV はピクセルのまま `ImageShader`(identity) へ（Flutter は正規化不要）。
- α: `PartState.alpha` を白×α 頂点カラー＋`drawVertices(v, modulate, paint)` で乗算。
- BlendMode: Mix→srcOver / Add→plus / Mul→multiply / Sub→(近似) / 他→srcOver。
- テクスチャキー = `cellmap.name_hash` = `DrawBatch.texture_hash`（再ハッシュしない）。

> `ssruntime_bindings.g.dart`（Layer 1・gitignore）は `build-runtime` / `generate-ffigen-code` の
> ffigen で生成された全 C-API バインディング（111 メソッド）です。C の
> `unsigned char*` / `uintptr_t*` は `Pointer<UnsignedChar>` / `Pointer<UintPtr>`
> になるため、Layer 2 は境界で `.cast()` して受けています。

詳細な API 対応表は設計書と `SpriteStudio-SDK/libs/ssruntime/docs/` を参照してください。
