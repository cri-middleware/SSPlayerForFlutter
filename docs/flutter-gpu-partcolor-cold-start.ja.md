# flutter_gpu PartColor（UBO 廃止）コールドスタート

flutter_gpu バックエンドの **peel PartColor パイプラインが UBO 配列参照で壊れている**問題を、
別セッション/後日に**ゼロから再開**するためのハンドオフ。ここだけ読めば、調査をやり直さずに実装へ入れる。

- 対象: `packages/ssplayer_flutter`（flutter_gpu バックエンドのみ。Canvas 版は正常・触らない）
- 前提知識: [`architecture.ja.md` §19](./architecture.ja.md)（flutter_gpu 節）、[ROADMAP.md](../ROADMAP.md) の `flutter_gpu` 項
- 関連コミット: `1c968aa`（ShapeMask 修正・済）/ `a9f7d4e`・`d9864ea`（本バグの記録）

---

## 0. TL;DR

- **やること**: GPU の peel PartColor（§10 tint）+ mask（§9）データを **UBO 配列 → per-vertex 属性**へ移す。
  Godot / Web 兄弟が既にやっている方式そのもの。**UBO を完全に捨てる**のが要点。
- **なぜ**: Impeller/Metal が **UBO の配列要素アクセスを壊す**（動的 index の +定数オフセットで 0 を返す／小さい配列 UBO を mis-bind）。
  兄弟は per-vertex 属性＋ハード補間なので UBO 配列自体が要らず、生 WebGL でも問題が出ない。
- **なぜ今の設計が UBO なのか**: dart:ui（Canvas）版を移植したから。**Canvas は runtime-effect シェーダが custom varying を
  持てない**ので uniform でフラグメント再構成する**必然**があった。だが **flutter_gpu は生 GLSL で varying が使える**
  （sprite パイプラインは既に `a_color` を per-vertex で使用）。**この制約は flutter_gpu には当てはまらない**＝設計ミス。
- **確度**: 兄弟で実績のある方式なので高い。しかも今の「UBO＋フラグメント bilinear 再構成」より**単純**になる。

---

## 1. 症状（何が壊れているか）

- **`rate > 0` の実 PartColor tint（Normal / Mesh / Instance）が GPU で効かず、素テクスチャが出る。**
  実機再現: `overall/Shape.ssab` のパーツ **"Normal"**（Mul ブレンド・青 tint）が、Canvas では青掛かるのに GPU では灰色（テクスチャそのまま）。
- **`Mask.ssab` では露見しない**: マスク対象が passthrough PartColor（白・`rate 0`）なので、tint が効こうが効くまいが見た目が同じ。
  → **必ず「実 tint を持つパーツ」で検証すること**（Shape.ssab の "Normal"、または新規に PartColored な .sspj を作る）。
- **既に直っているもの**: マスク対象 **Shape** の白化（`1c968aa`。原因は別＝頂点 `vec4` の 16byte 境界。§5 参照）。

---

## 2. 根本原因（Impeller/Metal の UBO 配列アクセス）

現状の GPU peel パイプライン（`shaders/gpu/partcolor.{vert,frag}`）は、1 ドローに複数パーツを畳み込む（fan-out collapse）ために:

- 全パーツの 9 vec4 を **UBO 配列 `uniform PartColorInfo { vec4 data[360]; }`** に入れ、
- 頂点ごとの `a_part`（slot index）で **`pc.data[part*9 + k]`** と**動的参照**する。

この `pc.data[dynamicIndex + constant]` を **Metal（SPIRV-Cross→MSL 変換）が誤コンパイル**し、`+定数` が非 0 の要素（rate/coef/mask）に **0** を返す。実測（macOS, `--enable-impeller --enable-flutter-gpu`）:

| 参照 | 結果 |
|---|---|
| `pc.data[base]`（動的・オフセット無し） | **読める** |
| `pc.data[base + 4]`（動的・+定数） | **0**（rate/coef/mask が落ちる → 素テクスチャ） |
| `pc.data[4]`（リテラル） | 読める（※大きい UBO のとき） |

**UBO の配列アクセスだけが問題**で、**struct メンバの UBO は正常**（下表）。ここが per-vertex 化で全部避けられる根拠。

