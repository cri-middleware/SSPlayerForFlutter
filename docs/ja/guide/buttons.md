# 🔘 ボタンと UI の状態

Flutter のボタンの中にアニメを置き、ボタンの状態（hover・押下・無効・フォーカス）を見せられます。形が四角でないボタンなら、絵の上だけでポインタを受けるようにもできます。ウィジェットは別のライブラリにあるので、アニメを再生するだけのアプリはこのための費用を払いません。

```dart
import 'package:ssplayer_flutter/ui.dart';

final states = WidgetStatesController();

SpriteStudioHitRegion(              // 任意: `face` パーツの上だけでポインタを受ける
  player: _player,
  parts: const ['face'],
  child: InkWell(
    statesController: states,
    onTap: _start,
    child: SpriteStudioStateView(
      player: _player,
      statesController: states,
      semanticLabel: 'スタート',
    ),
  ),
)
```

ビューにはボタンが受け取る `statesController` を渡します。`InkWell` とすべての `ButtonStyleButton`（`ElevatedButton`・`FilledButton` など）が受け取れます。役割・ジェスチャー・フォーカスはボタンが持ったままで、ビューは描くだけです。

## 状態の作り方

1 つのアニメに、状態と同じ名前のラベルを置きます。`normal`・`hover`・`pressed`・`disabled`・`focused` で、小文字の完全一致です。状態はそのラベルのフレームから、次のラベルの 1 フレーム手前まで（次が無ければアニメの最後まで）をループ再生します。

| ボタンの状態（`WidgetState`） | 再生するラベル | そのラベルが無いとき |
|---|---|---|
| 下のどれでもない | `normal` | アニメ全体 |
| `hovered` | `hover` | `normal` |
| `pressed` | `pressed` | `hover`、それも無ければ `normal` |
| `disabled` | `disabled` | `normal` |
| `focused` | `focused` | `normal` |

いくつかが同時に立ったときは、`disabled`・`pressed`・`hover`・`focused` の順で 1 つを見せ、どれも立っていなければ `normal` です。`selected` などほかの `WidgetState` は読みません。切り替えは即時で、新しい区間をその先頭フレームから再生し、再生途中の区間は捨てます。

ラベルを読むのはプレイヤーが選んでいるアニメです。`animationName:` を付けて読み込むか、`animation:` で別のアニメを指定してください。

## 既存のアニメを使う

`clips` で状態のラベルを置き換えられます。その状態に落ちてくるほかの状態も置き換え先を使います。

```dart
SpriteStudioStateView(
  player: _player,
  statesController: states,
  clips: const {
    SsUiState.normal: SsUiClip(animation: 'idle'),                 // アニメ全体
    SsUiState.hover: SsUiClip(label: 'over'),                      // そのアニメのラベル
    SsUiState.pressed: SsUiClip(animation: 'push', label: 'down'), // 別のアニメのラベル
  },
)
```

clip で指定した区間も、次のラベルの 1 フレーム手前までです。パックに無いアニメやラベルを指定した clip はログに 1 度だけ書かれ、その状態は clip が無いものとして再生されます。

## Reduced motion

`reducedMotion` を渡さなければ、プラットフォームの設定（`MediaQuery.disableAnimationsOf`）に従います。オンの間は各状態が区間の先頭フレームで止まり、ユーザーデータ・シグナル・サウンドのイベントは出ません。

アニメに `reduced_motion` ラベルがあれば、`normal`（と `normal` に落ちてくる状態）は代わりにその区間をイベント付きでループ再生します。止まった待機の代わりに、穏やかな待機を見せられます。

## 絵の上だけでポインタを受ける

ボタンは子が何を返しても箱全体でポインタを受けるので、判定を絞るものは**ボタンの外側**に置きます。`SpriteStudioHitRegion` は、プレイヤーが `parts` のどれか（`parts` が null ならどれかのパーツ）を描いている所でだけ、タップと hover を通します。下にあるそのプレイヤーのビューを見つけて点をその座標に変換するので、`ElevatedButton` のパディングがあってもずれません。

パーツの範囲は描かれているとおりの輪郭です。[パーツの輪郭](part-following.md#パーツの輪郭)を参照してください。絞るのはポインタだけで、キーボードのフォーカスとスクリーンリーダーからの操作はこれまでどおりボタンに届きます。

## スクリーンリーダー

`semanticLabel` が無ければビューは装飾で、セマンティクスツリーに何も足しません。渡すと、`Image.semanticLabel` と同じくそのラベルの画像として読まれます。役割と操作はボタンのものです。

## プレイヤー

ビューは表示されている間、プレイヤーの再生を引き受けます。アニメの選択、区間とループ回数の設定、再生と停止を行います。`SpriteStudioView` と同じく、ビューごとに別のプレイヤーを渡してください。プレイヤーはいつもどおり読み込めば、パックが入った時点で、またリロードの後にも、ビューが状態を見せます。

ウィジェットを使わないコードには、同じ規則を持つ `SsUiStateDriver` があります。

```dart
final driver = SsUiStateDriver(player);
driver.show(SsUiState.of(hovered: true));
driver.show(SsUiState.normal, reducedMotion: true);
```

## 関連

- [パーツトラッキング](part-following.md) —— ヒット判定に使う輪郭と、その隣の姿勢の読み取り
- [再生とイベント](playback.md) —— 再生区間（フレーム指定とラベル指定）
