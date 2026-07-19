# ロードマップと制約

これまでに出荷した描画 kind —— **Normal / PartColor / Mask / Mesh / Effect / Instance / Shape** ——
と Flame アダプタで、中核の機能セットはカバーしています。このページは残りの作業と、出荷時に留意する
点の要約です。詳細な最新ロードマップは
[`ROADMAP.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/ROADMAP.md) を参照。

## ロードマップの要点

作業は ☐ **着手可**（Player のみ・すぐ開始可）、⛔ **SDK 待ち**（先にランタイム側のフェーズが必要）、
🕒 **保留** で管理しています。

- ☐ **ラベル / フレーム範囲 / インデックス再生** —— 名前付きラベル範囲やインデックスでの再生。
- ☐ **`Nines` / `Text` kind ＋ `BoxFit` / アライメント** —— 残りの描画 kind と、デザイン境界を宛先
  ボックスへフィットさせる処理。
- ☐ **パーツ単位のランタイム上書き**（色 / セル / 表示）—— SDK の Override Layer API は出荷済みで、
  Player 側の口（`setPartColor` / `setPartCell` / `setPartVisible`）が残作業。
- ⛔ **インスタンス動的差し替え・シーケンス（`.ssqb`）再生・群衆描画** —— SDK Phase 3 待ち。
- 🕒 **`flutter_gpu` バックエンド** —— peeled シェーダのドローコール分散を解消しうる低レベル経路。

## パフォーマンス

バッチ化自体は既に**正しい** —— Normal / Mesh / Shape の各バッチにつき 1 回の `Canvas.drawVertices`
で、Brain のプランと一致し、隣接バッチは z 順を壊さずには結合できません。レバーは (a) 各バッチを
*組み立てる*ための毎フレームのアロケーションと、(b) *peeled* シェーダパーツのドローコール数です。
アロケーション健全化（ゼロコピー頂点ビュー・スクラッチ再利用・密なパーツ索引・Effect コマンド結合）は
出荷済み。残る最大のレバー（peeled PartColor / mask のドローコール分散）は **Flutter のシェーダモデルに
構造的に縛られます**（フラグメントシェーダは per-vertex varying を取れず、`drawVertices` からシェーダに
給餌できない）。それが `flutter_gpu` バックログの理由です。
[`ROADMAP.md`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/ROADMAP.md#performance) 参照。

## 既知の制約

### 描画

- **Shape / `Arrow` は上流不整合**: ランタイムが中心頂点のない 7 点ポリゴンを出す一方、どの Player も
  ファンにするため、矢印の外側が塗られます。修正は SDK 側（`Arrow` に中心 + 閉じ頂点を与える）。
  [`docs/architecture.ja.md` §11-A](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/docs/architecture.ja.md)
  参照。
- **ブレンドモード** —— `Sub` / `Invert` は `difference` に近似（Flutter の固定 enum では逆減算 /
  dst 置換を表現できない）。`Div2` / `Overlay2` は `srcOver` にフォールバック。

### 再生（共有の `libssruntime` 由来 —— 全 Player 共通）

- **`independent = true` パーツ（Instance / Effect）は逆再生・シークが正しく動かない** —— 独自の
  実時間クロックで走るため、正しいのは順再生のみ。
- **シークは飛ばしたフレームのイベントを発火しない** —— 発火するのは着地フレームのイベントだけ。
- **逆再生の音声は無し** —— 音声イベントは時間が前進する間だけ発火。
- **アニメブレンドは同一 `.ssab` 内のみ**。ブレンドする各アニメは同じパーツに同じセルを割り当てる必要。

### プラットフォーム

macOS・iOS（シミュレータ）・Android（エミュレータ）で動作確認済み。実機 iOS（署名付き `iphoneos`
スライス）と `armeabi-v7a` ABI の実行時は未確認。Web は予定。
