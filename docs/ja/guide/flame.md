# 🔥 Flame 連携

[`ssplayer_flame`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flame)
パッケージは `SpriteStudioComponent` を追加します —— `FlameGame` の中で SpriteStudio アニメを再生する
`PositionComponent` です。**外部クロック**の `SpriteStudioPlayer`（`Ticker` なし）を内部に持ち、Flame
のゲームループが時間を駆動します（`update(dt)` → `advance`、`render` → paint）。コアが `flame` を巻き込まないよう別パッケージになっており、`ssplayer_flutter` の API 全体を re-export します。

[Flame デモ](../../demo/flame/) は `examples/flame` を Web 向けにビルドしたものです。`SpriteStudioComponent` 1 つで Ringo を再生し、タップで再生 / 一時停止します。

## 依存を追加する

```bash
flutter pub add flame ssplayer_flame
```

`ssplayer_flutter` と `ssruntime_dart` は `ssplayer_flame` と一緒に入ります。そのほかの準備は[インストール](install.md)にあります。

## ゲームにコンポーネントを追加する

```dart
class RingoGame extends FlameGame {
  @override
  Future<void> onLoad() async {
    add(
      SpriteStudioComponent.asset(
        // reference テクスチャはキー自身のフォルダから解決します（embedded も同じ）。
        'assets/spritestudio/Ringo/Ringo.ssab',
        animation: 'wait1',
        position: Vector2(200, 200),
        anchor: Anchor.center,
        loopCount: -1,
      ),
    );
  }
}
```

`SpriteStudioComponent.asset(path, …)` は `onLoad` でアセットバンドルから `.ssab` を読み込み、
reference テクスチャをキー自身のフォルダから解決します。すでに手元にあるバイト列を再生する場合は、既定コンストラクタを使います: `SpriteStudioComponent(ssab: myBytes, baseAssetDir: 'assets/spritestudio/Ringo')`。バイト列にはアセットキーが無いので、`baseAssetDir` で兄弟の reference テクスチャがあるアセットのフォルダを指定します（embedded のパックには不要です）。

## 主なコンストラクタ引数

| 引数 | 既定 | 説明 |
|---|---|---|
| `animation` | パック先頭 | 読み込み時に選択するアニメ |
| `loopCount` | `-1` | ループ回数（`-1` 無限、`n` は n 回） |
| `speed` | `1.0` | 再生速度倍率 |
| `subFrame` | `true` | サブフレーム補間 |
| `autoStart` | `true` | 読み込み完了と同時に再生（`false` で自分で駆動） |
| `onEvents` / `onAnimationStarted` / `onAnimationFinished` / `onAnimationLooped` | `null` | プレイヤーのコールバックへ転送（[再生とイベント](playback.md)） |

`position`・`scale`・`angle`・`anchor`・`priority` は通常の `PositionComponent` と同じです。`size` は拡大縮小ではなく、アニメを描く箱の大きさです。アニメの原点は箱の中心（`size / 2`）に置かれ、`size` が既定のゼロのあいだは `position` に置かれます。`flutter_gpu` バックエンドでは箱が描画枠でもあり、外側は切り取られるので、明示する `size` は原点の周りの全方向に余白を取って絵が収まる大きさにしてください（作者のキャンバスの縦横それぞれ 2 倍が出発点になります）。`anchor` は箱の位置を動かすだけなので、`Anchor.center` が効くのは `size` を与えたときです。

## ボタン

`SpriteStudioButtonComponent` は、ボタンになった `SpriteStudioComponent` です。Flutter のウィジェットと同じ規則で、1 つのアニメがボタンの状態を見せます。状態と同じ名前のラベル、その落とし先、別のアニメやラベルを使う `clips` は[ボタンと UI の状態](buttons.md)を参照してください。

```dart
add(
  SpriteStudioButtonComponent.asset(
    'assets/ui/start.ssab',
    hitParts: const ['face'],
    onReleased: startGame,
    size: Vector2(240, 120),
    position: Vector2(200, 300),
    anchor: Anchor.center,
  ),
);
```

| 状態 | 立てるもの |
|---|---|
| `hover` | ボタンの上のマウス |
| `pressed` | 押したままのタップ |
| `disabled` | `isDisabled` |
| `focused` | `isFocused`。Flame には独自のフォーカスが無いので、ゲームパッドやキーボードで動かすメニューが、選んでいるボタンに立てます |

| 引数 | 既定値 | 説明 |
|---|---|---|
| `onPressed` / `onReleased` / `onCancelled` | `null` | タップが押されたとき・離されたとき・取り消されたとき。Flame の `ButtonComponent` と同じ時機です。無効のボタンはどれも呼びません |
| `hitParts` | `null` | ポインタを受けるパーツ。描かれている輪郭で、箱の中に限って判定します。null なら箱全体 |
| `hitOnArtwork` | `false` | `hitParts` が無いとき、箱全体ではなくどれかのパーツの上でポインタを受ける |
| `clips` | なし | 状態ごとのラベルの置き換え |
| `isDisabled` / `isFocused` / `reducedMotion` | `false` | プロパティでもあり、いつでも変えられます。Flame はプラットフォームの設定を読まないので、`reducedMotion` はゲーム自身が決めます |

アニメは箱の中心を原点として描かれるので、絵が収まる `size` を与えてください。ボタンはプレイヤーの再生を引き受けるので、`loopCount`・`speed`・`autoStart`・`onEvents`・`onAnimation…` の引数はありません。[`examples/flame/lib/button_check.dart`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/examples/flame/lib/button_check.dart) は、ポインタの受け方を変えた 3 つのボタンを動かすアプリです。リポジトリを clone して実行します（`flutter run -t lib/button_check.dart`。準備は[サンプルの README](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/examples/flame/README.md)のとおり）。

## 再生を制御する

`onLoad` の後は、`component.player` から `SpriteStudioPlayer` の全機能（再生制御・イベント・パーツのオーバーライド）に届きます。読み込みが終わるまでは `null` です。

```dart
component.player?..setAnimation('attack')..play();
```

クロックは Flame 側なので `Ticker` はありません —— トランスポート状態はプレイヤーが保持します。

読み込みに失敗しても（アセットキーの誤り、壊れた `.ssab`）例外は投げられません。コンポーネントは何も描かず、`player` は `null` のままで、エラーは `component.loadError` に入り、`FlutterError.onError` にも届きます。

## 解放する

コンポーネントは、ツリーから外されたときにネイティブのランタイムコンテキストとデコード済みテクスチャを解放し、付け直すと読み込み直します。`GameWidget` を破棄しても（ルートを戻る、ウィジェットを作り直す）コンポーネントは外されないので、ゲーム側で解放してください。ゲームは `build` の中で作らず、`State` のフィールドに持ちます。

```dart
class RingoGame extends FlameGame {
  // …onLoad は上のとおり…
  @override
  void onDispose() {
    dispose(); // 子を外し、各コンポーネントのプレイヤーを解放する
    super.onDispose();
  }
}
```

上の `RingoGame` がゲームのすべてです。[`examples/flame/`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/flame) は、同じものをリポジトリを clone して実行できるアプリにしたものです。
