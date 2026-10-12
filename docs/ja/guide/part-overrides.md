# 🎨 パーツオーバーライド

パーツ単位のランタイムオーバーライドは、「このパーツを**今**この色に / このセルに / 非表示に」とコードから指示する機能です。オーバーライドはキーフレームやアニメーションのブレンドよりも優先されるので、アニメーションと取り合いになりません。

```dart
// パーツを乗算で着色（通常パーツに適用されます）
_player.setPartColorOverride(partName, Colors.red, blendOp: SsBlendOp.mul);

// 別のセルを描画させる（セルマップ名は ".ssce" を付けずに指定）
_player.setPartCellOverride(partName, cellmap, cellName);

// パーツを強制非表示にする（子孫にもカスケード）
_player.setPartVisibilityOverride(partName, true, cascade: true);

// 解除
_player.clearPartColorOverride(partName);
_player.clearAllPartOverrides();
```

!!! warning "アニメーションを選択してから設定する"
    オーバーライドはランタイムがパーツ数ぶんのテーブルとして保持しますが、そのテーブルが確保されるのは
    **`setAnimation()`（または `load(animationName: ...)`）を実行した時点**です。それ以前はすべての呼び出しが `false` で拒否されます。

    ややこしいのは、**パーツ名の解決だけは先に成功する**ことです（パーツ名は `.ssab` から読むため）。「`findPartIndex()` は有効な値を返すのに `set` が失敗する」場合は、まずこれを疑ってください。

    さらに `setAnimation()` は `Permanent` 以外のオーバーライドを**解除**します。したがってオーバーライドは常に**アニメーション選択の後**に設定してください。

## メソッド

`SpriteStudioPlayer` のメソッドです。

| メソッド | 説明 |
|---|---|
| `findPartIndex(name)` | パーツインデックス。パックに無ければ `-1` |
| `partNames` | パーツ名一覧 / 名前⇔インデックスの相互解決（`PartNameTable`） |
| `setPartColorOverride(part, color, blendOp:, priority:)` | パーツカラーオーバーライド（単色） |
| `setPartColorOverrideCorners(part, corners, blendOp:, priority:)` | 4 隅個別指定（グラデーション）。`corners` は `SsCornerColors` レコード |
| `setPartCellOverride(part, cellmapName, cellName, priority:)` | 別のセルで描画する |
| `setPartVisibilityOverride(part, hide, cascade:)` | 強制非表示（`hide: false` でアニメーションに戻す） |
| `clearPartColorOverride` / `clearPartCellOverride` / `clearPartVisibilityOverride` | 1 パーツの 1 オーバーライドを解除 |
| `clearAllPartOverrides()` | そのプレイヤーの全オーバーライドを解除 |
| `...ByIndex(...)` | 上記各メソッドのパーツ**インデックス**指定版（末尾に `ByIndex` が付きます） |

各メソッドは**パーツ名**を取り、末尾に `ByIndex` が付いた版が**パーツインデックス**を取ります。インデックスは `findPartIndex` で引いて得る最適化であって、既定ではありません。パーツが不明な場合やランタイムが受け付けなかった場合は `false` を返します。

!!! tip "パーツインデックスの使い方について"
    パーツインデックスは同一パック（同じ `.ssab`）内では安定しているので、頻繁にオーバーライドするなら
    `findPartIndex()` で一度パーツ名を解決し、そのインデックスを使い回すことを推奨します。

!!! note "低レベル API からも同じように使えます"
    ここに挙げたメソッドは、`SpriteStudioPlayer`（L3）だけでなく、その下位にある描画エンジン
    `SpriteStudioInternalPlayer`（L2）にも同じ名前・同じ引数で用意されています。ヘッドレス実行や独自の描画アダプタから直接叩く場合はそちらを使ってください（レイヤーの構成は [アーキテクチャ](../contributing/architecture.md) を参照）。

    違いは**変更が反映される時点と、再描画の責任**です。オーバーライドはプレイヤーの次の tick から反映されます。`SpriteStudioPlayer` は設定・解除が成功するとリスナーへ通知し、一時停止中なら次のフレームで 0 秒の tick を 1 回実行します。`SpriteStudioInternalPlayer` はどちらも行わないため、呼び出し側が次に `update`・`seek`・`setupAnimation` を呼んだときから反映され、再描画も呼び出し側の責任になります。

セルオーバーライドに指定できるセルマップ名 / セル名は、プレイヤーから列挙できます。

