# SpriteStudio-SDK v7 Flutter Player アーキテクチャ設計書

> 本書は元の PDF「SpriteStudio-SDK v7 Flutter Player アーキテクチャ設計書」をテキスト化し、
> リポジトリ内で参照・更新できるようにした Markdown 版です。設計意図の一次情報として扱います。
> C-API の正確なシグネチャは生成ヘッダ（cbindgen 出力：`packages/ssplayer_flutter/native/include/`）と
> SDK 移植ガイド（`SpriteStudio-SDK/libs/ssruntime/docs/`）を正とします。

---

## 0-A. コールドスタート（この設計の実装をどこから続けるか）

- **現状**: 足場 ＋ Layer 1〜4 ＋ **Phase 1 Basic 実描画**まで完了。フラグシップ
  `SSPlayerForGodot/ss_player/ss_internal_player.cpp` の描画レシピに準拠。
  `flutter analyze` 0 件、`flutter test` 2 件 PASS、`flutter run -d macos` で
  `[ssplayer] OK — playing "anime_1"`（実描画確認済み）。
- **まず読むもの**:
  - [`../AGENTS.md`](../AGENTS.md) — 実装規約・要注意点（FFI 寿命 / ネイティブ同梱（Native Assets）/ `updateFlag` の罠 / UV ピクセル座標 / 再ハッシュ禁止）。
  - [`../README.md`](../README.md) — 構成・セットアップ・テスト・Dart API 使い方。
  - `SpriteStudio-SDK/libs/ssruntime/docs/30_core/30_render_loop.ja.md` — レンダリング契約（一次情報）。
- **主要ファイル**: `packages/ssplayer_flutter/lib/src/{internal_player,player,texture_registry,texture_loader,ssab_info}.dart`、`render/{sprite_studio_view,geometry_builder,blend,part_color}.dart`。L1 バインディングは `packages/ssruntime_dart/lib/src/ssruntime_bindings.g.dart`（`@Native`）。
- **描画の分割（リファクタ済み）**: L2 は「FFI ライフサイクル＋トランスポート＋ kind 別ディスパッチ」を持ち、頂点ベイクは純粋（Widget/FFI 非依存）な `GeometryBuilder`（`DrawFrame` バンドルを消費）へ、ブレンド写像は `render/blend.dart` へ切り出し済み。兄弟移植（Web `GeometryBuilder` / Unity `SpriteStudioGeometryBuilder` / Godot `_build_*`・`_emit_*`）に倣う。`paint()` の `switch (batch.kind)` は全 kind を列挙し、未移植 kind は Phase-2 の差し込み口として明示的にスキップする。
- **次の作業（Phase 2）**: PartColor（§10, `render/part_color.dart` ＋ `shaders/partcolor.frag`）と
  Mask（§9, `render/mask.dart` ＋ `shaders/mask_write.frag`）は**実装済み**。以降は Mesh / Effect / Instance（§8）
  → BoxFit スケール配置 → 各プラットフォーム同梱の実機検証（Linux/Windows/iOS/Android）。各 kind の実装は
  `GeometryBuilder` に build メソッドを足し、`paint()` の対応 case を埋める形で追加する。なお各 kind を移植するときは、
  その kind が **マスクの書き手にも対象にもなり得る**ことに注意（現状の writer 収集は Normal / Mask パーツの 4 隅クアッド前提）。

### 実装と設計の差分（重要・設計書本文の訂正）

実装／実ランタイム検証で判明した、本文と異なる点。**実装ではこちらを正とする**。

| 箇所 | 設計書の記述 | 実装での事実 |
|---|---|---|
| §7 `local_uvs` | 「parts×8 float」 | **parts×10**（`lt,rt,lb,rb,center` の 5UV）。`local_vertices` と同ストライド。 |
| §7 テクスチャハッシュ取得 | `ss_runtime_get_cell_texture_hashes` | その API は無い。`DrawBatch.texture_hash()`（＝`cellmap.name_hash`）を使う。セルメタは `ss_runtime_get_cell_meta`。 |
| §7 UV 座標系 | 「そのまま渡すだけ」 | UV は**テクスチャピクセル座標**。Flutter は `ImageShader`(identity) がピクセル空間サンプルなので**そのまま渡せる**（Godot は正規化が必要）。 |
| §16C テクスチャ | 「embedded を既定」 | SDK 同梱の `overall` は **reference（兄弟 PNG）**。実装は reference/embedded 両対応でセルマップ毎にルーティング。 |
| §5 座標系設定 | 座標系/原点/単位の 3 つを設定 | フラグシップは `ss_context_set_coordinate_system(ctx,1)` のみ設定。原点/単位は既定のまま（配置は Body が `dst` 中央で行う）。 |
| §6 `set_speed` | `ss_runtime_set_speed` | 実 API は `ss_runtime_set_animation_speed`。 |
| FlatBuffers `updateFlag` | （言及なし） | 生成 Dart の `bit_flags` enum は複合ビットで `StateError` を投げる。`PartState.updateFlag` は**呼ばず**生 uint64 を読む。Basic は 4 隅クアッド固定で回避。 |

---

## 前提

SpriteStudio-SDK は本 Flutter リポジトリに Git サブモジュールとして組み込まれ、`libssruntime`（Brain）と
`libssconverter` の C-API・FlatBuffers スキーマ（`.fbs`）を参照します。Flutter Player は移植ガイドにおける
**Body（描画・リソース・座標変換）**の実装です。描画バックエンドは **Impeller** を前提とします。

## 0. 参照ドキュメント対応表

