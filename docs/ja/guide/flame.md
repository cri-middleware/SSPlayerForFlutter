# 🔥 Flame 連携

[`ssplayer_flame`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/packages/ssplayer_flame)
パッケージは `SpriteStudioComponent` を追加します —— `FlameGame` の中で SpriteStudio アニメを再生する
`PositionComponent` です。**外部クロック**の `SpriteStudioPlayer`（`Ticker` なし）を内部に持ち、Flame
のゲームループが時間を駆動します（`update(dt)` → `advance`、`render` → paint）。コアが `flame` を
巻き込まないよう別パッケージになっており、`ssplayer_flutter` の API 全体を re-export します。

[Flame デモ](../../demo/flame/) は `examples/flame` を Web 向けにビルドしたものです —— このページの
コードがそのまま動いています。

## 依存を追加する

[インストール](install.md) と同じ GitHub Releases バンドルから `ssplayer_flame` を追加します。

```yaml
dependencies:
  ssplayer_flame:
    path: vendor/SSPlayerForFlutter/packages/ssplayer_flame
```

## ゲームにコンポーネントを追加する

```dart
class RingoGame extends FlameGame {
  @override
  Future<void> onLoad() async {
    add(
      SpriteStudioComponent.asset(
        // reference テクスチャはキー自身のフォルダから解決します（embedded も同じ）。
        'assets/overall/Basic.ssab',
        position: Vector2(200, 200),
        anchor: Anchor.center,
        loopCount: -1,
      ),
    );
  }
}
```

`SpriteStudioComponent.asset(path, …)` は `onLoad` でアセットバンドルから `.ssab` を読み込み、
reference テクスチャをキー自身のフォルダから解決します。すでに手元にあるバイト列を再生する場合は、
既定コンストラクタ `SpriteStudioComponent(ssab: myBytes)` を使います。

## 主なコンストラクタ引数

| 引数 | 既定 | 説明 |
|---|---|---|
| `animation` | パック先頭 | 読み込み時に選択するアニメ |
| `loopCount` | `-1` | ループ回数（`-1` 無限、`n` は n 回） |
| `speed` | `1.0` | 再生速度倍率 |
| `subFrame` | `true` | サブフレーム補間 |
| `autoStart` | `true` | 読み込み完了と同時に再生（`false` で自分で駆動） |
| `onEvents` / `onAnimationStarted` / `onAnimationFinished` / `onAnimationLooped` | `null` | プレイヤーのコールバックへ転送（[再生とイベント](playback.md)） |

`PositionComponent` の標準フィールド（`position`・`size`・`scale`・`angle`・`anchor`・`priority`）も
通常どおり使えます。

## 再生を制御する

`onLoad` 後は `component.player` から L3 トランスポート一式にアクセスできます。

```dart
component.player?..setAnimation('attack')..play();
```

クロックは Flame 側なので `Ticker` はありません —— トランスポート状態はプレイヤーが保持します。

完全な `FlameGame` の例は
[`examples/flame/`](https://github.com/cri-middleware/SSPlayerForFlutter/tree/main/examples/flame)
を参照してください。