| UBO 形態 | アクセス | 実機結果 |
|---|---|---|
| `MaskInfo { vec4 a; vec4 b; vec4 c; }`（ShapeMask, 48B） | struct メンバ `mask.a` | ✅ 正常（`1c968aa` で検証） |
| `TintInfo { vec4 row_r; ... }`（ColorMatrix, 48B） | struct メンバ | ⚠️ 未検証だが上と同型なので多分正常 |
| `PartColorInfo { vec4 data[360]; }` | 配列 `data[base+k]` | ❌ 誤コンパイル |
| `PartColorInfo { vec4 data[9]; }`（小配列に縮小） | 配列 `data[4]`（リテラル） | ❌ mis-bind で 0（原因未特定） |

→ 教訓: **UBO の“配列”を使うな。** struct メンバ UBO（MaskInfo/TintInfo）は OK。per-part の可変データは per-vertex 属性へ。

---

## 3. 正しい設計（兄弟＝Godot/Web と同じ per-vertex 属性）

**ssplayer-webgl `PartsColorProgram`**（`../SSPlayerForWeb/packages/ssplayer-webgl/src/programs/PartsColorProgram.ts`）:

```glsl
attribute vec2 aPosition;
attribute vec2 aUV;
attribute vec4 aColor;   // その頂点(隅)の色（4隅グラデはハード補間任せ）
attribute vec4 aVarg;    // (rate, isMix, isMul, isAddSub)
varying vec4 vColor; varying vec4 vVarg;
// frag: rate=vVarg.x; mix/mul/addSub をセレクタで選び、texColor と合成
```

- **色は「隅ごとに頂点属性」** に載せ、4隅グラデは**ラスタライザの頂点補間**に任せる（フラグメント bilinear 再構成が不要）。
- **rate・ブレンドモード**も per-vertex 属性（`aVarg`）。Godot も同じで `CUSTOM0 = (rate, blend_idx, pma, 0)`。
- **UBO は使わない。** だから生 WebGL（flutter_gpu と同じ低レベル）でも壊れない。

**flutter_gpu も生 GLSL なので同じことができる**（sprite パイプライン `shaders/gpu/sprite.vert` は既に `in vec4 a_color` を per-vertex で使用）。

---

## 4. 実装手順（ファイル・関数・具体変更）

### 4-1. 新しい頂点レイアウト（peel PartColor 用）

per-part の可変データ（今 UBO に入れている 9 vec4）を**全部頂点属性**に移す。4 頂点（lt/rt/lb/rb）それぞれに:

| loc | 属性 | 中身 | 補間 |
|---|---|---|---|
| 0 | `a_position` vec2 | world 済みの隅座標（= v_local にも使う） | 補間 |
| 1 | `a_uv` vec2 | 正規化 UV | 補間 |
| 2 | `a_color` vec4 | **その隅**の色 rgba | 補間（4隅グラデが無料で出る） |
| 3 | `a_coef` vec4 | `(coef.x, coef.y, coef.z, rate)`（rate を 4 番目に詰める） | 補間（rate は隅ごとに違うので補間で正しい） |
| 4 | `a_mask_bits` vec4 | `(increment, invert, visibleInside, enabled)` | flat（part 内一定） |
| 5 | `a_mask_uv` vec4 | `(m00, m01, m10, m11)` | flat |
| 6 | `a_mask_off` vec2 | `(ox, oy)` | flat |

- **`a_st`（quad-local s,t）は不要になる**: 色の bilinear をフラグメントで作らず頂点補間に任せるので、s,t が要らない。
  マスクは `v_local`（= a_position）でサンプルするので、こちらも s,t 不要。→ **今より属性が減る面もある。**
- flat にしたい属性（mask 系, coef）は `flat out`/`flat in`。ただし **`int` varying は shader-bundle reflection が拒否**するので必ず **float/vec** で。
- 頂点数の上限に注意（Metal は概ね 31 attribute まで。上記 7 属性なら余裕）。

### 4-2. シェーダ（`shaders/gpu/partcolor.vert` / `.frag`）

- `.vert`: `PartColorInfo` UBO を**削除**。上記属性を `in` で受け、`v_local=a_position; v_uv=a_uv; v_color=a_color; v_coef=a_coef; v_mask_*=...` を `out`。
- `.frag`: **UBO 参照を全部消す**。`v_color`（補間済み隅色）と `v_coef`（rate は `.w`）で式を適用:
  ```
  float rate = v_coef.w;
  float vx = 1.0 + v_coef.x * rate;
  float vy = v_coef.y * rate;
  float vz = v_coef.z;
  vec3 rgb = pixel * vx + mix(vec3(1.0), pixel, vz) * v_color.rgb * vy;
  float a = tex.a * v_color.a;
  ```
  （現行 `.frag` の式と同一。coef の意味は `render/blend.dart` の `partColorCoef`＝`(fSrc,fDst,mulFlag,0)`）