本書の各章と、準拠元の移植ガイド（`SpriteStudio-SDK/libs/ssruntime/docs/`）の対応。

| 本書 | 準拠元 |
|---|---|
| §1 Brain/Body 分担 | `10_introduction/10_introduction.ja.md` / `20_design/20_architecture.ja.md` |
| §3 準備・プロジェクト構成 | `20_design/10_preparation.ja.md` |
| §4 実装ロードマップ | `20_design/30_implementation_roadmap.ja.md`（`tests/overall/overall.sspj` 検証） |
| §5 ロードと初期化 | `30_core/10_initialization.ja.md` / `50_reference/10_no_std_integration.ja.md` |
| §6 再生制御とイベント | `30_core/20_playback_control.ja.md` |
| §7 レンダリングループとバッチ描画 | `30_core/30_render_loop.ja.md` / `SCHEMA.ja.md` |
| §8 Instance / Effect / Mesh | `40_components/{10_instance,20_effect,30_mesh}.ja.md` |
| §9 Mask | `40_components/40_mask.ja.md` |
| §10 パーツカラー | `40_components/50_parts_color.ja.md` |
| §11 外部リソースとオプション機能 | `40_components/70_external_resources.ja.md` |
| §12 アニメーションブレンド | `40_components/60_animation_blending.ja.md` |
| §13 特殊アトリビュート（UV / Flip） | `40_components/...special_parts` |
| §14 no_std / FFI 統合 | `50_reference/10_no_std_integration.ja.md` |
| §15 トラブルシューティング | `50_reference/20_troubleshooting.ja.md` |
| §16 エディタ連携・アセットパイプライン | `60_tooling/10_editor_integration.ja.md` |
| §18 既知の制限 | `10_introduction/20_limitations.ja.md` |

---

# 第1章 設計と準備

## 1. コア設計思想と Brain / Body 分担

準拠: `10_introduction` / `20_design/20_architecture`。

「Flutter 標準の宣言的 Widget エコシステムへの親和性」と「Brain（Rust）への計算集約 ＋
`dart:ui` `Canvas.drawVertices` による軽量描画」の両立。

- **Brain（頭脳・計算）= `libssruntime`**: 時間管理・補間・属性計算・サブフレーム（`f32`）管理・
  DrawBatch プラン生成。ステートレスな計算機。
- **Body（身体・描画）= Flutter Player**（本書対象）: FlatBuffers による `.ssab` メタデータの解釈、
  リソース検証、テクスチャ／音声のロード、ワールド座標変換、描画実行、イベント処理。
- **プレイヤー実装者の責務**: ライブラリ統合（`dart:ffi`）、メモリ戦略（Borrow/Copy）、座標系設定、アセット管理範囲の決定。
- **ハイブリッド構成**: 表層は `SpriteStudioView` 等の Widget として提供し導入の敷居を下げる。重い計算は Brain（SIMD）に集約。
- **【重要】Dart 側は「計算ゼロ」ではない**: Brain はローカル頂点とワールド行列を別々（SoA）で返すため、
  バッチを 1 回の `drawVertices` にまとめる場合は Body（Dart）側で各パーツ頂点に `M·v` を適用してベイクする必要がある（§7）。
  1 パーツ 4〜5 頂点の軽量な行列適用で、補間・属性計算といった重い処理は Brain 側に残る。
- **「逃げ道」設計**: 共通コア（Layer 2 の InternalPlayer・Layer 3 の Player）を Widget 非依存の Pure Dart として保ち、
  Flame・`CustomPainter`・`flutter_gpu`・ヘッドレステストから再利用可能に。ffigen 生成の生 Pointer API も公開する。

## 2. レイヤーアーキテクチャ（4 層・Flutter Body の内部構造）

Body の内部は 4 層。各層は単一責務を持ち、上位が下位を保持する厳密な下降依存
（Brain → L1 bindings → L2 InternalPlayer → L3 Player → L4 View）。下位ほど Brain（Rust）に近い。

```
Layer 4  描画アダプタ Widget/Painter
  ├─ SpriteStudioView (LeafRenderObjectWidget + RenderBox)   ← 必須
  └─ SpriteStudioComponent / Painter (Flame / CustomPaint)   ← 任意
Layer 3  ユーザー向け制御
  └─ SpriteStudioPlayer (ChangeNotifier / Ticker / play・seek・events)
Layer 2  描画特化エンジン (Pure Dart)
  ├─ SpriteStudioInternalPlayer (Resource・Context / paint = kind 別ディスパッチ)
  ├─ ssab メタデータ (Dart FlatBuffers パース)
  ├─ GeometryBuilder + DrawFrame (DrawBatch + SoA → ui.Vertices ベイク・純粋)
  ├─ blend.dart (BlendType → ui.BlendMode 写像)
  └─ TextureRegistry (texture_hash → ui.Image / ImageShader)
Layer 1  dart:ffi @Native Bindings（Native Assets）
  └─ ssruntime_bindings.g.dart (ffigen @Native / トップレベル関数・ローダ無し)
Brain    libssruntime (Rust Native / 計算・SIMD・DrawBatch)
```

- **Layer 1**（`ssruntime_dart` パッケージ）: SDK `build.rs` が出力する C ヘッダを入力に `package:ffigen` で
  `ssruntime_bindings.g.dart`（`@Native` トップレベル関数）を生成。ネイティブ `libssruntime` は **Native Assets**
  （`hook/build.dart` が `CodeAsset` として同梱し `@ffi.DefaultAsset` で解決）で届くため、`DynamicLibrary` ローダは無い。
  `Pointer<Void>`（Resource/Context ハンドル）、`Pointer<Uint8>`（.ssab）、SoA バッファポインタを扱う薄い層。生 API も public 公開。
