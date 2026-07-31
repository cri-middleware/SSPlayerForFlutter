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
| `frameRate` | `int` | 進行レート（fps）。上書きしなければパックに設定された値 |
| `subFrame` | `bool` | サブフレーム補間（既定オン） |
| `isPlaying` / `isPaused` | `bool`（読取） | 現在のトランスポート状態 |
| `isFinished` / `isLooped` | `bool`（読取） | 全ループを再生し終えた（sticky）/ 直前の進行でループ境界を跨いだ（エッジ） |
| `frameNo` / `currentAnimation` | 読取 | 現在フレーム / 再生中のアニメ名 |
| `startFrame` / `endFrame` / `totalFrames` | `int`（読取） | 再生対象のフレーム区間とその長さ。`totalFrames` はスクラバに渡す用 |

!!! note "`frameRate` は `setupAnimation` をまたいで復元されない"
    `loop` / `speed` はセットアップ後に自動で再適用されますが、`frameRate` は意図的にしていません。
    Brain はそこでパックに設定された fps を読み直すので、ホスト側の上書きを重ねると
    アニメの設定値を黙って上書きしてしまうためです。維持したい場合はセットアップのたびに
    再設定してください。設定値に触れずに再生を伸縮させたいだけなら `speed` を使います。

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
| `onUserData` | `void Function(SsUserData)` | タイムラインの**ユーザーデータ**を通過したとき。1 件につき 1 回 |
| `onSignal` | `void Function(SsSignal)` | 有効な**シグナル**キーフレームを通過したとき。無効なシグナルは通知されない |
| `onAudio` | `void Function(SsAudioEvent)` | **オーディオ**トリガを通過したとき。プレイヤー自身は音を鳴らさない（下記参照） |
| `onComplete` | `VoidCallback` | 設定したループを全て再生し終えたとき。`loop` が無限のときは**発火せず**、`stop()` でも発火しない |
| `onLoop` | `VoidCallback` | ループ境界を跨いだとき（最終周は代わりに `onComplete` が発火） |
| `onEvents` | `void Function(List<int> passedEventIndices)` | 低レベルの逃げ道。デコード前の生の index がそのフレーム分だけ渡される |

通常はデコード済みの `onUserData` / `onSignal` / `onAudio` を使ってください。`onEvents` が渡すのは
現在のアニメのイベントテーブルへの index で、デコードは呼び出し側の仕事になります。デコードは
3 つのデコード済みコールバックがどれも未設定なら丸ごとスキップされるので、`onEvents` だけを
登録しても余計なコストはかかりません。

### 例: ユーザーデータを受け取る

```dart
_player.onUserData = (userData) {
  // SpriteStudio で設定した項目だけが非 null になります。
  if (userData.string == 'footstep') _audio.play();
};
```

### 例: オーディオトリガを鳴らす

SpriteStudio のオーディオはトリガのみです。プレイヤーは「鳴らすべき音」を渡すだけで、
オーディオスタックには関与しません。ハッシュをパック相対パスに解決して、お使いの再生手段に渡してください。

```dart
_player.onAudio = (audio) {
  final path = _player.soundFilePath(audio.soundNameHash); // 例: "sound/foo.mp3"
  if (path != null) _audio.play(path, times: audio.loopNum);
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

## パーツへのウィジェット追従

指定パーツの位置・回転・スケールにウィジェットを毎フレーム追従させる、あるいはその瞬間の姿勢だけを
読み取るには、[パーツトラッキング](part-following.md) を参照してください。

## パーツ単位の上書き

特定のパーツだけを、キーフレームより優先して別の色 / セル / 非表示にするには、
[パーツオーバーライド](part-overrides.md) を参照してください。

## 開発中のライブ更新

再エクスポートした `.ssab` をトランスポート状態を保ったまま差し替えるには、
[ライブリロード](live-reload.md) を参照してください。
