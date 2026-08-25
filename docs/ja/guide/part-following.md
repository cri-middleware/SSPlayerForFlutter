# 🎯 パーツトラッキング

パーツトラッキングは、指定したパーツに任意の Flutter ウィジェット（武器・エフェクト・当たり判定の目印・
HP バーなど）を毎フレーム追従させる機能です。追従するのは**位置・回転・スケール**です。プレイヤーは
そのウィジェットを生成も破棄もせず、姿勢を渡すだけの連動（Constraint）方式で、子ウィジェットの
ライフサイクルは通常のウィジェットと同じくユーザーが所有します。

`SpriteStudioPartAnchor` がパーツの姿勢を読み取り、子ウィジェットを `Transform` で包みます。

```dart
Stack(
  fit: StackFit.expand,
  children: [
    SpriteStudioView(player: _player),
    Positioned.fill(
      child: SpriteStudioPartAnchor(
        player: _player,
        partName: 'FrontHand',
        child: const Icon(Icons.star),
      ),
    ),
  ],
)
```

!!! warning "アンカーはビューと同じ座標空間に置く"
    ビューはアニメーションのワールド原点を**自身のボックスの中央**に配置し、アンカーは**自身の制約**から同じ中央寄せを適用します。
    両者が一致するのは、アンカーがビューとまったく同じボックスを覆っているときだけです。
    したがって 1 つの `Stack` の中で `SpriteStudioView` の兄弟として `Positioned.fill` で重ね、位置の微調整やスケールは `Stack` 全体に掛けて両者が一緒に動くようにしてください。
    異なるボックスを与えると、子ウィジェットはその差の半分だけパーツからずれます。制約が非有限の軸では
    中央寄せの基準が無いため `0` にフォールバックします。

## プロパティ

| プロパティ | 説明 |
|---|---|
| **`player`** | 追従元となるプレイヤー（必須） |
| **`partName`** | 追従対象のパーツ名（`.ssab` の `PartData` 名）。存在しない名前や現在のアニメーションに無いパーツを指定した場合は、解決できるようになるまで何も描画しません |
| **`child`** | パーツに貼り付けるウィジェット。その**左上**がパーツの原点に固定されます |
| **`onHidden`** | パーツが hide のフレームでの挙動。`followAlways`（既定）/ `hideChild` |
| **`onMirrored`** | プレイヤーを反転したときの子ウィジェットの扱い。`follow`（既定）/ `cancel` |
| **`filterQuality`** | 任意の `Transform.filterQuality`。回転・拡縮した子を滑らかにしたい場合は `FilterQuality.low` など。null なら Flutter 既定（最近傍）のまま |

### hide フレームでの挙動（`SpriteStudioAnchorHidden`）

| 値 | 挙動 |
|---|---|
| `followAlways`（既定） | hide フラグに関係なく追従を継続し、子ウィジェットを表示し続ける（ForUnity の `FollowAlways`、ForGodot の `FOLLOW_ALWAYS`、ForWeb の `onHide: 'follow'` に相当） |
| `hideChild` | パーツが hide の間は子ウィジェットを描画しない（ForUnity の `Deactivate`、ForGodot の `HIDE_TARGET`、ForWeb の `onHide: 'hide'` に相当） |

ここでいう hide は、キーフレームの `hide` と表示指定オーバーライドを合成した結果です
（[パーツオーバーライド](part-overrides.md) が書き込むのと同じ値）。

### プレイヤーを反転したときの挙動（`SpriteStudioAnchorMirror`）

プレイヤーの [`flipX` / `flipY`](playback.md) はアンカーにもそのまま伝わるので、キャラクターが向きを
変えても子ウィジェットはパーツから外れません。決めるのは、**子ウィジェット自身を鏡像にするかどうか**
だけです。

| 値 | 挙動 |
|---|---|
| `follow`（既定） | パーツの姿勢をそのまま適用する。プレイヤーが反転していれば子ウィジェットも鏡像になる |
| `cancel` | 反転後の**位置**には追従しつつ、子ウィジェット自身の向きは保つ |

武器やエフェクトのようにキャラクターと一緒に反転してほしいものは `follow`、文字・アイコン・HP バーの
ように鏡像になると困るものは `cancel` を選んでください。

```dart
SpriteStudioPartAnchor(
  player: _player,
  partName: 'Head',
  onMirrored: SpriteStudioAnchorMirror.cancel, // 名前ラベルは常に正立
  child: const Text('Ringo'),
)
```