- **Layer 2** (`SpriteStudioInternalPlayer` ＝ Pure Dart): 移植元の `SSInternalPlayer` 相当。FFI の Resource/Context 管理、
  `FrameData` ＋ SoA の取得、テクスチャ解決、イベント取り出し、`paint(Canvas, {Rect dst, BoxFit fit})`。
  `paint` は 1 フレーム分の `FrameData` ＋ SoA を `DrawFrame` に束ね（フラグシップの `DrawFrame` 構造体に相当）、
  `DrawBatch.kind` で分岐する。頂点ベイク自体は純粋な `GeometryBuilder`（`ui.Vertices` を返す・Canvas/FFI 非依存）に委譲し、
  ブレンド写像は `render/blend.dart` に分離する（兄弟移植の `GeometryBuilder` / blend テーブルに対応）。
  Widget 非依存・`dispose` 可能で上位やヘッドレステストから再利用。
  セルマップ・パーツ構造・親子・イベント定義は Body が `.ssab` を Dart の FlatBuffers バインディングで直接パースして得る。
- **Layer 3** (`SpriteStudioPlayer`): 移植元の `SSPlayer` 相当。InternalPlayer を 1 つ内包し、play/pause/seek/アニメ切替・
  イベント購読を公開する `ChangeNotifier`。`SpriteStudioPlayer({required TickerProvider vsync})` が `Ticker` を保持して時間を進める。
  Widget 非依存なので 1 つの Player を複数アダプタで共有できる。
- **Layer 4**: L3 の Player を受け取り（observe）、再描画通知で各 Canvas に `player.paint(canvas)` する薄いアダプタ。
  描画ロジックは InternalPlayer の paint に 1 本化。必須は `SpriteStudioView` のみ。

## 3. 準拠準備とプロジェクト構成

準拠: `20_design/10_preparation`。

- **事前確認**: ① Rust ツールチェーン、② `flatc` ＋ Dart `flat_buffers` パッケージ、③ 変換済み `.ssab` とテクスチャ。
- **リポジトリ構成**: 専用リポジトリ（pub パッケージ）に SpriteStudio-SDK を Git サブモジュールとして組み込む。
  ネイティブは各バインディングパッケージの **build hook**（`hook/build.dart`）がプリビルド dylib を `CodeAsset` として
  同梱する Native Assets 方式。プラットフォーム別のプラグインネイティブビルド（podspec / CMake）は不要。

```
（実際の構成は README.md「リポジトリ構成」を参照）
scripts/build-runtime.{sh,ps1}         # Rust ビルド ＋ 配置
scripts/generate-ffigen-code.{sh,ps1}  # ffigen（C-API 変更時に手動実行 → commit）
scripts/generate-fbs-code.{sh,ps1}     # flatc（.fbs 変更時のみ）
packages/ssplayer_flutter/             # 配布 pub パッケージ（Flutter・ssruntime_dart 依存）
example/                               # overall.sspj 検証用 Flutter アプリ
```

## 4. 実装ロードマップ

準拠: `20_design/30_implementation_roadmap`。各段階で `tests/overall/overall.sspj` を再生し、
エディタと同じ見た目になれば合格、という公式の検証方針に従う。

1. **Basic**: 位置・回転・スケール・不透明度の親子継承（ワールド行列 ＋ `drawVertices` で 1 体表示）。
2. **BlendMode / PartsColor**: 加算・乗算ブレンド（`Paint.blendMode`）と頂点／パーツカラー（`FragmentProgram`, §10）。
3. **Instance / Mask / Mesh**: Slot API・SoA バッファ、マスク（カバレッジビットマップ, §9）、メッシュ変形。
4. **UserData / Signal / Bounding**: イベントポーリングのコールバック化、当たり範囲。
5. **Effect**: Effect Slot 経由のパーティクル。

Flutter としては **Phase 1**（Basic〜BlendMode を `SpriteStudioView` で動かす）→
**Phase 2**（Mask/PartsColor/Effect/Instance、Flame、配布整備、Web）の 2 段で進める。

---

# 第2章 コア実装（基本再生）

## 5. ロードと初期化

準拠: `30_core/10_initialization` / `50_reference/10_no_std_integration`。
`SpriteStudioInternalPlayer` が Resource / Context のライフサイクルを保持する。

- **初期化シーケンス（C-API）**: ① `.ssab` バイト列 → ② `ss_resource_create_borrow(ptr, len)`（または `_copy`）で Resource →
  ③ `ss_runtime_create()` で Context → ④ `ss_runtime_bind_resource(context, resource)` で束縛 → ⑤ 座標系を設定。
- **Borrow / Copy**: Borrow＝Player がバイト列の生存責任を持ち Brain はポインタ参照のみ（ゼロコピー）。ネイティブでは Borrow 既定。
  Copy＝Brain 側がヒープに複製し元データは即破棄可。Web（WASM）は Copy を用いる。
- **座標系の 3 設定**: `ss_context_set_coordinate_system`（Y-Up/Y-Down）、`ss_context_set_origin`（中央/左上）、
  `ss_context_set_unit`（ピクセル/正規化）。Flutter は **Y-Down（値 1）・ピクセル**を基本。Y 反転は Brain が一括処理するので Body で二重反転しないこと。
  （※ 実装ではフラグシップに倣い coordinate_system のみ設定、原点/単位は既定。§0-A 差分表参照。）
