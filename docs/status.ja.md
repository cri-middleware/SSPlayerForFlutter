# 実装ロードマップと現状

> [README](../README.md) から退避した進捗です。実装規約は [AGENTS.md](../AGENTS.md)、
> 設計は [architecture.ja.md](./architecture.ja.md) を参照してください。

## 実装ロードマップ

公式検証方針: `SpriteStudio-SDK/tests/overall/overall.sspj` がエディタと一致すれば合格。

- **Phase 1** — Basic（位置/回転/スケール/α の親子継承）→ BlendMode。`SpriteStudioView` で 1 体表示。
- **Phase 2** — PartsColor / Mask / Mesh / Instance / Effect、Flame 対応、配布整備、Web。

## 現状

**足場 ＋ Layer 1〜4 ＋ Phase 1 Basic 実描画 ＋ PartColor（§10）＋ Mask（§9）
＋ Mesh / Effect / Instance（§8）**（フラグシップ
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
| ↳ Instance 配下へのマスク継承（§3-2-2）| ⏳ TODO（下の Instance 行を参照）|
| **Mesh（§8）**（ワールド頂点 SoA・CSR スライス・index 再ベース・バッチ描画）| ✅ 実装・`test/mesh_test.dart` PASS |
| ↳ Mesh の PartColor（Whole-only＝`lt` 一律）／ Mesh のマスク対象判定 | ⏳ TODO（シェーダが varying を取れずクアッドアフィンに乗らないため）|
| **Effect（§8）**（Slot API・`EffectDrawPlan`・独立再生・パーツ α 合成）| ✅ 実装・`test/effect_test.dart` PASS |
| ↳ コマンドの動的マージ（同一 cellmap＋blend の連続コマンド）| ✅ 実装（連続する同一キーのコマンドを 1 `drawVertices` に。`buildEffectGroup` が index 再ベース・16bit 上限でグループ分割。→ [ROADMAP.md](../ROADMAP.md#performance)）|
| **Instance（§8）**（Slot API・子プレイヤー再帰・外部 `.ssab` 解決・α 伝搬）| ✅ 実装・`test/instance_test.dart` PASS・example で Instance.ssab 目視確認済み |
| ↳ 再生属性（label/loop/speed/reverse/pingpong/independent）| ✅ **すべて Brain 側**（`ss_instance_slot_step` が解決）。Body は `PartAttributeInstance` を一切読まない |
| ↳ Instance 配下へのマスク継承（§3-2-2＝親の `mask_local_to_uv * slot_xf` を子に渡す）| ⏳ TODO（子は自前のマスクは正しく描ける。親→子の継承のみ未実装）|
| ↳ Instance パーツ自身の PartColor | ⏳ TODO（フラグシップも未対応。α のみ伝搬）|
| ↳ 子リソースの共有（現状 1 インスタンスパーツ＝1 Resource）| ⏳ 最適化 TODO（Context は個別必須だが Resource は共有できるはず）|
| **Shape（§11）**（中心ファン・ローカル頂点×world 行列・box_coords 4隅バイリニア・バッチ結合）| ✅ 実装・`test/shape_test.dart` PASS・example で Shape.ssab 目視確認済み |
| ↳ Shape の PartColor | ✅ **合成式をバイパス**（§1-2-3）＝頂点色＝`pc.rgba` 直値・Mix 固定・rate 1.0。シェーダ不要（頂点カラーのみ） |
| ↳ Shape を writer とするマスク | ✅ 実装（ポリゴンそのものがマスク＝カットアウト閾値なし §2-5「シェイプの特例」。テクスチャもシェーダも不要）|
| ↳ Shape をマスク対象とするマスク | ✅ 実装（頂点カラー × `partcolor.frag` をマスクゲートとして modulate）|
| ↳ **Arrow シェイプ**（Triangle/Rectangle/Star は正しい）| ⚠️ **SDK 側の不整合**（下記）|
| **`ssconverter_dart`**（`SsConverter` / `ssconvert` CLI / embedded）| ✅ analyze・test・CLI 検証済み |
| **ライブリロード**（`ssgen_dart` / `ssgen_flutter` / `ssdev`・SS7 保存→即反映）| ✅ desktop / mobile 実動 |
| **実機検証**（Flutter / `flutter analyze` 0 件、`flutter test` PASS）| ✅ |
| ↳ FFI パイプライン（load→update→FrameData→SoA）スモークテスト | ✅ PASS |
| ↳ 実描画テスト（テクスチャ付き非空フレームをラスタライズ）| ✅ PASS（目視でも overall/Basic がエディタ相当に描画） |
| **macOS デスクトップ example 起動**（`flutter run -d macos`、Native Assets 同梱＆再生）| ✅ `[ssplayer] OK — playing "anime_1"` |
| ↳ 埋め込み検証（`flutter build macos` → `.app/Contents/Frameworks/ssruntime.framework`）| ✅ NativeAssetsManifest.json 写像確認済み |
| Shape / Nines / Text、BoxFit スケール | ⏳ TODO（Phase 2。Mesh / Effect / Instance は上記の通り実装済み）|

## 機能どうしの整合性（kind × 横断機能）

各 kind が「PartColor / マスク writer / マスク対象 / α（Instance 連鎖）」をどう扱うかの一覧。
**コードから機械的に確認した結果**であって、ドキュメントの記述ではありません（確認方法も併記）。

| kind | PartColor (§10) | マスク writer (§9) | マスク対象 (§9) | α スケール (§8 Instance 連鎖) |
|---|---|---|---|---|
| **Normal** | ✅ シェーダで 4隅補間 | ✅ スプライトクアッド | ✅ | ✅ |
| **Mask**（純粋マスク） | — 色を描かない | ✅ スプライトクアッド | — | — |
| **Shape** | ✅ 頂点カラー（式バイパス）| ✅ ポリゴン・閾値なし | ✅ | ✅ |
| **Mesh** | ⏳ TODO | ❌ 除外（誤形状を描くよりマシ）| ⏳ TODO | ✅ |
| **Effect** | ❌ 非対応（plan が自前の色を持つ）| ❌ | ⏳ TODO | ✅ |
| **Instance** | ⏳ TODO（フラグシップも未対応）| ❌ | ⏳ TODO（§3-2-2 継承も未）| ✅ |
| **Nines / Text** | ❌ kind 自体が未実装 | ❌ 除外 | ❌ | — |

確認方法（再現手順）:

* **マスク対象**: `MaskPlan.bitsForTarget` の呼び出し元は `_emitNormalBatch` と `_emitShapeBatch` の 2 箇所のみ。
  → Mesh / Effect / Instance はマスク対象になってもテストされず素通しで描かれる。
* **PartColor**: `PartColor.read` の呼び出し元は `_emitNormalBatch`（シェーダ経路）と
  `GeometryBuilder.buildShapeParts`（頂点カラー経路）の 2 箇所のみ。
* **マスク writer**: `MaskPartFlags.drawableWriter` ＝ `quadGeometry || shapeGeometry`。
  `quadGeometry` は Normal / Mask パーツ型、`shapeGeometry` は Shape パーツ型。他は writer 収集で落とす。
* **α スケール**: `DrawFrame.alphaOf` が一点集約なので、それを通る全経路
  （`buildNormalParts` / `buildMeshGeometry` / `buildEffectCommand` / `buildShapeParts` /
  `_emitInstanceBatch`）に届く。シェーダ経路だけは `pc.scaleAlpha(frame.alphaScale)` で別途適用
  （PartColor の α には階層 α が事前合成済みなので再乗算してはいけないため）。

### 既知の不整合・要判断

* **Arrow シェイプ（SDK 側）**: ランタイムの `compute_shape_vertices` は Rectangle / Triangle / Star を
  `[center, 周, 閉じ]` の**中心ファン**で出すのに、**Arrow だけ中心頂点なしの素の 7 点多角形**を出します
  （`libs/ssruntime/src/core/geometry.rs`）。一方で全プレイヤー（Godot / Unity / Web / 本実装）は
  `(0, i+1, i+2)` の中心ファンとして消費するため、**Arrow は矢印の外側が塗られます**
  （5 枚のファン三角形のうち 2 枚が多角形外：数値確認済み）。
  **修正は SDK 側が正しい**（Arrow にも中心＋閉じ頂点を足して count 7→9。12 スロットに収まる）。
  そうすれば 4 プレイヤーすべてが同時に直ります。Body 側で個別対応すると、内部の頂点順に依存した
  脆いコードが 4 リポジトリに散ります。Triangle / Rectangle / Star は影響ありません。
* **マスク writer のアンチエイリアス**: カバレッジは「数」であって絵ではないため、
  writer のエッジが AA されると半端な値が**別の writer のビット**としてデコードされ得ます。
  Shape writer は `isAntiAlias = false` で描いていますが、既存のクアッド writer 経路
  （`drawPath` ＋ シェーダ）は Paint 既定の AA のままです。実害はエッジ 1px に限られるものの、
  同じ理由で AA を切るべきです（未対応・低優先）。

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