- `maskPasses()` は現行のまま（`v_mask_bits/v_mask_uv/v_mask_off` と `v_local` から復元）。中身のロジックは変えない。
- **注意（impellerc の癖）**: 使われない `in`/`out` は剥がされて reflection が壊れる（ShapeMask 修正で踏んだ。§5）。
  全属性を必ず出力/使用に繋ぐこと。

### 4-3. Dart 側

- `lib/src/render/backend/flutter_gpu_backend.dart`:
  - `_writePartColorEntry`（UBO へ 36 float 書く関数）→ **廃止**。代わりに「頂点1つ分の属性を書く」関数へ。
  - `_drawPartColorRun` / `_drawMeshPartColorRun`: UBO の emplace/bindUniform を消し、per-vertex 属性を含む頂点バッファを作って draw。
    **バッチは維持できる**（各頂点が自己記述するので `a_part` 不要。run 内の全パーツを 1 VBO に詰めて 1 ドロー）。
  - `_kMaxPartColorRun`（UBO 40 個上限）は不要になる（UBO を使わないので）。
- `lib/src/render/geometry_builder.dart`:
  - `buildPartColorQuad`（今は corners + affine を返す）→ per-vertex に色/rate/coef/mask を載せて焼く関数へ拡張、
    または `_drawPartColorRun` 側で `PartColor`（`render/part_color.dart`）から直接頂点へ書く。
  - `buildMeshPartColorInterleaved`: Mesh は whole-only なので**全頂点に `lt` 隅の色/rate**を載せる（4隅補間不要）。
- `lib/src/render/part_color.dart`: `PartColor.lt/rt/lb/rb`（`PartColorCorner{r,g,b,a,rate}`）と `coef`（`partColorCoef`）から
  頂点属性を作る。α の扱いは現行通り（§1-3: tint 有りは corner α に階層 α 込み。`scaleAlpha` は instance chain 用）。

### 4-4. Instance グループ tint（§10・別経路なので分けて考える）

- Instance パーツ tint は **ColorMatrix パイプライン**（`shaders/gpu/colormatrix.{vert,frag}` + `TintInfo` **struct** UBO）で、
  UBO **配列**ではない。§2 の表より struct UBO は多分正常だが、**未検証**。まず実機で確認（該当アセットが無いので要作成 or 目視困難）。
  壊れていたら同様に per-vertex 化 or 定数 push でなく struct 維持のまま調べる。**PartColor 本体（4-1〜4-3）とは別タスク**。

---

## 5. 踏んだ地雷（再挑戦しないこと）

1. **`vec4` 頂点属性の 16byte 境界**（ShapeMask 白化・`1c968aa` で解決済）: 頂点 `vec4` は byte offset を 16 の倍数に置く。
   `[pos.xy, rgba]`（色 offset 8）は Impeller が誤読→白。`[pos.xy, pad.xy, rgba]`（色 offset 16）にする。
   **→ 新レイアウトでも各 `vec4` 属性を 16byte 境界に。**（vec2×偶数個の後に vec4、が安全）
2. **未使用属性は impellerc が剥がして reflection 失敗**: ダミー pad 属性は不可。必ず出力に使う値を入れる
   （ShapeMask では pad に local 座標を再度入れて回避）。
3. **UBO 配列 `data[base+const]` は 0 を返す**（本バグ）。→ UBO 配列を使わない。
4. **小さい配列 UBO（`data[9]`）は mis-bind**（1 ドロー 1 パーツ＋リテラル index を試した時に踏んだ、原因未特定）。→ UBO 配列を使わない。
5. **ローカル配列コピー＋インクリメント index はコンパイラに畳み戻される**（`for{ d[k]=pc.data[idx]; idx++; }` が `data[base+k]` に戻る）。効果なし。

---

## 6. ビルド・実機検証（macOS）

### 6-1. GPU を実際に走らせる（超重要）

`gpu_backend_test.dart` / 素の `flutter run` は **Impeller/FlutterGPU 未有効**で、`isFlutterGpuAvailable()==false` → **Canvas にフォールバック**する（＝ GPU 経路が動かない）。**両フラグ必須**:

```
cd examples/overall
flutter run -d macos --debug \
  --dart-define=SS_BACKEND=gpu \
  --enable-impeller --enable-flutter-gpu
```