- **メモリ所有権**: ① `SsabData` = Player 所有（Borrow）/ Brain 所有（Copy）。② `AnimationResource` = Brain が Arc 参照カウントで保持し、
  束縛中の全 Context 破棄まで生存。③ `Context` = Player 所有、`ss_runtime_destroy` で明示破棄。破棄順は参照カウントにより前後しても安全。
- **FrameData / SoA ポインタの寿命**: Brain 内部バッファへの借用。解放不要・次の `update` までが有効。paint 内で消費しきる（§7）。
- **検証は Body の責務**: Brain は性能優先で `.ssab` を検証しない。Player 側で先頭の識別子（オフセット 4–7 の `"SSAB"`）を確認し、
  信頼できない入力には FlatBuffers Verifier をかける。不正データは未定義動作。
- **ssab メタデータの Dart パース**: セルマップ（`image_path` 等）・パーツ構造・親子・イベント定義は Body が `.ssab` を直接読む。

## 6. 再生制御とイベント処理

準拠: `30_core/20_playback_control`。公開 API は `SpriteStudioPlayer`（制御）が提供し、内部で C-API を呼ぶ。

**A. コントローラとしての `SpriteStudioPlayer`**: `VideoPlayerController`/`AnimationController` 流に、
`SpriteStudioPlayer({required TickerProvider vsync})` が `Ticker` を保持して時間を進め、`ChangeNotifier` として状態変化を通知。

**B. 再生制御 API（C-API ラッパー）**:
- `ss_runtime_setup_animation(context, name)`（アニメをセット、frame 0 へ。name→hash は必ず `ss_runtime_hash_string` を使い、自前 FNV-1a を再実装しない）。
- `ss_runtime_play` / `ss_runtime_pause`（pause はトグル）/ `ss_runtime_set_loop(context, count)`（-1=無限）/
  `ss_runtime_set_animation_speed(context, speed)` / `ss_runtime_set_frame_no(context, frame_f32)`（サブフレーム可）/ `ss_runtime_reset`。
- `ss_runtime_update(context, delta)` — Ticker の経過時間を渡す。フレームスキップは Brain が自動算出。フレーム番号は `f32` でサブフレーム補間。
- 状態取得: `ss_runtime_is_end_frame_reached` / `ss_runtime_is_looped`。有効フレーム範囲は `[start_frame, end_frame+1)` の半開区間。末尾クランプ不要。

**C. イベント処理（ポーリング）**:
- `ss_runtime_update` の後、`ss_runtime_get_passed_event_count(context)` と `ss_runtime_get_passed_event_index(context, i)` で
  「このフレームで通過したイベント」のインデックスを取得し、Body が `.ssab` の `events()` を FlatBuffers でパースして
  `users()`（UserData）/ `signals()`（型付きパラメータ）/ `audios()`（音声指示）を読む。
- `SpriteStudioPlayer` は `onUserData` / `onSignal` / `onComplete` / `onLoop` として Stream / コールバック公開。UI isolate 上で同期ディスパッチ。
- **音声非依存**: `audios()` はトリガのみ。実際の再生はアプリ側の責務。
- **制限（§18）**: `set_frame_no` によるシークは、旧→新フレーム間のイベントを取りこぼす。

## 7. レンダリングループとバッチ描画

準拠: `30_core/30_render_loop` / `SCHEMA`。Body の中核。`SpriteStudioInternalPlayer.paint(Canvas)` が以下を実行。

**A. 毎フレームの手順**:
1. `ss_runtime_update(ctx, dt)` → `ss_runtime_get_frame_data(ctx, frame_no)` で `FrameData`（FlatBuffers ルート）を取得。
2. SoA バッファのポインタを取得（フレームに 1 回、ゼロコピー）: `ss_runtime_get_world_matrices`（parts×16 float）、
   `ss_runtime_get_local_vertices`（parts×10 float）、`ss_runtime_get_local_uvs`（**parts×10 float**）、
   `ss_runtime_get_cell_meta`（parts×6 float）。Dart からは `pointer.asTypedList(n)` でゼロコピー Float32List にする。
3. `frame_data.draw_batches()` を反復。各 DrawBatch につき Paint を 1 つ設定（`texture_hash`→`ImageShader`、`blend_type`→`Paint.blendMode`）し、
   `draw_order[start_rank .. start_rank+count)` のパーツを 1 つの Vertices に積んで `canvas.drawVertices(...)` をバッチごとに 1 回呼ぶ。

**B. DrawBatch 契約（SCHEMA）**:
- `FrameData`: `draw_order[]`（描画優先度順のパーツ index・非表示は除外）、`draw_batches[]`、`mask_indices[]`、
  `parts[]`（PartState）、プール（`cells` / `parts_color` / `vertices` / `deforms`）。
- `DrawBatch`（inline struct）: `start_rank`, `count`, `texture_hash`(uint32), `vertex_count`, `index_count`, `blend_type`,
  `kind`（Normal/Shape/Instance/Effect/Mesh/Text/Nines/Mask）, `flags`（bit `0x01` = MASK_INFLUENCE）。テクスチャ＋ブレンド＋kind が連続する区間が 1 バッチ。
- `BlendType → Paint.blendMode`: Mix→`srcOver` / Add→`plus` / Mul→`multiply` / Sub→（近似）/ その他→`srcOver`（フラグシップ準拠。非 premultiplied）。