```dart
final cellmap = _player.cellmapNames.first;   // 例: パック先頭のセルマップ
final cells   = _player.cellNames(cellmap);   // そのセルマップの全セル名
```

## 合成モード（`SsBlendOp`）

`setPartColorOverride()` の `blendOp` は、キーフレームのパーツカラーと同じ 4 種です。

| 値 | 合成モード |
|---|---|
| `SsBlendOp.mix` | Mix（既定） |
| `SsBlendOp.mul` | Mul（乗算） |
| `SsBlendOp.add` | Add（加算） |
| `SsBlendOp.sub` | Sub（減算） |

## 優先モード（`SsOverridePriority`）

パーツカラーとセルのオーバーライドはアニメーションと競合するため、`priority` を取ります（表示指定にはありません。単なる強制非表示フラグで、アニメーションを設定し直すと必ずクリアされます）。

| 優先モード | 挙動 |
|---|---|
| `overwriteOnNextKeyframe` | アニメーションデータが当該アトリビュートを更新するまで、オーバーライドが適用される |
| `holdUntilNextAnimation`（既定） | 現在のアニメーション中は勝ち続け、新しいアニメーションを設定すると解除される |
| `permanent` | 同じアニメーションデータ（`.ssab`）である間、オーバーライドが適用される（アニメーション変更をまたいでも持続） |

## 再適用は不要です

オーバーライドはランタイムが保持し、そのライフサイクルもランタイムが管理します。**毎フレーム設定し直す実装にしないでください。** 1 度設定すれば、以降のフレームでは自動的に適用され続けます（アニメーションのループをまたいでも維持されます）。

```dart
// ✅ 1 度だけ設定する
_player.setPartColorOverride(partName, Colors.red, blendOp: SsBlendOp.mul);

// ❌ 毎フレーム設定し直す必要はありません
```

## 注意点

- **カラー**は通常パーツ、**セル**は通常パーツとマスクパーツに適用されます。それ以外の種別のパーツでは黙って無視されます（呼び出し自体は `true` を返します）。
- そのため **`false` は「拒否された」の意味であり、「見た目が変わらなかった」ではありません。**
  戻り値でオーバーライドが見えているかを判定しないでください。
- 色はオーサリングされた Part Color と同じ 8bit sRGB 空間として解釈され、アルファはランタイム側で
  pre-multiply されます。自前で変換したり、パーツのアルファを掛け込んだりしないでください。
- 4 隅指定の順序は **左上・右上・左下・右下** です。
- セルオーバーライドは設定時に解決されるため、存在しないセルマップ名 / セル名はその場で失敗します（`false` を返します）。セルマップ名に `.ssce` は付けません。
- 空文字列を 2 つ渡すとセルオーバーライドを解除し、アニメーションのセルに戻ります。
- 別の `.ssab` を読み込むと、パーツの同一性が失われるため全オーバーライドが解除されます。
- インスタンスパーツ**配下**のパーツには届きません（子アニメーションは別のプレイヤーとして動作するため）。インスタンスパーツ自体を強制非表示にした場合は、その配下もまとめて描画されなくなります。
- `cascade` はオーバーライド由来の非表示だけを伝播します。キーフレームの `hide` はパーツ単位で、子孫には波及しません。この非対称性は意図的なものです。

!!! note "一時停止中でも反映されます"
    オーバーライドはフレーム番号を変えずに描画結果を変えるため、他のプレイヤー実装では停止中に設定しても画面が更新されないことがあります。オーバーライドは次の tick から反映され、一時停止中の `SpriteStudioPlayer` はそのために次のフレームで 0 秒の tick を 1 回実行するので、描画とパーツの読み取りが同時に変わります。追加の操作は不要です。

## Flame から使う

`ssplayer_flame` は専用の API を持ちません。コンポーネントが公開するプレイヤーを通して、上記のメソッドをそのまま呼べます。

```dart
final player = component.player!;
player.setPartColorOverride(partName, Colors.red, blendOp: SsBlendOp.mul);
```

## 関連

- [テクスチャ差し替え](textures.md) —— セルマップ（テクスチャ）を**まるごと**実行時に差し替える（着せ替え）。そのテクスチャを参照する**全パーツ**が着せ替わります。対してこちらのセルオーバーライドは**パーツ 1 つ単位**で描画するセルそのものを差し替えます。目的に応じて使い分けてください。
- [パーツトラッキング](part-following.md) —— 逆方向の読み取り。パーツの現在の姿勢にウィジェットを追従させる
- [再生とイベント](playback.md) —— トランスポートとイベントコールバック