- `SS_BACKEND=gpu` で GPU 要求（既定 canvas）。
- パックを指定して起動したい時は `main.dart` の initState に一時的に
  `const p = String.fromEnvironment('SS_PACK'); if (p.isNotEmpty && _packs.contains(p)) _pack = p;` を足して
  `--dart-define=SS_PACK=Shape`（Web の `?pack=` の native 版・調査用。コミットしない）。

### 6-2. ビルド env の落とし穴（SDK release 404）

`_sdkVersion = v7.0.0-alpha.1` の GitHub Release が 404 だと、`ssruntime_dart`/`ssconverter_dart` の
build hook の**ダウンロードが失敗**して native assets ビルドが落ちる。回避（hook の 3-way resolver の branch2）:

```
# alpha.1 ABI と一致する既存 dylib を置く（git-ignore・コミットしない）
cp examples/overall/build/native_assets/macos/libssruntime.dylib \
   packages/ssruntime_dart/native/libs/macos/libssruntime.dylib
```

- **SDK submodule を自前ビルドした dylib は ABI がズレて 12 unit test が壊れる**（実機は動くが unit の厳密チェックで露見）。
  正しいのは以前 DL 済みの `examples/overall/build/native_assets/macos/libssruntime.dylib`（~1.4MB）。

### 6-3. 目視の取り方（自動スクショ）

`toImage()` キャプチャは GPU で不正確（Mask を 0 と誤る）なので**画面を直接撮る**:

```
osascript -e 'tell application "ssplayer_flutter_example" to activate'
# ウィンドウ矩形: System Events で position/size を取得し screencapture -x → PIL でクロップ
```

- Python は `/usr/bin/python3 -m pip install --user Pillow` で PIL 可。
- **フラグメントに一時デバッグ出力**（`frag_color = vec4(coef.z, coef.z, coef.z, 1.0)` 等）を入れて、
  「読めているか」を色で確認するのが速い（coef.z は Mul フラグ＝アニメで変わらない定数なので判定に最適）。

---

## 7. 検証チェックリスト（完了条件）

- [ ] `Shape.ssab` の "Normal" パーツ（Mul tint）が GPU で**青掛かる**（Canvas と一致）。素テクスチャの灰色でない。
- [ ] `Shape.ssab` の "Shape" パーツ（ShapeMask 経路・`1c968aa`）が引き続き正しい（degrade してない）。
- [ ] `Mask.ssab` が引き続き正しい（passthrough 経路）。
- [ ] `PartsColor.ssab`（Normal PartColor・多数）を GPU で目視 → Canvas と一致。
- [ ] Mesh PartColor / Instance tint 用の**実データ（.sspj）が無い**問題を解消 or 明記（現状どのサンプルにも Mesh/Instance の PartColor は無い）。
- [ ] `flutter test`（153+）緑・`flutter analyze` クリーン。
- [ ] `gpu_backend_test.dart` を「両フラグ必須＋GPU 未実行なら fail」に是正し、信頼できるキャプチャに（別タスクだが本命修正の後で）。

---

## 8. 参照

- 兄弟実装（本命の手本）:
  - `../SSPlayerForWeb/packages/ssplayer-webgl/src/programs/PartsColorProgram.ts`（`aColor` + `aVarg`）
  - `../SSPlayerForWeb/packages/ssplayer-webgl/src/SSWebGLRenderer.ts`（`vargBuffer` で per-vertex 詰め・バッチ）
  - Godot: `../SSPlayerForGodot/ss_player/ss_internal_player.cpp`（CUSTOM0 = `(rate, blend_idx, pma, 0)`）
- この repo:
  - シェーダ: `packages/ssplayer_flutter/shaders/gpu/partcolor.{vert,frag}`（要改修）、`sprite.{vert,frag}`（per-vertex a_color の手本）、`shapemask.*`（struct UBO が動く例）
  - バックエンド: `lib/src/render/backend/flutter_gpu_backend.dart`（`_drawPartColorRun` / `_drawMeshPartColorRun` / `_writePartColorEntry`）
  - ベイク: `lib/src/render/geometry_builder.dart`（`buildPartColorQuad` / `buildMeshPartColorInterleaved` / `PartColorQuad`）
  - データ: `lib/src/render/part_color.dart`（`PartColor` / `PartColorCorner` / `coef`）、`render/blend.dart`（`partColorCoef`）
  - shader bundle 登録: `packages/ssplayer_flutter/ssplayer.shaderbundle.json`
- 背景: [`architecture.ja.md` §19](./architecture.ja.md)、[ROADMAP.md](../ROADMAP.md)（`flutter_gpu` 項）