**C. 頂点レイアウトとワールド変換（Flutter の要点）**:
- 頂点は 1 パーツ 4 隅（lt/rt/lb/rb）＋必要時 center のローカル座標。`update_flag` に `AttributeVertex` か `AttributePartColor` がある時のみ
  center を使い三角形ファンで描く（グラデーション用）。通常は 4 隅から三角形 2 枚 `{0,1,2, 1,3,2}`。プリミティブは三角形。
- **ワールド変換は Body の責務**: 各パーツのワールド行列 `M`（列優先 4×4）をローカル頂点に適用: `x'=m0·x+m4·y+m12`, `y'=m1·x+m5·y+m13`。
  UV / Flip は SoA にベイク済みでそのまま使える（§13）。UV は**テクスチャピクセル座標**で、Flutter は `ImageShader`(identity) にそのまま渡せる。
- **α**: `PartState.alpha` を白×α の頂点カラーにし、`drawVertices(v, BlendMode.modulate, paint)` で texture と乗算。
- **2 つのベイク方針**: (A) バッチベイク（推奨・採用）: 各パーツ頂点を Dart 側で `M·v` 変換しバッチ内を 1 Vertices に連結 → `drawVertices` 1 回/バッチ。
  (B) パーツ単位 `canvas.transform(M)`＋`drawVertices`（Dart 計算ゼロだがドローコール増）。原則 (A)。

**D. ゼロコピー / 性能**:
- SoA は `asTypedList` ビューで受ける（コピーなし）。`ui.Vertices.raw(...)` は構築時に 1 度コピー（シングルコピー。§18）。
- FlatBuffers のアクセサ経由の逐次読み出しは遅い。`parts` / `parts_color` 等は `ByteData` でバイトオフセット直読みする（移植ガイド 07）。
- `TextureRegistry`: `texture_hash` → `ui.Image` / `ImageShader`。名前→hash は `ss_runtime_hash_string` に揃える。

---

# 第3章 コンポーネント実装（高度な表現）

## 8. Instance / Effect / Mesh の実装

準拠: `40_components/{10_instance,20_effect,30_mesh}`。いずれも `DrawBatch.kind` で区別され、基本ループの延長として消費。

- **Instance（サブアニメ）**: `ss_instance_slot_step` が `ss_instance_step_result`（`transitioned` / `visible` /
  `child_frame_no`(float・サブフレーム精度)）を返す。親のサブフレーム補間設定を子へ再帰伝播。`ExternalInstance`（別 `.ssab` 参照）は
  `SSAB.external_instances()` から解決し、参照先 `.ssab` を Body（レジストリ）が別 Resource として供給。未供給ならスロット描画スキップ。
- **Effect（パーティクル・実装済み）**: `ss_effect_slot_step` が `EffectDrawPlan`（別 FlatBuffers ルート）を返す。フィールド:
  `commands[]`（各 `EffectDrawCommand`: `cellmap_hash` / `quad_count` / `particle_offset` / `blend`(0=Mix,1=Add)）、`verts[]`、`uvs[]`、
  `colors[]`(RGBA 0..1)、`indices[]`(コマンド内 0..quad_count*4)。引数 `y_flip=true`（Flutter は Y-Down）、`vert_stride=2`（2D）。
  実装は `render/effect.dart`（`EffectPart` ＝ ssab の `ref_effect_name_hash` 読み出し、`EffectSlots` ＝ スロット寿命＋step）
  ＋ `GeometryBuilder.buildEffectCommand`（ベイク）＋ `_emitEffectBatch`。**他の kind と異なる 3 点**:
  - **頂点はスロット空間**（slot API に行列を渡す引数が無い）＝ **エフェクトパーツの world 行列を Body が適用**する（Mesh とは逆）。
  - **UV は正規化 0..1**（runtime が `size_original` で除算済み）＝ Flutter では**テクスチャサイズを掛けてピクセルに戻す**
    （`local_uvs` / `mesh_uvs` はピクセルなので、ここだけ逆）。
  - **`blend` は `BlendType` ではない**（0=Mix / 1=Add の SS6 生値）→ `effectBlendModeFor`。`blendModeFor` に渡すと Add が Mul になる。
  - パーツ α は plan に入っていないので、頂点カラーへ合成する（`alphaOf(part)`）。seed は フラグシップと同式 `part_index ^ effect_name_hash`。
  - Effect バッチの `texture_hash` / `vertex_count` / `index_count` は無意味（テクスチャは `command.cellmap_hash`）。
  step は **`update()` 側**で行う（dt が要るため）。フラグシップは draw 内で step するため再描画の間引きが
  シミュレーションの間引きを兼ねてしまい `is_independent` の判定が要るが、Flutter は Ticker が update→paint を 1:1 で回すので不要。
  差異として、**hide 中の independent エフェクト**はフラグシップでは時計が止まり、こちらは進み続ける。
  independent 再生は `delta_seconds`＋`fps` で親停止中も進行（synced は `parent_frame` のみで決まり dt を無視）。
  同一 `cellmap_hash`＋blend の連続コマンドの動的マージは未実装（実装時は index に `dest_quad_count*4` の再ベースが必要）。
