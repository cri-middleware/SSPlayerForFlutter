# 🔥 Flame 連携

[`ssplayer_flame`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flame)
パッケージは `SpriteStudioComponent` を追加します —— `FlameGame` の中で SpriteStudio アニメを再生する
`PositionComponent` です。**外部クロック**の `SpriteStudioPlayer`（`Ticker` なし）を内部に持ち、Flame
のゲームループが時間を駆動します（`update(dt)` → `advance`、`render` → paint）。コアが `flame` を巻き込まないよう別パッケージになっており、`ssplayer_flutter` の API 全体を re-export します。

[Flame デモ](../../demo/flame/) は `examples/flame` を Web 向けにビルドしたものです —— このページのコードがそのまま動いています。

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
reference テクスチャをキー自身のフォルダから解決します。すでに手元にあるバイト列を再生する場合は、既定コンストラクタ `SpriteStudioComponent(ssab: myBytes)` を使います。

## 主なコンストラクタ引数

| 引数 | 既定 | 説明 |
|---|---|---|
| `animation` | パック先頭 | 読み込み時に選択するアニメ |
| `loopCount` | `-1` | ループ回数（`-1` 無限、`n` は n 回） |
| `speed` | `1.0` | 再生速度倍率 |
| `subFrame` | `true` | サブフレーム補間 |
| `autoStart` | `true` | 読み込み完了と同時に再生（`false` で自分で駆動） |
| `onEvents` / `onAnimationStarted` / `onAnimationFinished` / `onAnimationLooped` | `null` | プレイヤーのコールバックへ転送（[再生とイベント](playback.md)） |

`PositionComponent` の標準フィールド（`position`・`size`・`scale`・`angle`・`anchor`・`priority`）も通常どおり使えます。

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

アニメは箱の中心を原点として描かれるので、絵が収まる `size` を与えてください。ボタンはプレイヤーの再生を引き受けるので、`loopCount`・`speed`・`autoStart` の引数はありません。[`examples/flame/lib/button_check.dart`](https://github.com/cri-middleware/SSPlayerForFlutter/blob/main/examples/flame/lib/button_check.dart) で、ポインタの受け方を変えた 3 つを動かせます。

## 再生を制御する

`onLoad` 後は `component.player` から L3 トランスポート一式にアクセスできます。

```dart
component.player?..setAnimation('attack')..play();
```

クロックは Flame 側なので `Ticker` はありません —— トランスポート状態はプレイヤーが保持します。

完全な `FlameGame` の例は
[`examples/flame/`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/flame)
を参照してください。