!!! info "`cancel` は厳密で、ズレを残しません"
    取り消しているのは、このライブラリ自身が掛けた ±1 の対角行列だけです。そのため位置は完全に正確な
    まま、余計な回転も残りません。姿勢を「回転 + スケール」に分解する ForUnity / ForGodot では、
    同等の設定（`Drive Scale` / `update_scale` を OFF）にすると水平反転時に 180 度のズレが残りますが、
    ForFlutter では発生しません。

    なお、**SpriteStudio 側でパーツ（やその親）に付けられた負のスケールは、どちらを選んでも子ウィジェット
    に届きます**。それはアニメーションの一部だからです。`cancel` が取り消すのはプレイヤーの
    `flipX` / `flipY` の分だけです。

!!! tip "追従の基準点を変える"
    パーツに乗るのは子ウィジェットの左上です。別の点を合わせたい場合は子側で包んでください。
    `FractionalTranslation(translation: Offset(-0.5, -0.5), child: ...)` とすれば、子の中心がパーツに乗ります。

## ウィジェットを使わずに姿勢を読む

アンカーは `SpriteStudioPlayer` の読み取り API を薄く包んだものです。そのため Flame コンポーネントや
`CustomPainter`、独自のレイアウトコードから、自前でパーツに追従させることもできます。

```dart
// パーツ名の解決は 1 度だけ。パーツインデックスは同じ .ssab 内では安定しています。
final hand = _player.findPartIndex('FrontHand');

// そのパーツの現在フレームの姿勢（プレイヤーローカル＝アニメーション空間）。
final Matrix4? pose = _player.partTransformOf(hand);
if (pose != null && !_player.isPartHiddenOf(hand)) {
  final x = pose.storage[12];
  final y = pose.storage[13];
  // ... (x, y) に弾を発射する、自前のコンポーネントを配置する、など
}
```

| メソッド | 説明 |
|---|---|
| `findPartIndex(name)` | パーツインデックス。パックに無ければ `-1` |
| `partNames` | パーツ名一覧 / 名前⇔インデックスの相互解決（`PartNameTable`） |
| `partTransform(name)` | そのパーツの現在フレームの変換行列を `Matrix4?` で返す（プレイヤーローカル）。`load()` 前や不明なパーツでは null |
| `partTransformOf(index)` | `partTransform` のインデックス指定版（名前解決を省略） |
| `isPartHidden(name)` | そのパーツが現在フレームで hide かを返す。`load()` 前や不明なパーツでは `false` |
| `isPartHiddenOf(index)` | `isPartHidden` のインデックス指定版 |

!!! tip "一瞬だけ知りたいならアンカーは不要です"
    常時追従させるまでもなく「その瞬間のパーツ位置だけ知りたい」場合（弾の発射位置を取るなど）は、`SpriteStudioPartAnchor` を配置せず `partTransform()` を直接呼ぶ方が簡潔です。

### 行列が持つ情報

返される `Matrix4` が保持するのは **2D アフィンの 6 項（`m0, m1, m4, m5, m12, m13`）だけ**で、
Z / W 行は単位行列のままです。これにより、余計な Z スケールや透視項が `Transform` に紛れ込むことは
ありません。位置・回転・スケール・せん断（Skew）はすべてこの 6 項に含まれるため、行列はそのまま
`Transform` ウィジェットに渡せます。平行移動成分は `storage[12]` / `storage[13]` です。

Y-Down の反転は**ランタイム側で適用済み**です。呼び出し側で再度反転しないでください。

プレイヤーの [`flipX` / `flipY` / `offset`](playback.md) も適用済みです。つまりこの行列は**実際に描かれて
いる姿勢**であり、追従先は反転しても絵の上のパーツから外れません。

### 鏡像（反射）になることがあります

返される行列は**反射**——行列式が負の行列——になることがあります。原因は 2 つあり、しかも
**掛け合わさります**。

- SpriteStudio 側でパーツやその親に負のスケールが付いている（実データでは珍しくありません）
- プレイヤーの [`flipX` / `flipY`](playback.md)

2 つが重なると**打ち消し合って**行列式は正に戻ります。したがって「`flipX` したから鏡像」とも「反転させて
いないから鏡像ではない」とも言えません。符号が必要なときは、そのとき手にしている行列から
`determinant()` で読み取ってください。

