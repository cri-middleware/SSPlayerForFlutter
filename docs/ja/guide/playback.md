# ▶️ 再生とイベント

`SpriteStudioPlayer` は直感的なトランスポートとイベントコールバックを備え、アプリのロジックにそのまま組み込めます。ここでは再生制御・アニメ切り替え・イベント処理を扱います。

以下のコードの `_player` は `SpriteStudioPlayer` です。自分で持つもの（[クイックスタート](quickstart.md#プレイヤーを自分で持つ場合)）か、`SpriteStudioAnimation` が `onPlayerCreated` で渡すものを使います。

## 再生制御

```dart
_player.setAnimation('attack'); // アニメを選択（先頭フレームで待機）
_player.play();                    // 先頭から再生
```

| メンバー | 種別 | 説明 |
|---|---|---|
| `play()` | メソッド | 設定済みアニメを先頭から再生 |
| `pause()` / `resume()` | メソッド | 一時停止（現在フレームを保持）/ 保持を解除してその場から続行。どちらも冪等で、`resume()` は**停止中・完了後には何もしません** —— 開始するのは `play()` の役目で、そちらは先頭へ巻き戻します |
| `togglePlayPause()` | メソッド | 再生/一時停止ボタン 1 つ分。進行中なら一時停止、保持中なら再開、停止中・完了後なら `play()` で先頭から |
| `stop()` | メソッド | 再生を停止。再生ヘッドは **その場に留まり**、巻き戻りません（停止したフレームを描画し続けます）。先頭に戻すのは `play()` です |
| `seek(double frame)` | メソッド | 任意フレームへジャンプ（小数可）。独立再生のインスタンス / エフェクトは追従しません |
| `loopCount` | `int` | ループ回数 —— `-1`（または `0`）で無限、`n` で n 回 |
| `speedScale` | `double` | 再生速度倍率。`0` と負値は逆再生ではなく**再生ヘッドの停止**です —— 向きを変えるのは `setPlaybackDirection` の役目 |
| `frameRate` | `int` | 進行レート（fps）。上書きしなければパックに設定された値 |
| `setPlaybackDirection(dir, style)` | メソッド | 再生方向（`SsPlaybackDirection.forward` / `.backward`）と終端での挙動（`SsPlaybackStyle.normal` / `.pingPong`） |
| `playbackDirection` / `playbackStyle` | 読取 | 上記 2 つの現在値 |
| `setAnimationSection(start, end)` | メソッド | **現在の**アニメの再生範囲をフレーム区間で限定する。終わりが始まりより前なら `false` を返し、何も変えない |
| `setAnimationSectionByLabel(start, end, {startOffset, endOffset})` | メソッド | 同じことを、現在のアニメのラベルで両端を指定して行う |
| `frameSkipEnabled` | `bool` | ON（既定）はフレームを落として実時間に追従、OFF は 1 ティックにつき厳密に 1 フレーム進む |
| `subFrameEnabled` | `bool` | サブフレーム補間（既定オン） |
| `isPlaying` / `isPausing` | `bool`（読取） | `isPlaying` は `play()` から停止・完了までが `true` で、**一時停止中も `true`** です。`isPausing` は保持中だけ `true`。「いま進んでいる」は `isPlaying && !isPausing` です |
| `isFinished` / `justLooped` | `bool`（読取） | 全ループを再生し終えた（sticky）/ 直前の進行でループ境界を跨いだ（エッジ） |
| `isPlayingForward` | `bool`（読取） | 再生ヘッドが**実際に**どちら向きに進んでいるか。設定値である `playbackDirection` とは別物で、ピンポンの戻りでは `playbackDirection` が `forward` のままこちらは `false` になります。**音声はこれで抑止してください** |
| `frameNo` / `currentAnimation` | 読取 | 現在フレーム / track 0 が再生しているアニメ名。[クロスフェード](motion-blending.md)では呼んだ時点で入ってくる側の名前になります |
| `startFrame` / `endFrame` / `totalFrames` | `int`（読取） | 再生対象のフレーム区間とその長さ。`totalFrames` はスクラバに渡す用 |

### `setAnimation` をまたいで残るもの

アニメをセットアップすると、ランタイムでリセットされるのは再生区間とループ回数の 2 つです。速度・フレームレートの上書き・フレームスキップ・再生方向とスタイルはランタイムで保たれ、ループ回数はプレイヤーが戻します。そのため**あなたが決めた設定**は残り、**アニメ自身を表す設定**だけがリセットされます。

| 残る | リセットされる |
|---|---|
| `loopCount` / `speedScale` / `frameSkipEnabled` / `frameRate` / `playbackDirection`・`playbackStyle` / `subFrameEnabled` | 再生区間 |

再生区間は別のアニメでは意味を持たないフレーム番号の範囲です。持ち越すと、いま選んだアニメの設定を黙って上書きしてしまいます。必要ならセットアップのたびに設定し直してください。特に区間を
`setAnimation` の**前**に設定しても消えてしまう点に注意してください。

`frameRate` の上書きも遷移を跨いで残るので、各アニメの authored 値に戻したいときは `0` を渡してクリアしてください。authored 値そのものを置き換えずに再生を伸縮させたいだけなら、`frameRate` ではなく `speedScale` を使います。

### 逆再生と往復再生

```dart
_player.setPlaybackDirection(SsPlaybackDirection.backward, SsPlaybackStyle.pingPong);
```

`pingPong` では 1 ループが**往復 1 回**なので、`loopCount = 1` で行って戻って終わりです。`speedScale` に負の値を渡しても逆再生にはならず（再生ヘッドが停止します）、向きを変えるのは `playbackDirection` です。こちらはセットアップをまたいで残ります。

### アニメの一部だけ再生する

```dart
_player.setAnimation('attack');
_player.setAnimationSection(10, 24);   // setup の後で。前だと消える
_player..loopCount = -1..play();            // 10〜24 の範囲でループ
```

`startFrame` / `endFrame` / `totalFrames` は区間を反映するので、それらに紐づけたスクラバもそのまま追従します。

範囲外の値（`-1` など）を渡すと、その側はアニメの端になります。両端ともアニメの範囲内で終わりが始まりより前なら受け付けません。`setAnimationSection` は `false` を返してログに 1 度だけ書き、区間も再生ヘッドも変えません。

両端はラベルでも指定できます。それぞれにフレーム単位のオフセットを足せます。

```dart
_player.setAnimation('attack');
_player.setAnimationSectionByLabel('windup', 'hit', endOffset: -1); // `hit` の 1 フレーム手前まで
```

`_start` と `_end` は SpriteStudio と同じくアニメの先頭と最後のフレームを指します。アニメに無いラベルを渡したときと、ラベルとオフセットから出たフレームが `setAnimationSection` の受け付けない区間になったときは、`false` を返してログに 1 度だけ書き、区間は変えません。

## 反転・オフセット・スケール

プレイヤーが**描くもの**だけを反転・移動・拡大縮小できます。ウィジェットツリーには一切触れません。

| プロパティ | 型 | 説明 |
|---|---|---|
| `flipX` | `bool` | 描画を左右反転（Flutter 自身の `Transform.flip(flipX: …)` と同じ考え方） |
| `flipY` | `bool` | 描画を上下反転 |
| `offset` | `Offset` | 描画を論理ピクセル単位でずらす。反転の**後**に適用されるため、オフセット自身は反転しません |
| `scale` | `double` | 描画を原点まわりに拡大縮小。フィット付きのビューでは、フィットの倍率を置き換えず掛け合わせます |
| `rootTransform` | `SsRootTransform` | 上記 4 つをまとめた値。複数を同時に変えるときはこちらへ代入すれば再描画は 1 回で済みます |

```dart
// 進行方向を向く
_player.flipX = velocity.dx < 0;
```

インスタンスパーツの子アニメーションを含むツリー全体に適用され、`reload()` をまたいでも保持されます。変更するとリスナーへ通知されるため、ビューは自動で再描画されます。

!!! question "`Transform.flip` でビューを包むのとの違い"
    包む方法は、包んだサブツリー**全体**を反転します。[パーツトラッキング](part-following.md) を併用していると、これが問題になります。

    | やり方 | 結果 |
    |---|---|
    | `Stack` 全体を `Transform.flip` で包む | アンカーした子ウィジェット（アイコンや文字）まで鏡像になる |
    | `SpriteStudioView` だけを包む | アンカーが反転前の位置に取り残される |
    | **`player.flipX`** | アニメーションが反転し、アンカーも一緒に移動する。子ウィジェット自身は正立させたままにもできる |

    パーツトラッキングを使っていないなら `Transform.flip` で包む方法で十分です。

    反転したプレイヤーにウィジェットを追従させるときの詳細は
    [パーツトラッキング](part-following.md) を参照してください。

!!! note "Flame アダプタでは"
    `SpriteStudioComponent` は Flame の `PositionComponent` として `flipHorizontally()` などを既に持つため、反転用の引数は持ちません。

## アニメを切り替える

`setAnimation(name)` はアニメを選択して**先頭フレームで待機**します —— 再生は開始しません。

ランタイムのトランスポートはリセットされますが、`SpriteStudioPlayer` は**あなたが設定した `loopCount` / `speedScale` を覚えていて再適用**するので、アニメを切り替えるたびに設定し直す必要はありません（「`setAnimation` をまたいで残るもの」の表のとおり）。

```dart
_player.setAnimation('walk');
_player..loopCount = 3..speedScale = 1.5..play();
```

すでに選択中のアニメを指定しても何も起きません —— 再生ヘッド・区間・パーツオーバーライドはそのままなので、ステートマシンが毎フレーム現在のクリップを指定しても安全です。最初からやり直すなら `play()` を呼びます。パックに無い名前を渡すと `setAnimation` は `false` を返し、ログに 1 度だけ書きます。

利用可能なアニメ名は `animationNames`（または `SsAnimeInfo(bytes).animationNames`）で取得します。

切り替えずにフェードでつなぐ、あるアニメの上に別のアニメを重ねる、といったことは[モーションブレンド](motion-blending.md)を参照してください。`setAnimation` はその重ねたトラックを track 0 だけに戻します。

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
| `onAnimationStarted` | `VoidCallback` | 再生が**始まった**とき。自分のコードからの `play()` に限らず、autoplay ラッパーやホストのステートマシンが呼んだものも含みます。`resume()` では発火しません（一時停止の解除は続行であって開始ではないため） |
| `onAnimationFinished` | `VoidCallback` | 設定したループを全て再生し終えたとき。`loopCount` が無限のときは**発火せず**、`stop()` でも発火しない |
| `onAnimationLooped` | `VoidCallback` | ループ境界を跨いだとき（最終周は代わりに `onAnimationFinished` が発火） |
| `onEvents` | `void Function(List<int> passedEventIndices)` | 低レベルの逃げ道。デコード前の生の index がそのフレーム分だけ渡される |

通常はデコード済みの `onUserData` / `onSignal` / `onAudio` を使ってください。`onEvents` が渡すのは index だけで、デコードは呼び出し側の仕事になります。index は**それを発火したアニメ**のイベントテーブルを指し、track 0 を[クロスフェード](motion-blending.md)した後は `setAnimation` で選んだアニメとは限りません。デコード済みのコールバックは、イベントごとに正しいテーブルで引きます。デコードは 3 つのデコード済みコールバックがどれも未設定なら丸ごとスキップされるので、`onEvents` だけを登録しても余計なコストはかかりません。

デコード済みの 3 つはいずれも `partIndex` / `partName` / `frameNo` / `source` を持ちます。`frameNo` はキーが**置かれている** フレームであって、検出されたフレームとは限りません。1 回の `advance` で複数フレームをまたぐことがあり、その間のキーはすべてそこで発火するため、プレイヤーの現在フレームとは一致しません。`source` は発火した[ソース](motion-blending.md#sources)のハンドルです。既定では track 0 のアニメだけが発火するので、オーバーレイやクロスフェードの出ていく側にも発火させない限り `trackMainSource(0)` になります。

### 例: ユーザーデータを受け取る

```dart
_player.onUserData = (userData) {
  // SpriteStudio で設定した項目（integer / rect / point / string）だけが非 null になります。
  if (userData.string == 'footstep') _audio.play();
};
```

### 例: シグナルを受け取る

```dart
_player.onSignal = (signal) {
  if (signal.commandId != 'spawn') return;
  for (final p in signal.params) {           // 作者が置いた順
    if (p.paramId == 'count' && p.value is int) _spawn(p.value as int);
  }
};
```

### 例: オーディオトリガを鳴らす

SpriteStudio のオーディオはトリガのみです。プレイヤーは「鳴らすべき音」を渡すだけで、オーディオスタックには関与しません。ハッシュをパック相対パスに解決して、お使いの再生手段に渡してください。

**`isPlayingForward` で抑止してください。** SpriteStudio に逆再生の音声は無いので、逆向きに進んでいる最中に通過したキーは鳴らすべきものではありません。自前のオーディオバックエンドを持つプレイヤーはこの判定を自分で行いますが、こちらは再生せず通知するだけなので `onAudio` はどちらでも発火します。判定はあなたの側の仕事です。

```dart
_player.onAudio = (audio) {
  if (!_player.isPlayingForward) return; // 逆再生の音声は無い
  final path = _player.soundFilePath(audio.soundNameHash); // 例: "sound/foo.mp3"
  if (path != null) _audio.play(path, times: audio.loopNum);
};
```

`isPlayingForward` は*瞬間の*向きです。`playbackDirection` ではなくこちらで判定するのはそのためで、
`SsPlaybackStyle.pingPong` の戻りでは `playbackDirection` が `forward` のまま実際には逆向きに進んでいます。再生前は `true` なので、このゲートが初回フレームを取りこぼすことはありません。

### 例: アニメを連結する

```dart
_player.onAnimationFinished = () {
  if (_player.currentAnimation == 'attack') {
    _player.setAnimation('idle');
    _player..loopCount = -1..play();
  }
};
```

## パーツへのウィジェット追従

指定パーツの位置・回転・スケールにウィジェットを毎フレーム追従させる、あるいはその瞬間の姿勢だけを読み取るには、[パーツトラッキング](part-following.md) を参照してください。

## パーツ単位の上書き

特定のパーツだけを、キーフレームより優先して別の色 / セル / 非表示にするには、
[パーツオーバーライド](part-overrides.md) を参照してください。

## 開発中のライブ更新

再エクスポートした `.ssab` をトランスポート状態を保ったまま差し替えるには、
[ライブリロード](live-reload.md) を参照してください。
