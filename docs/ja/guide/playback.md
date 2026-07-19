# 再生とイベント

`SpriteStudioPlayer` は直感的なトランスポートとイベントコールバックを備え、アプリのロジックに
そのまま組み込めます。ここでは再生制御・アニメ切り替え・イベント処理を扱います。

## 再生制御

```dart
_player.setupAnimation('attack'); // アニメを選択（先頭フレームで待機）
_player.play();                    // 先頭から再生
```

| メンバー | 種別 | 説明 |
|---|---|---|
| `play()` | メソッド | 設定済みアニメを先頭から再生 |
| `pause()` / `resume()` | メソッド | 一時停止（現在フレームを保持）/ 再開 |
| `togglePlayPause()` | メソッド | 再生中なら一時停止、停止中なら再開 |
| `stop()` | メソッド | 再生を停止 |
| `seek(double frame)` | メソッド | 任意フレームへジャンプ（小数可） |
| `loop` | `set int` | ループ回数 —— `-1`（または `0`）で無限、`n` で n 回 |
| `speed` | `set double` | 再生速度倍率（負で逆再生） |
| `subFrame` | `bool` | サブフレーム補間（既定オン） |
| `isPlaying` / `isPaused` | `bool`（読取） | 現在のトランスポート状態 |
| `frameNo` / `currentAnimation` | 読取 | 現在フレーム / 再生中のアニメ名 |

## アニメを切り替える

`setupAnimation(name)` はアニメを選択して**先頭フレームで待機**します —— 再生は開始せず、
**loop / speed をランタイム既定にリセット**します。

!!! warning "`loop` / `speed` は `setupAnimation` の後に設定する"
    `setupAnimation` は巻き戻してトランスポートをリセットするため、後から `loop` / `speed` を
    再設定しないと、ループが暗黙に無限へ戻ってしまいます。

```dart
_player.setupAnimation('walk');
_player..loop = 3..speed = 1.5..play();
```

利用可能なアニメ名は `getAnimations()`（または `SsAnimeInfo(bytes).animationNames`）で取得します。

## クロックの駆動

- **vsync モード** —— `SpriteStudioPlayer(vsync: this)` で生成すると、プレイヤーが自前の `Ticker`
  を回します。これがウィジェット経路です（[クイックスタート](quickstart.md)）。
- **外部クロック** —— `vsync` を省き、毎ティック `advance(delta)` を自分で呼びます。
  [Flame](flame.md) アダプタはこの方式で駆動します。

## イベント

プレイヤーにコールバックを設定します。再生の進行に応じて発火します。

| コールバック | シグネチャ | 発火タイミング |
|---|---|---|
| `onEvents` | `void Function(List<int> passedEventIndices)` | ユーザーデータ／シグナルのあるフレームを通過したとき。イベントの index が渡される |
| `onComplete` | `VoidCallback` | 設定したループを全て再生し終えたとき。`loop` が無限のときは**発火せず**、`stop()` でも発火しない |
| `onLoop` | `VoidCallback` | ループ境界を跨いだとき（最終周は代わりに `onComplete` が発火） |

### 例: ユーザーデータイベントで効果音を鳴らす

```dart
_player.onEvents = (indices) {
  // index はこのフレームで SpriteStudio に設定されたユーザーデータ／シグナルのキーを表します。
  if (indices.contains(footstepEventIndex)) _audio.play();
};
```

### 例: アニメを連結する

```dart
_player.onComplete = () {
  if (_player.currentAnimation == 'attack') {
    _player.setupAnimation('idle');
    _player..loop = -1..play();
  }
};
```

## 開発中のライブ更新

再エクスポートした `.ssab` をトランスポート状態を保ったまま差し替えるには、
[ライブリロード](../customize/live-reload.md) を参照してください。