!!! tip "ForFlutter は分解しないので、そのまま正確です"
    姿勢は `Matrix4` のまま `Transform` ウィジェットへ渡るため、鏡像も欠落なく運ばれます。姿勢を
    `Quaternion` や `Transform2D` へ分解する ForUnity / ForGodot には鏡像固有の制約がありますが
    （`Matrix4x4.rotation` が未定義になる、水平反転で回転に 180 度の差が残る、など）、ForFlutter では
    発生しません。

    ただし**自分で分解する場合**は同じ制約を引き受けます。行列から回転角を取り出すようなコードを書く
    ときは、先に `determinant()` の符号を確認してください。平行移動成分（`storage[12]` /
    `storage[13]`）は符号に関係なく常に正確です。

!!! note "低レベル API にも同じ読み取りがあります"
    `SpriteStudioPlayer`（L3）の下位にある描画エンジンにも同じ 2 つの読み取りがありますが、インデックス指定のみで、名前も異なります ——
    `SpriteStudioInternalPlayer.partWorldMatrix(index)` と `partHidden(index)`（L2）です。
    ヘッドレス実行や独自の描画アダプタから直接叩く場合はそちらを使ってください（レイヤーの構成は [アーキテクチャ](../contributing/architecture.md) を参照）。

## 追従のタイミングと精度

読み取りは**描画パスが描くのと同じフレーム**をサンプリングし直します（サブフレーム補間が有効なら小数、
無効なら切り捨て）。そのため姿勢は常に画面上の絵と同一フレームで一致します。描画との順序を自前で
制御する必要はありません。

パーツオーバーライドと違い、これらは**純粋な読み取りでリスナーへ通知しません**（何も変更していない
ため）。プレイヤーのリスナーから駆動して、フレームの変換が確定した advance 直後に読み直すようにして
ください。`SpriteStudioPartAnchor` は内部でこれを行っているので、ビューが再描画するのと同じ通知で
リビルドされ、同じフレームに乗ります。

`load()` の完了前に姿勢を問い合わせることは**エラーではありません**。オーバーライドと同様、例外を投げず
`null` / `false` を返すため、パックのロード中に動く UI でもガードは不要です。

## 注意点

- **存在しないパーツ名では、`onHidden` の設定に関係なく何も描画されません。** `followAlways` /
  `hideChild` が決めるのは、実在してそのフレームで hide になっているパーツの扱いだけです。
- **そのフレームに存在しないパーツ**は hide では*ない*と読まれます（ワールド変換自体は有効なため）。
  これは他プレイヤーの追従実装と揃えた挙動です。
- パーツ名は、そのプレイヤー自身が再生しているアニメーションのパーツから解決されます。
  **インスタンスパーツの内部（子アニメーション）のパーツは追従できません**（子は別のプレイヤーとして
  動作するため）。インスタンスパーツ自体は追従できます。
- 同名のパーツが複数ある場合は、**最初**に見つかったものが使われます（SpriteStudio 7 はパーツ名の
  一意性を保証しません）。
- 名前は読み取りのたびに解決し直されるため、**アニメーションの切り替えや別の `.ssab` の読み込みでも
  登録し直す必要はありません**。名前が解決でき次第、アンカーは再びそのパーツを掴みます。
- 追従で転送されるのは**空間的な変換だけで、描画順は含みません**。子ウィジェットはアニメーション全体の
  手前に描画され、キャラクター自身のパーツの間に挟み込むことはできません。
- アンカーはビューが**等倍で描画される**ことを前提とします。ビュー側のスケール / `BoxFit` 配置は未実装
  で、これが実装された際にはアンカーにも同じフィットの適用が必要になります。
- **所有権はユーザー側にあります。** アンカーは子ウィジェットもプレイヤーも生成・破棄せず、姿勢を読んで
  適用するだけです。

## Flame から使う

`ssplayer_flame` は専用の API を持たず、`SpriteStudioPartAnchor` はウィジェットなので Flame の
コンポーネントツリーの中では使えません。コンポーネントが公開するプレイヤーから姿勢を読み、自前の
コンポーネントを駆動してください。

```dart
final player = component.player!;
final pose = player.partTransform('FrontHand');
if (pose != null && !player.isPartHidden('FrontHand')) {
  marker.position = Vector2(pose.storage[12], pose.storage[13]);
}
```

姿勢は**プレイヤーローカル（アニメーション空間）**なので、`SpriteStudioComponent` 自体を配置したのと
同じ要領で、自分のコンポーネントの空間へ変換してください。

## 関連

- [パーツオーバーライド](part-overrides.md) —— 逆方向の書き込み。パーツの色 / セル / 表示を強制する
- [再生とイベント](playback.md) —— トランスポートとイベントコールバック
- [制限事項と適用範囲](../limitations.md) —— 現時点の追従まわりの制約