- **Mesh / Deform（実装済み）**: SoA で供給（`ss_runtime_get_mesh_vertices_x/_y`、`ss_runtime_get_mesh_uvs`、`ss_runtime_get_mesh_indices`、各 offsets）。
  頂点は X/Y 別 SoA で **既にワールド変換済み**（Normal の `local_vertices` と違い world 行列を掛けてはいけない）。
  UV はテクスチャピクセル space・interleaved で静的、index はパーツローカル 0 始まり。各バッファは **CSR 前置和**（長さ `parts+1`）で
  `[offsets[p], offsets[p+1])` にスライスし、非 Mesh パーツは空レンジ。実装は `MeshBuffers`（スライス）＋
  `GeometryBuilder.buildMeshGeometry`（ベイク）＋ `_emitMeshBatch`。**Mesh バッチは batchable（`count>1` あり）** なので、
  1 バッチを 1 `drawVertices` にまとめる際は各パーツの vertex base を index に加算する（実装済み）。
  未対応: Mesh の PartColor（Whole-only＝`lt` を全頂点へ。かつ PartColor 有り時の α は `PartState.alpha` ではなく `pc.lt.a` を使う
  ＝両者を掛けると階層 α の二重適用）と、Mesh のマスク（対象・writer とも）。いずれも `partcolor.frag` がクアッドアフィン前提のため。

## 9. Mask の実装（カバレッジビットマップ方式）

準拠: `40_components/40_mask`。`dart:ui` Canvas にはステンシルバッファが無いため、移植ガイド 3-2 の
「ステンシル非依存（カバレッジビットマップ）」経路を採用する（Godot 4.6 canvas と同方式）。

- **ランタイムが出すもの**: `draw_order[]`、`mask_indices[]`、PartState の `mask`(0..255)・`priority`・`mask_influence`、
  PartData の `mask_write` / `draw_as_mask` / `visible_inside_mask`。`DrawBatchKind::Mask` と `flags` の `MASK_INFLUENCE`(0x01) で識別。
  書き手メタは `mask_meta`（`draw_rank` / `bit` / `op_invert` / `is_clipping`）。
- **Flutter での実現（実装済み）**: `render/mask.dart`（純粋ロジック）＋ `shaders/mask_write.frag`（書き手）
  ＋ `shaders/partcolor.frag` の `maskPasses()`（対象側）。① `PictureRecorder` に各書き手の bit を
  `BlendMode.plus` で加算描画し `Picture.toImageSync()` でカバレッジ RGBA8 を得る（最大 24 書き手＝RGB 24bit）。
  ② 対象パーツは `partcolor.frag` に peel して描き、カバレッジをサンプルしてステンシルを再構成・判定する。
  マスク対象は PartColor の有無に関わらずこのシェーダを通す（PartColor 無しは `PartColor.identity`＝白・rate 0 で素通し）。
- **フラグシップとの意図的な差分（2 点）**:
  - **`mask_meta[]` 配列を持たない**。スコープ（§2-1）は CPU 側（`MaskPlan.bitsFor`）で解決し、
    シェーダへは「増分側／反転側」の 24bit セット 2 つだけを渡す。bit は draw rank 昇順に割り当てられるので、
    シェーダが bit 0→23 を走査すれば OP の適用順が draw order と一致する。
  - **1 フレーム遅延の対策が不要**。`toImageSync` は同一フレーム内でカバレッジを読めるため、移植ガイド §3-2-3 の
    サイズクラス量子化・縮小ヒステリシス・旧 target の 1 フレーム保持はいずれも実装していない（bbox 実寸・長辺 1024 上限のみ）。
- **Instance 配下のマスク**は親のカバレッジ UV 変換 `M_child = M_parent · slot_xf` を子へ伝える（Instance kind 移植時）。
- **コスト**: オフスクリーン確保と 2 パス、かつマスク対象はバッチから peel されるため重い（§18-D）。
  カバレッジはフレーム毎に確保しており、プールは未実装（最適化余地）。矩形クリップで足りる箇所は `clipRect` に落として段階最適化。

## 10. パーツカラー (Parts Color)

準拠: `40_components/50_parts_color`。パーツカラーのブレンド（シェーダ側・4 モード）は、フレームバッファ合成（`blend_type`, §7）とは別物。

- **データ表現**: `FrameData.parts_color_index()` が -1（なし）または `parts_color` プールの index。各 `parts_color` は 4 隅 lt/rt/lb/rb に
  `rgba()`（階層 α 合成済み）と `rate()`(0..1)、および `blend_type`（0 Mix / 1 Mul / 2 Add / 3 Sub）を持つ。
- **Flutter では `FragmentProgram` が必須**: `drawVertices` の `BlendMode.modulate` だけでは Mul/Add/Sub＋rate を表現できない。
  頂点カラー（CUSTOM0 相当）＋係数テーブルで統一式 `rgb = pixel_rgb·varg.x + mix(white, pixel_rgb, varg.z)·color_rgb·varg.y` を実装（CPU ブレンドはしない）。
  - フラグシップの CUSTOM0 = `(rate, blend_idx, pma, 0)`、係数テーブル `_PartColorCoef`（Mix/Mul/Add/Sub）。
- **パーツ種別ルール**: Normal=4 隅個別、Mesh=全頂点 lt 一律、Shape=`rate` を 1.0・Mix に固定。デフォルト（PartColor 無し）は白・rate 0 で素通し（＝テクスチャそのまま）。

## 11. 外部リソースとオプション機能

準拠: `40_components/70_external_resources`。多くは Body の責務。

- **テクスチャオーバーライド（Body）**: `cellmap_name_hash → Texture` のマップを Player が保持し、`DrawBatch.texture_hash()` で解決（差し替え・スキン・DL 配信）。
- **External Instance（Body）**: 外部 `.ssab` を別 Resource としてロード・キャッシュし、インスタンス setup 時に `ref_anime_hash` を解決。
- **シーケンス (.ssqe)（Body のステートマシン）**: 一括再生 API は無い。`ss_runtime_is_end_frame_reached()` を検知して
  次項目を `ss_runtime_setup_animation()` で切り替える状態機械を Player が実装する。
- **9-Slice / Shape（Runtime 側で計算済み）**: 9-slice は `local_vertices` に展開済み。Shape は `ss_runtime_get_shape_vertices()` の SoA をそのまま使う。
- **Sound（Body）**: passed_event の `audios` を監視してアプリのオーディオで再生。

## 12. アニメーションブレンド / ミキシング

準拠: `40_components/60_animation_blending`。ブレンドはランタイム駆動で、Body は API を呼ぶだけ。

- **独立再生キー**: `ss_runtime_add_blend_source(context, name, weight)` → handle、`ss_runtime_set_source_weight / _frame / _speed`、
  `ss_runtime_source_frame / _weight`。weight は相対正規化。
- **自動クロスフェード**: `ss_runtime_crossfade(ctx, from, to, duration_ms)` / `_crossfade_progress` / `_cancel_crossfade`。完了時 to が primary に昇格。
- **離散 vs 連続**: 連続値（位置・回転・スケール・α・UV・skew 等）は全ソースを重みブレンド。離散値（cell・part_color・flip・hide・priority・mesh_deform 等）は primary のみ。
  空ソース `ss_runtime_add_empty_blend_source` で setup ポーズへフェード。制約: ブレンドは同一 `.ssab` 内のみ（§18）。per-source イベント閾値は `ss_runtime_set_source_event_threshold`。

## 13. 特殊アトリビュート (UV / Flip)

準拠: special attributes。

- UV アニメ（平行移動・回転・スケール）は `FrameData.local_uvs` SoA に、Flip（`flip_h/v`・`img_flip_h/v`）は `local_vertices` SoA に計算済み。
  `Canvas.drawVertices` に頂点・UV をそのまま渡すだけで、Body 側の追加変換・反転は不要。

---

# 第4章 リファレンス

## 14. no_std / FFI 統合とメモリ・ライフサイクル

準拠: `50_reference/10_no_std_integration`。`dart:ffi` 固有の要点。

- **生成・破棄**: `ss_resource_create_borrow/copy` / `ss_resource_destroy`、`ss_runtime_create / _destroy / _reset`、`ss_runtime_bind_resource`。
  Resource は内部 Arc 参照カウントで Context と前後どちらでも安全に破棄可能。
- **アロケータ**: ネイティブ配布は `libc_alloc` ベースのプリビルドを使う。特殊ホストで `custom_alloc` を使う場合のみ、リンク時に
  `ss_custom_alloc(size, align)` / `_free` / `_abort` を提供（`align` バイト境界保証が必須）。
- **ログ**: `ss_runtime_set_log_callback(level, message)` を Dart 側コールバックに繋ぐ。
- **Dart 側のメモリ管理**: Context・貸し出した `.ssab` バッファは `dispose()` で明示解放し、保険に `NativeFinalizer` を併用。
  `FrameData` / SoA ポインタは次の `update` までの借用で解放不要、paint 内で消費する。
- **ハッシュ**: 名前→ID は必ず `ss_runtime_hash_string` を使う（自前 FNV-1a 再実装は衝突の元）。
- **Web**: `dart:ffi` 不可。`web` フィーチャの WASM（WASM SIMD 必須）＋ JS interop 経由で、メモリ空間が別のため Copy 方式を使う。
  Layer 1 を抽象化しネイティブ/Web の 2 実装を差し替える。

## 15. トラブルシューティング

準拠: `50_reference/20_troubleshooting`。FFI Player 特有の落とし穴。

- **ポインタ寿命**: 実行中の処理がポインタを参照中に Context/ハンドルを破棄するとセグフォールト（Dart 例外にならずアプリごと落ちる）。破棄はフレーム境界・dispose で。
- **スレッド**: 1 つの Context は単一 isolate が所有。別 isolate と共有する場合はメッセージパッシングで直列化。
- **ハッシュ衝突**: 文字列→hash は `ss_runtime_hash_string` に統一。
- **消費順序**: `ss_runtime_update` → フレームデータ読み出しの順を守る。
- **ネイティブビルド**: Windows（MSVC の LNK2019 等）・macOS のリンク警告は移植ガイド 15 の対処を参照。

---

# 第5章 ツール連携・配布・運用（Flutter 固有）

## 16. エディタ連携とアセットパイプライン

準拠: `60_tooling/10_editor_integration`。Flutter には GUI エディタが無いため、変換は「コード / ビルド時」に寄せる。

**A. 変換経路（sspj → ssab）**:
- 事前コンバート（CLI・推奨）: `ssconverter-cli` で `.ssab` 群を生成し `pubspec.yaml` の `assets:` に登録（本リポジトリは `scripts/prepare-example-assets.sh`）。
- ビルドフック: `flutter build` 時に `libssconverter` を呼び `.sspj` → `.ssab` を自動生成。
- ランタイム変換: ツール系アプリでは `libssconverter` を FFI 同梱しメモリ上変換も可。

**B. `libssconverter` の非同期 API（UAF 防止が要点）**:
- `ss_converter_create / _destroy`、走査 `ss_converter_scan_dir / _scan_found / _visited / _result_count / _result_at(i)`、
  変換 `ss_converter_convert(path) / _is_finished / _abort / _get_result`。
- 重要規約: `ss_converter_abort` 後は `ss_converter_is_finished` が true になるまでポーリングしてから `ss_converter_destroy`（ワーカースレッドの UAF 防止）。

**C. テクスチャ供給モード（embedded / reference）**:
`.ssab` は内部バンドル（embedded）/ 外部参照（reference）を選べる。Flutter は両対応。`TextureRegistry` の差し替え可能な Provider 2 実装に収める。
- `EmbeddedTextureProvider`: `.ssab` 内の画像バイト列（`embedded_assets`）を取り出しデコード。単一ファイル自己完結。
- `AssetTextureProvider` / `NetworkTextureProvider`: セル名・パス（`cellmap.image_path`）を `rootBundle` / `File` / HTTP で解決しデコード。アトラス共有・実行時差し替え・解像度バリアントに適合。
- ルーティング: `texture_id`（＝`cellmap.name_hash`）ごとに解決方式を判定し `TextureRegistry` が適切な Provider に振り分け（同一 `.ssab` 内の混在も許容）。
  （※ 実装は `SsTextureLoader`（ルーティング）＋ `TextureRegistry`（hash→`ui.Image`/`ImageShader` の格納）に統合。cellmap 毎に embedded 優先→reference へフォールバック。
  **上記の `EmbeddedTextureProvider` / `AssetTextureProvider` / `NetworkTextureProvider` という Provider クラス階層は設けない**——兄弟移植（Web の単一 `IResourceManager` ＋任意 `loadTextureFromBytes`、Unity のインポート時ベイク、Godot の `_loadTextures`）のいずれもクラス階層は持たず、hash キーの単一ストア＋cellmap 毎ルーティングで両モードを扱う。ネットワーク差し替え等が要る時に `SsTextureLoader` を注入点として拡張する。）

## 17. 配布形式と対応バージョン

- **配布**: pub.dev。ネイティブバイナリは原則コミットせず、`ssruntime_dart` / `ssconverter_dart` の
  **build hook**（`hook/build.dart`）が Native Assets の `CodeAsset` として同梱する。プリビルドは
  `hook/build.dart` がピン留めした SDK リリース（SS7-SDK 側 CI が GitHub Releases に publish）から
  自動DLする（Rust 不要）か、`build-runtime.*` でソースビルド（Rust 必要）。ffigen バインディングはコミット済み。
- **Web**: `dart:ffi` 不可のため別配布。`web` フィーチャの WASM ＋ JS グルーを web アセット同梱し `dart:js_interop` でロード。
- **対応バージョン**: Flutter 3.38+ / Dart 3.10+（**Native Assets 標準対応**）/ **Impeller 前提**（Skia 分岐は持たない）。`dart:ffi` `@Native` / `ffigen` / `NativeFinalizer` を前提に最新 API を活用。
- **ネイティブ同梱（実装メモ）**: Flutter 側は **Native Assets** に一本化。`hook/build.dart` が素の dylib を
  `CodeAsset(linkMode: DynamicLoadingBundled())` として登録し、`flutter build` が macOS では
  `Contents/Frameworks/ssruntime.framework` に再ラップして `NativeAssetsManifest.json` に写像を記録する
  （`flutter build macos` で埋め込み確認済み）。podspec の `vendored_frameworks` や `macos/Frameworks/`
  シンボリックリンクは廃止。SDK が生成する `libssruntime.framework` は他プレイヤー（Godot/Unity/RenPy）向けに残る。詳細は AGENTS.md。

## 18. 既知の制限・トレードオフ

準拠: `10_introduction/20_limitations`（SDK 公式制限）＋ Flutter 固有。

**A. SDK 公式の制限**:
- WASM SIMD 必須（非対応ブラウザでは Web ランタイムが動かない）。
- `independent=true` 子パーツ: シーク/逆再生で破綻（前方再生のみ前提）。
- シークのイベント取りこぼし: `ss_runtime_set_frame_no` は旧→新フレーム間のイベントを発火しない。
- 入力検証なし: ランタイムは `.ssab` を検証しない（§5 で Body が検証）。
- embedded のパス衝突: 同名パスをキーにすると内部アセットが取りこぼされる。
- ブレンド制約: 同一 `.ssab` 内のみ・セル整合が必要・α は primary が上書き・per-source イベント閾値（§12）。

**B. Flutter 固有のトレードオフ**:
- **A. シングルコピー**: `Vertices.raw` がエンジン内部へ 1 度コピー。SoA は `asTypedList` で受けて追加コピー/GC を排除（さらに削るなら `flutter_gpu`）。
- **B. UI isolate シングルスレッド**: DrawBatch 消費・`drawVertices` 記録・`M·v` ベイクは UI スレッドで直列。大量表示ではボトルネック（別 Isolate / `flutter_gpu` を検討）。
- **C. Web は別コードパス**: `dart:ffi` 不可 → WASM ＋ JS interop。性能・並列性がネイティブと分岐。
- **D. マスク・saveLayer の負荷**: カバレッジビットマップ方式（§9）はオフスクリーン＋2 パスで重い。矩形クリップは `clipRect` に落とす。
- **E. FFI クラッシュ**: ポインタ寿命管理ミスはセグフォールト（Dart 例外にならない）。`dispose` ＋ `NativeFinalizer` ＋ Debug 時の状態バリデーションで防波堤。
- **F. Hot reload / Hot restart**: Dart 状態と乖離してネイティブ状態が残存しうる。ロードを冪等にし、Hot restart 検知時にネイティブ状態をリセットできる経路を用意。Context は必ず dispose。
- **G. 物理アタリ判定なし**: 毎フレーム変形メッシュに追従するコライダ生成は非現実的。特定パーツ座標を公開する追従アンカーを提供し、`Positioned` / 当たり矩形 / Flame HitboxComponent に接続する。
